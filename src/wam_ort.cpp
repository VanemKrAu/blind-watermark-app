#include "wam_ort.hpp"

#include <cmath>
#include <cstring>

#include "image_io.hpp"
#include "onnxruntime_c_api.h"

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#if defined(_WIN32)
#define BWM_EXPORT __declspec(dllexport)
#else
#define BWM_EXPORT __attribute__((visibility("default")))
#endif

namespace bwm {

namespace {

// Windows builds use wchar_t model paths (ORTCHAR_T); Android uses char.
std::basic_string<ORTCHAR_T> toOrtChar(const std::string& s) {
#ifdef _WIN32
    std::basic_string<ORTCHAR_T> out;
    out.resize(s.size());
    for (size_t i = 0; i < s.size(); ++i) {
        out[i] = static_cast<ORTCHAR_T>(static_cast<unsigned char>(s[i]));
    }
    return out;
#else
    return s;
#endif
}

constexpr int kImgSize = 256;
constexpr float kMean[3] = {0.485f, 0.456f, 0.406f};
constexpr float kStd[3] = {0.229f, 0.224f, 0.225f};

// WAM checkpoint params (wam_mit.pth / params.json): the watermarked image is
// imgs_w = scaling_i * imgs + scaling_w * preds_w, then JND attenuation, where
// preds_w is the embedder's raw output (a delta in [-1,1]). The embedder ONNX
// exports ONLY preds_w — treating it directly as the output image produces the
// "noise image" bug seen on device.
constexpr float kScalingI = 1.0f;
constexpr float kScalingW = 2.0f;
constexpr float kJndAlpha = 1.0f;   // JND forward() alpha
constexpr float kJndClc = 0.3f;     // JND heatmaps() clc
constexpr float kJndBeta = 0.117f;  // JND jnd_cm() beta
constexpr float kJndEps = 1e-5f;
constexpr bool kJndBlue = true;     // jnd_1_3_blue: R/G channels attenuated half

// Bilinear stretch to 256x256 (dst is 256*256*3 RGB). Same family as
// Bitmap.createScaledBitmap(256,256,true); exact pixel match is not required
// because embed and extract use the same path and the extractor tolerates
// small pixel differences (the app's history match allows <=4 bit errors).
void resizeBilinear(const uint8_t* src, int sw, int sh, uint8_t* dst) {
    const int dw = kImgSize, dh = kImgSize;
    for (int y = 0; y < dh; ++y) {
        float sy = (sh > 1) ? (y * (sh - 1)) / static_cast<float>(dh - 1) : 0.0f;
        int y0 = static_cast<int>(sy);
        int y1 = (y0 < sh - 1) ? y0 + 1 : y0;
        float fy = sy - y0;
        for (int x = 0; x < dw; ++x) {
            float sx = (sw > 1) ? (x * (sw - 1)) / static_cast<float>(dw - 1) : 0.0f;
            int x0 = static_cast<int>(sx);
            int x1 = (x0 < sw - 1) ? x0 + 1 : x0;
            float fx = sx - x0;
            const uint8_t* p00 = src + (static_cast<size_t>(y0) * sw + x0) * 3;
            const uint8_t* p01 = src + (static_cast<size_t>(y0) * sw + x1) * 3;
            const uint8_t* p10 = src + (static_cast<size_t>(y1) * sw + x0) * 3;
            const uint8_t* p11 = src + (static_cast<size_t>(y1) * sw + x1) * 3;
            uint8_t* d = dst + (static_cast<size_t>(y) * dw + x) * 3;
            for (int c = 0; c < 3; ++c) {
                float top = p00[c] + (p01[c] - p00[c]) * fx;
                float bot = p10[c] + (p11[c] - p10[c]) * fx;
                float v = top + (bot - top) * fy;
                d[c] = static_cast<uint8_t>(v < 0 ? 0 : (v > 255 ? 255 : v + 0.5f));
            }
        }
    }
}

// RGB -> normalized CHW float [3,256,256] (matches the previous toTensor).
void toTensorCHW(const uint8_t* rgb, float* out) {
    const int hw = kImgSize * kImgSize;
    for (int i = 0; i < hw; ++i) {
        float r = rgb[i * 3] / 255.0f;
        float g = rgb[i * 3 + 1] / 255.0f;
        float b = rgb[i * 3 + 2] / 255.0f;
        out[i] = (r - kMean[0]) / kStd[0];
        out[i + hw] = (g - kMean[1]) / kStd[1];
        out[i + 2 * hw] = (b - kMean[2]) / kStd[2];
    }
}

// Zero-padded same-size 2D convolution (correlation), matching torch Conv2d
// with padding=k/2 and default zero padding. w/h = image dimensions.
void convSame(const float* in, float* out, int w, int h, const float* k,
              int ksize) {
    const int p = ksize / 2;
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            float acc = 0.0f;
            for (int ky = 0; ky < ksize; ++ky) {
                int sy = y + ky - p;
                if (sy < 0 || sy >= h) continue;
                const float* row = in + sy * w;
                for (int kx = 0; kx < ksize; ++kx) {
                    int sx = x + kx - p;
                    if (sx < 0 || sx >= w) continue;
                    acc += row[sx] * k[ky * ksize + kx];
                }
            }
            out[y * w + x] = acc;
        }
    }
}

// JND (Just Noticeable Difference) attenuation heatmap from a luminance image
// in [0,1]. Port of watermark_anything.modules.jnd.JND.heatmaps with
// in_channels=1 / out_channels=3 / blue=true (config jnd_1_3_blue). Output is
// the per-pixel heatmap in [0,1] that scales how much watermark may be added.
void jndHeatmap(const float* lum01, float* hm, int w, int h) {
    const int hw = w * h;
    std::vector<float> lum255(static_cast<size_t>(hw));
    for (int i = 0; i < hw; ++i) lum255[i] = lum01[i] * 255.0f;

    // 5x5 luminance kernel / 3x3 Sobel kernels (from JND.__init__).
    const float kLum[5 * 5] = {
        1, 1, 1, 1, 1,
        1, 2, 2, 2, 1,
        1, 2, 0, 2, 1,
        1, 2, 2, 2, 1,
        1, 1, 1, 1, 1,
    };
    const float kSx[3 * 3] = {-1, 0, 1, -2, 0, 2, -1, 0, 1};
    const float kSy[3 * 3] = {1, 2, 1, 0, 0, 0, -1, -2, -1};

    std::vector<float> la(static_cast<size_t>(hw));
    std::vector<float> gx(static_cast<size_t>(hw));
    std::vector<float> gy(static_cast<size_t>(hw));
    convSame(lum255.data(), la.data(), w, h, kLum, 5);
    convSame(lum255.data(), gx.data(), w, h, kSx, 3);
    convSame(lum255.data(), gy.data(), w, h, kSy, 3);

    for (int i = 0; i < hw; ++i) {
        // Luminance masking (jnd_la): la = conv_lum/32.
        float lav = la[i] / 32.0f;
        if (lav <= 127.0f) {
            la[i] = 17.0f * (1.0f - std::sqrt(lav / 127.0f + kJndEps));
        } else {
            la[i] = 3.0f / 128.0f * (lav - 127.0f) + 3.0f;
        }
        // Contrast masking (jnd_cm): sqrt(Sobel), then 16*cm^2.4/(cm^2+26^2).
        float cm = std::sqrt(gx[i] * gx[i] + gy[i] * gy[i]);
        cm = 16.0f * std::pow(cm, 2.4f) / (cm * cm + 26.0f * 26.0f);
        cm *= kJndBeta;
        // hmaps = clamp_min(la + cm - clc*min(la, cm), 0), then /255.
        float hh = la[i] + cm - kJndClc * (la[i] < cm ? la[i] : cm);
        hm[i] = (hh > 0.0f ? hh : 0.0f) / 255.0f;
    }
}

// Bilinear resize of a single float channel from (sw,sh) to (dw,dh).
// Used to stretch the 256x256 embedder delta up to the carrier's resolution
// (mirrors the reference Wam.embed() inverse_resize step).
void resizeChannelBilinear(const float* src, int sw, int sh, float* dst,
                           int dw, int dh) {
    for (int y = 0; y < dh; ++y) {
        float sy = (sh > 1) ? (y * (sh - 1)) / static_cast<float>(dh - 1) : 0.0f;
        int y0 = static_cast<int>(sy);
        int y1 = (y0 < sh - 1) ? y0 + 1 : y0;
        float fy = sy - y0;
        for (int x = 0; x < dw; ++x) {
            float sx = (sw > 1) ? (x * (sw - 1)) / static_cast<float>(dw - 1) : 0.0f;
            int x0 = static_cast<int>(sx);
            int x1 = (x0 < sw - 1) ? x0 + 1 : x0;
            float fx = sx - x0;
            const float* r0 = src + y0 * sw + x0;
            const float* r1 = src + y1 * sw + x0;
            dst[y * dw + x] = r0[0] * (1 - fx) * (1 - fy) +
                              r0[1] * fx * (1 - fy) +
                              r1[0] * (1 - fx) * fy +
                              r1[1] * fx * fy;
        }
    }
}

// Reconstruct the watermarked image exactly like the reference Wam.embed():
//   preds_w = embedder(img_norm, msg)          (raw delta, [-1,1])
//   imgs_w  = scaling_i*img_norm + scaling_w*preds_w
//   imgs_w  = JND(img_norm, imgs_w)            (attenuate by local visibility)
// Then converts to RGB uint8. imgs/preds are CHW float at (w x h).
void blendAndAttenuate(const float* imgs, const float* preds, uint8_t* rgb,
                       int w, int h) {
    const int hw = w * h;
    const size_t sz = static_cast<size_t>(3) * hw;
    std::vector<float> imgs01(sz), blend01(sz);
    for (int c = 0; c < 3; ++c) {
        for (int i = 0; i < hw; ++i) {
            float img = imgs[i + c * hw];
            float blend = kScalingI * img + kScalingW * preds[i + c * hw];
            imgs01[i + c * hw] = img * kStd[c] + kMean[c];
            blend01[i + c * hw] = blend * kStd[c] + kMean[c];
        }
    }
    // Luminance of the ORIGINAL image in [0,1] (heatmaps uses imgs, not imgs_w).
    std::vector<float> lum(static_cast<size_t>(hw));
    for (int i = 0; i < hw; ++i) {
        lum[i] = 0.299f * imgs01[i] + 0.587f * imgs01[i + hw] +
                 0.114f * imgs01[i + 2 * hw];
    }
    std::vector<float> hm(static_cast<size_t>(hw));
    jndHeatmap(lum.data(), hm.data(), w, h);

    for (int i = 0; i < hw; ++i) {
        for (int c = 0; c < 3; ++c) {
            // jnd_1_3_blue: R and G channels attenuated at half the B strength.
            float hmc = hm[i] * (c < 2 ? 0.5f : 1.0f);
            float wm = imgs01[i + c * hw] +
                       kJndAlpha * hmc * (blend01[i + c * hw] - imgs01[i + c * hw]);
            float v = wm * 255.0f;
            rgb[i * 3 + c] = static_cast<uint8_t>(
                v < 0 ? 0 : (v > 255 ? 255 : v + 0.5f));
        }
    }
}

}  // namespace

WamEngine::~WamEngine() {
    std::lock_guard<std::mutex> lk(mu_);
    releaseLocked();
}

void WamEngine::releaseLocked() {
    if (embedSession_) {
        api_->ReleaseSession(embedSession_);
        embedSession_ = nullptr;
    }
    if (extractSession_) {
        api_->ReleaseSession(extractSession_);
        extractSession_ = nullptr;
    }
    if (env_) {
        api_->ReleaseEnv(env_);
        env_ = nullptr;
    }
    if (libHandle_) {
#ifdef _WIN32
        FreeLibrary(static_cast<HMODULE>(libHandle_));
#else
        dlclose(libHandle_);
#endif
        libHandle_ = nullptr;
    }
    api_ = nullptr;
    loaded_ = false;
}

bool WamEngine::load() {
    std::lock_guard<std::mutex> lk(mu_);
    return loadLocked();
}

namespace {
std::string g_debug_info;

const std::string& debugInfo() { return g_debug_info; }
void setDebugInfo(std::string s) { g_debug_info = std::move(s); }
}  // namespace

bool WamEngine::loadLocked() {
    if (loaded_) return true;
    if (libHandle_ == nullptr) {
#ifdef _WIN32
        HMODULE h = LoadLibraryA("onnxruntime.dll");
        libHandle_ = h;
        if (h != nullptr) {
            char path[1024] = {0};
            GetModuleFileNameA(h, path, sizeof(path) - 1);
            setDebugInfo(std::string("dll=") + path);
        }
#else
        void* h = dlopen("libonnxruntime.so", RTLD_NOW);
        libHandle_ = h;
#endif
        if (libHandle_ == nullptr) return false;
        typedef const OrtApiBase* (*OrtGetApiBaseFn)(void);
#ifdef _WIN32
        auto fn = reinterpret_cast<OrtGetApiBaseFn>(
            GetProcAddress(static_cast<HMODULE>(libHandle_), "OrtGetApiBase"));
#else
        auto fn = reinterpret_cast<OrtGetApiBaseFn>(
            dlsym(libHandle_, "OrtGetApiBase"));
#endif
        if (fn == nullptr) {
            releaseLocked();
            return false;
        }
        const OrtApiBase* base = fn();
        if (base == nullptr) {
            releaseLocked();
            return false;
        }
        api_ = base->GetApi(ORT_API_VERSION);
        if (api_ == nullptr) {
            releaseLocked();
            return false;
        }
    }
    loaded_ = true;
    return true;
}

bool WamEngine::ensureSessionsLocked(std::string& err) {
    if (!loadLocked()) {
        err = "onnxruntime library unavailable";
        return false;
    }
    if (env_ == nullptr) {
        OrtStatus* st = api_->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "bwm_wam",
                                        &env_);
        if (st != nullptr) {
            err = api_->GetErrorMessage(st);
            api_->ReleaseStatus(st);
            env_ = nullptr;
            return false;
        }
    }
    return true;
}

bool WamEngine::ensureEmbedSessionLocked(std::string& err) {
    if (!ensureSessionsLocked(err)) return false;
    if (embedSession_ == nullptr) {
        OrtSessionOptions* so = nullptr;
        api_->CreateSessionOptions(&so);
        // Disable graph optimization: the QDQ optimizer of some ORT builds
        // fails session creation for the int8 extractor with
        // "Could not find an implementation for ConvInteger" (kernels are
        // registered at run time, not at optimization time). The models are
        // small; unoptimized inference is fine.
        api_->SetSessionGraphOptimizationLevel(so, ORT_DISABLE_ALL);
        auto modelPath = toOrtChar(modelsDir_ + "/wam_embedder.onnx");
        OrtStatus* st = api_->CreateSession(env_, modelPath.c_str(), so,
                                            &embedSession_);
        if (so) api_->ReleaseSessionOptions(so);
        if (st != nullptr) {
            err = api_->GetErrorMessage(st);
            api_->ReleaseStatus(st);
            embedSession_ = nullptr;
            return false;
        }
    }
    return true;
}

bool WamEngine::ensureExtractSessionLocked(std::string& err) {
    if (!ensureSessionsLocked(err)) return false;
    if (extractSession_ == nullptr) {
        OrtSessionOptions* so = nullptr;
        api_->CreateSessionOptions(&so);
        api_->SetSessionGraphOptimizationLevel(so, ORT_DISABLE_ALL);
        auto modelPath = toOrtChar(modelsDir_ + "/wam_extractor_int8.onnx");
        OrtStatus* st = api_->CreateSession(env_, modelPath.c_str(), so,
                                            &extractSession_);
        if (so) api_->ReleaseSessionOptions(so);
        if (st != nullptr) {
            err = api_->GetErrorMessage(st);
            api_->ReleaseStatus(st);
            extractSession_ = nullptr;
            return false;
        }
    }
    return true;
}

bool WamEngine::embed(const uint8_t* png, size_t pngLen, const float* msg32,
                      std::vector<uint8_t>& outPng, std::string& err) {
    std::lock_guard<std::mutex> lk(mu_);
    if (!ensureEmbedSessionLocked(err)) return false;

    Image img;
    if (!loadImageFromMemory(png, pngLen, img)) {
        err = "cannot decode input PNG";
        return false;
    }
    std::vector<uint8_t> rgb256(static_cast<size_t>(kImgSize) * kImgSize * 3);
    resizeBilinear(img.data.data(), img.width, img.height, rgb256.data());

    const int hw = kImgSize * kImgSize;
    std::vector<float> tensor(static_cast<size_t>(3) * hw);
    toTensorCHW(rgb256.data(), tensor.data());
    std::vector<float> msg(msg32, msg32 + 32);

    const int64_t imgShape[4] = {1, 3, kImgSize, kImgSize};
    const int64_t msgShape[2] = {1, 32};

    OrtMemoryInfo* mem = nullptr;
    api_->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &mem);
    if (mem == nullptr) {
        err = "CreateCpuMemoryInfo failed";
        return false;
    }

    OrtValue* imgVal = nullptr;
    OrtValue* msgVal = nullptr;
    OrtValue* outVal = nullptr;
    bool ok = false;
    auto status = api_->CreateTensorWithDataAsOrtValue(
        mem, tensor.data(), tensor.size() * sizeof(float), imgShape, 4,
        ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &imgVal);
    if (status != nullptr) {
        err = api_->GetErrorMessage(status);
        api_->ReleaseStatus(status);
    } else {
        status = api_->CreateTensorWithDataAsOrtValue(
            mem, msg.data(), msg.size() * sizeof(float), msgShape, 2,
            ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &msgVal);
        if (status != nullptr) {
            err = api_->GetErrorMessage(status);
            api_->ReleaseStatus(status);
        } else {
            const char* inputNames[] = {"img", "msg"};
            const OrtValue* inputs[] = {imgVal, msgVal};
            const char* outputName[] = {"imgs_w"};
            status = api_->Run(embedSession_, nullptr, inputNames, inputs, 2,
                               outputName, 1, &outVal);
            if (status != nullptr) {
                err = api_->GetErrorMessage(status);
                api_->ReleaseStatus(status);
            } else {
                float* outData = nullptr;
                status = api_->GetTensorMutableData(outVal, (void**)&outData);
                if (status != nullptr) {
                    err = api_->GetErrorMessage(status);
                    api_->ReleaseStatus(status);
                } else {
                    // The embedder output is the raw watermark delta (preds_w).
                    // Reconstruct the final watermarked image = blend + JND
                    // (this is what Wam.embed() does; without it the output is
                    // the delta alone = a noise image).
                    const int cw = img.width;
                    const int ch = img.height;
                    std::vector<uint8_t> rgbOut(static_cast<size_t>(3) * cw * ch);
                    if (cw == kImgSize && ch == kImgSize) {
                        // 256x256 carrier: reuse the pre-normalized input tensor.
                        blendAndAttenuate(tensor.data(), outData, rgbOut.data(),
                                          cw, ch);
                    } else {
                        // Full-resolution output (sharp): normalize the carrier
                        // at its own size, stretch the 256x256 delta up to it,
                        // then blend + JND at the carrier's resolution (mirrors
                        // Wam.embed()'s inverse_resize + blend + attenuation).
                        const int chw = cw * ch;
                        std::vector<float> imgsFull(static_cast<size_t>(3) * chw);
                        for (int i = 0; i < chw; ++i) {
                            for (int c = 0; c < 3; ++c) {
                                imgsFull[i + c * chw] =
                                    (img.data[i * 3 + c] / 255.0f - kMean[c]) /
                                    kStd[c];
                            }
                        }
                        std::vector<float> deltaFull(static_cast<size_t>(3) * chw);
                        for (int c = 0; c < 3; ++c) {
                            resizeChannelBilinear(
                                outData + c * (kImgSize * kImgSize), kImgSize,
                                kImgSize, deltaFull.data() + c * chw, cw, ch);
                        }
                        blendAndAttenuate(imgsFull.data(), deltaFull.data(),
                                          rgbOut.data(), cw, ch);
                    }
                    Image outImg;
                    outImg.width = cw;
                    outImg.height = ch;
                    outImg.channels = 3;
                    outImg.data = std::move(rgbOut);
                    if (encodeImage(outImg, "png", outPng)) {
                        ok = true;
                    } else {
                        err = "PNG encode failed";
                    }
                }
            }
        }
    }
    if (imgVal) api_->ReleaseValue(imgVal);
    if (msgVal) api_->ReleaseValue(msgVal);
    if (outVal) api_->ReleaseValue(outVal);
    api_->ReleaseMemoryInfo(mem);
    return ok;
}

bool WamEngine::extract(const uint8_t* png, size_t pngLen,
                        std::vector<int>& bits, double& confidence,
                        std::string& err) {
    std::lock_guard<std::mutex> lk(mu_);
    if (!ensureExtractSessionLocked(err)) return false;

    Image img;
    if (!loadImageFromMemory(png, pngLen, img)) {
        err = "cannot decode input PNG";
        return false;
    }
    std::vector<uint8_t> rgb256(static_cast<size_t>(kImgSize) * kImgSize * 3);
    resizeBilinear(img.data.data(), img.width, img.height, rgb256.data());

    const int hw = kImgSize * kImgSize;
    std::vector<float> tensor(static_cast<size_t>(3) * hw);
    toTensorCHW(rgb256.data(), tensor.data());

    const int64_t imgShape[4] = {1, 3, kImgSize, kImgSize};

    OrtMemoryInfo* mem = nullptr;
    api_->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &mem);
    if (mem == nullptr) {
        err = "CreateCpuMemoryInfo failed";
        return false;
    }

    OrtValue* imgVal = nullptr;
    OrtValue* outVal = nullptr;
    bool ok = false;
    auto status = api_->CreateTensorWithDataAsOrtValue(
        mem, tensor.data(), tensor.size() * sizeof(float), imgShape, 4,
        ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &imgVal);
    if (status != nullptr) {
        err = api_->GetErrorMessage(status);
        api_->ReleaseStatus(status);
    } else {
        const char* inputNames[] = {"img"};
        const OrtValue* inputs[] = {imgVal};
        const char* outputName[] = {"preds"};
        status = api_->Run(extractSession_, nullptr, inputNames, inputs, 1,
                           outputName, 1, &outVal);
        if (status != nullptr) {
            err = api_->GetErrorMessage(status);
            api_->ReleaseStatus(status);
        } else {
            float* outData = nullptr;
            status = api_->GetTensorMutableData(outVal, (void**)&outData);
            if (status != nullptr) {
                err = api_->GetErrorMessage(status);
                api_->ReleaseStatus(status);
            } else {
                // [1,33,256,256] C order: channel k at [k*hw, (k+1)*hw).
                std::vector<bool> mask(hw);
                for (int i = 0; i < hw; ++i) {
                    mask[i] =
                        1.0f / (1.0f + std::exp(-outData[i])) > 0.5f;
                }
                // Confidence = mean |bit margin|: for each of the 32 bit
                // channels, the mean logit over watermarked pixels, absolute.
                // Clean watermarks push logits far from 0 (~8), while a wrong
                // candidate (cropped/mixed content) gives margins near 0 —
                // the app picks the attempt with the highest value.
                double confSum = 0.0;
                bits.clear();
                for (int k = 1; k <= 32; ++k) {
                    const float* ch = outData + static_cast<size_t>(k) * hw;
                    double sum = 0.0;
                    int n = 0;
                    for (int i = 0; i < hw; ++i) {
                        if (mask[i]) {
                            sum += ch[i];
                            n++;
                        }
                    }
                    double m = (n > 0) ? sum / n : 0.0;
                    bits.push_back(m > 0.0 ? 1 : 0);
                    confSum += std::fabs(m);
                }
                confidence = confSum / 32.0;
                ok = true;
            }
        }
    }
    if (imgVal) api_->ReleaseValue(imgVal);
    if (outVal) api_->ReleaseValue(outVal);
    api_->ReleaseMemoryInfo(mem);
    return ok;
}

// ---------------------------------------------------------------------------
// FFI exports
// ---------------------------------------------------------------------------
extern "C" {

static WamEngine g_wam;

BWM_EXPORT void bwm_wam_set_models_dir(const char* dir) {
    if (dir != nullptr) {
        g_wam.setModelsDir(dir);
    }
}

BWM_EXPORT const char* bwm_wam_debug_info() {
    static thread_local std::string buf;
    buf = bwm::debugInfo();
    return buf.c_str();
}

// Returns 0 on success; fills err (up to errCap bytes) otherwise.
BWM_EXPORT int bwm_wam_embed(const uint8_t* png, size_t len, const float* msg,
                             uint8_t** out, size_t* outLen, char* err,
                             size_t errCap) {
    std::vector<uint8_t> pngOut;
    std::string e;
    if (!g_wam.embed(png, len, msg, pngOut, e)) {
        if (err && errCap > 0) {
            snprintf(err, errCap, "%s", e.empty() ? "wam embed failed" : e.c_str());
        }
        return 1;
    }
    uint8_t* buf = static_cast<uint8_t*>(malloc(pngOut.size()));
    if (buf == nullptr) return 2;
    memcpy(buf, pngOut.data(), pngOut.size());
    *out = buf;
    *outLen = pngOut.size();
    return 0;
}

// Returns 0 on success; bits must point to 32 bytes; confidence (0..1) is the
// fraction of pixels the model considers watermarked (may be nullptr).
BWM_EXPORT int bwm_wam_extract(const uint8_t* png, size_t len, uint8_t* bits,
                               float* confidence, char* err, size_t errCap) {
    std::vector<int> b;
    double conf = 0.0;
    std::string e;
    if (!g_wam.extract(png, len, b, conf, e)) {
        if (err && errCap > 0) {
            snprintf(err, errCap, "%s", e.empty() ? "wam extract failed" : e.c_str());
        }
        return 1;
    }
    for (int i = 0; i < 32 && i < static_cast<int>(b.size()); ++i) {
        bits[i] = static_cast<uint8_t>(b[i] ? 1 : 0);
    }
    if (confidence != nullptr) *confidence = static_cast<float>(conf);
    return 0;
}

}  // extern "C"

}  // namespace bwm
