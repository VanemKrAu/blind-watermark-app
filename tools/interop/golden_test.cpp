// Golden comparison harness for NumpyRng.
// Reads golden lines from stdin, compares with C++ implementation.
#include "numpy_rng.hpp"
#include <cstdint>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include <algorithm>
#include <cstdio>

using namespace bwm;

static std::vector<double> rand_seq(uint32_t seed, int n) {
    NumpyRng rng(seed);
    std::vector<double> v;
    for (int i = 0; i < n; ++i) v.push_back(rng.next_double());
    return v;
}

static std::vector<uint32_t> shuffle_seq(uint32_t seed, int n) {
    std::vector<uint32_t> a(n);
    for (int i = 0; i < n; ++i) a[i] = static_cast<uint32_t>(i);
    NumpyRng rng(seed);
    rng.shuffle(a);
    return a;
}

static std::vector<uint32_t> strategy1_row(uint32_t seed, int row, int rows, int cols) {
    // numpy: RandomState(seed).random(size=(rows, cols)).argsort(axis=1)
    // random fill is row-major continuous; per-row argsort.
    NumpyRng rng(seed);
    std::vector<double> m;
    rng.random_matrix(rows, cols, m);
    std::vector<uint32_t> idx(cols);
    for (int i = 0; i < cols; ++i) idx[i] = static_cast<uint32_t>(i);
    const double* base = m.data() + static_cast<size_t>(row) * cols;
    std::sort(idx.begin(), idx.end(), [base](uint32_t x, uint32_t y) {
        return base[x] < base[y];
    });
    return idx;
}

static std::string fmt_d(double d) {
    char buf[64];
    // 17 significant digits, matching repr(double) round-trip
    std::snprintf(buf, sizeof(buf), "%.17g", d);
    return std::string(buf);
}

int main() {
    std::string line;
    int total = 0, fail = 0;
    while (std::getline(std::cin, line)) {
        if (line.empty()) continue;
        std::istringstream ss(line);
        std::string label;
        ss >> label;
        if (label == "rand") {
            uint32_t seed;
            ss >> seed;
            std::vector<double> got = rand_seq(seed, 10);
            for (int i = 0; i < 10; ++i) {
                std::string want;
                ss >> want;
                std::string g = fmt_d(got[i]);
                ++total;
                if (g != want) {
                    ++fail;
                    std::printf("MISMATCH rand seed=%u idx=%d want=%s got=%s\n", seed, i, want.c_str(), g.c_str());
                }
            }
        } else if (label == "shuf") {
            uint32_t seed;
            int n;
            char c1, c2;
            ss >> seed >> n;
            std::vector<uint32_t> want(n);
            for (int i = 0; i < n; ++i) ss >> want[i];
            std::vector<uint32_t> got = shuffle_seq(seed, n);
            ++total;
            bool ok = (got == want);
            if (!ok) {
                ++fail;
                std::printf("MISMATCH shuf seed=%u n=%d want=[", seed, n);
                for (auto v : want) std::printf("%u ", v);
                std::printf("] got=[");
                for (auto v : got) std::printf("%u ", v);
                std::printf("]\n");
            }
        } else if (label == "strategy1") {
            uint32_t seed;
            int row;
            ss >> seed >> row;
            std::vector<uint32_t> want(16);
            for (int i = 0; i < 16; ++i) ss >> want[i];
            std::vector<uint32_t> got = strategy1_row(seed, row, 8, 16);
            ++total;
            bool ok = (got == want);
            if (!ok) {
                ++fail;
                std::printf("MISMATCH strategy1 seed=%u row=%d want=[", seed, row);
                for (auto v : want) std::printf("%u ", v);
                std::printf("] got=[");
                for (auto v : got) std::printf("%u ", v);
                std::printf("]\n");
            }
        }
    }
    std::printf("golden: total=%d fail=%d %s\n", total, fail, fail == 0 ? "PASS" : "FAIL");
    return fail == 0 ? 0 : 1;
}




