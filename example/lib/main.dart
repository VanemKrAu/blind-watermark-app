import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_blind_watermark/flutter_blind_watermark.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Blind Watermark Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const WatermarkDemo(),
    );
  }
}

class WatermarkDemo extends StatefulWidget {
  const WatermarkDemo({super.key});

  @override
  State<WatermarkDemo> createState() => _WatermarkDemoState();
}

class _WatermarkDemoState extends State<WatermarkDemo> {
  Uint8List? _imageBytes;
  Uint8List? _watermarkedBytes;
  String _watermarkText = 'Hello Flutter!';
  int? _wmLength;
  String _status = '';
  String _extractedText = '';
  bool _isProcessing = false;
  bool _useAsyncApi = true; // Toggle between sync/async API

  // Image resolution
  int? _originalWidth;
  int? _originalHeight;
  int? _watermarkedWidth;
  int? _watermarkedHeight;

  // Timing
  Duration? _embedDuration;
  Duration? _extractDuration;

  final TextEditingController _textController =
      TextEditingController(text: 'Hello Flutter!');

  // Watermark strength parameters - must be same for embed and extract
  // Higher values = more robust against compression but more visible artifacts
  // d1=36, d2=20 is recommended for JPG compatibility
  static const double _d1 = 36.0;
  static const double _d2 = 20.0;

  // BlindWatermark instance for async operations
  late final BlindWatermark _bwm;

  @override
  void initState() {
    super.initState();
    _bwm = BlindWatermark(d1: _d1, d2: _d2);
    _loadDefaultImage();
  }

  Future<void> _loadDefaultImage() async {
    try {
      final bytes = await rootBundle.load('assets/Lena_512x512.jpg');
      final imageBytes = bytes.buffer.asUint8List();
      final resolution = await _getImageResolution(imageBytes);
      setState(() {
        _imageBytes = imageBytes;
        _originalWidth = resolution.$1;
        _originalHeight = resolution.$2;
        _status = 'Default image loaded (Lena 512x512)';
      });
    } catch (e) {
      setState(() {
        _status = 'No default image found. Please select an image.';
      });
    }
  }

  Future<(int, int)> _getImageResolution(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    return (image.width, image.height);
  }

  String _formatDuration(Duration duration) {
    if (duration.inSeconds >= 1) {
      final seconds = duration.inMilliseconds / 1000;
      return '${seconds.toStringAsFixed(2)} s';
    } else {
      return '${duration.inMilliseconds} ms';
    }
  }

  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );

    if (result != null && result.files.isNotEmpty) {
      final file = result.files.first;
      if (file.path != null) {
        final bytes = await File(file.path!).readAsBytes();
        final resolution = await _getImageResolution(bytes);
        setState(() {
          _imageBytes = bytes;
          _originalWidth = resolution.$1;
          _originalHeight = resolution.$2;
          _watermarkedBytes = null;
          _watermarkedWidth = null;
          _watermarkedHeight = null;
          _extractedText = '';
          _wmLength = null;
          _embedDuration = null;
          _extractDuration = null;
          _status = 'Image loaded: ${file.name}';
        });
      }
    }
  }

  Future<void> _embedWatermark() async {
    if (_imageBytes == null) {
      setState(() => _status = 'Please select an image first');
      return;
    }

    setState(() {
      _isProcessing = true;
      _status = 'Embedding watermark (${_useAsyncApi ? "async" : "sync"})...';
    });

    try {
      final stopwatch = Stopwatch()..start();

      Uint8List resultBytes;
      int wmLen;

      if (_useAsyncApi) {
        // Use the new async API - runs in background isolate automatically
        final result = await _bwm.embedStringAsync(
          _imageBytes!,
          _watermarkText,
          format: 'png',
        );
        resultBytes = result.imageBytes;
        wmLen = result.wmBitLength;
      } else {
        // Use sync API - blocks the main thread (for comparison)
        final syncBwm = BlindWatermark(d1: _d1, d2: _d2);
        try {
          syncBwm.readImageBytes(_imageBytes!);
          syncBwm.setWatermarkString(_watermarkText);
          resultBytes = syncBwm.embedToBytes(format: 'png');
          wmLen = syncBwm.watermarkBitLength;
        } finally {
          syncBwm.dispose();
        }
      }

      stopwatch.stop();

      final resolution = await _getImageResolution(resultBytes);

      setState(() {
        _watermarkedBytes = resultBytes;
        _watermarkedWidth = resolution.$1;
        _watermarkedHeight = resolution.$2;
        _wmLength = wmLen;
        _embedDuration = stopwatch.elapsed;
        _status = 'Watermark embedded! Bit length: $wmLen';
        _isProcessing = false;
      });
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
        _isProcessing = false;
      });
    }
  }

  Future<void> _extractWatermark() async {
    if (_watermarkedBytes == null || _wmLength == null) {
      setState(() => _status = 'Please embed a watermark first');
      return;
    }

    setState(() {
      _isProcessing = true;
      _status = 'Extracting watermark (${_useAsyncApi ? "async" : "sync"})...';
    });

    try {
      final stopwatch = Stopwatch()..start();

      String text;

      if (_useAsyncApi) {
        // Use the new async API - runs in background isolate automatically
        text = await _bwm.extractStringAsync(_watermarkedBytes!, _wmLength!);
      } else {
        // Use sync API - blocks the main thread (for comparison)
        final syncBwm = BlindWatermark(d1: _d1, d2: _d2);
        try {
          text = syncBwm.extractStringFromBytes(_watermarkedBytes!, _wmLength!);
        } finally {
          syncBwm.dispose();
        }
      }

      stopwatch.stop();

      setState(() {
        _extractedText = text;
        _extractDuration = stopwatch.elapsed;
        _status = 'Watermark extracted successfully!';
        _isProcessing = false;
      });
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
        _isProcessing = false;
      });
    }
  }

  Future<void> _saveWatermarkedImage() async {
    if (_watermarkedBytes == null) {
      setState(() => _status = 'No watermarked image to save');
      return;
    }

    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Save watermarked image',
      fileName: 'watermarked.png',
      type: FileType.image,
    );

    if (result != null) {
      await File(result).writeAsBytes(_watermarkedBytes!);
      setState(() => _status = 'Saved to: $result');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Flutter Blind Watermark Demo'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    if (_isProcessing)
                      const Padding(
                        padding: EdgeInsets.only(right: 12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    Expanded(child: Text(_status)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // API mode toggle
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Text('API Mode:'),
                    const SizedBox(width: 16),
                    ChoiceChip(
                      label: const Text('Async'),
                      selected: _useAsyncApi,
                      onSelected: (selected) {
                        setState(() => _useAsyncApi = true);
                      },
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('Sync'),
                      selected: !_useAsyncApi,
                      onSelected: (selected) {
                        setState(() => _useAsyncApi = false);
                      },
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        _useAsyncApi
                            ? 'Non-blocking (recommended for UI)'
                            : 'Blocks main thread',
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Image selection
            ElevatedButton.icon(
              onPressed: _pickImage,
              icon: const Icon(Icons.image),
              label: const Text('Select Image'),
            ),
            const SizedBox(height: 16),

            // Images display
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Original image
                Expanded(
                  child: Column(
                    children: [
                      const Text('Original',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      if (_originalWidth != null && _originalHeight != null)
                        Text(
                          '$_originalWidth x $_originalHeight',
                          style: TextStyle(
                              color: Colors.grey.shade600, fontSize: 12),
                        ),
                      const SizedBox(height: 8),
                      Container(
                        height: 300,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: _imageBytes != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.memory(_imageBytes!,
                                    fit: BoxFit.contain),
                              )
                            : const Center(child: Text('No image')),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                // Watermarked image
                Expanded(
                  child: Column(
                    children: [
                      const Text('Watermarked',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      if (_watermarkedWidth != null &&
                          _watermarkedHeight != null)
                        Text(
                          '$_watermarkedWidth x $_watermarkedHeight',
                          style: TextStyle(
                              color: Colors.grey.shade600, fontSize: 12),
                        )
                      else
                        const Text(' ', style: TextStyle(fontSize: 12)),
                      const SizedBox(height: 8),
                      Container(
                        height: 300,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: _watermarkedBytes != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.memory(_watermarkedBytes!,
                                    fit: BoxFit.contain),
                              )
                            : const Center(child: Text('No watermark yet')),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // Timing info
            if (_embedDuration != null || _extractDuration != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Card(
                  color: Colors.blue.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        if (_embedDuration != null)
                          Column(
                            children: [
                              const Text('Embed Time',
                                  style:
                                      TextStyle(fontWeight: FontWeight.bold)),
                              Text(_formatDuration(_embedDuration!)),
                            ],
                          ),
                        if (_extractDuration != null)
                          Column(
                            children: [
                              const Text('Extract Time',
                                  style:
                                      TextStyle(fontWeight: FontWeight.bold)),
                              Text(_formatDuration(_extractDuration!)),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 24),

            // Watermark text input
            TextField(
              controller: _textController,
              decoration: const InputDecoration(
                labelText: 'Watermark Text',
                border: OutlineInputBorder(),
                hintText: 'Enter text to embed as watermark',
              ),
              onChanged: (value) => _watermarkText = value,
            ),
            const SizedBox(height: 16),

            // Action buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _embedWatermark,
                    icon: const Icon(Icons.add_photo_alternate),
                    label: const Text('Embed Watermark'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing || _watermarkedBytes == null
                        ? null
                        : _extractWatermark,
                    icon: const Icon(Icons.search),
                    label: const Text('Extract Watermark'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Save button
            ElevatedButton.icon(
              onPressed: _watermarkedBytes == null ? null : _saveWatermarkedImage,
              icon: const Icon(Icons.save),
              label: const Text('Save Watermarked Image'),
            ),
            const SizedBox(height: 24),

            // Extracted text display
            if (_extractedText.isNotEmpty)
              Card(
                color: Colors.green.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Extracted Watermark:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _extractedText,
                        style: const TextStyle(fontSize: 18),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _extractedText == _watermarkText
                            ? 'Match!'
                            : 'Different from original',
                        style: TextStyle(
                          color: _extractedText == _watermarkText
                              ? Colors.green
                              : Colors.red,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Info
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Library Version: ${BlindWatermark.version}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text('Algorithm: DWT-DCT-SVD'),
                    const Text('Supported formats: PNG, JPEG, WebP, BMP, GIF'),
                    const SizedBox(height: 8),
                    const Text(
                        'This watermark is invisible and survives compression, cropping, and other attacks.'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    _bwm.dispose();
    super.dispose();
  }
}
