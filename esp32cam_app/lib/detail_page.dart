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
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return "${date.day}/${date.month}/${date.year} • ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    final preds = List<Map<String, dynamic>>.from(item["pred"]);
    final best = preds.isNotEmpty
        ? preds.reduce((a, b) => (a["score"] as num) > (b["score"] as num) ? a : b)
        : {"label": "Unknown", "score": 0.0};

    final label = best["label"] as String;
    final score = (best["score"] as num).toDouble();
    final imageUrl = item["image_url"] as String;

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
                    const Text(
                      "Detail Hasil Deteksi",
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
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
                            child: const Icon(Icons.error, size: 60),
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
                              Icon(_getLabelIcon(label), color: _getLabelColor(label), size: 48),
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
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),

                      // Info tambahan
                      _buildInfoCard("Waktu Deteksi", _formatDate(item["timestamp"])),
                      _buildInfoCard("Device ID", item["device_id"] ?? "Manual"),
                      _buildInfoCard("Jumlah Objek", "${preds.length} telur terdeteksi"),

                      const SizedBox(height: 24),

                      // Daftar semua deteksi
                      if (preds.length > 1) ...[
                        const Text(
                          "Detail Semua Deteksi",
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 12),
                        ...preds.map((p) {
                          final l = p["label"] as String;
                          final s = (p["score"] as num).toDouble();
                          return Card(
                            color: _getLabelColor(l).withOpacity(0.1),
                            child: ListTile(
                              leading: Icon(_getLabelIcon(l), color: _getLabelColor(l)),
                              title: Text(l, style: const TextStyle(fontWeight: FontWeight.w600)),
                              trailing: Text("${(s * 100).toStringAsFixed(1)}%"),
                            ),
                          );
                        }),
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
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: const TextStyle(fontSize: 15, color: Colors.grey)),
            Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}