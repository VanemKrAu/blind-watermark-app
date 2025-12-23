#ifndef DWT_HPP
#define DWT_HPP

#include <Eigen/Dense>
#include <vector>

namespace bwm {

/// Result of 2D DWT decomposition
struct DwtResult {
    Eigen::MatrixXd LL;  // Low-Low (approximation)
    Eigen::MatrixXd LH;  // Low-High (horizontal detail)
    Eigen::MatrixXd HL;  // High-Low (vertical detail)
    Eigen::MatrixXd HH;  // High-High (diagonal detail)
};

/// 2D Haar Discrete Wavelet Transform
/// @param input Input matrix (must have even dimensions)
/// @return DWT decomposition (LL, LH, HL, HH)
DwtResult dwt2d(const Eigen::MatrixXd& input);

/// 2D Inverse Haar Discrete Wavelet Transform
/// @param dwt DWT coefficients
/// @return Reconstructed matrix
Eigen::MatrixXd idwt2d(const DwtResult& dwt);

/// Multi-level 2D DWT
/// @param input Input matrix
/// @param level Number of decomposition levels
/// @return Vector of DWT results for each level
std::vector<DwtResult> dwt2d_multilevel(const Eigen::MatrixXd& input, int level);

/// Multi-level 2D IDWT
/// @param levels Vector of DWT results
/// @return Reconstructed matrix
Eigen::MatrixXd idwt2d_multilevel(const std::vector<DwtResult>& levels);

/// Pad matrix to have even dimensions
/// @param input Input matrix
/// @return Padded matrix with even dimensions
Eigen::MatrixXd padToEven(const Eigen::MatrixXd& input);

/// Crop matrix to original dimensions
/// @param input Padded matrix
/// @param origRows Original number of rows
/// @param origCols Original number of columns
/// @return Cropped matrix
Eigen::MatrixXd cropToOriginal(const Eigen::MatrixXd& input, int origRows, int origCols);

} // namespace bwm

#endif // DWT_HPP
