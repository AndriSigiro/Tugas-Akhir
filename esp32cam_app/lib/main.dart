import 'dart:convert';
import 'dart:io';
import 'package:esp32cam_app/detail_page.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'detail_page.dart'; // pastikan path-nya benar
import 'package:cached_network_image/cached_network_image.dart';

void main() {
  runApp(const MyApp());
}

const String baseUrl = "http://172.18.215.92:9090";

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

// ==================== HOME PAGE ====================
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

  // ========== API Methods ==========
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

    final uri = Uri.parse("$baseUrl/upload-file");
    final request = http.MultipartRequest("POST", uri);
    request.files.add(
      await http.MultipartFile.fromPath("file", imageFile.path),
    );

    try {
      final response = await request.send();
      final resBody = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        final data = jsonDecode(resBody);
        setState(() {
          _predictions = List<Map<String, dynamic>>.from(data["pred"]);
          _imageWithBoxesBase64 = data["image_with_boxes"];
          _latestImageUrl =
              "$baseUrl/latest?ts=${DateTime.now().millisecondsSinceEpoch}";
        });
      } else {
        _showSnackBar("Upload gagal: ${response.statusCode}", isError: true);
      }
    } catch (e) {
      _showSnackBar("Error: $e", isError: true);
    }

    setState(() => _loading = false);
  }

  Future<void> fetchLatestResult() async {
    try {
      final res = await http.get(Uri.parse("$baseUrl/result"));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          _predictions = List<Map<String, dynamic>>.from(data["pred"]);
          _latestImageUrl =
              "$baseUrl/latest?ts=${DateTime.now().millisecondsSinceEpoch}";
        });
      }
    } catch (e) {
      debugPrint("Error fetchLatestResult: $e");
    }
  }

  // ========== Helper Methods ==========
  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Color _getLabelColor(String label) {
    if (label == "fertile") {
      return Colors.green;
    } else if (label == "unfertile") {
      return const Color(0xFFFF9800); // Orange Material
    } else {
      return Colors.grey;
    }
  }

  Map<String, dynamic>? get _bestPrediction {
    if (_predictions.isEmpty) return null;
    return _predictions.reduce((a, b) => (a["score"] > b["score"]) ? a : b);
  }

  // ========== UI Build Methods ==========
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.blue.shade50, Colors.white],
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
      padding: const EdgeInsets.all(24),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.shade600,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.blue.withOpacity(0.3),
                  blurRadius: 15,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: const Icon(
              Icons.egg_outlined,
              size: 32,
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
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
                Text(
                  "AI Detection System",
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed:
                () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const HistoryPage()),
                ),
            icon: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.purple.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.history,
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
        _buildSectionTitle(),
        const SizedBox(height: 20),
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
        else if (_bestPrediction != null)
          _buildResultContainer()
        else
          _buildNoDetection(),
        const SizedBox(height: 24),
        _buildActionButtons(),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildSectionTitle() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 20,
            decoration: BoxDecoration(
              color: Colors.blue.shade600,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          const Text(
            "Hasil Deteksi Terbaru",
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A2E),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageContainer() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(
        maxHeight: 500, // batas maksimal biar tidak terlalu tinggi
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          children: [
            _buildImage(), // gambar utama
            if (_predictions.isNotEmpty) _buildImageOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildImage() {
    // Prioritas: 1. hasil deteksi (dengan box), 2. latest dari server, 3. gambar lokal
    if (_imageWithBoxesBase64 != null) {
      return _buildNetworkOrMemoryImage(
        isBase64: true,
        data: _imageWithBoxesBase64!,
      );
    } else if (_latestImageUrl != null) {
      return _buildNetworkOrMemoryImage(isBase64: false, url: _latestImageUrl!);
    } else if (_imageFile != null) {
      return Image.file(
        _imageFile!,
        fit: BoxFit.contain, // penting!
        width: double.infinity,
      );
    }

    return _buildFallbackImage();
  }

  // FUNGSI BARU: menangani gambar dari base64 atau network dengan rasio asli
  Widget _buildNetworkOrMemoryImage({
    required bool isBase64,
    String? url,
    String? data,
  }) {
    // Gunakan InteractiveViewer biar bisa zoom & pan kalau perlu
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 4.0,
      child: Container(
        width: double.infinity,
        color: Colors.black, // background hitam biar kelihatan rapi
        child:
            isBase64
                ? Image.memory(
                  base64Decode(data!.split(',').last),
                  fit:
                      BoxFit.contain, // INI YANG MEMBUAT GAMBAR TIDAK DIPOTONG!
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => _buildFallbackImage(),
                )
                : CachedNetworkImage(
                  imageUrl: url!,
                  fit: BoxFit.contain, // SAMA PENTING DI SINI!
                  placeholder:
                      (context, url) => const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                  errorWidget: (context, url, error) => _buildFallbackImage(),
                ),
      ),
    );
  }

  Widget _buildImageOverlay() {
    return Positioned(
      top: 12,
      left: 12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.7),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.egg, color: Colors.white, size: 18),
            const SizedBox(width: 6),
            Text(
              "${_predictions.length} telur",
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFallbackImage() {
    return Container(
      color: Colors.grey.shade100,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.image_outlined, size: 80, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            "Belum ada gambar",
            style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 8),
          Text(
            "Pilih gambar untuk memulai deteksi",
            style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          CircularProgressIndicator(color: Colors.blue.shade600),
          const SizedBox(height: 16),
          Text(
            "Menganalisis gambar...",
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey.shade700,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultContainer() {
    final best = _bestPrediction!;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _getLabelColor(best["label"]).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.check_circle,
                  color: _getLabelColor(best["label"]),
                  size: 32,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Hasil Deteksi",
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      best["label"],
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    Text(
                      "${_predictions.length} objek terdeteksi",
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoDetection() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(Icons.search_off, size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(
            "Tidak ada telur terdeteksi",
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey.shade700,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: _buildActionButton(
            icon: Icons.camera_alt,
            label: "Kamera",
            gradient: LinearGradient(
              colors: [Colors.blue.shade600, Colors.blue.shade400],
            ),
            onPressed: () => pickImage(ImageSource.camera),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildActionButton(
            icon: Icons.image,
            label: "Galeri",
            gradient: LinearGradient(
              colors: [Colors.purple.shade600, Colors.purple.shade400],
            ),
            onPressed: () => pickImage(ImageSource.gallery),
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Gradient gradient,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            gradient: gradient,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: gradient.colors.first.withOpacity(0.4),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 32),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== HISTORY PAGE ====================
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
      final res = await http.get(Uri.parse("$baseUrl/results?limit=20"));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() => items = data["items"]);
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
    if (lowerLabel.contains('fertile')) {
      return Colors.green;
    } else if (lowerLabel.contains('unfertil') ||
        lowerLabel.contains('unfertile')) {
      return Colors.orange.shade700; // Orange gelap biar kelihatan bagus
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
    final preds = List<Map<String, dynamic>>.from(item["pred"]);
    final best =
        preds.isNotEmpty
            ? preds.reduce((a, b) => a["score"] > b["score"] ? a : b)
            : null;

    final label = best?["label"] ?? "Unknown";
    final labelColor = best != null ? _getLabelColor(label) : Colors.grey;
    final imageUrl = "${item["image_url"]}";
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
                        child: Image.network(
                          imageUrl,
                          fit: BoxFit.cover,
                          errorBuilder:
                              (_, __, ___) => Container(
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
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),

                    // Info Section
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Status Badge
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: labelColor.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _getLabelIcon(label),
                                  size: 16,
                                  color: labelColor,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  label.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: labelColor,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),

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
                                _formatTimestamp(item["timestamp"]),
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
