/// WAM model configuration.
///
/// The strong-robust mode uses two ONNX models:
///   - wam_embedder.onnx          (~0.9 MB)
///   - wam_extractor_int8.onnx    (~95 MB)
///
/// Release builds do NOT bundle the models; they are downloaded on first use
/// from [modelBaseUrl]. Test builds bundle them in assets, in which case no
/// download is needed.
///
/// IMPORTANT for release: replace [modelBaseUrl] with your own server /
/// CDN URL before publishing. Files must be named exactly as below.
class WamConfig {
  static const modelBaseUrl =
      'https://github.com/VanemKrAu/blind-watermark-models/releases/download/v1.0';

  static const embedderFile = 'wam_embedder.onnx';
  static const extractorFile = 'wam_extractor_int8.onnx';

  static String embedderUrl() => '$modelBaseUrl/$embedderFile';
  static String extractorUrl() => '$modelBaseUrl/$extractorFile';

  static const embedderSizeMb = 1;
  static const extractorSizeMb = 95;
}
