#include "watermark_core.hpp"
#include "color_convert.hpp"
#include "dwt.hpp"
#include "dct.hpp"
#include "numpy_rng.hpp"
#include <Eigen/SVD>
#include <algorithm>
#include <cmath>
#include <cstring>

namespace bwm {

namespace {

// numpy floor division semantics for positive values: std::floor(s / d).
inline double floorDiv(double s, double d) { return std::floor(s / d); }

// x[shuffler] = y  (scatter), 16 elements.
void scatterShuffled(double* x, const double* y, const std::vector<uint32_t>& shuffler) {
    for (int k = 0; k < 16; ++k) {
        x[shuffler[k]] = y[k];
    }
}

// y[k] = x[shuffler[k]] (gather), 16 elements.
void gatherShuffled(double* y, const double* x, const std::vector<uint32_t>& shuffler) {
    for (int k = 0; k < 16; ++k) {
        y[k] = x[shuffler[k]];
    }
}

std::string utf8DecodeReplace(const std::string& bytes) {
    // Python bytes.decode('utf-8', errors='replace'): invalid sequences -> U+FFFD.
    std::string out;
    out.reserve(bytes.size());
    size_t i = 0;
    const size_t n = bytes.size();
    while (i < n) {
        unsigned char c = static_cast<unsigned char>(bytes[i]);
        if (c < 0x80) {
            out.push_back(static_cast<char>(c));
            ++i;
        } else if ((c & 0xE0) == 0xC0) {
            if (i + 1 < n && (static_cast<unsigned char>(bytes[i + 1]) & 0xC0) == 0x80) {
                unsigned char c2 = static_cast<unsigned char>(bytes[i + 1]);
                unsigned cp = ((c & 0x1F) << 6) | (c2 & 0x3F);
                if (cp >= 0x80) {
                    if (cp < 0x800) {
                        out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
                        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
                    } else {
                        out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
                        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
                        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
                    }
                    i += 2;
                    continue;
                }
            }
            out += "\xEF\xBF\xBD";
            ++i;
        } else if ((c & 0xF0) == 0xE0) {
            if (i + 2 < n && (static_cast<unsigned char>(bytes[i + 1]) & 0xC0) == 0x80 &&
                (static_cast<unsigned char>(bytes[i + 2]) & 0xC0) == 0x80) {
                unsigned c2 = static_cast<unsigned char>(bytes[i + 1]);
                unsigned c3 = static_cast<unsigned char>(bytes[i + 2]);
                unsigned cp = ((c & 0x0F) << 12) | ((c2 & 0x3F) << 6) | (c3 & 0x3F);
                if (cp >= 0x800) {
                    out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
                    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
                    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
                    i += 3;
                    continue;
                }
            }
            out += "\xEF\xBF\xBD";
            ++i;
        } else if ((c & 0xF8) == 0xF0) {
            if (i + 3 < n && (static_cast<unsigned char>(bytes[i + 1]) & 0xC0) == 0x80 &&
                (static_cast<unsigned char>(bytes[i + 2]) & 0xC0) == 0x80 &&
                (static_cast<unsigned char>(bytes[i + 3]) & 0xC0) == 0x80) {
                unsigned c2 = static_cast<unsigned char>(bytes[i + 1]);
                unsigned c3 = static_cast<unsigned char>(bytes[i + 2]);
                unsigned c4 = static_cast<unsigned char>(bytes[i + 3]);
                unsigned cp = ((c & 0x07) << 18) | ((c2 & 0x3F) << 12) | ((c3 & 0x3F) << 6) | (c4 & 0x3F);
                if (cp >= 0x10000) {
                    out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
                    out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
                    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
                    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
                    i += 4;
                    continue;
                }
            }
            out += "\xEF\xBF\xBD";
            ++i;
        } else {
            out += "\xEF\xBF\xBD";
            ++i;
        }
    }
    return out;
}

}  // namespace

BlindWatermarkCore::BlindWatermarkCore(const WatermarkConfig& config) : config_(config) {}

void BlindWatermarkCore::setImage(const Image& img) {
    prepare(img, yuv_, img_w_, img_h_);
}

void BlindWatermarkCore::setWatermarkText(const std::string& text) {
    mode_ = WmMode::Str;
    wm_bit_ = textToBits(text);
    // Python: np.random.RandomState(password_wm).shuffle(wm_bit)
    std::vector<uint32_t> idx(wm_bit_.size());
    for (size_t i = 0; i < idx.size(); ++i) idx[i] = static_cast<uint32_t>(i);
    NumpyRng rng(static_cast<uint32_t>(config_.passwordWm));
    rng.shuffle(idx);
    std::vector<uint8_t> shuffled(wm_bit_.size());
    for (size_t i = 0; i < idx.size(); ++i) shuffled[i] = wm_bit_[idx[i]];
    wm_bit_ = std::move(shuffled);
    wm_img_w_ = wm_img_h_ = 0;
}

void BlindWatermarkCore::setWatermarkImage(const Image& img) {
    mode_ = WmMode::Img;
    wm_img_w_ = img.width;
    wm_img_h_ = img.height;
    wm_bit_ = imgToBits(img);
    std::vector<uint32_t> idx(wm_bit_.size());
    for (size_t i = 0; i < idx.size(); ++i) idx[i] = static_cast<uint32_t>(i);
    NumpyRng rng(static_cast<uint32_t>(config_.passwordWm));
    rng.shuffle(idx);
    std::vector<uint8_t> shuffled(wm_bit_.size());
    for (size_t i = 0; i < idx.size(); ++i) shuffled[i] = wm_bit_[idx[i]];
    wm_bit_ = std::move(shuffled);
}

void BlindWatermarkCore::setWatermarkBits(const std::vector<uint8_t>& bits) {
    mode_ = WmMode::Bit;
    wm_img_w_ = wm_img_h_ = 0;
    wm_bit_ = bits;
    std::vector<uint32_t> idx(wm_bit_.size());
    for (size_t i = 0; i < idx.size(); ++i) idx[i] = static_cast<uint32_t>(i);
    NumpyRng rng(static_cast<uint32_t>(config_.passwordWm));
    rng.shuffle(idx);
    std::vector<uint8_t> shuffled(wm_bit_.size());
    for (size_t i = 0; i < idx.size(); ++i) shuffled[i] = wm_bit_[idx[i]];
    wm_bit_ = std::move(shuffled);
}

// ---------------------------------------------------------------------------
// Preparation: RGB(A) -> YUV (BT.601), zero-pad to even dimensions.
// Matches cv2.cvtColor(BGR2YUV) + cv2.copyMakeBorder(BORDER_CONSTANT, 0, 0, h%2, 0, w%2).
// ---------------------------------------------------------------------------
void BlindWatermarkCore::prepare(const Image& img, std::vector<Eigen::MatrixXd>& outYuv,
                                 int& w, int& h) {
    if (img.empty()) {
        throw std::runtime_error("Invalid image");
    }
    // Treat input as RGB (channel order is preserved as-is; BT.601 coeffs same for BGR
    // vs RGB ordering, since the transform is symmetric per-channel).
    std::vector<uint8_t> rgb = img.data;
    int channels = img.channels;
    if (channels == 4) {
        // Drop alpha (matches Python: img[:, :, :3]).
        std::vector<uint8_t> tmp(static_cast<size_t>(img.width) * img.height * 3);
        for (size_t i = 0; i < tmp.size(); ++i) {
            tmp[i] = img.data[i / 3 * 4 + i % 3];
        }
        rgb = std::move(tmp);
        channels = 3;
    }

    Eigen::MatrixXd Y, U, V;
    rgbToYuv(rgb, img.width, img.height, Y, U, V);

    const int padRows = img.height % 2;
    const int padCols = img.width % 2;
    const int pH = img.height + padRows;
    const int pW = img.width + padCols;

    outYuv.resize(3);
    outYuv[0] = Eigen::MatrixXd::Zero(pH, pW);
    outYuv[1] = Eigen::MatrixXd::Zero(pH, pW);
    outYuv[2] = Eigen::MatrixXd::Zero(pH, pW);
    outYuv[0].topLeftCorner(img.height, img.width) = Y;
    outYuv[1].topLeftCorner(img.height, img.width) = U;
    outYuv[2].topLeftCorner(img.height, img.width) = V;
    // Rest is zero (BORDER_CONSTANT value=(0,0,0)).

    w = img.width;
    h = img.height;
}

// ---------------------------------------------------------------------------
// Per-block shuffle permutations: numpy RandomState(seed).random((num,16)).argsort(axis=1)
// ---------------------------------------------------------------------------
void BlindWatermarkCore::buildShuffle(int blockNum) {
    idx_shuffle_.clear();
    idx_shuffle_.resize(blockNum);
    NumpyRng rng(static_cast<uint32_t>(config_.passwordImg));
    std::vector<double> m;
    rng.random_matrix(blockNum, 16, m);
    for (int b = 0; b < blockNum; ++b) {
        std::vector<uint32_t>& perm = idx_shuffle_[b];
        perm.resize(16);
        for (int k = 0; k < 16; ++k) perm[k] = static_cast<uint32_t>(k);
        const double* base = m.data() + static_cast<size_t>(b) * 16;
        std::sort(perm.begin(), perm.end(), [base](uint32_t x, uint32_t y) {
            return base[x] < base[y];
        });
    }
}

// ---------------------------------------------------------------------------
// Embedding core (block_add_wm_slow, the default 'common' mode):
// dct -> flatten -> shuffle -> svd -> modify s0,s1 -> rebuild -> unshuffle -> idct
// ---------------------------------------------------------------------------
Eigen::MatrixXd BlindWatermarkCore::blockAddWm(const Eigen::MatrixXd& block,
                                               const std::vector<uint32_t>& shuffler,
                                               double wm1, double d1, double d2) {
    Eigen::MatrixXd blockDct = dct2d(block);

    // block_dct_shuffled = block_dct.flatten()[shuffler].reshape(4,4)
    // flatten in row-major order like numpy
    double flat[16], shuffled[16];
    for (int r = 0; r < 4; ++r) {
        for (int c = 0; c < 4; ++c) {
            flat[r * 4 + c] = blockDct(r, c);
        }
    }
    gatherShuffled(shuffled, flat, shuffler);

    Eigen::Map<Eigen::Matrix<double, 4, 4, Eigen::RowMajor>> shufMat(shuffled, 4, 4);

    Eigen::JacobiSVD<Eigen::MatrixXd> svd(shufMat, Eigen::ComputeFullU | Eigen::ComputeFullV);
    Eigen::VectorXd s = svd.singularValues();
    Eigen::MatrixXd u = svd.matrixU();
    Eigen::MatrixXd v = svd.matrixV();

    // s[0] = (s[0] // d1 + 1/4 + 1/2 * wm_1) * d1
    s[0] = (floorDiv(s[0], d1) + 0.25 + 0.5 * wm1) * d1;
    if (d2 > 0 && s.size() > 1) {
        s[1] = (floorDiv(s[1], d2) + 0.25 + 0.5 * wm1) * d2;
    }

    Eigen::MatrixXd rebuilt = u * s.asDiagonal() * v.transpose();

    // block_dct_flatten[shuffler] = block_dct_flatten.copy() (scatter back)
    double outFlat[16];
    for (int r = 0; r < 4; ++r) {
        for (int c = 0; c < 4; ++c) {
            outFlat[r * 4 + c] = rebuilt(r, c);
        }
    }
    double scattered[16];
    scatterShuffled(scattered, outFlat, shuffler);

    Eigen::Map<Eigen::Matrix<double, 4, 4, Eigen::RowMajor>> scatMat(scattered, 4, 4);
    return idct2d(scatMat);
}

void BlindWatermarkCore::embedChannel(Eigen::MatrixXd& channel) {
    DwtResult dwt = dwt2d(channel);
    Eigen::MatrixXd& LL = dwt.LL;

    const int llRows = static_cast<int>(LL.rows());
    const int llCols = static_cast<int>(LL.cols());
    blocks_per_col_ = llRows / config_.blockSize;
    blocks_per_row_ = llCols / config_.blockSize;
    const int blockNum = blocks_per_col_ * blocks_per_row_;
    if (blockNum <= 0) {
        throw std::runtime_error("Image too small for watermark");
    }
    if (static_cast<int>(wm_bit_.size()) >= blockNum) {
        // mirrors Python assert wm_size < block_num
        throw std::runtime_error("Watermark too large for image");
    }
    if (idx_shuffle_.size() != static_cast<size_t>(blockNum)) {
        buildShuffle(blockNum);
    }
    block_num_ = blockNum;

    const size_t wmSize = wm_bit_.size();
    for (int b = 0; b < blockNum; ++b) {
        const int r = b / blocks_per_row_;
        const int c = b % blocks_per_row_;
        Eigen::MatrixXd block = LL.block(r * 4, c * 4, 4, 4);
        const double wm1 = wm_bit_[static_cast<size_t>(b) % wmSize] ? 1.0 : 0.0;
        Eigen::MatrixXd newBlock =
            blockAddWm(block, idx_shuffle_[b], wm1, config_.d1, config_.d2);
        LL.block(r * 4, c * 4, 4, 4) = newBlock;
    }

    // embed_ca[:, :] = ca_part only over complete-block region (rest unchanged)
    // (we wrote blocks in place into LL, which is exactly the same region)

    // Reconstruct
    Eigen::MatrixXd recon = idwt2d(dwt);
    // Crop back to padded size (input channel was already padded to even)
    channel = recon;
}

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------
double BlindWatermarkCore::blockGetWm(const Eigen::MatrixXd& block,
                                      const std::vector<uint32_t>& shuffler,
                                      double d1, double d2) {
    Eigen::MatrixXd blockDct = dct2d(block);
    double flat[16], shuffled[16];
    for (int r = 0; r < 4; ++r) {
        for (int c = 0; c < 4; ++c) {
            flat[r * 4 + c] = blockDct(r, c);
        }
    }
    gatherShuffled(shuffled, flat, shuffler);

    Eigen::Map<Eigen::Matrix<double, 4, 4, Eigen::RowMajor>> shufMat(shuffled, 4, 4);
    Eigen::JacobiSVD<Eigen::MatrixXd> svd(shufMat, Eigen::ComputeFullU | Eigen::ComputeFullV);
    Eigen::VectorXd s = svd.singularValues();

    // wm = (s[0] % d1 > d1/2) * 1
    double wm = std::fmod(s[0], d1) > d1 / 2.0 ? 1.0 : 0.0;
    if (d2 > 0 && s.size() > 1) {
        double tmp = std::fmod(s[1], d2) > d2 / 2.0 ? 1.0 : 0.0;
        wm = (wm * 3.0 + tmp) / 4.0;
    }
    return wm;
}

std::vector<std::vector<double>> BlindWatermarkCore::extractRawChannels(const Image& img) {
    std::vector<Eigen::MatrixXd> yuv;
    int w, h;
    prepare(img, yuv, w, h);

    DwtResult dwt0 = dwt2d(yuv[0]);
    const int llRows = static_cast<int>(dwt0.LL.rows());
    const int llCols = static_cast<int>(dwt0.LL.cols());
    const int bpc = llRows / config_.blockSize;
    const int bpr = llCols / config_.blockSize;
    const int blockNum = bpc * bpr;
    if (blockNum <= 0) {
        throw std::runtime_error("Image too small to extract");
    }
    if (idx_shuffle_.size() != static_cast<size_t>(blockNum)) {
        buildShuffle(blockNum);
    }
    blocks_per_col_ = bpc;
    blocks_per_row_ = bpr;
    block_num_ = blockNum;

    std::vector<std::vector<double>> result(3, std::vector<double>(blockNum, 0.0));
    for (int ch = 0; ch < 3; ++ch) {
        DwtResult dwt = dwt2d(yuv[ch]);
        const Eigen::MatrixXd& LL = dwt.LL;
        for (int b = 0; b < blockNum; ++b) {
            const int r = b / bpr;
            const int c = b % bpr;
            Eigen::MatrixXd block = LL.block(r * 4, c * 4, 4, 4);
            result[ch][b] = blockGetWm(block, idx_shuffle_[b], config_.d1, config_.d2);
        }
    }
    return result;
}

std::vector<double> BlindWatermarkCore::extractAvg(
    const std::vector<std::vector<double>>& blockBits, size_t wmSize) {
    // wm_avg[i] = wm_block_bit[:, i::wm_size].mean()
    if (wmSize == 0) {
        return std::vector<double>();  // guard against i % 0
    }
    std::vector<double> avg(wmSize, 0.0);
    std::vector<double> cnt(wmSize, 0.0);
    for (int ch = 0; ch < 3; ++ch) {
        for (size_t i = 0; i < blockBits[ch].size(); ++i) {
            avg[i % wmSize] += blockBits[ch][i];
            cnt[i % wmSize] += 1.0;
        }
    }
    for (size_t i = 0; i < wmSize; ++i) {
        avg[i] /= cnt[i];
    }
    return avg;
}

void BlindWatermarkCore::decrypt(std::vector<double>& wmAvg) {
    // wm_index = arange(wm_size); RandomState(password_wm).shuffle(wm_index)
    // wm_avg[wm_index] = wm_avg.copy()
    const size_t n = wmAvg.size();
    std::vector<uint32_t> idx(n);
    for (size_t i = 0; i < n; ++i) idx[i] = static_cast<uint32_t>(i);
    NumpyRng rng(static_cast<uint32_t>(config_.passwordWm));
    rng.shuffle(idx);
    std::vector<double> old = wmAvg;
    for (size_t i = 0; i < n; ++i) {
        wmAvg[idx[i]] = old[i];
    }
}

std::vector<double> BlindWatermarkCore::extractRaw(const Image& img, size_t wmSize) {
    auto blockBits = extractRawChannels(img);
    std::vector<double> avg = extractAvg(blockBits, wmSize);
    decrypt(avg);
    return avg;
}

std::vector<uint8_t> BlindWatermarkCore::kmeans01(const std::vector<double>& inputs) {
    // numpy one_dim_kmeans
    if (inputs.empty()) {
        return std::vector<uint8_t>();
    }
    double threshold = 0.0;
    const double eTol = 1e-6;
    double c0 = *std::min_element(inputs.begin(), inputs.end());
    double c1 = *std::max_element(inputs.begin(), inputs.end());
    const size_t n = inputs.size();
    for (int it = 0; it < 300; ++it) {
        threshold = (c0 + c1) / 2.0;
        std::vector<uint8_t> is01(n);
        double sum0 = 0.0, sum1 = 0.0;
        size_t cnt0 = 0, cnt1 = 0;
        for (size_t i = 0; i < n; ++i) {
            if (inputs[i] > threshold) {
                is01[i] = 1;
                sum1 += inputs[i];
                ++cnt1;
            } else {
                sum0 += inputs[i];
                ++cnt0;
            }
        }
        c0 = cnt0 ? sum0 / cnt0 : 0.0;
        c1 = cnt1 ? sum1 / cnt1 : 0.0;
        if (std::abs((c0 + c1) / 2.0 - threshold) < eTol) {
            threshold = (c0 + c1) / 2.0;
            break;
        }
    }
    std::vector<uint8_t> out(n);
    for (size_t i = 0; i < n; ++i) out[i] = inputs[i] > threshold ? 1 : 0;
    return out;
}

std::string BlindWatermarkCore::extractText(const Image& img, size_t wmLength) {
    std::vector<double> avg = extractRaw(img, wmLength);
    std::vector<uint8_t> bits = kmeans01(avg);
    return bitsToText(bits);
}

Image BlindWatermarkCore::extractImage(const Image& img, int wmHeight, int wmWidth) {
    size_t numBits = static_cast<size_t>(wmHeight) * wmWidth;
    std::vector<double> avg = extractRaw(img, numBits);
    return bitsToGrayImage(avg, wmHeight, wmWidth);
}

std::vector<uint8_t> BlindWatermarkCore::extractBits(const Image& img, size_t wmLength) {
    std::vector<double> avg = extractRaw(img, wmLength);
    return kmeans01(avg);
}

// ---------------------------------------------------------------------------
// Payload encoding (bit-exact with the Python library)
// ---------------------------------------------------------------------------

// Python: bin(int(wm.encode('utf-8').hex(), base=16))[2:]
// -> hex string -> big integer -> binary string without leading zeros.
std::vector<uint8_t> BlindWatermarkCore::textToBits(const std::string& text) {
    // utf-8 bytes -> hex string
    if (text.empty()) {
        return std::vector<uint8_t>();
    }
    std::string hex;
    static const char* kDigits = "0123456789abcdef";
    for (unsigned char c : text) {
        hex.push_back(kDigits[c >> 4]);
        hex.push_back(kDigits[c & 0x0F]);
    }
    // hex -> binary bit string (no leading zeros), then bits
    std::string bits;
    bits.reserve(hex.size() * 4);
    for (char h : hex) {
        int v = (h <= '9') ? (h - '0') : (h - 'a' + 10);
        for (int b = 3; b >= 0; --b) {
            bits.push_back(((v >> b) & 1) ? '1' : '0');
        }
    }
    // strip leading '0' (int() semantics); if empty -> "0"
    size_t start = bits.find_first_not_of('0');
    if (start == std::string::npos) {
        start = bits.size() - 1;  // "0"
    }
    std::vector<uint8_t> out;
    out.reserve(bits.size() - start);
    for (size_t i = start; i < bits.size(); ++i) {
        out.push_back(bits[i] == '1' ? 1 : 0);
    }
    return out;
}

// Python: bytes.fromhex(hex(int(byte, base=2))[2:]).decode('utf-8', errors='replace')
std::string BlindWatermarkCore::bitsToText(const std::vector<uint8_t>& bits) {
    if (bits.empty()) return std::string();
    // binary string -> value -> hex (int strips leading zeros; 0 -> "0")
    std::string bitstr;
    bitstr.reserve(bits.size());
    for (uint8_t b : bits) bitstr.push_back(b ? '1' : '0');
    // pad to multiple of 4
    size_t pad = (4 - bitstr.size() % 4) % 4;
    std::string padded(pad, '0');
    padded += bitstr;
    std::string hex;
    static const char* kDigits = "0123456789abcdef";
    for (size_t i = 0; i < padded.size(); i += 4) {
        int v = (padded[i] - '0') * 8 + (padded[i + 1] - '0') * 4 +
                (padded[i + 2] - '0') * 2 + (padded[i + 3] - '0');
        hex.push_back(kDigits[v]);
    }
    // strip leading '0' hex chars (hex(int) shortest form); if all zero -> "0"
    size_t start = hex.find_first_not_of('0');
    if (start == std::string::npos) {
        start = hex.size() - 1;
    }
    hex = hex.substr(start);
    if (hex.size() % 2 == 1) {
        // Python bytes.fromhex raises on odd length; mirror by returning empty
        return std::string();
    }
    std::string bytes;
    bytes.reserve(hex.size() / 2);
    for (size_t i = 0; i < hex.size(); i += 2) {
        auto nib = [](char c) -> int {
            return (c <= '9') ? (c - '0') : (c - 'a' + 10);
        };
        bytes.push_back(static_cast<char>((nib(hex[i]) << 4) | nib(hex[i + 1])));
    }
    return utf8DecodeReplace(bytes);
}

// Python: wm.flatten() > 128  (grayscale image)
std::vector<uint8_t> BlindWatermarkCore::imgToBits(const Image& img) {
    std::vector<uint8_t> bits;
    bits.reserve(static_cast<size_t>(img.width) * img.height);
    for (int y = 0; y < img.height; ++y) {
        for (int x = 0; x < img.width; ++x) {
            uint8_t v = 0;
            if (img.channels == 1) {
                v = img.at(x, y, 0);
            } else {
                double r = img.at(x, y, 0);
                double g = img.at(x, y, 1);
                double b = img.at(x, y, 2);
                v = static_cast<uint8_t>(std::round(0.299 * r + 0.587 * g + 0.114 * b));
            }
            bits.push_back(v > 128 ? 1 : 0);
        }
    }
    return bits;
}

// Python: 255 * wm_avg.reshape(h, w)
Image BlindWatermarkCore::bitsToGrayImage(const std::vector<double>& vals, int h, int w) {
    Image img;
    img.allocate(w, h, 1);
    size_t idx = 0;
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            double v = 255.0 * (idx < vals.size() ? vals[idx] : 0.0);
            v = v < 0 ? 0 : (v > 255 ? 255 : v);
            img.set(x, y, 0, static_cast<uint8_t>(std::round(v)));
            ++idx;
        }
    }
    return img;
}

// ---------------------------------------------------------------------------
// Embed full image
// ---------------------------------------------------------------------------
Image BlindWatermarkCore::embed() {
    if (yuv_.size() != 3) {
        throw std::runtime_error("No image set");
    }
    if (wm_bit_.empty()) {
        throw std::runtime_error("No watermark set");
    }

    // Embed in place: the previous copies of all three channels peaked at
    // ~+75MB on a 2048px image — meaningful on low-RAM phones, and nothing
    // reads yuv_ after embed(). Bit-identical results (same math on the same
    // matrices).
    for (int ch = 0; ch < 3; ++ch) {
        embedChannel(yuv_[ch]);
    }

    // Reconstruct: padded YUV -> RGB
    const int pH = static_cast<int>(yuv_[0].rows());
    const int pW = static_cast<int>(yuv_[0].cols());

    // yuvToRgb works on full matrices; crop to original size first.
    Eigen::MatrixXd Y = yuv_[0].topLeftCorner(img_h_, img_w_);
    Eigen::MatrixXd U = yuv_[1].topLeftCorner(img_h_, img_w_);
    Eigen::MatrixXd V = yuv_[2].topLeftCorner(img_h_, img_w_);

    std::vector<uint8_t> rgb;
    yuvToRgb(Y, U, V, rgb);

    // clip 0-255 already handled inside yuvToRgb (clamp255 + round)
    Image result;
    result.width = img_w_;
    result.height = img_h_;
    result.channels = 3;
    result.data = std::move(rgb);
    return result;
}

}  // namespace bwm

