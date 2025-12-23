#include "color_convert.hpp"
#include <cmath>

namespace bwm {

void rgbToYuv(const std::vector<uint8_t>& rgb, int width, int height,
              Eigen::MatrixXd& Y, Eigen::MatrixXd& U, Eigen::MatrixXd& V) {
    Y.resize(height, width);
    U.resize(height, width);
    V.resize(height, width);

    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            size_t idx = static_cast<size_t>(y * width + x) * 3;
            double r = rgb[idx];
            double g = rgb[idx + 1];
            double b = rgb[idx + 2];

            // ITU-R BT.601 conversion
            Y(y, x) = 0.299 * r + 0.587 * g + 0.114 * b;
            U(y, x) = -0.14713 * r - 0.28886 * g + 0.436 * b + 128.0;
            V(y, x) = 0.615 * r - 0.51499 * g - 0.10001 * b + 128.0;
        }
    }
}

void yuvToRgb(const Eigen::MatrixXd& Y, const Eigen::MatrixXd& U, const Eigen::MatrixXd& V,
              std::vector<uint8_t>& rgb) {
    int height = static_cast<int>(Y.rows());
    int width = static_cast<int>(Y.cols());
    rgb.resize(static_cast<size_t>(height) * width * 3);

    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            double yVal = Y(y, x);
            double uVal = U(y, x) - 128.0;
            double vVal = V(y, x) - 128.0;

            // ITU-R BT.601 inverse conversion
            double r = yVal + 1.13983 * vVal;
            double g = yVal - 0.39465 * uVal - 0.58060 * vVal;
            double b = yVal + 2.03211 * uVal;

            size_t idx = static_cast<size_t>(y * width + x) * 3;
            rgb[idx] = static_cast<uint8_t>(clamp255(std::round(r)));
            rgb[idx + 1] = static_cast<uint8_t>(clamp255(std::round(g)));
            rgb[idx + 2] = static_cast<uint8_t>(clamp255(std::round(b)));
        }
    }
}

Eigen::MatrixXd rgbToGray(const std::vector<uint8_t>& rgb, int width, int height) {
    Eigen::MatrixXd gray(height, width);

    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            size_t idx = static_cast<size_t>(y * width + x) * 3;
            double r = rgb[idx];
            double g = rgb[idx + 1];
            double b = rgb[idx + 2];

            // Standard grayscale conversion
            gray(y, x) = 0.299 * r + 0.587 * g + 0.114 * b;
        }
    }

    return gray;
}

void grayToRgb(const Eigen::MatrixXd& gray, std::vector<uint8_t>& rgb) {
    int height = static_cast<int>(gray.rows());
    int width = static_cast<int>(gray.cols());
    rgb.resize(static_cast<size_t>(height) * width * 3);

    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            uint8_t val = static_cast<uint8_t>(clamp255(std::round(gray(y, x))));
            size_t idx = static_cast<size_t>(y * width + x) * 3;
            rgb[idx] = val;
            rgb[idx + 1] = val;
            rgb[idx + 2] = val;
        }
    }
}

Eigen::MatrixXd binarize(const Eigen::MatrixXd& input, double threshold) {
    Eigen::MatrixXd output(input.rows(), input.cols());

    for (int y = 0; y < input.rows(); ++y) {
        for (int x = 0; x < input.cols(); ++x) {
            output(y, x) = (input(y, x) > threshold) ? 255.0 : 0.0;
        }
    }

    return output;
}

} // namespace bwm
