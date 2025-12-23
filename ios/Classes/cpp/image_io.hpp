#ifndef IMAGE_IO_HPP
#define IMAGE_IO_HPP

#include <vector>
#include <string>
#include <cstdint>

namespace bwm {

/// Image data structure (RGB format)
struct Image {
    int width = 0;
    int height = 0;
    int channels = 0;
    std::vector<uint8_t> data;  // Interleaved RGB or RGBA data

    bool empty() const { return data.empty(); }
    size_t size() const { return data.size(); }

    // Get pixel value at (x, y) for channel c
    uint8_t at(int x, int y, int c) const {
        return data[(y * width + x) * channels + c];
    }

    // Set pixel value at (x, y) for channel c
    void set(int x, int y, int c, uint8_t value) {
        data[(y * width + x) * channels + c] = value;
    }

    // Allocate image with given dimensions
    void allocate(int w, int h, int ch) {
        width = w;
        height = h;
        channels = ch;
        data.resize(static_cast<size_t>(w) * h * ch);
    }
};

/// Load image from file
/// @param filename Path to image file (PNG, JPEG, BMP supported)
/// @param img Output image (RGB format, 3 channels)
/// @return true on success, false on failure
bool loadImage(const std::string& filename, Image& img);

/// Load image from memory buffer
/// @param buffer Pointer to image data (PNG, JPEG, BMP encoded)
/// @param length Length of buffer in bytes
/// @param img Output image (RGB format, 3 channels)
/// @return true on success, false on failure
bool loadImageFromMemory(const uint8_t* buffer, size_t length, Image& img);

/// Save image to file
/// @param filename Path to output file (.png, .jpg, .bmp based on extension)
/// @param img Input image
/// @return true on success, false on failure
bool saveImage(const std::string& filename, const Image& img);

/// Encode image to memory buffer
/// @param img Input image
/// @param format Output format: "png", "jpg", or "bmp"
/// @param buffer Output buffer
/// @param quality JPEG quality (1-100), ignored for PNG/BMP
/// @return true on success, false on failure
bool encodeImage(const Image& img, const std::string& format,
                 std::vector<uint8_t>& buffer, int quality = 95);

/// Load grayscale image from file
/// @param filename Path to image file
/// @param img Output image (1 channel grayscale)
/// @return true on success, false on failure
bool loadGrayscaleImage(const std::string& filename, Image& img);

/// Load grayscale image from memory
/// @param buffer Pointer to image data
/// @param length Length of buffer
/// @param img Output image (1 channel grayscale)
/// @return true on success, false on failure
bool loadGrayscaleImageFromMemory(const uint8_t* buffer, size_t length, Image& img);

} // namespace bwm

#endif // IMAGE_IO_HPP
