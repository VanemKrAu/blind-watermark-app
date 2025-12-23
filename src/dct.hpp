#ifndef DCT_HPP
#define DCT_HPP

#include <Eigen/Dense>

namespace bwm {

/// 2D Discrete Cosine Transform (DCT-II)
/// @param input Input matrix
/// @return DCT transformed matrix
Eigen::MatrixXd dct2d(const Eigen::MatrixXd& input);

/// 2D Inverse Discrete Cosine Transform (DCT-III)
/// @param input DCT coefficients
/// @return Reconstructed matrix
Eigen::MatrixXd idct2d(const Eigen::MatrixXd& input);

/// 1D DCT-II (used internally)
/// @param input Input vector
/// @return DCT coefficients
Eigen::VectorXd dct1d(const Eigen::VectorXd& input);

/// 1D IDCT (DCT-III, used internally)
/// @param input DCT coefficients
/// @return Reconstructed vector
Eigen::VectorXd idct1d(const Eigen::VectorXd& input);

/// Create DCT matrix for size N
/// This is used for efficient matrix-based DCT computation
/// @param N Size of the transform
/// @return NxN DCT matrix
Eigen::MatrixXd createDctMatrix(int N);

/// Create IDCT matrix for size N
/// @param N Size of the transform
/// @return NxN IDCT matrix
Eigen::MatrixXd createIdctMatrix(int N);

} // namespace bwm

#endif // DCT_HPP
