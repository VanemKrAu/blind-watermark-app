#ifndef WAM_ORT_HPP
#define WAM_ORT_HPP

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include "onnxruntime_c_api.h"

namespace bwm {

// ---------------------------------------------------------------------------
// WAM (Watermark Anything) inference through the ONNX Runtime C API directly.
//
// The previous implementation used the ai.onnxruntime Java/JNI bridge, which
// aborts with SIGABRT inside sess.run on Android 16 (ART JNI fatal, seen on a
// Xiaomi 14 / SDK 36 device). The ORT C core itself was verified locally with
// the exact same models and shapes (C API test: embed [1,3,256,256]+[1,32] ->
// [1,3,256,256], extract [1,3,256,256] -> [1,33,256,256]). Calling the C API
// from our own FFI library removes the failing Java/JNI layer entirely (Dart
// FFI does not go through ART's JNI checks).
// ---------------------------------------------------------------------------
class WamEngine {
public:
    ~WamEngine();

    // Loads libonnxruntime and the ORT API; returns false on failure.
    bool load();

    // Directory containing wam_embedder.onnx / wam_extractor_int8.onnx
    // (extracted by the host app).
    void setModelsDir(const std::string& dir) { modelsDir_ = dir; }

    // Embed a 32-bit message (values 0/1) into a PNG image (any size,
    // stretched to 256x256 like the previous Bitmap.createScaledBitmap path).
    // Output: watermarked 256x256 PNG.
    bool embed(const uint8_t* png, size_t pngLen, const float* msg32,
               std::vector<uint8_t>& outPng, std::string& err);

    // Extract 32 bits from a PNG image (stretched to 256x256).
    bool extract(const uint8_t* png, size_t pngLen, std::vector<int>& bits,
                 std::string& err);

private:
    std::mutex mu_;  // ORT sessions are not thread-safe; serialize all calls.

    bool loadLocked();
    bool ensureSessionsLocked(std::string& err);
    bool ensureEmbedSessionLocked(std::string& err);
    bool ensureExtractSessionLocked(std::string& err);

    const OrtApi* api_ = nullptr;
    void* libHandle_ = nullptr;
    OrtEnv* env_ = nullptr;
    OrtSession* embedSession_ = nullptr;
    OrtSession* extractSession_ = nullptr;
    bool loaded_ = false;

    std::string modelsDir_;  // directory containing the .onnx files

    void releaseLocked();
};

}  // namespace bwm

#endif  // WAM_ORT_HPP
