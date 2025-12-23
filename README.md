# Flutter Blind Watermark

[![Pub Version](https://img.shields.io/pub/v/flutter_blind_watermark.svg)](https://pub.dev/packages/flutter_blind_watermark)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A Flutter plugin for embedding and extracting invisible (blind) watermarks in images using the **DWT-DCT-SVD** algorithm.

## Features

- **Invisible Watermarking**: Embed watermarks that are imperceptible to the human eye
- **Robust**: Watermarks survive JPEG compression, cropping, rotation, and other attacks
- **High Performance**: Native C++ implementation using Eigen library for fast matrix operations
- **Cross-platform**: Supports both Android and iOS via FFI
- **Flexible API**: Both synchronous and asynchronous APIs available
- **Multiple Watermark Types**: Support for text, binary, and image watermarks

## How It Works

The algorithm combines three powerful transforms:

1. **DWT (Discrete Wavelet Transform)**: Decomposes the image into frequency sub-bands
2. **DCT (Discrete Cosine Transform)**: Further transforms the coefficients for better embedding
3. **SVD (Singular Value Decomposition)**: Embeds the watermark into singular values for robustness

## Installation

Add this to your package's `pubspec.yaml` file:

```yaml
dependencies:
  flutter_blind_watermark: ^0.0.1
```

Then run:

```bash
flutter pub get
```

## Quick Start

### Embedding a Watermark

```dart
import 'package:flutter_blind_watermark/flutter_blind_watermark.dart';

// Simple one-shot API (async, recommended)
final result = await embedStringWatermarkAsync(imageBytes, 'My Secret Watermark');
final watermarkedImage = result.imageBytes;
final wmBitLength = result.wmBitLength; // Save this for extraction!

// Or sync version
final syncResult = embedStringWatermark(imageBytes, 'My Secret Watermark');
```

### Extracting a Watermark

```dart
// Async version (recommended)
final extractedText = await extractStringWatermarkAsync(
  watermarkedImageBytes,
  wmBitLength,  // The bit length from embedding
);

// Sync version
final text = extractStringWatermark(watermarkedImageBytes, wmBitLength);
```

### Using BlindWatermark Class

For more control or multiple operations, use the `BlindWatermark` class:

```dart
final bwm = BlindWatermark(
  d1: 36.0,  // Embedding strength (higher = more robust, more artifacts)
  d2: 20.0,
);

try {
  // Async API (recommended for UI apps)
  final result = await bwm.embedStringAsync(imageBytes, 'Hello World', format: 'png');

  // Or sync API
  bwm.readImageBytes(imageBytes);
  bwm.setWatermarkString('Hello World');
  final result = bwm.embedToBytes(format: 'jpg');
} finally {
  bwm.dispose(); // Always dispose when done
}
```

## API Reference

### Convenience Functions

| Function | Description |
|----------|-------------|
| `embedStringWatermark()` | Embed text watermark (sync) |
| `embedStringWatermarkAsync()` | Embed text watermark (async) |
| `extractStringWatermark()` | Extract text watermark (sync) |
| `extractStringWatermarkAsync()` | Extract text watermark (async) |

### BlindWatermark Class Methods

#### Embedding
- `readImageBytes(Uint8List)` - Load image from bytes
- `readImageFile(String)` - Load image from file path
- `setWatermarkString(String)` - Set text watermark
- `setWatermarkBits(List<bool>)` - Set binary watermark
- `setWatermarkImageFile(String)` - Set image watermark
- `embedToBytes({format})` - Embed and return as bytes
- `embedToFile(String)` - Embed and save to file
- `embedStringAsync()` - Async embedding with isolate
- `embedBitsAsync()` - Async bit array embedding

#### Extraction
- `extractStringFromBytes()` - Extract text from bytes
- `extractStringFromFile()` - Extract text from file
- `extractBitsFromBytes()` - Extract binary from bytes
- `extractImageFromBytes()` - Extract image watermark
- `extractStringAsync()` - Async text extraction
- `extractBitsAsync()` - Async binary extraction
- `extractImageAsync()` - Async image extraction

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `passwordWm` | 1 | Password for watermark encryption |
| `passwordImg` | 1 | Password for image processing |
| `d1` | 36.0 | Embedding strength for first singular value (10-50 recommended) |
| `d2` | 20.0 | Embedding strength for second singular value (5-30 recommended) |

**Trade-off**:
- Higher `d1`/`d2` values = More robust watermark, but more visible artifacts
- Lower `d1`/`d2` values = Better image quality, but less robust watermark

## Supported Formats

- **Input**: PNG, JPEG, WebP, BMP, GIF
- **Output**: PNG, JPEG, WebP

## Example App

Check out the [example](example/) directory for a complete demo application that shows:
- Embedding text watermarks
- Extracting watermarks
- Comparing sync vs async performance
- Saving watermarked images

## Platform Support

| Platform | Support |
|----------|---------|
| Android | Supported |
| iOS | Supported |
| macOS | Coming soon |
| Windows | Coming soon |
| Linux | Coming soon |
| Web | Not supported (requires FFI) |

## Technical Details

The native implementation is written in C++ and uses:
- **Eigen**: High-performance linear algebra library
- **stb_image**: Lightweight image loading/saving
- FFI bindings for Dart integration

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## Credits

- Algorithm based on DWT-DCT-SVD blind watermarking technique
- Uses [Eigen](https://eigen.tuxfamily.org/) library for matrix operations
- Uses [stb_image](https://github.com/nothings/stb) for image I/O

## Issues

If you encounter any issues, please file them on the [GitHub Issues](https://github.com/JackCaow/flutter_blind_watermark/issues) page.
