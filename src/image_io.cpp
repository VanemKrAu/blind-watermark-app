#define STB_IMAGE_IMPLEMENTATION
#define STB_IMAGE_WRITE_IMPLEMENTATION

#include "image_io.hpp"
#include "../third_party/stb_image.h"
#include "../third_party/stb_image_write.h"
#include <algorithm>
#include <cstring>

#ifdef BWM_HAVE_WEBP
#include "webp/decode.h"
#include "webp/encode.h"
#endif

namespace bwm {

// Check if buffer is WebP format (RIFF....WEBP header)
static bool isWebP(const uint8_t* buffer, size_t length) {
    if (length < 12) return false;
    return buffer[0] == 'R' && buffer[1] == 'I' && buffer[2] == 'F' && buffer[3] == 'F' &&
           buffer[8] == 'W' && buffer[9] == 'E' && buffer[10] == 'B' && buffer[11] == 'P';
}

#ifdef BWM_HAVE_WEBP
// Decode WebP from memory
static bool loadWebPFromMemory(const uint8_t* buffer, size_t length, Image& img) {
    int width, height;

    // Get image dimensions
    if (!WebPGetInfo(buffer, length, &width, &height)) {
        return false;
    }

    // Decode to RGB
    uint8_t* data = WebPDecodeRGB(buffer, length, &width, &height);
    if (!data) {
        return false;
    }

    img.width = width;
    img.height = height;
    img.channels = 3;
    img.data.assign(data, data + static_cast<size_t>(width) * height * 3);

    WebPFree(data);
    return true;
}

// Encode to WebP
static bool encodeWebP(const Image& img, std::vector<uint8_t>& buffer, int quality) {
    uint8_t* output = nullptr;
    size_t outputSize = 0;

    if (img.channels == 3) {
        outputSize = WebPEncodeRGB(img.data.data(), img.width, img.height,
                                    img.width * 3, static_cast<float>(quality), &output);
    } else if (img.channels == 4) {
        outputSize = WebPEncodeRGBA(img.data.data(), img.width, img.height,
                                     img.width * 4, static_cast<float>(quality), &output);
    } else {
        return false;
    }

    if (outputSize == 0 || output == nullptr) {
        return false;
    }

    buffer.assign(output, output + outputSize);
    WebPFree(output);
    return true;
}
#endif

bool loadImage(const std::string& filename, Image& img) {
    int width, height, channels;
    // Force load as RGB (3 channels)
    unsigned char* data = stbi_load(filename.c_str(), &width, &height, &channels, 3);

    if (!data) {
        return false;
    }

    img.width = width;
    img.height = height;
    img.channels = 3;
    img.data.assign(data, data + static_cast<size_t>(width) * height * 3);

    stbi_image_free(data);
    return true;
}

bool loadImageFromMemory(const uint8_t* buffer, size_t length, Image& img) {
#ifdef BWM_HAVE_WEBP
    // Check for WebP format first
    if (isWebP(buffer, length)) {
        return loadWebPFromMemory(buffer, length, img);
    }
#endif

    int width, height, channels;
    // Force load as RGB (3 channels)
    unsigned char* data = stbi_load_from_memory(
        buffer, static_cast<int>(length), &width, &height, &channels, 3);

    if (!data) {
        return false;
    }

    img.width = width;
    img.height = height;
    img.channels = 3;
    img.data.assign(data, data + static_cast<size_t>(width) * height * 3);

    stbi_image_free(data);
    return true;
}

bool loadGrayscaleImage(const std::string& filename, Image& img) {
    int width, height, channels;
    // Force load as grayscale (1 channel)
    unsigned char* data = stbi_load(filename.c_str(), &width, &height, &channels, 1);

    if (!data) {
        return false;
    }

    img.width = width;
    img.height = height;
    img.channels = 1;
    img.data.assign(data, data + static_cast<size_t>(width) * height);

    stbi_image_free(data);
    return true;
}

bool loadGrayscaleImageFromMemory(const uint8_t* buffer, size_t length, Image& img) {
    int width, height, channels;
    // Force load as grayscale (1 channel)
    unsigned char* data = stbi_load_from_memory(
        buffer, static_cast<int>(length), &width, &height, &channels, 1);

    if (!data) {
        return false;
    }

    img.width = width;
    img.height = height;
    img.channels = 1;
    img.data.assign(data, data + static_cast<size_t>(width) * height);

    stbi_image_free(data);
    return true;
}

bool saveImage(const std::string& filename, const Image& img) {
    if (img.empty()) {
        return false;
    }

    // Determine format from extension
    std::string ext;
    size_t dot = filename.rfind('.');
    if (dot != std::string::npos) {
        ext = filename.substr(dot + 1);
        std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    }

    int result = 0;
    if (ext == "png") {
        result = stbi_write_png(filename.c_str(), img.width, img.height,
                                img.channels, img.data.data(), img.width * img.channels);
    } else if (ext == "jpg" || ext == "jpeg") {
        result = stbi_write_jpg(filename.c_str(), img.width, img.height,
                                img.channels, img.data.data(), 95);
    } else if (ext == "bmp") {
        result = stbi_write_bmp(filename.c_str(), img.width, img.height,
                                img.channels, img.data.data());
    } else {
        // Default to PNG
        result = stbi_write_png(filename.c_str(), img.width, img.height,
                                img.channels, img.data.data(), img.width * img.channels);
    }

    return result != 0;
}

// Callback for writing to memory buffer
static void stbi_write_callback(void* context, void* data, int size) {
    auto* buffer = static_cast<std::vector<uint8_t>*>(context);
    auto* bytes = static_cast<uint8_t*>(data);
    buffer->insert(buffer->end(), bytes, bytes + size);
}

bool encodeImage(const Image& img, const std::string& format,
                 std::vector<uint8_t>& buffer, int quality) {
    if (img.empty()) {
        return false;
    }

    buffer.clear();

    std::string fmt = format;
    std::transform(fmt.begin(), fmt.end(), fmt.begin(), ::tolower);

    int result = 0;
    if (fmt == "png") {
        result = stbi_write_png_to_func(stbi_write_callback, &buffer,
                                        img.width, img.height, img.channels,
                                        img.data.data(), img.width * img.channels);
    } else if (fmt == "jpg" || fmt == "jpeg") {
        result = stbi_write_jpg_to_func(stbi_write_callback, &buffer,
                                        img.width, img.height, img.channels,
                                        img.data.data(), quality);
    } else if (fmt == "bmp") {
        result = stbi_write_bmp_to_func(stbi_write_callback, &buffer,
                                        img.width, img.height, img.channels,
                                        img.data.data());
#ifdef BWM_HAVE_WEBP
    } else if (fmt == "webp") {
        return encodeWebP(img, buffer, quality);
#endif
    } else {
        // Default to PNG
        result = stbi_write_png_to_func(stbi_write_callback, &buffer,
                                        img.width, img.height, img.channels,
                                        img.data.data(), img.width * img.channels);
    }

    return result != 0;
}

} // namespace bwm
