#ifndef BWM_NUMPY_RNG_HPP
#define BWM_NUMPY_RNG_HPP

#include <cstdint>
#include <vector>

namespace bwm {

// MT19937 random generator that reproduces numpy legacy RandomState bit-for-bit.
// Implements: mt19937_seed / mt19937_next (tempering), rk_double (53-bit double),
// rk_interval (bounded int via rejection sampling, inclusive max),
// Fisher-Yates shuffle matching numpy RandomState.shuffle, and
// random(size=(rows,cols)) row-major fill matching numpy random_sample.
class NumpyRng {
public:
    explicit NumpyRng(uint32_t seed);

    // rk_random: next tempered uint32 from MT19937
    uint32_t next_u32();

    // rk_double: numpy random_sample double in [0, 1)
    double next_double();

    // numpy 2.x legacy shuffle path: next_uint64 = (u32 << 32) | u32
    uint64_t next_u64();

    // numpy random_interval(max): uniform in [0, max) via Lemire mask-rejection
    uint64_t random_interval(uint64_t max);

    // numpy: RandomState(seed).shuffle(arr) - Fisher-Yates over the whole vector
    void shuffle(std::vector<uint32_t>& arr);

    // numpy: RandomState(seed).random(size=(rows, cols)) - row-major fill
    void random_matrix(int rows, int cols, std::vector<double>& out);

private:
    static constexpr int kN = 624;
    static constexpr int kM = 397;
    uint32_t mt_[kN];
    int pos_;
    void twist();
};

}  // namespace bwm

#endif  // BWM_NUMPY_RNG_HPP
