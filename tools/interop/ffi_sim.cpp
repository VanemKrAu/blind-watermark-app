// Simulate the Dart app's exact FFI call sequence to reproduce embed failures.
// Mirrors: bwm_create_with_strength -> bwm_read_image_buffer -> bwm_read_watermark_string
//          -> bwm_embed_to_buffer -> bwm_get_watermark_size -> bwm_get_last_error
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <fstream>
#include <iostream>

extern "C" {
typedef void* BWMHandle;
void* bwm_create_with_strength(int, int, float, float);
int bwm_read_image_buffer(void*, const unsigned char*, size_t);
int bwm_read_watermark_string(void*, const char*);
int bwm_embed_to_buffer(void*, unsigned char**, size_t*, const char*);
size_t bwm_get_watermark_size(void*);
const char* bwm_get_last_error(void*);
void bwm_free_buffer(void*);
void bwm_destroy(void*);
}

static std::string readFile(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

static void test(const std::string& imgPath, const std::string& wmText, int pwWm, int pwImg) {
    std::string data = readFile(imgPath);
    std::printf("=== image=%s (%zu bytes) wm=%s pw=(%d,%d) ===\n",
                imgPath.c_str(), data.size(), wmText.c_str(), pwWm, pwImg);
    BWMHandle h = bwm_create_with_strength(pwWm, pwImg, 36.0f, 20.0f);
    if (!h) { std::printf("FAIL: create handle\n"); return; }
    int rc = bwm_read_image_buffer(h, (const unsigned char*)data.data(), data.size());
    if (rc != 0) {
        std::printf("FAIL: read_image rc=%d last=%s\n", rc, bwm_get_last_error(h) ? bwm_get_last_error(h) : "(null)");
        bwm_destroy(h);
        return;
    }
    rc = bwm_read_watermark_string(h, wmText.c_str());
    if (rc != 0) {
        std::printf("FAIL: read_wm rc=%d last=%s\n", rc, bwm_get_last_error(h) ? bwm_get_last_error(h) : "(null)");
        bwm_destroy(h);
        return;
    }
    size_t wmSize = bwm_get_watermark_size(h);
    unsigned char* out = nullptr;
    size_t outLen = 0;
    rc = bwm_embed_to_buffer(h, &out, &outLen, "png");
    if (rc != 0) {
        std::printf("FAIL: embed rc=%d last=%s\n", rc, bwm_get_last_error(h) ? bwm_get_last_error(h) : "(null)");
        bwm_destroy(h);
        return;
    }
    std::printf("OK: embed wm_size=%zu out=%zu bytes\n", wmSize, outLen);
    bwm_free_buffer(out);
    bwm_destroy(h);
}

int main(int argc, char** argv) {
    if (argc < 3) { std::printf("usage: %s <img> <text>\n", argv[0]); return 1; }
    test(argv[1], argv[2], 1, 1);
    return 0;
}
