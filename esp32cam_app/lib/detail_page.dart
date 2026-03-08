// detail_page.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

class DetailPage extends StatelessWidget {
  final Map<String, dynamic> item;

  const DetailPage({super.key, required this.item});

  // Helper to get confidence from either 'score' (server) or 'conf' (local)
  double _getConfidence(Map<String, dynamic> prediction) {
    // Try 'score' first (server data)
    if (prediction.containsKey('score') && prediction['score'] != null) {
      return (prediction['score'] as num).toDouble();
    }
    // Try 'conf' (local data)
    if (prediction.containsKey('conf') && prediction['conf'] != null) {
      return (prediction['conf'] as num).toDouble();
    }
    return 0.0;
  }

  Color _getLabelColor(String label) {
    final l = label.toLowerCase();
    if (l.contains('fertil') || l.contains('fertile')) return Colors.green;
    if (l.contains('infertil') || l.contains('infertile') || l.contains('unfertil') || l.contains('unfertile')) {
      return Colors.orange.shade700;
    }
    return Colors.grey;
  }

  IconData _getLabelIcon(String label) {
    final l = label.toLowerCase();
    if (l.contains('fertil') || l.contains('fertile')) return Icons.check_circle_rounded;
    return Icons.cancel_rounded;
  }

  String _formatDate(int timestamp) {
    try {
      final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
      return "${date.day}/${date.month}/${date.year} • ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}";
    } catch (e) {
      return "Tanggal tidak valid";
    }
  }

  @override
  Widget build(BuildContext context) {
    // ✅ ULTRA SAFE PARSING - INI YANG BIKIN ERROR HILANG!
    List<Map<String, dynamic>> preds = [];
    
    // Check apakah 'pred' ada dan bukan null
    if (item.containsKey("pred") && item["pred"] != null) {
      final dynamic predData = item["pred"];
      
      // Check apakah pred adalah List
      if (predData is List) {
        preds = predData
            .where((p) => p != null)
            .where((p) => p is Map)
            .cast<Map<String, dynamic>>()
            .toList();
      }
    }

    // ✅ SAFE best prediction
    Map<String, dynamic> best = {"label": "Unknown", "score": 0.0};
    if (preds.isNotEmpty) {
      try {
        best = preds.reduce((a, b) {
          final scoreA = _getConfidence(a);
          final scoreB = _getConfidence(b);
          return scoreA > scoreB ? a : b;
        });
      } catch (e) {
        debugPrint("Error reducing predictions: $e");
      }
    }

    // ✅ SAFE extraction
    final label = best["label"]?.toString() ?? "Unknown";
    final score = _getConfidence(best);
    final imageUrl = item["image_url"]?.toString() ?? "";
    
    // ✅ SAFE timestamp
    final timestamp = (item["timestamp"] as int?) ?? 0;
    final deviceId = item["device_id"]?.toString() ?? "Manual";
    
    // ✅ Check if local or server data
    final isLocal = item["is_local"] == true;
    final imagePath = item["image_path"];
    final imageBase64 = item["image_base64"];
    final source = item["source"]?.toString() ?? (isLocal ? "lokal" : "server");
    
    // ✅ Count fertile/infertile
    int fertileCount = preds.where((p) {
      final l = (p['label']?.toString() ?? '').toLowerCase();
      return l == 'fertile' || l == 'fertil';
    }).length;
    int infertileCount = preds.where((p) {
      final l = (p['label']?.toString() ?? '').toLowerCase();
      return l == 'infertile' || l == 'infertil';
    }).length;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF8F9FA), Color(0xFFE8EAF6)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(color: Colors.black12, blurRadius: 8)
                        ],
                      ),
                      child: IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.arrow_back_ios_new_rounded),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Detail Deteksi",
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1A1A2E),
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: isLocal 
                                  ? [Colors.blue.shade400, Colors.blue.shade600]
                                  : [Colors.purple.shade400, Colors.purple.shade600],
                              ),
                              borderRadius: BorderRadius.circular(10),
                              boxShadow: [
                                BoxShadow(
                                  color: (isLocal ? Colors.blue : Colors.purple).withOpacity(0.3),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Text(
                              isLocal ? "📱 LOKAL" : "☁️ SERVER",
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Gambar besar dengan box
                      Hero(
                        tag: 'detail_image_${item["timestamp"] ?? 0}',
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: [
                              BoxShadow(
                                color: (fertileCount > infertileCount ? Colors.green : Colors.orange).withOpacity(0.15),
                                blurRadius: 24,
                                offset: const Offset(0, 8),
                                spreadRadius: -4,
                              ),
                              BoxShadow(
                                color: Colors.black.withOpacity(0.08),
                                blurRadius: 16,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(24),
                            child: _buildDetailImage(isLocal, imageUrl, imagePath, imageBase64),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Colors.white, Colors.grey.shade50.withOpacity(0.3)],
                          ),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.grey.shade200),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.04),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            _buildInfoRow(Icons.access_time_rounded, "Waktu Deteksi", _formatDate(timestamp), Colors.blue),
                            const Divider(height: 24),
                            _buildInfoRow(Icons.devices_rounded, "Sumber", isLocal ? "Deteksi Lokal" : "Server ($deviceId)", Colors.purple),
                            const Divider(height: 24),
                            _buildInfoRow(Icons.egg_outlined, "Total Objek", "${preds.length} telur", Colors.amber),
                            const Divider(height: 24),
                            _buildInfoRow(Icons.check_circle_outline, "Fertil", "$fertileCount telur", Colors.green),
                            const Divider(height: 24),
                            _buildInfoRow(Icons.cancel_outlined, "Infertil", "$infertileCount telur", Colors.orange),
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),

                      // Daftar semua deteksi
                      if (preds.length > 1) ...[
                        const Text(
                          "Detail Semua Deteksi",
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1A1A2E),
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 16),
                        ...preds.asMap().entries.map((entry) {
                          final index = entry.key;
                          final p = entry.value;
                          
                          final l = p["label"]?.toString() ?? "Unknown";
                          final s = _getConfidence(p);
                          
                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Colors.white, _getLabelColor(l).withOpacity(0.05)],
                              ),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: _getLabelColor(l).withOpacity(0.3), width: 1.5),
                              boxShadow: [
                                BoxShadow(
                                  color: _getLabelColor(l).withOpacity(0.1),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                              leading: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      _getLabelColor(l).withOpacity(0.8),
                                      _getLabelColor(l),
                                    ],
                                  ),
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: _getLabelColor(l).withOpacity(0.3),
                                      blurRadius: 8,
                                      offset: const Offset(0, 3),
                                    ),
                                  ],
                                ),
                                child: Icon(_getLabelIcon(l), color: Colors.white, size: 22),
                              ),
                              title: Text(
                                l.toUpperCase(),
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: _getLabelColor(l),
                                  letterSpacing: 0.3,
                                ),
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Row(
                                  children: [
                                    Icon(Icons.analytics, size: 14, color: Colors.grey.shade600),
                                    const SizedBox(width: 4),
                                    Text(
                                      "${(s * 100).toStringAsFixed(1)}% confidence",
                                      style: TextStyle(
                                        color: Colors.grey.shade700,
                                        fontWeight: FontWeight.w500,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              trailing: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      _getLabelColor(l).withOpacity(0.2),
                                      _getLabelColor(l).withOpacity(0.3),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Text(
                                  "#${index + 1}",
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: _getLabelColor(l),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ] else if (preds.isEmpty) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          margin: const EdgeInsets.only(top: 16),
                          decoration: BoxDecoration(
                            color: Colors.orange.shade50,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.orange.shade200),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.info_outline, 
                                   color: Colors.orange.shade700, 
                                   size: 28),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  "Tidak ada prediksi yang ditemukan untuk gambar ini",
                                  style: TextStyle(
                                    color: Colors.orange.shade700,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailImage(bool isLocal, String imageUrl, dynamic imagePath, dynamic imageBase64) {
    // Jika data lokal, tampilkan dari file atau base64
    if (isLocal) {
      // Coba base64 dulu
      if (imageBase64 != null && imageBase64.toString().isNotEmpty) {
        try {
          final bytes = base64Decode(imageBase64.toString());
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            width: double.infinity,
            height: 400,
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
            width: double.infinity,
            height: 400,
            errorBuilder: (_, __, ___) => _buildPlaceholderImage(),
          );
        }
      }
      
      return _buildPlaceholderImage();
    }
    
    // Jika data server, tampilkan dari URL
    if (imageUrl.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: imageUrl,
        placeholder: (_, __) => Container(
          height: 400,
          color: Colors.grey.shade200,
          child: const Center(child: CircularProgressIndicator()),
        ),
        errorWidget: (_, __, ___) => _buildPlaceholderImage(),
        fit: BoxFit.cover,
        width: double.infinity,
        height: 400,
      );
    }
    
    return _buildPlaceholderImage();
  }

  Widget _buildPlaceholderImage() {
    return Container(
      height: 400,
      color: Colors.grey.shade200,
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.image_not_supported_outlined, size: 60, color: Colors.grey),
          SizedBox(height: 8),
          Text("Gambar tidak dapat dimuat", style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String title, String value, Color color) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, size: 20, color: color),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A2E),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInfoCard(String title, String value) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 15,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w500,
              ),
            ),
            Flexible(
              child: Text(
                value,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A2E),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}