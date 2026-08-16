#include "watermark_core.hpp"
#include "image_io.hpp"
#include <csignal>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <ctime>
#include <memory>
#include <string>
#ifndef _WIN32
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/syscall.h>
#include <ucontext.h>
#include <unistd.h>
#endif

// Error codes
#define BWM_OK 0
#define BWM_ERROR_INVALID_HANDLE -1
#define BWM_ERROR_FILE_NOT_FOUND -2
#define BWM_ERROR_INVALID_IMAGE -3
#define BWM_ERROR_EMBED_FAILED -4
#define BWM_ERROR_EXTRACT_FAILED -5
#define BWM_ERROR_INVALID_PARAMS -6
#define BWM_ERROR_UNKNOWN -99

namespace {

// ---------------------------------------------------------------------------
// Crash capture: native faults (SIGSEGV/SIGABRT/SIGBUS/SIGFPE) write a marker
// to a file the app reads at next launch and shows to the user. This turns an
// otherwise silent "闪退" into a reportable diagnostic. The handler only does
// open/write/close (async-signal-safe in practice) and re-raises so the
// system still produces its own tombstone.
// ---------------------------------------------------------------------------
char g_crash_log[1024] = {0};

#ifndef _WIN32
void crash_handler(int sig, siginfo_t* /*si*/, void* uc) {
    // Async-signal-safe ONLY: open/write/close/snprintf. No dladdr, no
    // malloc — the addresses are resolved by bwm_symbolize() at next launch
    // (normal context), where dladdr is safe.
    if (g_crash_log[0] != 0) {
        int fd = open(g_crash_log, O_WRONLY | O_CREAT | O_APPEND, 0600);
        if (fd >= 0) {
            char buf[512];
            // PC/LR from the crash site (signal handler runs on the faulting
            // thread; ucontext carries its registers).
            uintptr_t pc = 0, lr = 0, fp = 0;
#if defined(__aarch64__)
            ucontext_t* u = static_cast<ucontext_t*>(uc);
            pc = u->uc_mcontext.pc;
            lr = u->uc_mcontext.regs[30];
            fp = u->uc_mcontext.regs[29];
#elif defined(__arm__)
            ucontext_t* u = static_cast<ucontext_t*>(uc);
            pc = u->uc_mcontext.arm_pc;
            lr = u->uc_mcontext.arm_lr;
            fp = u->uc_mcontext.arm_fp;
#elif defined(__x86_64__)
            ucontext_t* u = static_cast<ucontext_t*>(uc);
            pc = static_cast<uintptr_t>(u->uc_mcontext.gregs[REG_RIP]);
            lr = static_cast<uintptr_t>(u->uc_mcontext.gregs[REG_RBP]);
            fp = lr;
#endif
            // Best-effort thread name (/proc/self/task/<tid>/comm).
            char comm[64] = "?";
            char comm_path[128];
            int n = snprintf(comm_path, sizeof(comm_path),
                             "/proc/self/task/%ld/comm",
                             static_cast<long>(syscall(SYS_gettid)));
            if (n > 0 && n < static_cast<int>(sizeof(comm_path))) {
                int cfd = open(comm_path, O_RDONLY);
                if (cfd >= 0) {
                    ssize_t r = read(cfd, comm, sizeof(comm) - 1);
                    if (r > 0) {
                        comm[r] = 0;
                        while (r > 0 && (comm[r - 1] == '\n' || comm[r - 1] == '\r')) {
                            comm[--r] = 0;
                        }
                    }
                    close(cfd);
                }
            }
            n = snprintf(buf, sizeof(buf),
                         "NATIVE CRASH: signal=%d at %lld tid=%ld thread=%s\nPC=0x%llx\nLR=0x%llx\n",
                         sig, static_cast<long long>(time(nullptr)),
                         static_cast<long>(syscall(SYS_gettid)), comm,
                         static_cast<unsigned long long>(pc),
                         static_cast<unsigned long long>(lr));
            write(fd, buf, static_cast<size_t>(n > 0 ? n : 0));

            // Frame-pointer stack walk: PC/LR are both inside abort() itself
            // (abort raises SIGABRT synchronously), so the caller of abort is
            // one frame up. With SIGSEGV/SIGBUS masked (sa_mask), a faulting
            // read leaves the destination unchanged (0) and the guards break
            // the loop, so a corrupt chain cannot recurse.
            // aarch64 frame: [fp+0] = saved fp, [fp+8] = saved lr.
            for (int i = 0; i < 20 && fp > 0x10000; ++i) {
                uintptr_t saved_lr =
                    *reinterpret_cast<const uintptr_t*>(fp + 8);
                uintptr_t saved_fp =
                    *reinterpret_cast<const uintptr_t*>(fp);
                n = snprintf(buf, sizeof(buf), "F%d=0x%llx\n", i,
                             static_cast<unsigned long long>(saved_lr));
                write(fd, buf, static_cast<size_t>(n > 0 ? n : 0));
                if (saved_fp <= fp || saved_fp > fp + 0x400000) break;
                fp = saved_fp;
            }
            close(fd);
        }
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

struct CrashGuard {
    CrashGuard() {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = crash_handler;
        sa.sa_flags = SA_SIGINFO;
        // Block the handled signals while the handler runs: a fault during
        // the frame-pointer walk stays pending instead of recursing, and a
        // faulting read leaves its destination unchanged (0), so the walk
        // guards break cleanly.
        sigemptyset(&sa.sa_mask);
        sigaddset(&sa.sa_mask, SIGSEGV);
        sigaddset(&sa.sa_mask, SIGBUS);
        sigaddset(&sa.sa_mask, SIGABRT);
        sigaddset(&sa.sa_mask, SIGFPE);
        sigaction(SIGSEGV, &sa, nullptr);
        sigaction(SIGABRT, &sa, nullptr);
        sigaction(SIGBUS, &sa, nullptr);
        sigaction(SIGFPE, &sa, nullptr);
        // Default crash log location: the app cache dir when TMPDIR is set
        // (Android sets it per-app), else the app's files dir (fixed package
        // id — the app reads both locations at startup).
        const char* tmp = getenv("TMPDIR");
        if (tmp != nullptr && tmp[0] != 0) {
            snprintf(g_crash_log, sizeof(g_crash_log), "%s/crash.txt", tmp);
        } else {
            snprintf(g_crash_log, sizeof(g_crash_log),
                     "/data/user/0/com.example.flutter_blind_watermark_example/files/crash.txt");
        }
    }
} g_crash_guard;
#endif

}  // namespace

// Handle wrapper
struct BWMHandleData {
    bwm::BlindWatermarkCore* core;
    bwm::Image image;
    std::string lastError;
};

// Ensure symbols are exported
#if defined(_WIN32)
    #define BWM_EXPORT __declspec(dllexport)
#else
    #define BWM_EXPORT __attribute__((visibility("default")))
#endif

extern "C" {

BWM_EXPORT void* bwm_create(int password_wm, int password_img) {
    try {
        bwm::WatermarkConfig config;
        config.passwordWm = password_wm;
        config.passwordImg = password_img;

        auto* handle = new BWMHandleData();
        handle->core = new bwm::BlindWatermarkCore(config);
        return handle;
    } catch (...) {
        return nullptr;
    }
}

BWM_EXPORT void* bwm_create_with_strength(int password_wm, int password_img, float d1, float d2) {
    try {
        bwm::WatermarkConfig config;
        config.passwordWm = password_wm;
        config.passwordImg = password_img;
        config.d1 = d1;
        config.d2 = d2;

        auto* handle = new BWMHandleData();
        handle->core = new bwm::BlindWatermarkCore(config);
        return handle;
    } catch (...) {
        return nullptr;
    }
}

BWM_EXPORT void bwm_destroy(void* handle) {
    if (handle) {
        auto* data = static_cast<BWMHandleData*>(handle);
        delete data->core;
        delete data;
    }
}

BWM_EXPORT int bwm_read_image(void* handle, const char* filename) {
    if (!handle || !filename) return BWM_ERROR_INVALID_PARAMS;

    auto* data = static_cast<BWMHandleData*>(handle);

    try {
        if (!bwm::loadImage(filename, data->image)) {
            data->lastError = "Failed to load image: " + std::string(filename);
            return BWM_ERROR_FILE_NOT_FOUND;
        }
        data->core->setImage(data->image);
        return BWM_OK;
    } catch (const std::exception& e) {
        data->lastError = e.what();
        return BWM_ERROR_INVALID_IMAGE;
    }
}

BWM_EXPORT int bwm_read_image_buffer(void* handle, const uint8_t* buffer, size_t length) {
    if (!handle || !buffer || length == 0) return BWM_ERROR_INVALID_PARAMS;

    auto* data = static_cast<BWMHandleData*>(handle);

    try {
        if (!bwm::loadImageFromMemory(buffer, length, data->image)) {
            data->lastError = "Failed to decode image from buffer";
            return BWM_ERROR_INVALID_IMAGE;
        }
        data->core->setImage(data->image);
        return BWM_OK;
    } catch (const std::exception& e) {
        data->lastError = e.what();
        return BWM_ERROR_INVALID_IMAGE;
    }
}

BWM_EXPORT int bwm_read_watermark_string(void* handle, const char* text) {
    if (!handle || !text) return BWM_ERROR_INVALID_PARAMS;

    auto* data = static_cast<BWMHandleData*>(handle);

    try {
        data->core->setWatermarkText(text);
        return BWM_OK;
    } catch (const std::exception& e) {
        data->lastError = e.what();
        return BWM_ERROR_INVALID_PARAMS;
    }
}

BWM_EXPORT int bwm_read_watermark_image(void* handle, const char* filename) {
    if (!handle || !filename) return BWM_ERROR_INVALID_PARAMS;

    auto* data = static_cast<BWMHandleData*>(handle);

    try {
        bwm::Image wmImage;
        if (!bwm::loadGrayscaleImage(filename, wmImage)) {
            data->lastError = "Failed to load watermark image: " + std::string(filename);
            return BWM_ERROR_FILE_NOT_FOUND;
        }
        data->core->setWatermarkImage(wmImage);
        return BWM_OK;
    } catch (const std::exception& e) {
        data->lastError = e.what();
        return BWM_ERROR_INVALID_IMAGE;
    }
}

BWM_EXPORT int bwm_read_watermark_bits(void* handle, const uint8_t* bits, size_t length) {
    if (!handle || !bits || length == 0) return BWM_ERROR_INVALID_PARAMS;

    auto* data = static_cast<BWMHandleData*>(handle);

    try {
        std::vector<uint8_t> bitVec(bits, bits + length);
        data->core->setWatermarkBits(bitVec);
        return BWM_OK;
    } catch (const std::exception& e) {
        data->lastError = e.what();
        return BWM_ERROR_INVALID_PARAMS;
    }
}

BWM_EXPORT int bwm_embed(void* handle, const char* output_filename) {
    if (!handle || !output_filename) return BWM_ERROR_INVALID_PARAMS;

    auto* data = static_cast<BWMHandleData*>(handle);

    try {
        bwm::Image result = data->core->embed();
        if (!bwm::saveImage(output_filename, result)) {
            data->lastError = "Failed to save image: " + std::string(output_filename);
            return BWM_ERROR_EMBED_FAILED;
        }
        return BWM_OK;
    } catch (const std::exception& e) {
        data->lastError = e.what();
        return BWM_ERROR_EMBED_FAILED;
    }
}

BWM_EXPORT int bwm_embed_to_buffer(void* handle, uint8_t** out_data, size_t* out_length, const char* format) {
    if (!handle || !out_data || !out_length) return BWM_ERROR_INVALID_PARAMS;

    auto* data = static_cast<BWMHandleData*>(handle);

    try {
        bwm::Image result = data->core->embed();

        std::vector<uint8_t> buffer;
        std::string fmt = format ? format : "png";
        if (!bwm::encodeImage(result, fmt, buffer)) {
            data->lastError = "Failed to encode image";
            return BWM_ERROR_EMBED_FAILED;
        }

        *out_data = static_cast<uint8_t*>(malloc(buffer.size()));
        if (!*out_data) {
            return BWM_ERROR_UNKNOWN;
        }
        memcpy(*out_data, buffer.data(), buffer.size());
        *out_length = buffer.size();

        return BWM_OK;
    } catch (const std::exception& e) {
        data->lastError = e.what();
        return BWM_ERROR_EMBED_FAILED;
    }
}

BWM_EXPORT int bwm_extract_string(void* handle, const char* filename, size_t wm_length, char** out_text) {
    if (!handle || !filename || !out_text || wm_length == 0) return BWM_ERROR_INVALID_PARAMS;

    auto* data = static_cast<BWMHandleData*>(handle);

    try {
        bwm::Image img;
        if (!bwm::loadImage(filename, img)) {
            data->lastError = "Failed to load image: " + std::string(filename);
            return BWM_ERROR_FILE_NOT_FOUND;
        }

        std::string text = data->core->extractText(img, wm_length);

        *out_text = static_cast<char*>(malloc(text.size() + 1));
        if (!*out_text) {
            return BWM_ERROR_UNKNOWN;
        }
        memcpy(*out_text, text.c_str(), text.size() + 1);

        return BWM_OK;
    } catch (const std::exception& e) {
        data->lastError = e.what();
        return BWM_ERROR_EXTRACT_FAILED;
    }
}

BWM_EXPORT int bwm_extract_string_buffer(void* handle, const uint8_t* buffer, size_t length,
                                          size_t wm_length, char** out_text) {
    if (!handle || !buffer || length == 0 || !out_text || wm_length == 0) return BWM_ERROR_INVALID_PARAMS;

    auto* data = static_cast<BWMHandleData*>(handle);

    try {
        bwm::Image img;
        if (!bwm::loadImageFromMemory(buffer, length, img)) {
            data->lastError = "Failed to decode image from buffer";
            return BWM_ERROR_INVALID_IMAGE;
        }

        std::string text = data->core->extractText(img, wm_length);

        *out_text = static_cast<char*>(malloc(text.size() + 1));
        if (!*out_text) {
            return BWM_ERROR_UNKNOWN;
        }
        memcpy(*out_text, text.c_str(), text.size() + 1);

        return BWM_OK;
    } catch (const std::exception& e) {
        data->lastError = e.what();
        return BWM_ERROR_EXTRACT_FAILED;
    }
}

BWM_EXPORT int bwm_extract_image(void* handle, const char* filename,
                                  int wm_height, int wm_width, const char* output_filename) {
    if (!handle || !filename || !output_filename || wm_height <= 0 || wm_width <= 0) {
        return BWM_ERROR_INVALID_PARAMS;
    }

    auto* data = static_cast<BWMHandleData*>(handle);

    try {
        bwm::Image img;
        if (!bwm::loadImage(filename, img)) {
            data->lastError = "Failed to load image: " + std::string(filename);
            return BWM_ERROR_FILE_NOT_FOUND;
        }

        bwm::Image wmImage = data->core->extractImage(img, wm_height, wm_width);

        if (!bwm::saveImage(output_filename, wmImage)) {
            data->lastError = "Failed to save watermark image";
            return BWM_ERROR_EXTRACT_FAILED;
        }

        return BWM_OK;
    } catch (const std::exception& e) {
        data->lastError = e.what();
        return BWM_ERROR_EXTRACT_FAILED;
    }
}

BWM_EXPORT int bwm_extract_image_buffer(void* handle, const uint8_t* buffer, size_t length,
                                         int wm_height, int wm_width,
                                         uint8_t** out_data, size_t* out_length) {
    if (!handle || !buffer || length == 0 || !out_data || !out_length ||
        wm_height <= 0 || wm_width <= 0) {
        return BWM_ERROR_INVALID_PARAMS;
    }

    auto* data = static_cast<BWMHandleData*>(handle);

    try {
        bwm::Image img;
        if (!bwm::loadImageFromMemory(buffer, length, img)) {
            data->lastError = "Failed to decode image from buffer";
            return BWM_ERROR_INVALID_IMAGE;
        }

        bwm::Image wmImage = data->core->extractImage(img, wm_height, wm_width);

        std::vector<uint8_t> outBuffer;
        if (!bwm::encodeImage(wmImage, "png", outBuffer)) {
            data->lastError = "Failed to encode watermark image";
            return BWM_ERROR_EXTRACT_FAILED;
        }

        *out_data = static_cast<uint8_t*>(malloc(outBuffer.size()));
        if (!*out_data) {
            return BWM_ERROR_UNKNOWN;
        }
        memcpy(*out_data, outBuffer.data(), outBuffer.size());
        *out_length = outBuffer.size();

        return BWM_OK;
    } catch (const std::exception& e) {
        data->lastError = e.what();
        return BWM_ERROR_EXTRACT_FAILED;
    }
}

BWM_EXPORT int bwm_extract_bits(void* handle, const char* filename, size_t wm_length, uint8_t** out_bits) {
    if (!handle || !filename || !out_bits || wm_length == 0) return BWM_ERROR_INVALID_PARAMS;

    auto* data = static_cast<BWMHandleData*>(handle);

    try {
        bwm::Image img;
        if (!bwm::loadImage(filename, img)) {
            data->lastError = "Failed to load image: " + std::string(filename);
            return BWM_ERROR_FILE_NOT_FOUND;
        }

        std::vector<uint8_t> bits = data->core->extractBits(img, wm_length);

        *out_bits = static_cast<uint8_t*>(malloc(bits.size()));
        if (!*out_bits) {
            return BWM_ERROR_UNKNOWN;
        }
        memcpy(*out_bits, bits.data(), bits.size());

        return BWM_OK;
    } catch (const std::exception& e) {
        data->lastError = e.what();
        return BWM_ERROR_EXTRACT_FAILED;
    }
}

BWM_EXPORT int bwm_extract_bits_buffer(void* handle, const uint8_t* buffer, size_t length,
                                        size_t wm_length, uint8_t** out_bits) {
    if (!handle || !buffer || length == 0 || !out_bits || wm_length == 0) return BWM_ERROR_INVALID_PARAMS;

    auto* data = static_cast<BWMHandleData*>(handle);

    try {
        bwm::Image img;
        if (!bwm::loadImageFromMemory(buffer, length, img)) {
            data->lastError = "Failed to decode image from buffer";
            return BWM_ERROR_INVALID_IMAGE;
        }

        std::vector<uint8_t> bits = data->core->extractBits(img, wm_length);

        *out_bits = static_cast<uint8_t*>(malloc(bits.size()));
        if (!*out_bits) {
            return BWM_ERROR_UNKNOWN;
        }
        memcpy(*out_bits, bits.data(), bits.size());

        return BWM_OK;
    } catch (const std::exception& e) {
        data->lastError = e.what();
        return BWM_ERROR_EXTRACT_FAILED;
    }
}

BWM_EXPORT size_t bwm_get_watermark_size(void* handle) {
    if (!handle) return 0;

    auto* data = static_cast<BWMHandleData*>(handle);
    return data->core->getWatermarkSize();
}

BWM_EXPORT void bwm_free_buffer(void* buffer) {
    free(buffer);
}

BWM_EXPORT void bwm_free_string(char* str) {
    free(str);
}

BWM_EXPORT const char* bwm_get_last_error(void* handle) {
    if (!handle) return "Invalid handle";
    auto* data = static_cast<BWMHandleData*>(handle);
    return data->lastError.empty() ? nullptr : data->lastError.c_str();
}

BWM_EXPORT const char* bwm_get_error_message(int result) {
    switch (result) {
        case BWM_OK: return "Success";
        case BWM_ERROR_INVALID_HANDLE: return "Invalid handle";
        case BWM_ERROR_FILE_NOT_FOUND: return "File not found";
        case BWM_ERROR_INVALID_IMAGE: return "Invalid image";
        case BWM_ERROR_EMBED_FAILED: return "Embed failed";
        case BWM_ERROR_EXTRACT_FAILED: return "Extract failed";
        case BWM_ERROR_INVALID_PARAMS: return "Invalid parameters";
        default: return "Unknown error";
    }
}

BWM_EXPORT const char* bwm_get_version() {
    return "0.0.1";
}

#ifndef _WIN32
// Resolve an address to "module (symbol)" for crash reports. dladdr is NOT
// async-signal-safe, so it is only called from normal context (next launch,
// from Dart) — never from the signal handler.
BWM_EXPORT const char* bwm_symbolize(uintptr_t addr) {
    static thread_local std::string buf;
    buf.clear();
    Dl_info info;
    if (addr != 0 && dladdr(reinterpret_cast<void*>(addr), &info) != 0 &&
        info.dli_fname != nullptr) {
        buf = info.dli_fname;
        if (info.dli_sname != nullptr) {
            buf += " (";
            buf += info.dli_sname;
            buf += ")";
        }
    } else {
        buf = "?";
    }
    return buf.c_str();
}
#endif

} // extern "C"

