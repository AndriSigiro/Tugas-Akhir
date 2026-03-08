import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:tflite_flutter/tflite_flutter.dart' as tfl;
import 'package:image/image.dart' as img_lib;

import 'detail_page.dart';
import 'database_helper.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

const String vpsBaseUrl = "http://203.194.112.163:9090";
const String raspberryCaptureUrl = "http://10.183.178.167/capture";

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Deteksi Telur YOLO',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  // TFLite Local Variables (dari kode pertama)
  tfl.Interpreter? _interpreter;
  File? _imageFile;
  Uint8List? _imageWithBoxes;
  List<Map<String, dynamic>> _detections = [];
  final List<String> _labels = ['fertile', 'infertile'];
  
  // Server Variables (dari kode kedua - untuk webcam)
  String? _latestImageUrl;
  List<Map<String, dynamic>> _serverPredictions = [];
  String? _serverImageBase64;
  
  bool _loading = false;
  String _result = 'Belum ada gambar';

  AnimationController? _animationController;
  Animation<double>? _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _initAnimation();
    _loadModel();
    fetchLatestResult(); // untuk history webcam
  }

  void _initAnimation() {
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController!, curve: Curves.easeIn),
    );
  }

  // ========== LOAD MODEL TFLITE LOCAL ==========
  Future<void> _loadModel() async {
    try {
      _interpreter = await tfl.Interpreter.fromAsset('assets/model/best (17)_float32.tflite');
      debugPrint('✅ Model TFLite berhasil dimuat');
      debugPrint('Input shape: ${_interpreter!.getInputTensor(0).shape}');
      debugPrint('Output shape: ${_interpreter!.getOutputTensor(0).shape}');
      setState(() {});
    } catch (e) {
      debugPrint('❌ Gagal memuat model: $e');
      _showSnackBar('Gagal load model: $e', isError: true);
    }
  }

  // ========== PICK IMAGE (LOKAL TFLITE) ==========
  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: source);

    if (pickedFile != null) {
      setState(() {
        _imageFile = File(pickedFile.path);
        _imageWithBoxes = null;
        _result = 'Sedang memproses...';
        _detections = [];
        _serverPredictions = [];
        _serverImageBase64 = null;
        _latestImageUrl = null;
      });
      _animationController?.forward(from: 0.0);
      await _runLocalInference();
    }
  }

  // ========== RUN INFERENCE TFLITE LOCAL ==========
  Future<void> _runLocalInference() async {
    if (_interpreter == null || _imageFile == null) {
      setState(() => _result = 'Error: Model atau gambar tidak tersedia');
      return;
    }

    setState(() => _loading = true);

    try {
      debugPrint('🔄 Mulai preprocessing lokal...');
      final bytes = await _imageFile!.readAsBytes();
      img_lib.Image? original = img_lib.decodeImage(bytes);
      
      if (original == null) {
        setState(() => _result = 'Gagal decode gambar');
        setState(() => _loading = false);
        return;
      }

      debugPrint('📏 Ukuran asli: ${original.width}x${original.height}');

      img_lib.Image resized = img_lib.copyResize(
        original,
        width: 640,
        height: 640,
        interpolation: img_lib.Interpolation.linear,
      );

      final input = Float32List(1 * 640 * 640 * 3);
      int pixelIndex = 0;
      for (final pixel in resized) {
        input[pixelIndex++] = pixel.r / 255.0;
        input[pixelIndex++] = pixel.g / 255.0;
        input[pixelIndex++] = pixel.b / 255.0;
      }

      final inputTensor = input.reshape([1, 640, 640, 3]);
      final outputShape = _interpreter!.getOutputTensor(0).shape;
      debugPrint('📊 Output shape: $outputShape');

      var outputBuffer = List.generate(
        outputShape[0],
        (_) => List.generate(
          outputShape[1],
          (_) => List<double>.filled(6, 0.0),
        ),
      );

      debugPrint('🔄 Running inference...');
      _interpreter!.run(inputTensor, outputBuffer);
      debugPrint('✅ Inference done');

      final rawOutput = outputBuffer[0];
      List<Map<String, dynamic>> detections = [];

      for (int i = 0; i < rawOutput.length; i++) {
        final row = rawOutput[i];
        final xMin = row[0];
        final yMin = row[1];
        final xMax = row[2];
        final yMax = row[3];
        final conf = row[4];
        final classId = row[5].toInt();

        if (conf < 0.25) continue;
        if (classId < 0 || classId >= _labels.length) continue;

        detections.add({
          'label': _labels[classId],
          'conf': conf,
          'xMin': xMin,
          'yMin': yMin,
          'xMax': xMax,
          'yMax': yMax,
        });
      }

      debugPrint('📦 Deteksi sebelum NMS: ${detections.length}');
      detections = _applyNMS(detections, 0.5);
      debugPrint('✅ Deteksi setelah NMS: ${detections.length}');

      if (detections.isNotEmpty) {
        await _drawBoundingBoxes(original, detections);
      }

      int fertileCount = detections.where((d) => d['label'] == 'fertile').length;
      int infertileCount = detections.where((d) => d['label'] == 'infertile').length;

      // Simpan ke database lokal
      if (detections.isNotEmpty) {
        try {
          // Simpan dengan image base64 jika ada
          String? imageBase64;
          if (_imageWithBoxes != null) {
            imageBase64 = base64Encode(_imageWithBoxes!);
          }
          
          await DatabaseHelper.instance.insertDeteksi(
            imagePath: _imageFile!.path,
            imageBase64: imageBase64,
            detections: detections,
            fertileCount: fertileCount,
            infertileCount: infertileCount,
            source: 'local',
          );
          debugPrint('✅ Hasil deteksi disimpan ke database lokal');
        } catch (e) {
          debugPrint('❌ Error menyimpan ke database: $e');
        }
      }

      setState(() {
        _detections = detections;
        if (detections.isEmpty) {
          _result = 'Tidak ada telur terdeteksi';
        } else {
          _result = '${detections.length} Telur Terdeteksi';
        }
      });

      _showSnackBar('Deteksi lokal selesai ✅ (${detections.length} telur)');
      debugPrint('✅ Fertile: $fertileCount, Infertile: $infertileCount');
    } catch (e, stack) {
      debugPrint('❌ Error: $e\n$stack');
      setState(() => _result = 'Error: $e');
      _showSnackBar('Error deteksi: $e', isError: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> _applyNMS(
    List<Map<String, dynamic>> detections,
    double iouThreshold,
  ) {
    if (detections.isEmpty) return [];
    detections.sort((a, b) => b['conf'].compareTo(a['conf']));
    List<Map<String, dynamic>> keep = [];

    while (detections.isNotEmpty) {
      var best = detections.removeAt(0);
      keep.add(best);
      detections.removeWhere((det) {
        double iou = _calculateIoU(best, det);
        return iou > iouThreshold;
      });
    }
    return keep;
  }

  double _calculateIoU(Map<String, dynamic> box1, Map<String, dynamic> box2) {
    double x1 = box1['xMin'] > box2['xMin'] ? box1['xMin'] : box2['xMin'];
    double y1 = box1['yMin'] > box2['yMin'] ? box1['yMin'] : box2['yMin'];
    double x2 = box1['xMax'] < box2['xMax'] ? box1['xMax'] : box2['xMax'];
    double y2 = box1['yMax'] < box2['yMax'] ? box1['yMax'] : box2['yMax'];

    double intersectionArea = (x2 - x1).clamp(0, double.infinity) * 
                              (y2 - y1).clamp(0, double.infinity);
    double box1Area = (box1['xMax'] - box1['xMin']) * (box1['yMax'] - box1['yMin']);
    double box2Area = (box2['xMax'] - box2['xMin']) * (box2['yMax'] - box2['yMin']);
    double unionArea = box1Area + box2Area - intersectionArea;

    return unionArea > 0 ? intersectionArea / unionArea : 0;
  }

  Future<void> _drawBoundingBoxes(
    img_lib.Image original,
    List<Map<String, dynamic>> detections,
  ) async {
    debugPrint('🎨 Mulai menggambar ${detections.length} bounding boxes...');
    debugPrint('📐 Ukuran gambar: ${original.width}x${original.height}');

    img_lib.Image drawn = img_lib.Image.from(original);

    for (int i = 0; i < detections.length; i++) {
      var det = detections[i];
      
      double normXMin = det['xMin'];
      double normYMin = det['yMin'];
      double normXMax = det['xMax'];
      double normYMax = det['yMax'];
      
      debugPrint('📍 Normalized: xMin=$normXMin, yMin=$normYMin, xMax=$normXMax, yMax=$normYMax');
      
      int x1 = (normXMin * original.width).round().clamp(0, original.width - 1);
      int y1 = (normYMin * original.height).round().clamp(0, original.height - 1);
      int x2 = (normXMax * original.width).round().clamp(0, original.width - 1);
      int y2 = (normYMax * original.height).round().clamp(0, original.height - 1);

      debugPrint('🥚 Deteksi #${i + 1}: ${det['label']} PIXEL: ($x1, $y1) -> ($x2, $y2)');

      if (x2 <= x1 || y2 <= y1) {
        debugPrint('❌ SKIP: Box invalid!');
        continue;
      }

      img_lib.Color boxColor = det['label'] == 'fertile'
          ? img_lib.ColorRgb8(76, 175, 80)
          : img_lib.ColorRgb8(255, 152, 0);

      int thickness = 5;
      for (int t = 0; t < thickness; t++) {
        img_lib.drawLine(drawn, x1: x1, y1: y1 + t, x2: x2, y2: y1 + t, color: boxColor);
        img_lib.drawLine(drawn, x1: x1, y1: y2 - t, x2: x2, y2: y2 - t, color: boxColor);
        img_lib.drawLine(drawn, x1: x1 + t, y1: y1, x2: x1 + t, y2: y2, color: boxColor);
        img_lib.drawLine(drawn, x1: x2 - t, y1: y1, x2: x2 - t, y2: y2, color: boxColor);
      }

      String labelText = det['label'] == 'fertile' ? 'FERTIL' : 'INFERTIL';
      int labelHeight = 10;
      int labelWidth = labelText.length * 5;
      int labelStartY = (y1 - labelHeight).clamp(0, original.height - 1);
      
      for (int ly = labelStartY; ly < y1 && ly < original.height; ly++) {
        for (int lx = x1; lx < (x1 + labelWidth).clamp(0, original.width) && lx < original.width; lx++) {
          drawn.setPixel(lx, ly, boxColor);
        }
      }

      if (labelStartY + 8 >= 0 && labelStartY + 8 < original.height) {
        img_lib.drawString(
          drawn,
          labelText,
          font: img_lib.arial14,
          x: x1 + 10,
          y: labelStartY + 8,
          color: img_lib.ColorRgb8(255, 255, 255),
        );
      }
    }

    final pngBytes = img_lib.encodePng(drawn);
    setState(() {
      _imageWithBoxes = Uint8List.fromList(pngBytes);
    });

    debugPrint('✅ Bounding boxes berhasil digambar!');
  }

  // ========== TRIGGER WEBCAM (SERVER - DARI KODE KEDUA) ==========
  Future<void> triggerWebcamCapture() async {
    setState(() => _loading = true);
    _showSnackBar("Mengambil foto dari webcam...", isError: false);

    final client = http.Client();
    try {
      final response = await client
          .get(Uri.parse(raspberryCaptureUrl))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        _showSnackBar("Capture berhasil! Sedang diproses di server...", isError: false);
        await Future.delayed(const Duration(seconds: 12));
        await loadLatestDetection();
      } else {
        _showSnackBar("Trigger gagal: ${response.statusCode}", isError: true);
      }
    } catch (e) {
      _showSnackBar("Error: $e\nPastikan HP & Raspberry satu WiFi!", isError: true);
    } finally {
      client.close();
      setState(() => _loading = false);
    }
  }

  Future<void> loadLatestDetection() async {
    try {
      final response = await http.get(Uri.parse("$vpsBaseUrl/latest-detection"));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        setState(() {
          _serverPredictions = List<Map<String, dynamic>>.from(data["predictions"] ?? []);
          _serverImageBase64 = data["image_with_boxes"];
          _latestImageUrl = data["image_url"];
          
          // Clear local detection
          _imageFile = null;
          _imageWithBoxes = null;
          _detections = [];
        });

        _animationController?.forward(from: 0.0);
        _showSnackBar("Hasil deteksi server dimuat!");
      }
    } catch (e) {
      debugPrint("Error loadLatestDetection: $e");
    }
  }

  Future<void> fetchLatestResult() async {
    await loadLatestDetection();
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade600 : Colors.green.shade600,
        duration: Duration(seconds: isError ? 5 : 3),
      ),
    );
  }

  Map<String, int> _countLabels() {
    Map<String, int> counts = {"fertile": 0, "infertile": 0};
    
    // Count local detections
    for (var det in _detections) {
      final label = det['label'];
      if (label == 'fertile') counts['fertile'] = counts['fertile']! + 1;
      if (label == 'infertile') counts['infertile'] = counts['infertile']! + 1;
    }
    
    // Count server predictions
    for (var pred in _serverPredictions) {
      final label = (pred['label'] ?? '').toString().toLowerCase().trim();
      if (label == 'fertil' || label == 'fertile') counts['fertile'] = counts['fertile']! + 1;
      if (label == 'infertil' || label == 'infertile') counts['infertile'] = counts['infertile']! + 1;
    }
    
    return counts;
  }

  int get fertileCount => _countLabels()['fertile']!;
  int get infertileCount => _countLabels()['infertile']!;

  @override
  void dispose() {
    _animationController?.dispose();
    _interpreter?.close();
    super.dispose();
  }

  // ========== UI BUILD ==========
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.blue.shade600.withOpacity(0.1),
              Colors.purple.shade400.withOpacity(0.05),
              Colors.white,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: fetchLatestResult,
                  color: Colors.blue.shade600,
                  child: _buildContent(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white, Colors.blue.shade50.withOpacity(0.3)],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.blue.withOpacity(0.08),
            blurRadius: 24,
            offset: const Offset(0, 8),
            spreadRadius: 0,
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 1,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.blue.shade500, Colors.blue.shade700],
              ),
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: Colors.blue.withOpacity(0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Icon(Icons.egg_alt_rounded, size: 32, color: Colors.white),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Deteksi Telur",
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1A1A2E),
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _interpreter != null ? Colors.green.shade400 : Colors.orange.shade400,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: (_interpreter != null ? Colors.green : Colors.orange).withOpacity(0.5),
                            blurRadius: 6,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _interpreter != null ? "Model Ready" : "Loading...",
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.purple.shade400, Colors.purple.shade600],
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.purple.withOpacity(0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const HistoryPage()),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Icon(Icons.history_rounded, color: Colors.white, size: 26),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      children: [
        if (_fadeAnimation != null)
          FadeTransition(opacity: _fadeAnimation!, child: _buildImageContainer())
        else
          _buildImageContainer(),
        const SizedBox(height: 20),
        if (_loading)
          _buildLoading()
        else if (fertileCount + infertileCount > 0)
          _buildResultContainer()
        else
          _buildNoDetection(),
        const SizedBox(height: 10),
        _buildActionButtons(),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _buildImageContainer() {
    return Hero(
      tag: 'image_preview',
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxHeight: 500),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 40,
              offset: const Offset(0, 20),
              spreadRadius: -5,
            ),
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: Stack(
            children: [
              _buildImage(),
              if (fertileCount + infertileCount > 0) _buildImageOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImage() {
    // Local detection (dari gallery/camera)
    if (_imageWithBoxes != null) {
      return Image.memory(_imageWithBoxes!, fit: BoxFit.contain, width: double.infinity);
    }
    if (_imageFile != null) {
      return Image.file(_imageFile!, fit: BoxFit.contain, width: double.infinity);
    }
    
    // Server detection (dari webcam)
    if (_serverImageBase64 != null) {
      return Image.memory(
        base64Decode(_serverImageBase64!.split(',').last),
        fit: BoxFit.contain,
        width: double.infinity,
      );
    }
    if (_latestImageUrl != null) {
      return CachedNetworkImage(
        imageUrl: _latestImageUrl!,
        fit: BoxFit.contain,
        placeholder: (_, __) => const Center(child: CircularProgressIndicator()),
      );
    }
    
    return _buildFallbackImage();
  }

  Widget _buildImageOverlay() {
    final total = fertileCount + infertileCount;
    return Positioned(
      top: 20,
      left: 20,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.black.withOpacity(0.75), Colors.black.withOpacity(0.55)],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.egg_alt, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "$total Telur",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green.shade300, size: 11),
                    const SizedBox(width: 4),
                    Text(
                      "$fertileCount",
                      style: TextStyle(color: Colors.green.shade200, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.cancel, color: Colors.orange.shade300, size: 11),
                    const SizedBox(width: 4),
                    Text(
                      "$infertileCount",
                      style: TextStyle(color: Colors.orange.shade200, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFallbackImage() {
    return Container(
      height: 350,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.grey.shade50, Colors.grey.shade100],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Icon(Icons.photo_library_outlined, size: 56, color: Colors.grey.shade400),
          ),
          const SizedBox(height: 24),
          Text(
            "Belum ada gambar",
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Pilih gambar untuk memulai deteksi",
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return Container(
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 30,
            offset: const Offset(0, 15),
            spreadRadius: -5,
          ),
        ],
      ),
      child: Column(
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 80,
                height: 80,
                child: CircularProgressIndicator(
                  strokeWidth: 6,
                  valueColor: AlwaysStoppedAnimation(Colors.blue.shade600),
                  backgroundColor: Colors.blue.shade50,
                ),
              ),
              Icon(Icons.analytics_outlined, size: 32, color: Colors.blue.shade600),
            ],
          ),
          const SizedBox(height: 28),
          const Text(
            "Menganalisis gambar...",
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Mohon tunggu sebentar",
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultContainer() {
    final total = fertileCount + infertileCount;
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white, Colors.blue.shade50.withOpacity(0.2)],
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 30,
            offset: const Offset(0, 15),
            spreadRadius: -5,
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.verified, color: Colors.green.shade500, size: 28),
              const SizedBox(width: 12),
              Text(
                "$total Telur Terdeteksi",
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1A1A2E),
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Colors.green.shade400, Colors.green.shade600],
                    ),
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.green.withOpacity(0.35),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.check_circle_rounded, color: Colors.white, size: 32),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '$fertileCount',
                        style: const TextStyle(
                          fontSize: 54,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                          height: 1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'FERTIL',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Colors.orange.shade400, Colors.orange.shade600],
                    ),
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.orange.withOpacity(0.35),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.cancel_rounded, color: Colors.white, size: 32),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '$infertileCount',
                        style: const TextStyle(
                          fontSize: 54,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                          height: 1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'INFERTIL',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNoDetection() {
    return Container(
      padding: const EdgeInsets.all(36),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.orange.shade100, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.orange.withOpacity(0.08),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.search_off_rounded, size: 52, color: Colors.orange.shade400),
          ),
          const SizedBox(height: 20),
          const Text(
            "Tidak ada telur terdeteksi",
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Coba ambil gambar yang lebih jelas",
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Column(
      children: [
        _buildPrimaryButton(
          icon: Icons.camera_enhance_rounded,
          label: "Ambil dari Webcam",
          subtitle: "Trigger Raspberry Pi (server)",
          gradient: LinearGradient(colors: [Colors.teal.shade600, Colors.teal.shade800]),
          onPressed: triggerWebcamCapture,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _buildSecondaryButton(
                icon: Icons.camera_alt_rounded,
                label: "Kamera",
                gradient: LinearGradient(colors: [Colors.blue.shade500, Colors.blue.shade700]),
                onPressed: () => _pickImage(ImageSource.camera),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: _buildSecondaryButton(
                icon: Icons.photo_library_rounded,
                label: "Galeri",
                gradient: LinearGradient(colors: [Colors.purple.shade500, Colors.purple.shade700]),
                onPressed: () => _pickImage(ImageSource.gallery),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPrimaryButton({
    required IconData icon,
    required String label,
    required String subtitle,
    required Gradient gradient,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          decoration: BoxDecoration(
            gradient: gradient,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: Colors.white, size: 30),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
                      Text(subtitle, style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSecondaryButton({
    required IconData icon,
    required String label,
    required Gradient gradient,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(gradient: gradient, borderRadius: BorderRadius.circular(18)),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Column(
              children: [
                Icon(icon, color: Colors.white, size: 28),
                const SizedBox(height: 10),
                Text(label, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ========== HISTORY PAGE ==========
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    fetchHistory();
  }

  Future<void> fetchHistory() async {
    setState(() => _loading = true);
    try {
      // Gabungkan data lokal + server
      List<Map<String, dynamic>> allItems = [];
      
      // 1. Ambil dari database lokal
      final localItems = await DatabaseHelper.instance.getAllDeteksi();
      allItems.addAll(localItems);
      
      // 2. Ambil dari server
      try {
        final res = await http.get(Uri.parse("$vpsBaseUrl/results?limit=20"));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final serverItems = List<Map<String, dynamic>>.from(data["items"] ?? []);
          // Tandai sebagai data server
          for (var item in serverItems) {
            item['is_local'] = false;
          }
          allItems.addAll(serverItems);
        }
      } catch (e) {
        debugPrint("Error fetching server history: $e");
      }
      
      // 3. Sort by timestamp descending
      allItems.sort((a, b) {
        final aTime = a['timestamp'] ?? 0;
        final bTime = b['timestamp'] ?? 0;
        return bTime.compareTo(aTime);
      });
      
      setState(() => items = allItems);
    } catch (e) {
      debugPrint("Error fetchHistory: $e");
    }
    setState(() => _loading = false);
  }

  String _formatTimestamp(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inMinutes < 60) {
      return "${diff.inMinutes} menit lalu";
    } else if (diff.inHours < 24) {
      return "${diff.inHours} jam lalu";
    } else if (diff.inDays < 7) {
      return "${diff.inDays} hari lalu";
    } else {
      return "${date.day}/${date.month}/${date.year}";
    }
  }

  Color _getLabelColor(String label) {
    final l = label.toLowerCase().trim();
    if (l == "fertil") return Colors.green;
    if (l == "infertil") return Colors.orange.shade700;
    return Colors.grey;
  }

  IconData _getLabelIcon(String label) {
    final l = label.toLowerCase().trim();
    if (l == "fertil") return Icons.check_circle_rounded;
    if (l == "infertil") return Icons.cancel_rounded;
    return Icons.help_outline;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0xFFF8F9FA),
              Colors.purple.shade50.withOpacity(0.3),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [_buildHeader(), Expanded(child: _buildContent())],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white, Colors.purple.shade50.withOpacity(0.3)],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.purple.withOpacity(0.08),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.purple.shade400, Colors.purple.shade600],
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.purple.withOpacity(0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => Navigator.pop(context),
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    size: 22,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Riwayat Deteksi",
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1A1A2E),
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.folder_outlined, size: 16, color: Colors.grey.shade500),
                    const SizedBox(width: 6),
                    Text(
                      "${items.length} hasil tersimpan",
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.purple.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.purple.shade200, width: 1.5),
            ),
            child: Text(
              "${items.length}",
              style: TextStyle(
                color: Colors.purple.shade700,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 80,
                  height: 80,
                  child: CircularProgressIndicator(
                    strokeWidth: 6,
                    valueColor: AlwaysStoppedAnimation(Colors.purple.shade600),
                    backgroundColor: Colors.purple.shade100,
                  ),
                ),
                Icon(Icons.history, size: 32, color: Colors.purple.shade600),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              "Memuat riwayat...",
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade700,
              ),
            ),
          ],
        ),
      );
    }

    if (items.isEmpty) {
      return _buildEmptyHistory();
    }

    return RefreshIndicator(
      onRefresh: fetchHistory,
      color: Colors.purple.shade600,
      child: ListView.builder(
        padding: const EdgeInsets.all(20),
        itemCount: items.length,
        itemBuilder: (_, i) => _buildHistoryItem(items[i], i),
      ),
    );
  }

  Widget _buildHistoryItem(Map<String, dynamic> item, int index) {
    // ✅ FIX: Tambah null check dan type casting yang aman
    final predData = item["pred"];
    List<Map<String, dynamic>> preds = [];

    if (predData != null) {
      if (predData is List) {
        preds =
            predData.map((e) {
              if (e is Map<String, dynamic>) {
                return e;
              }
              return <String, dynamic>{};
            }).toList();
      }
    }

    // ✅ FIX: Cari best prediction dengan aman
    Map<String, dynamic>? best;
    if (preds.isNotEmpty) {
      try {
        best = preds.reduce((a, b) {
          final aScore = (a["score"] ?? 0) as num;
          final bScore = (b["score"] ?? 0) as num;
          return aScore > bScore ? a : b;
        });
      } catch (e) {
        debugPrint("Error finding best prediction: $e");
      }
    }

    final label = best?["label"] ?? "Unknown";
    final labelColor = best != null ? _getLabelColor(label) : Colors.grey;
    final imageUrl = item["image_url"] ?? "";
    final isLocal = item["is_local"] == true;
    final imagePath = item["image_path"];
    final imageBase64 = item["image_base64"];
    
    // Count fertile and infertile
    int fertileCount = preds.where((p) {
      final l = (p['label']?.toString() ?? '').toLowerCase();
      return l == 'fertile' || l == 'fertil';
    }).length;
    int infertileCount = preds.where((p) {
      final l = (p['label']?.toString() ?? '').toLowerCase();
      return l == 'infertile' || l == 'infertil';
    }).length;

    return TweenAnimationBuilder(
      duration: Duration(milliseconds: 350 + (index * 60)),
      tween: Tween<double>(begin: 0, end: 1),
      curve: Curves.easeOutCubic,
      builder: (context, double value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 30 * (1 - value)),
            child: child,
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.white, Colors.grey.shade50.withOpacity(0.3)],
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.grey.shade200, width: 1),
          boxShadow: [
            BoxShadow(
              color: (isLocal ? Colors.blue : Colors.purple).withOpacity(0.08),
              blurRadius: 20,
              offset: const Offset(0, 6),
              spreadRadius: -3,
            ),
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => DetailPage(item: item)),
              );
            },
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  // Image Preview with enhanced styling
                  Hero(
                    tag: 'history_image_$index',
                    child: Container(
                      width: 90,
                      height: 90,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        gradient: LinearGradient(
                          colors: [
                            (fertileCount > infertileCount ? Colors.green : Colors.orange).withOpacity(0.1),
                            Colors.white,
                          ],
                        ),
                        border: Border.all(
                          color: (fertileCount > infertileCount ? Colors.green : Colors.orange).withOpacity(0.3),
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: (fertileCount > infertileCount ? Colors.green : Colors.orange).withOpacity(0.15),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: _buildHistoryImage(isLocal, imageUrl, imagePath, imageBase64),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),

                  // Info Section
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Badge: Local/Server
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: isLocal ? Colors.blue.shade50 : Colors.purple.shade50,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                isLocal ? "LOKAL" : "SERVER",
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: isLocal ? Colors.blue.shade700 : Colors.purple.shade700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.egg,
                              size: 12,
                              color: Colors.grey.shade500,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              "F:$fertileCount • I:$infertileCount",
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade600,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.access_time_rounded,
                              size: 14,
                              color: Colors.grey.shade500,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _formatTimestamp(item["timestamp"] ?? 0),
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // Arrow Icon
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.arrow_forward_ios_rounded,
                      size: 16,
                      color: Colors.grey.shade400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryImage(bool isLocal, String imageUrl, dynamic imagePath, dynamic imageBase64) {
    // Jika data lokal, coba tampilkan dari file atau base64
    if (isLocal) {
      // Coba base64 dulu
      if (imageBase64 != null && imageBase64.toString().isNotEmpty) {
        try {
          final bytes = base64Decode(imageBase64.toString());
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _buildPlaceholderImage(),
          );
        } catch (e) {
          debugPrint("Error decoding base64: $e");
        }
      }
      
      // Coba file path
      if (imagePath != null && imagePath.toString().isNotEmpty) {
        final file = File(imagePath.toString());
        if (file.existsSync()) {
          return Image.file(
            file,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _buildPlaceholderImage(),
          );
        }
      }
      
      return _buildPlaceholderImage();
    }
    
    // Jika data server, tampilkan dari URL
    if (imageUrl.isNotEmpty) {
      return Image.network(
        imageUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildPlaceholderImage(),
        loadingBuilder: (_, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Container(
            color: Colors.grey.shade100,
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.grey.shade400,
                ),
              ),
            ),
          );
        },
      );
    }
    
    return _buildPlaceholderImage();
  }

  Widget _buildPlaceholderImage() {
    return Container(
      color: Colors.grey.shade100,
      child: Icon(
        Icons.egg_outlined,
        size: 36,
        color: Colors.grey.shade400,
      ),
    );
  }

  Widget _buildEmptyHistory() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Colors.purple.shade50,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.history_outlined,
              size: 80,
              color: Colors.purple.shade300,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            "Belum Ada Riwayat",
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A2E),
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Hasil deteksi akan muncul di sini\nsetelah kamu melakukan scan",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade600,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.purple.shade600,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              elevation: 0,
            ),
            icon: const Icon(Icons.camera_alt_rounded),
            label: const Text(
              "Mulai Scan",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}
