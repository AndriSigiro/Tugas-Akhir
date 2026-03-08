import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('deteksi_telur.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE deteksi (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp INTEGER NOT NULL,
        image_path TEXT,
        image_base64 TEXT,
        detections TEXT NOT NULL,
        fertile_count INTEGER NOT NULL,
        infertile_count INTEGER NOT NULL,
        source TEXT NOT NULL
      )
    ''');
  }

  Future<int> insertDeteksi({
    required String imagePath,
    String? imageBase64,
    required List<Map<String, dynamic>> detections,
    required int fertileCount,
    required int infertileCount,
    required String source, // 'camera', 'gallery', 'webcam'
  }) async {
    final db = await database;
    
    final data = {
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'image_path': imagePath,
      'image_base64': imageBase64,
      'detections': jsonEncode(detections),
      'fertile_count': fertileCount,
      'infertile_count': infertileCount,
      'source': source,
    };

    return await db.insert('deteksi', data);
  }

  Future<List<Map<String, dynamic>>> getAllDeteksi() async {
    final db = await database;
    
    final result = await db.query(
      'deteksi',
      orderBy: 'timestamp DESC',
    );

    return result.map((row) {
      return {
        'id': row['id'],
        'timestamp': row['timestamp'],
        'image_path': row['image_path'],
        'image_base64': row['image_base64'],
        'pred': jsonDecode(row['detections'] as String),
        'fertile_count': row['fertile_count'],
        'infertile_count': row['infertile_count'],
        'source': row['source'],
        'is_local': true, // Marker untuk bedakan dari server
      };
    }).toList();
  }

  Future<int> deleteDeteksi(int id) async {
    final db = await database;
    return await db.delete(
      'deteksi',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> clearAllDeteksi() async {
    final db = await database;
    return await db.delete('deteksi');
  }

  Future close() async {
    final db = await database;
    db.close();
  }
}
