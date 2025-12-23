/// A Flutter plugin for embedding and extracting invisible watermarks.
///
/// This library uses the DWT-DCT-SVD algorithm to embed invisible watermarks
/// into images that can survive compression, cropping, and other attacks.
///
/// ## Quick Start
///
/// ### Embedding a watermark (sync)
/// ```dart
/// final result = embedStringWatermark(imageBytes, 'My Watermark');
/// // result.imageBytes - watermarked image
/// // result.wmBitLength - save this for extraction
/// ```
///
/// ### Embedding a watermark (async, recommended for UI)
/// ```dart
/// final result = await embedStringWatermarkAsync(imageBytes, 'My Watermark');
/// ```
///
/// ### Extracting a watermark
/// ```dart
/// final text = extractStringWatermark(watermarkedBytes, wmBitLength);
/// // or async:
/// final text = await extractStringWatermarkAsync(watermarkedBytes, wmBitLength);
/// ```
///
/// ### Using the BlindWatermark class (for multiple operations)
/// ```dart
/// final bwm = BlindWatermark(d1: 36, d2: 20);
/// try {
///   // Sync API
///   bwm.readImageBytes(imageData);
///   bwm.setWatermarkString('Hello');
///   final result = bwm.embedToBytes(format: 'jpg');
///
///   // Or Async API
///   final asyncResult = await bwm.embedStringAsync(imageData, 'Hello', format: 'jpg');
/// } finally {
///   bwm.dispose();
/// }
/// ```
library flutter_blind_watermark;

export 'src/blind_watermark.dart'
    show
        BlindWatermark,
        BlindWatermarkConfig,
        BlindWatermarkException,
        embedStringWatermark,
        extractStringWatermark,
        embedStringWatermarkAsync,
        extractStringWatermarkAsync;
