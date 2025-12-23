#include "watermark_core.hpp"
#include "image_io.hpp"
#include <cstring>
#include <cstdlib>
#include <memory>
#include <string>

// Error codes
#define BWM_OK 0
#define BWM_ERROR_INVALID_HANDLE -1
#define BWM_ERROR_FILE_NOT_FOUND -2
#define BWM_ERROR_INVALID_IMAGE -3
#define BWM_ERROR_EMBED_FAILED -4
#define BWM_ERROR_EXTRACT_FAILED -5
#define BWM_ERROR_INVALID_PARAMS -6
#define BWM_ERROR_UNKNOWN -99

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

} // extern "C"
