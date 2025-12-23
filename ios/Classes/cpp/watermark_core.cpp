#include "watermark_core.hpp"
#include "color_convert.hpp"
#include "dwt.hpp"
#include "dct.hpp"
#include <Eigen/SVD>
#include <algorithm>
#include <numeric>
#include <cmath>

namespace bwm {

BlindWatermarkCore::BlindWatermarkCore(const WatermarkConfig& config)
    : config_(config) {}

void BlindWatermarkCore::setImage(const Image& img) {
    if (img.empty() || img.channels != 3) {
        throw std::runtime_error("Invalid image: must be RGB with 3 channels");
    }

    imgWidth_ = img.width;
    imgHeight_ = img.height;

    // Convert RGB to YUV
    rgbToYuv(img.data, img.width, img.height, Y_, U_, V_);
}

void BlindWatermarkCore::setWatermarkText(const std::string& text) {
    watermarkBits_ = textToBits(text);
    wmImgHeight_ = 0;
    wmImgWidth_ = 0;
}

void BlindWatermarkCore::setWatermarkImage(const Image& img) {
    watermarkBits_ = imageToBits(img);
    wmImgHeight_ = img.height;
    wmImgWidth_ = img.width;
}

void BlindWatermarkCore::setWatermarkBits(const std::vector<uint8_t>& bits) {
    watermarkBits_ = bits;
    wmImgHeight_ = 0;
    wmImgWidth_ = 0;
}

std::vector<uint8_t> BlindWatermarkCore::textToBits(const std::string& text) {
    std::vector<uint8_t> bits;
    bits.reserve(text.size() * 8);

    for (char c : text) {
        for (int i = 7; i >= 0; --i) {
            bits.push_back((static_cast<unsigned char>(c) >> i) & 1);
        }
    }
    return bits;
}

std::string BlindWatermarkCore::bitsToText(const std::vector<uint8_t>& bits) {
    std::string text;
    text.reserve(bits.size() / 8);

    for (size_t i = 0; i + 7 < bits.size(); i += 8) {
        unsigned char c = 0;
        for (int j = 0; j < 8; ++j) {
            c = (c << 1) | (bits[i + j] & 1);
        }
        if (c != 0) {  // Skip null characters
            text.push_back(static_cast<char>(c));
        }
    }
    return text;
}

std::vector<uint8_t> BlindWatermarkCore::imageToBits(const Image& img) {
    std::vector<uint8_t> bits;

    if (img.empty()) {
        return bits;
    }

    bits.reserve(static_cast<size_t>(img.width) * img.height);

    // Convert to grayscale if needed and binarize
    for (int y = 0; y < img.height; ++y) {
        for (int x = 0; x < img.width; ++x) {
            double gray;
            if (img.channels == 1) {
                gray = img.at(x, y, 0);
            } else {
                // RGB to grayscale
                double r = img.at(x, y, 0);
                double g = img.at(x, y, 1);
                double b = img.at(x, y, 2);
                gray = 0.299 * r + 0.587 * g + 0.114 * b;
            }
            // Binarize with threshold 128
            bits.push_back(gray > 128 ? 1 : 0);
        }
    }

    return bits;
}

Image BlindWatermarkCore::bitsToImage(const std::vector<uint8_t>& bits, int height, int width) {
    Image img;
    img.allocate(width, height, 1);

    size_t idx = 0;
    for (int y = 0; y < height && idx < bits.size(); ++y) {
        for (int x = 0; x < width && idx < bits.size(); ++x, ++idx) {
            img.set(x, y, 0, bits[idx] ? 255 : 0);
        }
    }

    return img;
}

std::vector<uint8_t> BlindWatermarkCore::scrambleBits(const std::vector<uint8_t>& bits, int password, bool inverse) {
    if (bits.empty()) {
        return bits;
    }

    size_t n = bits.size();
    std::vector<size_t> indices(n);
    std::iota(indices.begin(), indices.end(), 0);

    // Generate permutation using password as seed
    std::mt19937 gen(static_cast<unsigned int>(password));
    std::shuffle(indices.begin(), indices.end(), gen);

    std::vector<uint8_t> result(n);

    if (inverse) {
        // Inverse scramble
        for (size_t i = 0; i < n; ++i) {
            result[indices[i]] = bits[i];
        }
    } else {
        // Forward scramble
        for (size_t i = 0; i < n; ++i) {
            result[i] = bits[indices[i]];
        }
    }

    return result;
}

void BlindWatermarkCore::generateBlockIndices(int numBlocks, int password, int llRows, int llCols) {
    blockIndices_.clear();

    int blocksPerRow = llCols / config_.blockSize;
    int blocksPerCol = llRows / config_.blockSize;
    int totalBlocks = blocksPerRow * blocksPerCol;

    if (totalBlocks < numBlocks) {
        throw std::runtime_error("Image too small for watermark");
    }

    // Generate all block indices
    std::vector<std::pair<int, int>> allIndices;
    allIndices.reserve(totalBlocks);

    for (int r = 0; r < blocksPerCol; ++r) {
        for (int c = 0; c < blocksPerRow; ++c) {
            allIndices.emplace_back(r, c);
        }
    }

    // Shuffle using password
    std::mt19937 gen(static_cast<unsigned int>(password));
    std::shuffle(allIndices.begin(), allIndices.end(), gen);

    // Take first numBlocks indices
    blockIndices_.assign(allIndices.begin(), allIndices.begin() + numBlocks);
}

void BlindWatermarkCore::embedBits(Eigen::MatrixXd& channel, const std::vector<uint8_t>& bits) {
    if (bits.empty()) {
        return;
    }

    // Store original dimensions for cropping after IDWT
    int origRows = static_cast<int>(channel.rows());
    int origCols = static_cast<int>(channel.cols());

    // Apply multi-level DWT
    std::vector<DwtResult> dwtLevels = dwt2d_multilevel(channel, config_.dwtLevel);

    if (dwtLevels.empty()) {
        throw std::runtime_error("DWT failed");
    }

    // Get the LL subband at deepest level
    Eigen::MatrixXd& LL = dwtLevels.back().LL;
    int llRows = static_cast<int>(LL.rows());
    int llCols = static_cast<int>(LL.cols());

    // Apply redundancy: each bit is embedded multiple times
    std::vector<uint8_t> redundantBits;
    redundantBits.reserve(bits.size() * config_.redundancy);
    for (const auto& bit : bits) {
        for (int r = 0; r < config_.redundancy; ++r) {
            redundantBits.push_back(bit);
        }
    }

    // Generate block indices using actual LL dimensions
    generateBlockIndices(static_cast<int>(redundantBits.size()), config_.passwordImg, llRows, llCols);

    // Scramble watermark bits
    std::vector<uint8_t> scrambledBits = scrambleBits(redundantBits, config_.passwordWm);

    // Embed each bit using DCT-SVD
    for (size_t i = 0; i < scrambledBits.size(); ++i) {
        int blockRow = blockIndices_[i].first * config_.blockSize;
        int blockCol = blockIndices_[i].second * config_.blockSize;

        // Extract block
        Eigen::MatrixXd block = LL.block(blockRow, blockCol, config_.blockSize, config_.blockSize);

        // Apply DCT
        Eigen::MatrixXd dctBlock = dct2d(block);

        // Apply SVD
        Eigen::JacobiSVD<Eigen::MatrixXd> svd(dctBlock, Eigen::ComputeFullU | Eigen::ComputeFullV);
        Eigen::VectorXd S = svd.singularValues();
        Eigen::MatrixXd U = svd.matrixU();
        Eigen::MatrixXd V = svd.matrixV();

        // Embed bit by quantization modulation
        // s0 = (floor(s0 / d1) + 0.25 + 0.5 * bit) * d1
        double s0 = S(0);
        double bit = scrambledBits[i] ? 1.0 : 0.0;
        s0 = (std::floor(s0 / config_.d1) + 0.25 + 0.5 * bit) * config_.d1;
        S(0) = s0;

        // Also modify second singular value if d2 > 0
        if (config_.d2 > 0 && S.size() > 1) {
            double s1 = S(1);
            s1 = (std::floor(s1 / config_.d2) + 0.25 + 0.5 * bit) * config_.d2;
            S(1) = s1;
        }

        // Reconstruct block
        Eigen::MatrixXd newDctBlock = U * S.asDiagonal() * V.transpose();
        Eigen::MatrixXd newBlock = idct2d(newDctBlock);

        // Update LL subband
        LL.block(blockRow, blockCol, config_.blockSize, config_.blockSize) = newBlock;
    }

    // Update dwtLevels with modified LL
    dwtLevels.back().LL = LL;

    // Reconstruct image with inverse DWT
    Eigen::MatrixXd reconstructed = idwt2d_multilevel(dwtLevels);

    // Crop back to original dimensions (DWT may have padded)
    channel = reconstructed.block(0, 0, origRows, origCols);
}

std::vector<uint8_t> BlindWatermarkCore::extractBitsFromChannel(const Eigen::MatrixXd& channel, size_t numBits) {
    // Apply multi-level DWT
    std::vector<DwtResult> dwtLevels = dwt2d_multilevel(channel, config_.dwtLevel);

    if (dwtLevels.empty()) {
        throw std::runtime_error("DWT failed");
    }

    // Get the LL subband at deepest level
    const Eigen::MatrixXd& LL = dwtLevels.back().LL;
    int llRows = static_cast<int>(LL.rows());
    int llCols = static_cast<int>(LL.cols());

    // With redundancy, we need to extract numBits * redundancy blocks
    size_t totalBits = numBits * config_.redundancy;

    // Generate block indices using actual LL dimensions
    generateBlockIndices(static_cast<int>(totalBits), config_.passwordImg, llRows, llCols);

    std::vector<uint8_t> scrambledBits;
    scrambledBits.reserve(totalBits);

    // Extract each bit
    for (size_t i = 0; i < totalBits; ++i) {
        int blockRow = blockIndices_[i].first * config_.blockSize;
        int blockCol = blockIndices_[i].second * config_.blockSize;

        // Extract block
        Eigen::MatrixXd block = LL.block(blockRow, blockCol, config_.blockSize, config_.blockSize);

        // Apply DCT
        Eigen::MatrixXd dctBlock = dct2d(block);

        // Apply SVD
        Eigen::JacobiSVD<Eigen::MatrixXd> svd(dctBlock, Eigen::ComputeThinU | Eigen::ComputeThinV);
        Eigen::VectorXd S = svd.singularValues();

        // Extract bit using modulo detection
        // wm = (fmod(s0, d1) > d1 / 2) ? 1 : 0
        double s0 = S(0);
        double wm = (std::fmod(s0, config_.d1) > config_.d1 / 2.0) ? 1.0 : 0.0;

        // Combine with second singular value if d2 > 0 (weighted voting)
        if (config_.d2 > 0 && S.size() > 1) {
            double s1 = S(1);
            double tmp = (std::fmod(s1, config_.d2) > config_.d2 / 2.0) ? 1.0 : 0.0;
            wm = (wm * 3.0 + tmp) / 4.0;  // 3:1 weighted voting
        }

        uint8_t bit = (wm > 0.5) ? 1 : 0;
        scrambledBits.push_back(bit);
    }

    // Unscramble bits
    std::vector<uint8_t> unscrambledBits = scrambleBits(scrambledBits, config_.passwordWm, true);

    // Apply majority voting to combine redundant bits
    std::vector<uint8_t> finalBits;
    finalBits.reserve(numBits);
    for (size_t i = 0; i < numBits; ++i) {
        int count1 = 0;
        for (int r = 0; r < config_.redundancy; ++r) {
            if (unscrambledBits[i * config_.redundancy + r] == 1) {
                count1++;
            }
        }
        // Majority voting: if more than half are 1, result is 1
        finalBits.push_back(count1 > config_.redundancy / 2 ? 1 : 0);
    }

    return finalBits;
}

Image BlindWatermarkCore::embed() {
    if (Y_.size() == 0) {
        throw std::runtime_error("No image set");
    }
    if (watermarkBits_.empty()) {
        throw std::runtime_error("No watermark set");
    }

    // Work on a copy of Y channel
    Eigen::MatrixXd Y_embedded = Y_;

    // Embed watermark in Y channel
    embedBits(Y_embedded, watermarkBits_);

    // Convert back to RGB
    Image result;
    result.width = imgWidth_;
    result.height = imgHeight_;
    result.channels = 3;
    yuvToRgb(Y_embedded, U_, V_, result.data);

    return result;
}

std::string BlindWatermarkCore::extractText(const Image& img, size_t wmLength) {
    std::vector<uint8_t> bits = extractBits(img, wmLength);
    return bitsToText(bits);
}

Image BlindWatermarkCore::extractImage(const Image& img, int wmHeight, int wmWidth) {
    size_t numBits = static_cast<size_t>(wmHeight) * wmWidth;
    std::vector<uint8_t> bits = extractBits(img, numBits);
    return bitsToImage(bits, wmHeight, wmWidth);
}

std::vector<uint8_t> BlindWatermarkCore::extractBits(const Image& img, size_t wmLength) {
    if (img.empty() || img.channels != 3) {
        throw std::runtime_error("Invalid image: must be RGB with 3 channels");
    }

    // Convert RGB to YUV
    Eigen::MatrixXd Y, U, V;
    rgbToYuv(img.data, img.width, img.height, Y, U, V);

    // Update dimensions for block index generation
    imgWidth_ = img.width;
    imgHeight_ = img.height;

    // Extract bits from Y channel
    return extractBitsFromChannel(Y, wmLength);
}

} // namespace bwm
