// detail_page.dart
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

class DetailPage extends StatelessWidget {
  final Map<String, dynamic> item;

  const DetailPage({super.key, required this.item});

  Color _getLabelColor(String label) {
    final l = label.toLowerCase();
    if (l.contains('fertile')) return Colors.green;
    if (l.contains('unfertil') || l.contains('unfertile')) return Colors.orange.shade700;
    return Colors.grey;
  }

  IconData _getLabelIcon(String label) {
    final l = label.toLowerCase();
    if (l.contains('fertile')) return Icons.check_circle_rounded;
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
          final scoreA = (a["score"] as num?)?.toDouble() ?? 0.0;
          final scoreB = (b["score"] as num?)?.toDouble() ?? 0.0;
          return scoreA > scoreB ? a : b;
        });
      } catch (e) {
        debugPrint("Error reducing predictions: $e");
      }
    }

    // ✅ SAFE extraction
    final label = best["label"]?.toString() ?? "Unknown";
    final score = (best["score"] as num?)?.toDouble() ?? 0.0;
    final imageUrl = item["image_url"]?.toString() ?? "";
    
    // ✅ SAFE timestamp
    final timestamp = (item["timestamp"] as int?) ?? 0;
    final deviceId = item["device_id"]?.toString() ?? "Manual";

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
                    const Expanded(
                      child: Text(
                        "Detail Hasil Deteksi",
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
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
                      ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: CachedNetworkImage(
                          imageUrl: imageUrl,
                          placeholder: (_, __) => Container(
                            height: 400,
                            color: Colors.grey.shade200,
                            child: const Center(child: CircularProgressIndicator()),
                          ),
                          errorWidget: (_, __, ___) => Container(
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
                          ),
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: 400,
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Badge hasil utama
                      Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                          decoration: BoxDecoration(
                            color: _getLabelColor(label).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: _getLabelColor(label), width: 3),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(_getLabelIcon(label), 
                                   color: _getLabelColor(label), 
                                   size: 48),
                              const SizedBox(width: 16),
                              Column(
                                children: [
                                  Text(
                                    label.toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.bold,
                                      color: _getLabelColor(label),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    "${(score * 100).toStringAsFixed(1)}% Confidence",
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: _getLabelColor(label),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),

                      // Info tambahan
                      _buildInfoCard("Waktu Deteksi", _formatDate(timestamp)),
                      _buildInfoCard("Device ID", deviceId),
                      _buildInfoCard("Jumlah Objek", "${preds.length} objek terdeteksi"),

                      const SizedBox(height: 24),

                      // Daftar semua deteksi
                      if (preds.length > 1) ...[
                        const Text(
                          "Detail Semua Deteksi",
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 16),
                        ...preds.asMap().entries.map((entry) {
                          final index = entry.key;
                          final p = entry.value;
                          
                          final l = p["label"]?.toString() ?? "Unknown";
                          final s = (p["score"] as num?)?.toDouble() ?? 0.0;
                          
                          return Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            color: _getLabelColor(l).withOpacity(0.08),
                            elevation: 2,
                            child: ListTile(
                              contentPadding: const EdgeInsets.all(16),
                              leading: CircleAvatar(
                                backgroundColor: _getLabelColor(l).withOpacity(0.2),
                                child: Icon(_getLabelIcon(l), 
                                          color: _getLabelColor(l)),
                              ),
                              title: Text(
                                l,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                ),
                              ),
                              subtitle: Text(
                                "Confidence: ${(s * 100).toStringAsFixed(1)}%",
                                style: TextStyle(
                                  color: _getLabelColor(l),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              trailing: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12, 
                                  vertical: 6
                                ),
                                decoration: BoxDecoration(
                                  color: _getLabelColor(l).withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  "#${index + 1}",
                                  style: TextStyle(
                                    fontSize: 12,
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