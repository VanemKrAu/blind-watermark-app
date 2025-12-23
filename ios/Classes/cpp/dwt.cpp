#include "dwt.hpp"
#include <cmath>

namespace bwm {

// Haar wavelet coefficients
static const double SQRT2 = std::sqrt(2.0);
static const double INV_SQRT2 = 1.0 / SQRT2;

Eigen::MatrixXd padToEven(const Eigen::MatrixXd& input) {
    int rows = static_cast<int>(input.rows());
    int cols = static_cast<int>(input.cols());
    int newRows = (rows % 2 == 0) ? rows : rows + 1;
    int newCols = (cols % 2 == 0) ? cols : cols + 1;

    if (newRows == rows && newCols == cols) {
        return input;
    }

    Eigen::MatrixXd padded = Eigen::MatrixXd::Zero(newRows, newCols);
    padded.block(0, 0, rows, cols) = input;

    // Mirror padding for extra row/column
    if (newRows > rows) {
        padded.row(rows) = padded.row(rows - 1);
    }
    if (newCols > cols) {
        padded.col(cols) = padded.col(cols - 1);
    }

    return padded;
}

Eigen::MatrixXd cropToOriginal(const Eigen::MatrixXd& input, int origRows, int origCols) {
    return input.block(0, 0, origRows, origCols);
}

DwtResult dwt2d(const Eigen::MatrixXd& input) {
    int rows = static_cast<int>(input.rows());
    int cols = static_cast<int>(input.cols());

    // Ensure even dimensions
    Eigen::MatrixXd padded = padToEven(input);
    int pRows = static_cast<int>(padded.rows());
    int pCols = static_cast<int>(padded.cols());

    // Apply 1D DWT to rows
    Eigen::MatrixXd rowTransformed(pRows, pCols);

    for (int r = 0; r < pRows; ++r) {
        for (int c = 0; c < pCols / 2; ++c) {
            double a = padded(r, 2 * c);
            double b = padded(r, 2 * c + 1);

            // Haar wavelet transform
            rowTransformed(r, c) = (a + b) * INV_SQRT2;           // Low-pass
            rowTransformed(r, pCols / 2 + c) = (a - b) * INV_SQRT2; // High-pass
        }
    }

    // Apply 1D DWT to columns
    Eigen::MatrixXd result(pRows, pCols);

    for (int c = 0; c < pCols; ++c) {
        for (int r = 0; r < pRows / 2; ++r) {
            double a = rowTransformed(2 * r, c);
            double b = rowTransformed(2 * r + 1, c);

            result(r, c) = (a + b) * INV_SQRT2;                // Low-pass
            result(pRows / 2 + r, c) = (a - b) * INV_SQRT2;    // High-pass
        }
    }

    // Extract subbands
    DwtResult dwt;
    int halfRows = pRows / 2;
    int halfCols = pCols / 2;

    dwt.LL = result.block(0, 0, halfRows, halfCols);
    dwt.LH = result.block(0, halfCols, halfRows, halfCols);
    dwt.HL = result.block(halfRows, 0, halfRows, halfCols);
    dwt.HH = result.block(halfRows, halfCols, halfRows, halfCols);

    return dwt;
}

Eigen::MatrixXd idwt2d(const DwtResult& dwt) {
    int halfRows = static_cast<int>(dwt.LL.rows());
    int halfCols = static_cast<int>(dwt.LL.cols());
    int rows = halfRows * 2;
    int cols = halfCols * 2;

    // Reconstruct from subbands
    Eigen::MatrixXd combined(rows, cols);
    combined.block(0, 0, halfRows, halfCols) = dwt.LL;
    combined.block(0, halfCols, halfRows, halfCols) = dwt.LH;
    combined.block(halfRows, 0, halfRows, halfCols) = dwt.HL;
    combined.block(halfRows, halfCols, halfRows, halfCols) = dwt.HH;

    // Inverse DWT on columns
    Eigen::MatrixXd colReconstructed(rows, cols);

    for (int c = 0; c < cols; ++c) {
        for (int r = 0; r < halfRows; ++r) {
            double low = combined(r, c);
            double high = combined(halfRows + r, c);

            // Inverse Haar
            colReconstructed(2 * r, c) = (low + high) * INV_SQRT2;
            colReconstructed(2 * r + 1, c) = (low - high) * INV_SQRT2;
        }
    }

    // Inverse DWT on rows
    Eigen::MatrixXd result(rows, cols);

    for (int r = 0; r < rows; ++r) {
        for (int c = 0; c < halfCols; ++c) {
            double low = colReconstructed(r, c);
            double high = colReconstructed(r, halfCols + c);

            result(r, 2 * c) = (low + high) * INV_SQRT2;
            result(r, 2 * c + 1) = (low - high) * INV_SQRT2;
        }
    }

    return result;
}

std::vector<DwtResult> dwt2d_multilevel(const Eigen::MatrixXd& input, int level) {
    std::vector<DwtResult> results;
    results.reserve(level);

    Eigen::MatrixXd current = input;

    for (int l = 0; l < level; ++l) {
        DwtResult dwt = dwt2d(current);
        results.push_back(dwt);
        current = dwt.LL;  // Use LL for next level
    }

    return results;
}

Eigen::MatrixXd idwt2d_multilevel(const std::vector<DwtResult>& levels) {
    if (levels.empty()) {
        return Eigen::MatrixXd();
    }

    // Start from deepest level
    Eigen::MatrixXd current = levels.back().LL;

    // Reconstruct from deepest to shallowest
    for (int l = static_cast<int>(levels.size()) - 1; l >= 0; --l) {
        DwtResult dwt = levels[l];
        dwt.LL = current;  // Replace LL with reconstructed from deeper level
        current = idwt2d(dwt);
    }

    return current;
}

} // namespace bwm
