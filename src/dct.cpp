#include "dct.hpp"
#include <cmath>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace bwm {

Eigen::MatrixXd createDctMatrix(int N) {
    Eigen::MatrixXd C(N, N);
    double scale0 = std::sqrt(1.0 / N);
    double scaleK = std::sqrt(2.0 / N);

    for (int k = 0; k < N; ++k) {
        double scale = (k == 0) ? scale0 : scaleK;
        for (int n = 0; n < N; ++n) {
            C(k, n) = scale * std::cos(M_PI * k * (2.0 * n + 1.0) / (2.0 * N));
        }
    }
    return C;
}

Eigen::MatrixXd createIdctMatrix(int N) {
    // IDCT matrix is the transpose of DCT matrix
    return createDctMatrix(N).transpose();
}

Eigen::VectorXd dct1d(const Eigen::VectorXd& input) {
    int N = static_cast<int>(input.size());
    Eigen::VectorXd output(N);

    double scale0 = std::sqrt(1.0 / N);
    double scaleK = std::sqrt(2.0 / N);

    for (int k = 0; k < N; ++k) {
        double sum = 0.0;
        for (int n = 0; n < N; ++n) {
            sum += input(n) * std::cos(M_PI * k * (2.0 * n + 1.0) / (2.0 * N));
        }
        output(k) = ((k == 0) ? scale0 : scaleK) * sum;
    }

    return output;
}

Eigen::VectorXd idct1d(const Eigen::VectorXd& input) {
    int N = static_cast<int>(input.size());
    Eigen::VectorXd output(N);

    double scale0 = std::sqrt(1.0 / N);
    double scaleK = std::sqrt(2.0 / N);

    for (int n = 0; n < N; ++n) {
        double sum = 0.0;
        for (int k = 0; k < N; ++k) {
            double ck = (k == 0) ? scale0 : scaleK;
            sum += ck * input(k) * std::cos(M_PI * k * (2.0 * n + 1.0) / (2.0 * N));
        }
        output(n) = sum;
    }

    return output;
}

Eigen::MatrixXd dct2d(const Eigen::MatrixXd& input) {
    int rows = static_cast<int>(input.rows());
    int cols = static_cast<int>(input.cols());

    // For efficiency, use matrix multiplication approach for larger matrices
    // DCT(A) = C * A * C^T where C is the DCT matrix

    // Create DCT matrices
    Eigen::MatrixXd C_rows = createDctMatrix(rows);
    Eigen::MatrixXd C_cols = createDctMatrix(cols);

    // Apply 2D DCT: output = C_rows * input * C_cols^T
    return C_rows * input * C_cols.transpose();
}

Eigen::MatrixXd idct2d(const Eigen::MatrixXd& input) {
    int rows = static_cast<int>(input.rows());
    int cols = static_cast<int>(input.cols());

    // Create IDCT matrices (transpose of DCT matrices)
    Eigen::MatrixXd C_rows = createDctMatrix(rows);
    Eigen::MatrixXd C_cols = createDctMatrix(cols);

    // Apply 2D IDCT: output = C_rows^T * input * C_cols
    return C_rows.transpose() * input * C_cols;
}

} // namespace bwm
