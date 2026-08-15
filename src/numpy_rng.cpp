#include "numpy_rng.hpp"

namespace bwm {

namespace {
constexpr uint32_t kLowerMask = 0x7fffffffU;   // (1u << 31) - 1
constexpr uint32_t kUpperMask = 0x80000000U;   // 1u << 31
constexpr uint32_t kMatrixA = 0x9908b0dfU;
}  // namespace

NumpyRng::NumpyRng(uint32_t seed) {
    // numpy mt19937_seed: standard init_genrand from TAOCP Vol.2
    mt_[0] = seed & 0xffffffffUL;
    for (int i = 1; i < kN; ++i) {
        mt_[i] = (1812433253UL * (mt_[i - 1] ^ (mt_[i - 1] >> 30)) + static_cast<uint32_t>(i));
    }
    pos_ = kN;  // force twist on first next_u32, matching numpy mt19937_next
}

void NumpyRng::twist() {
    for (int i = 0; i < kN; ++i) {
        uint32_t y = (mt_[i] & kUpperMask) | (mt_[(i + 1) % kN] & kLowerMask);
        mt_[i] = mt_[(i + kM) % kN] ^ (y >> 1);
        if (y & 1U) {
            mt_[i] ^= kMatrixA;
        }
    }
    pos_ = 0;
}

uint32_t NumpyRng::next_u32() {
    if (pos_ >= kN) {
        twist();
    }
    uint32_t y = mt_[pos_++];
    // Tempering
    y ^= (y >> 11);
    y ^= (y << 7) & 0x9d2c5680UL;
    y ^= (y << 15) & 0xefc60000UL;
    y ^= (y >> 18);
    return y;
}

double NumpyRng::next_double() {
    // numpy rk_double: 53-bit mantissa from two 32-bit draws
    uint32_t a = next_u32() >> 5;
    uint32_t b = next_u32() >> 6;
    return (static_cast<double>(a) * 67108864.0 + static_cast<double>(b)) / 9007199254740992.0;
}

void NumpyRng::random_matrix(int rows, int cols, std::vector<double>& out) {
    out.resize(static_cast<size_t>(rows) * cols);
    for (double& v : out) {
        v = next_double();
    }
}

uint64_t NumpyRng::next_u64() {
    // numpy mt19937 next_uint64: high 32 bits first
    return (static_cast<uint64_t>(next_u32()) << 32) | next_u32();
}

uint64_t NumpyRng::random_interval(uint64_t max) {
    // numpy 2.x random_interval (distributions.c):
    //   mask = smallest bit mask >= max (or-expand)
    //   if max <= 0xffffffff: value = next_uint32 & mask, accept while value <= max
    //   else:                 value = next_uint64 & mask, accept while value <= max
    if (max == 0) {
        return 0;
    }
    uint64_t mask = max;
    mask |= mask >> 1;
    mask |= mask >> 2;
    mask |= mask >> 4;
    mask |= mask >> 8;
    mask |= mask >> 16;
    mask |= mask >> 32;
    if (max <= 0xffffffffULL) {
        while (true) {
            uint64_t v = static_cast<uint64_t>(next_u32()) & mask;
            if (v <= max) {
                return v;
            }
        }
    }
    while (true) {
        uint64_t v = next_u64() & mask;
        if (v <= max) {
            return v;
        }
    }
}

void NumpyRng::shuffle(std::vector<uint32_t>& arr) {
    // numpy legacy RandomState.shuffle: Fisher-Yates with random_interval(i)
    // (half-open [0, i)), i from n-1 down to 1.
    const size_t n = arr.size();
    if (n <= 1) {
        return;  // nothing to shuffle; also guards n==0 underflow
    }
    for (size_t i = n - 1; i > 0; --i) {
        uint64_t j = random_interval(i);
        std::swap(arr[i], arr[static_cast<size_t>(j)]);
    }
}

}  // namespace bwm

