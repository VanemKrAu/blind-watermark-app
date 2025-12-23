#ifndef COLOR_CONVERT_HPP
#define COLOR_CONVERT_HPP

#include <Eigen/Dense>
#include <vector>
#include <cstdint>

namespace bwm {

/// Convert RGB image to YUV color space
/// @param rgb Input RGB data (interleaved, 3 channels per pixel)
/// @param width Image width
/// @param height Image height
/// @param Y Output Y channel (luminance)
/// @param U Output U channel (chrominance)
/// @param V Output V channel (chrominance)
void rgbToYuv(const std::vector<uint8_t>& rgb, int width, int height,
              Eigen::MatrixXd& Y, Eigen::MatrixXd& U, Eigen::MatrixXd& V);

/// Convert YUV to RGB image
/// @param Y Input Y channel (luminance)
/// @param U Input U channel (chrominance)
/// @param V Input V channel (chrominance)
/// @param rgb Output RGB data (interleaved, 3 channels per pixel)
void yuvToRgb(const Eigen::MatrixXd& Y, const Eigen::MatrixXd& U, const Eigen::MatrixXd& V,
              std::vector<uint8_t>& rgb);

/// Convert RGB image to grayscale
/// @param rgb Input RGB data (interleaved, 3 channels per pixel)
/// @param width Image width
/// @param height Image height
/// @return Grayscale matrix
Eigen::MatrixXd rgbToGray(const std::vector<uint8_t>& rgb, int width, int height);

/// Convert grayscale matrix to RGB image
/// @param gray Input grayscale matrix
/// @param rgb Output RGB data (interleaved, 3 channels per pixel)
void grayToRgb(const Eigen::MatrixXd& gray, std::vector<uint8_t>& rgb);

/// Threshold a matrix to binary (0 or 255)
/// @param input Input matrix
/// @param threshold Threshold value (default: 128)
/// @return Binary matrix (values are 0 or 255)
Eigen::MatrixXd binarize(const Eigen::MatrixXd& input, double threshold = 128.0);

/// Clamp values to [0, 255] range
inline double clamp255(double v) {
    return v < 0 ? 0 : (v > 255 ? 255 : v);
}

} // namespace bwm

#endif // COLOR_CONVERT_HPP
