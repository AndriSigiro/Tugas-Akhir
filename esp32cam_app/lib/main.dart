import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'detail_page.dart';  // TAMBAHKAN BARIS INI

void main() {
  runApp(const MyApp());
}

const String vpsBaseUrl = "http://202.10.36.223:9090";
const String raspberryCaptureUrl = "http://10.15.192.167/capture"; // IP PRIVAT RASPBERRY (satu WiFi dengan HP!)

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

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  File? _imageFile;
  List<Map<String, dynamic>> _predictions = [];
  String? _imageWithBoxesBase64;
  String? _latestImageUrl;
  bool _loading = false;
  AnimationController? _animationController;
  Animation<double>? _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _initAnimation();
    fetchLatestResult();
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

  @override
  void dispose() {
    _animationController?.dispose();
    super.dispose();
  }

  // ========== TRIGGER WEBCAM (Raspberry) ==========
  Future<void> triggerWebcamCapture() async {
  setState(() => _loading = true);
  _showSnackBar("Mengambil foto dari webcam...", isError: false);

  final client = http.Client();
  try {
    final response = await client
        .get(Uri.parse(raspberryCaptureUrl))
        .timeout(const Duration(seconds: 20));

    if (response.statusCode == 200) {
      _showSnackBar("Capture berhasil! Sedang diproses di server...", isError: false);
      await Future.delayed(const Duration(seconds: 12));
      await loadLatestDetection();
    } else {
      _showSnackBar("Trigger gagal: ${response.statusCode}", isError: true);
    }
  } catch (e) {
    // SEMUA ERROR (termasuk timeout) ditangkap di sini
    if (e.toString().contains('TimeoutException')) {
      _showSnackBar("Timeout: Webcam tidak merespon dalam 20 detik", isError: true);
    } else {
      _showSnackBar("Error: $e\nPastikan HP & Raspberry satu WiFi!", isError: true);
    }
  } finally {
    client.close();
    setState(() => _loading = false);
  }
}
  // ========== LOAD HASIL TERBARU DARI VPS ==========
  Future<void> loadLatestDetection() async {
    try {
      final response = await http.get(Uri.parse("$vpsBaseUrl/latest-detection"));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        setState(() {
          _predictions = List<Map<String, dynamic>>.from(data["predictions"] ?? []);
          _imageWithBoxesBase64 = data["image_with_boxes"];
          _latestImageUrl = data["image_url"];
          _imageFile = null;
        });

        _animationController?.forward(from: 0.0);
        _showSnackBar("Hasil deteksi terbaru dimuat!");
      }
    } catch (e) {
      debugPrint("Error loadLatestDetection: $e");
    }
  }

  // ========== UPLOAD MANUAL DARI GALERI/KAMERA ==========
  Future<void> pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source);
    if (picked != null) {
      setState(() {
        _imageFile = File(picked.path);
        _predictions = [];
        _imageWithBoxesBase64 = null;
        _latestImageUrl = null;
      });
      _animationController?.forward(from: 0.0);
      await uploadImage(_imageFile!);
    }
  }

  Future<void> uploadImage(File imageFile) async {
    setState(() => _loading = true);

    final uri = Uri.parse("$vpsBaseUrl/upload-file");
    final request = http.MultipartRequest("POST", uri);
    request.files.add(await http.MultipartFile.fromPath("file", imageFile.path));

    try {
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _predictions = List<Map<String, dynamic>>.from(data["pred"]);
          _imageWithBoxesBase64 = data["image_with_boxes"];
          _latestImageUrl = "$vpsBaseUrl/latest?ts=${DateTime.now().millisecondsSinceEpoch}";
        });
      } else {
        _showSnackBar("Upload gagal: ${response.statusCode}", isError: true);
      }
    } catch (e) {
      _showSnackBar("Error upload: $e", isError: true);
    }

    setState(() => _loading = false);
  }

  // ========== REFRESH HASIL TERBARU ==========
  Future<void> fetchLatestResult() async {
    await loadLatestDetection();
  }

  // ========== HELPER ==========
  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              color: Colors.white,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        backgroundColor: isError ? Colors.red.shade600 : Colors.green.shade600,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: Duration(seconds: isError ? 5 : 3),
        margin: const EdgeInsets.all(16),
        elevation: 6,
      ),
    );
  }

  Map<String, int> _countLabels() {
    Map<String, int> counts = {"fertile": 0, "unfertile": 0};
    for (var pred in _predictions) {
      String label = (pred["label"] ?? "").toString().toLowerCase();
      if (label.contains("fertile") && !label.contains("unfertil")) {
        counts["fertile"] = counts["fertile"]! + 1;
      } else if (label.contains("unfertil")) {
        counts["unfertile"] = counts["unfertile"]! + 1;
      }
    }
    return counts;
  }

  // ========== UI (sama seperti kamu, hanya tombol trigger ditambah) ==========
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
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.blue.withOpacity(0.1),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.blue.shade600, Colors.blue.shade400],
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.blue.withOpacity(0.4),
                  blurRadius: 15,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: const Icon(
              Icons.egg_outlined,
              size: 28,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Deteksi Telur YOLO",
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A2E),
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  "AI Detection System",
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: Colors.purple.shade50,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.purple.shade100, width: 1.5),
            ),
            child: IconButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HistoryPage()),
              ),
              icon: Icon(
                Icons.history_rounded,
                color: Colors.purple.shade600,
                size: 24,
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
          FadeTransition(
            opacity: _fadeAnimation!,
            child: _buildImageContainer(),
          )
        else
          _buildImageContainer(),
        const SizedBox(height: 20),
        if (_loading)
          _buildLoading()
        else if (_countLabels()['fertile']! + _countLabels()['unfertile']! > 0)
          _buildResultContainer()
        else
          _buildNoDetection(),
        const SizedBox(height: 24),
        _buildActionButtons(),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildActionButtons() {
    return Column(
      children: [
        // Tombol Trigger Webcam (Full Width, Utama)
        _buildPrimaryButton(
          icon: Icons.camera_enhance_rounded,
          label: "Ambil dari Webcam",
          subtitle: "Trigger Raspberry Pi langsung",
          gradient: LinearGradient(
            colors: [Colors.teal.shade600, Colors.teal.shade800],
          ),
          onPressed: triggerWebcamCapture,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _buildSecondaryButton(
                icon: Icons.camera_alt_rounded,
                label: "Kamera",
                gradient: LinearGradient(
                  colors: [Colors.blue.shade500, Colors.blue.shade700],
                ),
                onPressed: () => pickImage(ImageSource.camera),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: _buildSecondaryButton(
                icon: Icons.photo_library_rounded,
                label: "Galeri",
                gradient: LinearGradient(
                  colors: [Colors.purple.shade500, Colors.purple.shade700],
                ),
                onPressed: () => pickImage(ImageSource.gallery),
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
            boxShadow: [
              BoxShadow(
                color: gradient.colors.first.withOpacity(0.5),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
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
                      Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.85),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_rounded,
                  color: Colors.white.withOpacity(0.9),
                  size: 24,
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
          decoration: BoxDecoration(
            gradient: gradient,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: gradient.colors.first.withOpacity(0.4),
                blurRadius: 15,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: Colors.white, size: 28),
                ),
                const SizedBox(height: 10),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Sisanya (image container, result, no detection, loading, fallback) TETAP SAMA seperti kode kamu
  // ... (copy dari kode kamu yang sudah bagus)

  // Contoh singkat (ganti saja bagian ini kalau perlu)
  Widget _buildImageContainer() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 500),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 30,
            offset: const Offset(0, 15),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            _buildImage(),
            if (_predictions.isNotEmpty) _buildImageOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildImage() {
    if (_imageWithBoxesBase64 != null) {
      return _buildNetworkOrMemoryImage(isBase64: true, data: _imageWithBoxesBase64!);
    } else if (_latestImageUrl != null) {
      return _buildNetworkOrMemoryImage(isBase64: false, url: _latestImageUrl!);
    } else if (_imageFile != null) {
      return Image.file(_imageFile!, fit: BoxFit.contain, width: double.infinity);
    }
    return _buildFallbackImage();
  }

  Widget _buildNetworkOrMemoryImage({required bool isBase64, String? url, String? data}) {
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 4.0,
      child: Container(
        width: double.infinity,
        color: Colors.black,
        child: isBase64
            ? Image.memory(
                base64Decode(data!.split(',').last),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => _buildFallbackImage(),
              )
            : CachedNetworkImage(
                imageUrl: url!,
                fit: BoxFit.contain,
                placeholder: (context, url) => const Center(child: CircularProgressIndicator(color: Colors.white)),
                errorWidget: (context, url, error) => _buildFallbackImage(),
              ),
      ),
    );
  }

  Widget _buildImageOverlay() {
    final totalCount = _countLabels()['fertile']! + _countLabels()['unfertile']!;
    return Positioned(
      top: 16,
      left: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.black.withOpacity(0.8), Colors.black.withOpacity(0.6)],
          ),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: Colors.white.withOpacity(0.2), width: 1.5),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), shape: BoxShape.circle),
              child: const Icon(Icons.egg, color: Colors.white, size: 16),
            ),
            const SizedBox(width: 8),
            Text(
              "$totalCount telur",
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFallbackImage() {
    return Container(
      color: Colors.grey.shade50,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(color: Colors.grey.shade100, shape: BoxShape.circle),
            child: Icon(Icons.image_outlined, size: 64, color: Colors.grey.shade400),
          ),
          const SizedBox(height: 20),
          Text(
            "Belum ada gambar",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.grey.shade700),
          ),
          const SizedBox(height: 8),
          Text(
            "Tekan tombol untuk mulai deteksi",
            style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 20, offset: const Offset(0, 10))],
      ),
      child: Column(
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              Container(width: 80, height: 80, decoration: BoxDecoration(color: Colors.blue.shade50, shape: BoxShape.circle)),
              SizedBox(
                width: 60,
                height: 60,
                child: CircularProgressIndicator(strokeWidth: 5, valueColor: AlwaysStoppedAnimation(Colors.blue.shade600)),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            "Menganalisis gambar...",
            style: TextStyle(fontSize: 17, color: Colors.grey.shade800, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            "Mohon tunggu sebentar",
            style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _buildResultContainer() {
    final labelCounts = _countLabels();
    final fertileCount = labelCounts["fertile"] ?? 0;
    final unfertileCount = labelCounts["unfertile"] ?? 0;
    final totalCount = fertileCount + unfertileCount;

    if (totalCount == 0) return _buildNoDetection();

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 20, offset: const Offset(0, 10))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [Colors.blue.shade600, Colors.blue.shade400]),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [BoxShadow(color: Colors.blue.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 4))],
                ),
                child: const Icon(Icons.analytics_outlined, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Hasil Deteksi",
                      style: TextStyle(fontSize: 13, color: Colors.grey.shade600, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "$totalCount Telur Terdeteksi",
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1A1A2E)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [Colors.green.shade400, Colors.green.shade600]),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [BoxShadow(color: Colors.green.withOpacity(0.4), blurRadius: 15, offset: const Offset(0, 8))],
                  ),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: Colors.white.withOpacity(0.25), shape: BoxShape.circle),
                        child: const Icon(Icons.check_circle_rounded, color: Colors.white, size: 32),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        "$fertileCount",
                        style: const TextStyle(fontSize: 38, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        "Fertil",
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), borderRadius: BorderRadius.circular(20)),
                        child: const Text(
                          "Dapat Ditetaskan",
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [Colors.orange.shade400, Colors.orange.shade600]),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [BoxShadow(color: Colors.orange.withOpacity(0.4), blurRadius: 15, offset: const Offset(0, 8))],
                  ),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: Colors.white.withOpacity(0.25), shape: BoxShape.circle),
                        child: const Icon(Icons.cancel_rounded, color: Colors.white, size: 32),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        "$unfertileCount",
                        style: const TextStyle(fontSize: 38, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        "Infertil",
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), borderRadius: BorderRadius.circular(20)),
                        child: const Text(
                          "Tidak Ditetaskan",
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600),
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
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 20, offset: const Offset(0, 10))],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: Colors.grey.shade100, shape: BoxShape.circle),
            child: Icon(Icons.search_off, size: 48, color: Colors.grey.shade400),
          ),
          const SizedBox(height: 16),
          Text(
            "Tidak ada telur terdeteksi",
            style: TextStyle(fontSize: 17, color: Colors.grey.shade700, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            "Coba ambil foto lain",
            style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }
}

// HistoryPage tetap sama seperti kode kamu (sudah bagus)

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
      final res = await http.get(Uri.parse("$vpsBaseUrl/results?limit=20"));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() => items = data["items"] ?? []);
      }
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
    final lowerLabel = label.toLowerCase();
    if (lowerLabel.contains('fertile') && !lowerLabel.contains('unfertil')) {
      return Colors.green;
    } else if (lowerLabel.contains('unfertil')) {
      return Colors.orange.shade700;
    } else {
      return Colors.grey;
    }
  }

  IconData _getLabelIcon(String label) {
    final normalized = label.toLowerCase();
    if (normalized.contains('fertil') && !normalized.contains('in')) {
      return Icons.check_circle_rounded;
    }
    return Icons.cancel_rounded;
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
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    size: 20,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Riwayat Deteksi",
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A2E),
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "${items.length} hasil scan tersimpan",
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
            CircularProgressIndicator(
              color: Colors.purple.shade600,
              strokeWidth: 3,
            ),
            const SizedBox(height: 16),
            Text(
              "Memuat riwayat...",
              style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
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
        preds = predData.map((e) {
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

    return TweenAnimationBuilder(
      duration: Duration(milliseconds: 300 + (index * 50)),
      tween: Tween<double>(begin: 0, end: 1),
      builder: (context, double value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 20 * (1 - value)),
            child: child,
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 15,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => DetailPage(item: item)),
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    // Image Preview
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: labelColor.withOpacity(0.2),
                          width: 2,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: imageUrl.isNotEmpty
                            ? Image.network(
                                imageUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  color: Colors.grey.shade100,
                                  child: Icon(
                                    Icons.egg_outlined,
                                    size: 36,
                                    color: Colors.grey.shade400,
                                  ),
                                ),
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
                              )
                            : Container(
                                color: Colors.grey.shade100,
                                child: Icon(
                                  Icons.egg_outlined,
                                  size: 36,
                                  color: Colors.grey.shade400,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(width: 16),

                    // Info Section
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Object count & Time
                          Row(
                            children: [
                              Icon(
                                Icons.radar_outlined,
                                size: 14,
                                color: Colors.grey.shade500,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                "${preds.length} objek terdeteksi",
                                style: TextStyle(
                                  fontSize: 13,
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