# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.2] - 2024-12-23

### Changed
- Added pub.dev topics for better discoverability (watermark, image-processing, steganography, ffi, security)

## [0.0.1] - 2024-12-23

### Added
- Initial release of Flutter Blind Watermark plugin
- DWT-DCT-SVD based invisible watermarking algorithm
- Support for text, binary, and image watermarks
- Synchronous API for simple use cases
- Asynchronous API with Dart isolates for non-blocking UI
- Support for PNG, JPEG, WebP, BMP, and GIF input formats
- Output support for PNG, JPEG, and WebP formats
- Android platform support via FFI
- iOS platform support via FFI
- Configurable embedding strength parameters (d1, d2)
- Password-based watermark encryption
- Comprehensive example application
