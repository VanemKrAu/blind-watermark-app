#ifndef WATERMARK_CORE_HPP
#define WATERMARK_CORE_HPP

#include <Eigen/Dense>
#include <vector>
#include <cstdint>
#include <string>
#include "image_io.hpp"

namespace bwm {

// Configuration matching guofei9987/blind_watermark defaults.
struct WatermarkConfig {
    int passwordWm = 1;    // seed for watermark bit scrambling
    int passwordImg = 1;   // seed for per-block shuffle permutation
    double d1 = 36.0;      // embed strength, first singular value
    double d2 = 20.0;      // embed strength, second singular value
    int blockSize = 4;     // DCT block size (must be 4 to match Python)
};

// Bit-exact re-implementation of guofei9987/blind_watermark (DWT-DCT-SVD),
// so that watermarks embedded here can be extracted by the Python library
// and vice versa.
class BlindWatermarkCore {
public:
    explicit BlindWatermarkCore(const WatermarkConfig& config = WatermarkConfig());
    ~BlindWatermarkCore() = default;

    enum class WmMode { Str, Img, Bit };

    // Carrier image: RGB(A). Stored as YUV (BT.601), zero-padded to even size.
    void setImage(const Image& img);

    // Watermark payload setters (mode is derived from the last call).
    void setWatermarkText(const std::string& text);
    void setWatermarkImage(const Image& img);   // binarized at >128, grayscale
    void setWatermarkBits(const std::vector<uint8_t>& bits);

    size_t getWatermarkSize() const { return wm_bit_.size(); }
    WmMode mode() const { return mode_; }

    // Embed watermark into the carrier image. Returns RGB(A) image.
    Image embed();

    // Extract raw averaged bit values in [0, 1] (before kmeans/decryption).
    // Mirrors WaterMarkCore.extract().
    std::vector<double> extractRaw(const Image& img, size_t wmSize);

    // Full pipeline for mode==Str: extract -> kmeans -> decrypt -> utf-8 text.
    std::string extractText(const Image& img, size_t wmLength);

    // Full pipeline for mode==Img: extract -> decrypt -> 255*v grayscale image.
    Image extractImage(const Image& img, int wmHeight, int wmWidth);

    // Full pipeline for mode==Bit: extract -> kmeans -> decrypt -> 0/1 bits.
    std::vector<uint8_t> extractBits(const Image& img, size_t wmLength);

private:
    WatermarkConfig config_;
    WmMode mode_ = WmMode::Bit;

    // Carrier YUV channels (double), padded to even dimensions.
    int img_w_ = 0;
    int img_h_ = 0;
    std::vector<Eigen::MatrixXd> yuv_;  // size 3

    // Watermark bits (0/1).
    std::vector<uint8_t> wm_bit_;
    int wm_img_w_ = 0;
    int wm_img_h_ = 0;

    // Per-block 16-element shuffle permutations (passwordImg-derived).
    std::vector<std::vector<uint32_t>> idx_shuffle_;
    int block_num_ = 0;
    int blocks_per_row_ = 0;
    int blocks_per_col_ = 0;

    // RGB(A) -> YUV + zero-pad to even size (cv2.copyMakeBorder BORDER_CONSTANT 0).
    void prepare(const Image& img, std::vector<Eigen::MatrixXd>& outYuv, int& w, int& h);
    // (re)build idx_shuffle_ for the current image size.
    void buildShuffle(int blockNum);
    // Embed bits into one YUV channel matrix (in place, full image matrix).
    void embedChannel(Eigen::MatrixXd& channel);
    // Extract per-block bits from all channels. Returns 3 x block_num values in [0,1].
    std::vector<std::vector<double>> extractRawChannels(const Image& img);
    // Average over channels and repetition rounds -> wm_size values.
    static std::vector<double> extractAvg(const std::vector<std::vector<double>>& blockBits, size_t wmSize);
    // Undo passwordWm scramble: wm_avg[wm_index] = wm_avg.copy()
    void decrypt(std::vector<double>& wmAvg);

    // Bit payload encoding (bit-exact with the Python library).
    static std::vector<uint8_t> textToBits(const std::string& text);
    static std::string bitsToText(const std::vector<uint8_t>& bits);
    static std::vector<uint8_t> imgToBits(const Image& img);
    static Image bitsToGrayImage(const std::vector<double>& vals, int h, int w);
    static std::vector<uint8_t> kmeans01(const std::vector<double>& inputs);

    // Block-level operations.
    static Eigen::MatrixXd blockAddWm(const Eigen::MatrixXd& block,
                                      const std::vector<uint32_t>& shuffler,
                                      double wm1, double d1, double d2);
    static double blockGetWm(const Eigen::MatrixXd& block,
                             const std::vector<uint32_t>& shuffler,
                             double d1, double d2);
};

}  // namespace bwm

#endif  // WATERMARK_CORE_HPP
