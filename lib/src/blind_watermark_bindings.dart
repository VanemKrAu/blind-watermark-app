// ignore_for_file: non_constant_identifier_names, camel_case_types

import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Result codes from the native library
class BWMResult {
  static const int ok = 0;
  static const int errorInvalidHandle = -1;
  static const int errorFileNotFound = -2;
  static const int errorInvalidImage = -3;
  static const int errorEmbedFailed = -4;
  static const int errorExtractFailed = -5;
  static const int errorInvalidParams = -6;
  static const int errorUnknown = -99;
}

/// Opaque handle type
typedef BWMHandle = Pointer<Void>;

// Native function typedefs
typedef _bwm_create_native = BWMHandle Function(Int32 password_wm, Int32 password_img);
typedef _bwm_create_dart = BWMHandle Function(int password_wm, int password_img);

typedef _bwm_create_with_strength_native = BWMHandle Function(Int32 password_wm, Int32 password_img, Float d1, Float d2);
typedef _bwm_create_with_strength_dart = BWMHandle Function(int password_wm, int password_img, double d1, double d2);

typedef _bwm_destroy_native = Void Function(BWMHandle handle);
typedef _bwm_destroy_dart = void Function(BWMHandle handle);

typedef _bwm_read_image_native = Int32 Function(BWMHandle handle, Pointer<Utf8> filename);
typedef _bwm_read_image_dart = int Function(BWMHandle handle, Pointer<Utf8> filename);

typedef _bwm_read_image_buffer_native = Int32 Function(BWMHandle handle, Pointer<Uint8> data, Size length);
typedef _bwm_read_image_buffer_dart = int Function(BWMHandle handle, Pointer<Uint8> data, int length);

typedef _bwm_read_watermark_string_native = Int32 Function(BWMHandle handle, Pointer<Utf8> text);
typedef _bwm_read_watermark_string_dart = int Function(BWMHandle handle, Pointer<Utf8> text);

typedef _bwm_read_watermark_image_native = Int32 Function(BWMHandle handle, Pointer<Utf8> filename);
typedef _bwm_read_watermark_image_dart = int Function(BWMHandle handle, Pointer<Utf8> filename);

typedef _bwm_read_watermark_bits_native = Int32 Function(BWMHandle handle, Pointer<Uint8> bits, Size length);
typedef _bwm_read_watermark_bits_dart = int Function(BWMHandle handle, Pointer<Uint8> bits, int length);

typedef _bwm_embed_native = Int32 Function(BWMHandle handle, Pointer<Utf8> output_filename);
typedef _bwm_embed_dart = int Function(BWMHandle handle, Pointer<Utf8> output_filename);

typedef _bwm_embed_to_buffer_native = Int32 Function(
    BWMHandle handle, Pointer<Pointer<Uint8>> out_data, Pointer<Size> out_length, Pointer<Utf8> format);
typedef _bwm_embed_to_buffer_dart = int Function(
    BWMHandle handle, Pointer<Pointer<Uint8>> out_data, Pointer<Size> out_length, Pointer<Utf8> format);

typedef _bwm_extract_string_native = Int32 Function(
    BWMHandle handle, Pointer<Utf8> filename, Size wm_length, Pointer<Pointer<Utf8>> out_text);
typedef _bwm_extract_string_dart = int Function(
    BWMHandle handle, Pointer<Utf8> filename, int wm_length, Pointer<Pointer<Utf8>> out_text);

typedef _bwm_extract_string_buffer_native = Int32 Function(
    BWMHandle handle, Pointer<Uint8> data, Size length, Size wm_length, Pointer<Pointer<Utf8>> out_text);
typedef _bwm_extract_string_buffer_dart = int Function(
    BWMHandle handle, Pointer<Uint8> data, int length, int wm_length, Pointer<Pointer<Utf8>> out_text);

typedef _bwm_extract_image_native = Int32 Function(
    BWMHandle handle, Pointer<Utf8> filename, Int32 wm_height, Int32 wm_width, Pointer<Utf8> output_filename);
typedef _bwm_extract_image_dart = int Function(
    BWMHandle handle, Pointer<Utf8> filename, int wm_height, int wm_width, Pointer<Utf8> output_filename);

typedef _bwm_extract_image_buffer_native = Int32 Function(BWMHandle handle, Pointer<Uint8> data, Size length,
    Int32 wm_height, Int32 wm_width, Pointer<Pointer<Uint8>> out_data, Pointer<Size> out_length);
typedef _bwm_extract_image_buffer_dart = int Function(BWMHandle handle, Pointer<Uint8> data, int length,
    int wm_height, int wm_width, Pointer<Pointer<Uint8>> out_data, Pointer<Size> out_length);

typedef _bwm_extract_bits_native = Int32 Function(
    BWMHandle handle, Pointer<Utf8> filename, Size wm_length, Pointer<Pointer<Uint8>> out_bits);
typedef _bwm_extract_bits_dart = int Function(
    BWMHandle handle, Pointer<Utf8> filename, int wm_length, Pointer<Pointer<Uint8>> out_bits);

typedef _bwm_extract_bits_buffer_native = Int32 Function(
    BWMHandle handle, Pointer<Uint8> data, Size length, Size wm_length, Pointer<Pointer<Uint8>> out_bits);
typedef _bwm_extract_bits_buffer_dart = int Function(
    BWMHandle handle, Pointer<Uint8> data, int length, int wm_length, Pointer<Pointer<Uint8>> out_bits);

typedef _bwm_get_watermark_size_native = Size Function(BWMHandle handle);
typedef _bwm_get_watermark_size_dart = int Function(BWMHandle handle);

typedef _bwm_free_buffer_native = Void Function(Pointer<Void> buffer);
typedef _bwm_free_buffer_dart = void Function(Pointer<Void> buffer);

typedef _bwm_free_string_native = Void Function(Pointer<Utf8> str);
typedef _bwm_free_string_dart = void Function(Pointer<Utf8> str);

typedef _bwm_get_error_message_native = Pointer<Utf8> Function(Int32 result);
typedef _bwm_get_error_message_dart = Pointer<Utf8> Function(int result);

typedef _bwm_get_version_native = Pointer<Utf8> Function();
typedef _bwm_get_version_dart = Pointer<Utf8> Function();

/// Native bindings for flutter_blind_watermark library
class BlindWatermarkBindings {
  final DynamicLibrary _lib;

  late final _bwm_create_dart bwm_create;
  late final _bwm_create_with_strength_dart bwm_create_with_strength;
  late final _bwm_destroy_dart bwm_destroy;
  late final _bwm_read_image_dart bwm_read_image;
  late final _bwm_read_image_buffer_dart bwm_read_image_buffer;
  late final _bwm_read_watermark_string_dart bwm_read_watermark_string;
  late final _bwm_read_watermark_image_dart bwm_read_watermark_image;
  late final _bwm_read_watermark_bits_dart bwm_read_watermark_bits;
  late final _bwm_embed_dart bwm_embed;
  late final _bwm_embed_to_buffer_dart bwm_embed_to_buffer;
  late final _bwm_extract_string_dart bwm_extract_string;
  late final _bwm_extract_string_buffer_dart bwm_extract_string_buffer;
  late final _bwm_extract_image_dart bwm_extract_image;
  late final _bwm_extract_image_buffer_dart bwm_extract_image_buffer;
  late final _bwm_extract_bits_dart bwm_extract_bits;
  late final _bwm_extract_bits_buffer_dart bwm_extract_bits_buffer;
  late final _bwm_get_watermark_size_dart bwm_get_watermark_size;
  late final _bwm_free_buffer_dart bwm_free_buffer;
  late final _bwm_free_string_dart bwm_free_string;
  late final _bwm_get_error_message_dart bwm_get_error_message;
  late final _bwm_get_version_dart bwm_get_version;

  BlindWatermarkBindings(this._lib) {
    bwm_create = _lib.lookupFunction<_bwm_create_native, _bwm_create_dart>('bwm_create');
    bwm_create_with_strength = _lib.lookupFunction<_bwm_create_with_strength_native, _bwm_create_with_strength_dart>('bwm_create_with_strength');
    bwm_destroy = _lib.lookupFunction<_bwm_destroy_native, _bwm_destroy_dart>('bwm_destroy');
    bwm_read_image = _lib.lookupFunction<_bwm_read_image_native, _bwm_read_image_dart>('bwm_read_image');
    bwm_read_image_buffer =
        _lib.lookupFunction<_bwm_read_image_buffer_native, _bwm_read_image_buffer_dart>('bwm_read_image_buffer');
    bwm_read_watermark_string = _lib
        .lookupFunction<_bwm_read_watermark_string_native, _bwm_read_watermark_string_dart>('bwm_read_watermark_string');
    bwm_read_watermark_image = _lib
        .lookupFunction<_bwm_read_watermark_image_native, _bwm_read_watermark_image_dart>('bwm_read_watermark_image');
    bwm_read_watermark_bits =
        _lib.lookupFunction<_bwm_read_watermark_bits_native, _bwm_read_watermark_bits_dart>('bwm_read_watermark_bits');
    bwm_embed = _lib.lookupFunction<_bwm_embed_native, _bwm_embed_dart>('bwm_embed');
    bwm_embed_to_buffer =
        _lib.lookupFunction<_bwm_embed_to_buffer_native, _bwm_embed_to_buffer_dart>('bwm_embed_to_buffer');
    bwm_extract_string =
        _lib.lookupFunction<_bwm_extract_string_native, _bwm_extract_string_dart>('bwm_extract_string');
    bwm_extract_string_buffer = _lib
        .lookupFunction<_bwm_extract_string_buffer_native, _bwm_extract_string_buffer_dart>('bwm_extract_string_buffer');
    bwm_extract_image = _lib.lookupFunction<_bwm_extract_image_native, _bwm_extract_image_dart>('bwm_extract_image');
    bwm_extract_image_buffer = _lib
        .lookupFunction<_bwm_extract_image_buffer_native, _bwm_extract_image_buffer_dart>('bwm_extract_image_buffer');
    bwm_extract_bits = _lib.lookupFunction<_bwm_extract_bits_native, _bwm_extract_bits_dart>('bwm_extract_bits');
    bwm_extract_bits_buffer =
        _lib.lookupFunction<_bwm_extract_bits_buffer_native, _bwm_extract_bits_buffer_dart>('bwm_extract_bits_buffer');
    bwm_get_watermark_size =
        _lib.lookupFunction<_bwm_get_watermark_size_native, _bwm_get_watermark_size_dart>('bwm_get_watermark_size');
    bwm_free_buffer = _lib.lookupFunction<_bwm_free_buffer_native, _bwm_free_buffer_dart>('bwm_free_buffer');
    bwm_free_string = _lib.lookupFunction<_bwm_free_string_native, _bwm_free_string_dart>('bwm_free_string');
    bwm_get_error_message =
        _lib.lookupFunction<_bwm_get_error_message_native, _bwm_get_error_message_dart>('bwm_get_error_message');
    bwm_get_version = _lib.lookupFunction<_bwm_get_version_native, _bwm_get_version_dart>('bwm_get_version');
  }

  /// Load the native library
  static BlindWatermarkBindings? _instance;

  static BlindWatermarkBindings get instance {
    _instance ??= BlindWatermarkBindings(_loadLibrary());
    return _instance!;
  }

  static DynamicLibrary _loadLibrary() {
    if (Platform.isIOS) {
      // iOS uses dynamic framework
      return DynamicLibrary.open('flutter_blind_watermark.framework/flutter_blind_watermark');
    } else if (Platform.isAndroid) {
      return DynamicLibrary.open('libflutter_blind_watermark.so');
    }
    throw UnsupportedError('Platform ${Platform.operatingSystem} is not supported. Only Android and iOS are supported.');
  }
}
