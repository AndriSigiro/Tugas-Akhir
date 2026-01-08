import os
import time
import base64
import sqlite3
import uuid
import json
import io
from flask import Flask, request, jsonify, send_file, send_from_directory
from ultralytics import YOLO
import cv2
import numpy as np

# ==================== CONFIGURATION ====================
app = Flask(__name__)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

UPLOAD_FOLDER = os.environ.get("UPLOAD_FOLDER", os.path.join(BASE_DIR, "uploads"))
MODEL_PATH = os.environ.get("MODEL_PATH", os.path.join(BASE_DIR, "Model", "best (12).pt"))
DB_NAME = os.environ.get("DB_NAME", os.path.join(BASE_DIR, "results.db"))

# Create upload folder
os.makedirs(UPLOAD_FOLDER, exist_ok=True)

# ==================== MODEL LOADING ====================
print("?? Loading YOLO model...")
yolo_model = YOLO(MODEL_PATH)
print(f"? Model loaded: {MODEL_PATH}")

# ==================== DATABASE ====================
def get_db_connection():
    conn = sqlite3.connect(DB_NAME)
    conn.row_factory = sqlite3.Row
    
    conn.execute("""
        CREATE TABLE IF NOT EXISTS results(
            id TEXT NOT NULL,
            device_id TEXT,
            ts INTEGER,
            file TEXT,
            label TEXT,
            score REAL,
            box_x1 REAL,
            box_y1 REAL,
            box_x2 REAL,
            box_y2 REAL
        );
    """)
    
    conn.execute("CREATE INDEX IF NOT EXISTS idx_results_id_ts ON results(id, ts DESC);")
    conn.commit()
    return conn

def save_detection_to_db(record_id, device_id, timestamp, filename, predictions):
    conn = get_db_connection()
    cursor = conn.cursor()
    
    cursor.execute("DELETE FROM results WHERE id = ?", (record_id,))
    
    for pred in predictions:
        label = pred.get("label", "unknown")
        score = pred.get("score", 0.0)
        box = pred.get("box", [])
        
        if label == "unknown":
            continue
        
        x1, y1, x2, y2 = (box[0], box[1], box[2], box[3]) if len(box) == 4 else (0, 0, 0, 0)
        
        cursor.execute("""
            INSERT INTO results (id, device_id, ts, file, label, score, box_x1, box_y1, box_x2, box_y2)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (record_id, device_id, timestamp, filename, label, round(score, 4),
              round(x1, 2), round(y1, 2), round(x2, 2), round(y2, 2)))
    
    if not predictions or all(p.get("label") == "unknown" for p in predictions):
        cursor.execute("""
            INSERT INTO results (id, device_id, ts, file, label, score, box_x1, box_y1, box_x2, box_y2)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (record_id, device_id, timestamp, filename, "no_detection", 0.0, 0, 0, 0, 0))
    
    conn.commit()
    conn.close()

def get_latest_result():
    conn = get_db_connection()
    cur = conn.execute("SELECT MAX(ts) as max_ts FROM results")
    row = cur.fetchone()
    
    if not row or not row["max_ts"]:
        conn.close()
        return None
    
    latest_ts = row["max_ts"]
    cur = conn.execute("""
        SELECT id, device_id, ts, file, label, score, box_x1, box_y1, box_x2, box_y2
        FROM results WHERE ts = ? ORDER BY score DESC
    """, (latest_ts,))
    rows = cur.fetchall()
    conn.close()
    
    if not rows:
        return None
    
    first = rows[0]
    predictions = []
    for r in rows:
        predictions.append({
            "label": r["label"],
            "score": r["score"],
            "box": [r["box_x1"], r["box_y1"], r["box_x2"], r["box_y2"]]
        })
    
    return {
        "id": first["id"],
        "device_id": first["device_id"],
        "timestamp": first["ts"],
        "file": first["file"],
        "pred": predictions
    }

def get_results_list(limit=20, offset=0):
    conn = get_db_connection()
    cur = conn.execute("""
        SELECT DISTINCT id, device_id, ts, file
        FROM results GROUP BY id ORDER BY ts DESC LIMIT ? OFFSET ?
    """, (limit, offset))
    records = cur.fetchall()
    
    result_list = []
    for record in records:
        det_cur = conn.execute("""
            SELECT label, score, box_x1, box_y1, box_x2, box_y2
            FROM results WHERE id = ? ORDER BY score DESC
        """, (record["id"],))
        detections = det_cur.fetchall()
        
        predictions = []
        for det in detections:
            predictions.append({
                "label": det["label"],
                "score": det["score"],
                "box": [det["box_x1"], det["box_y1"], det["box_x2"], det["box_y2"]]
            })
        
        result_list.append({
            "id": record["id"],
            "device_id": record["device_id"],
            "timestamp": record["ts"],
            "file": record["file"],
            "pred": predictions
        })
    
    conn.close()
    return result_list

# ==================== YOLO INFERENCE ====================
def run_yolo_detection(image_path):
    img = cv2.imread(image_path)
    orig_h, orig_w = img.shape[:2]  # Simpan resolusi asli
    
    # Resize ke 640x640 untuk inference (standar YOLO)
    input_size = 640
    img_resized = cv2.resize(img, (input_size, input_size))
    
    results = yolo_model.predict(source=img_resized, save=False, verbose=False, conf=0.5)
    
    predictions = []
    if results and results[0].boxes and len(results[0].boxes) > 0:
        for box in results[0].boxes:
            label = results[0].names[int(box.cls)]
            score = float(box.conf)
            xyxy = box.xyxy.cpu().numpy()[0].tolist()  # Box di resized image
            
            if score >= 0.6:
                # Scale kembali ke resolusi asli
                x1 = int(xyxy[0] * orig_w / input_size)
                y1 = int(xyxy[1] * orig_h / input_size)
                x2 = int(xyxy[2] * orig_w / input_size)
                y2 = int(xyxy[3] * orig_h / input_size)
                
                predictions.append({
                    "label": label,
                    "score": score,
                    "box": [x1, y1, x2, y2]
                })
    
    if not predictions:
        predictions = [{"label": "unknown", "score": 0.0, "box": []}]
    
    # Gambar box di gambar asli (bukan resized)
    image_with_boxes = draw_boxes_on_image(image_path, predictions)
    return predictions, image_with_boxes
def draw_boxes_on_image(image_path, predictions):
    img = cv2.imread(image_path)
    if img is None:
        raise ValueError(f"Failed to load image: {image_path}")
    
    THICKNESS = 8
    for pred in predictions:
        if pred["box"] and len(pred["box"]) == 4:
            x1, y1, x2, y2 = map(int, pred["box"])
            label = pred['label'].lower()
            
            if 'unfertil' in label:
                box_color = (0, 165, 255)  # Orange
            elif 'fertile' in label:
                box_color = (0, 255, 0)    # Green
            else:
                box_color = (128, 128, 128)  # Gray
            cv2.rectangle(img, (x1, y1), (x2, y2), box_color, THICKNESS)
    
    _, buffer = cv2.imencode(".jpg", img, [int(cv2.IMWRITE_JPEG_QUALITY), 90])
    img_base64 = base64.b64encode(buffer).decode('utf-8')
    return f"data:image/jpeg;base64,{img_base64}"

# ==================== HELPER FUNCTIONS ====================
def generate_record_id():
    return f"rec_{uuid.uuid4().hex[:12]}"

def save_base64_image(image_b64, device_id, timestamp):
    raw = base64.b64decode(image_b64)
    filename = f"{device_id}_{timestamp}.jpg"
    filepath = os.path.join(UPLOAD_FOLDER, filename)
    with open(filepath, "wb") as f:
        f.write(raw)
    return filename, filepath

# ==================== API ROUTES ====================
@app.route("/upload", methods=["POST"])
def upload_base64():
    """Terima upload dari Raspberry (webcam) atau ESP32"""
    try:
        data = request.get_json(force=True)
        device_id = data.get("device_id", "unknown")
        timestamp = int(data.get("timestamp", time.time()))
        image_b64 = data.get("image")
        
        if not image_b64:
            return jsonify({"error": "No image data provided"}), 400
        
        filename, filepath = save_base64_image(image_b64, device_id, timestamp)
        predictions, image_with_boxes = run_yolo_detection(filepath)
        
        record_id = generate_record_id()
        save_detection_to_db(record_id, device_id, timestamp, filename, predictions)
        
        return jsonify({
            "status": "ok",
            "id": record_id,
            "file": filename,
            "pred": predictions,
            "image_with_boxes": image_with_boxes
        }), 200
        
    except Exception as e:
        print(f"[ERROR] Upload failed: {str(e)}")
        return jsonify({"error": str(e)}), 500

@app.route("/upload-file", methods=["POST"])
def upload_file():
    """Upload manual dari Flutter"""
    try:
        if "file" not in request.files:
            return jsonify({"error": "No file uploaded"}), 400
        
        file = request.files["file"]
        if file.filename == "":
            return jsonify({"error": "Empty filename"}), 400
        
        timestamp = int(time.time())
        filename = f"manual_{timestamp}_{file.filename}"
        filepath = os.path.join(UPLOAD_FOLDER, filename)
        file.save(filepath)
        
        predictions, image_with_boxes = run_yolo_detection(filepath)
        
        record_id = generate_record_id()
        save_detection_to_db(record_id, "manual", timestamp, filename, predictions)
        
        return jsonify({
            "status": "ok",
            "id": record_id,
            "file": filename,
            "pred": predictions,
            "image_with_boxes": image_with_boxes
        }), 200
        
    except Exception as e:
        print(f"[ERROR] Upload file failed: {str(e)}")
        return jsonify({"error": str(e)}), 500

# /trigger-camera DIBIARKAN UNTUK KOMPATIBILITAS, TAPI TIDAK PULL GAMBAR
@app.route("/trigger-camera", methods=["POST"])
def trigger_camera():
    """Hanya informasi bahwa trigger diterima (trigger sebenarnya dari HP langsung ke Raspberry)"""
    print("\n" + "="*50)
    print("?? TRIGGER CAMERA REQUEST FROM HP (Info Only)")
    print("   Catatan: Capture & upload dilakukan langsung dari Raspberry ke VPS")
    print("="*50 + "\n")
    
    return jsonify({
        "status": "success",
        "message": "Trigger diterima. Raspberry akan capture & upload otomatis."
    }), 200

# Route lain tetap sama
@app.route("/latest", methods=["GET"])
def get_latest_image():
    result = get_latest_result()
    if not result:
        return jsonify({"error": "No images found"}), 404
    
    filepath = os.path.join(UPLOAD_FOLDER, result["file"])
    _, image_with_boxes = run_yolo_detection(filepath)
    
    image_data = base64.b64decode(image_with_boxes.split(',')[1])
    return send_file(io.BytesIO(image_data), mimetype="image/jpeg")

@app.route("/result", methods=["GET"])
def get_latest_result_json():
    result = get_latest_result()
    if not result:
        return jsonify({"error": "No results found"}), 404
    
    base_url = f"http://{request.host}"
    return jsonify({
        "id": result["id"],
        "device_id": result["device_id"],
        "timestamp": result["timestamp"],
        "file": result["file"],
        "pred": result["pred"],
        "image_url": f"{base_url}/uploads/{result['file']}"
    })

@app.route("/results", methods=["GET"])
def list_detection_results():
    limit = int(request.args.get("limit", 20))
    offset = int(request.args.get("offset", 0))
    results = get_results_list(limit, offset)
    
    base_url = f"http://{request.host}"
    items = []
    for result in results:
        items.append({
            "id": result["id"],
            "device_id": result["device_id"],
            "timestamp": result["timestamp"],
            "file": result["file"],
            "pred": result["pred"],
            "image_url": f"{base_url}/uploads/{result['file']}"
        })
    
    return jsonify({"items": items, "count": len(items)})

@app.route("/latest-detection", methods=["GET"])
def get_latest_detection():
    result = get_latest_result()
    if not result:
        return jsonify({"error": "No detection found"}), 404
    
    filepath = os.path.join(UPLOAD_FOLDER, result["file"])
    _, image_with_boxes = run_yolo_detection(filepath)
    
    base_url = f"http://{request.host}"
    source = "camera" if result["device_id"].startswith("web") or "raspberry" in result["device_id"] else "mobile"
    
    return jsonify({
        "status": "success",
        "id": result["id"],
        "device_id": result["device_id"],
        "timestamp": result["timestamp"],
        "source": source,
        "file": result["file"],
        "predictions": result["pred"],
        "image_url": f"{base_url}/uploads/{result['file']}",
        "image_with_boxes": image_with_boxes,
        "total_detections": len([p for p in result["pred"] if p["label"] not in ["unknown", "no_detection"]])
    }), 200

@app.route("/health", methods=["GET"])
def health_check():
    return jsonify({
        "status": "ok",
        "model": MODEL_PATH,
        "server": "VPS Cloud Server",
        "timestamp": int(time.time())
    })

@app.route('/uploads/<path:filename>')
def serve_uploads(filename):
    return send_from_directory(UPLOAD_FOLDER, filename)

# ==================== MAIN ====================
if __name__ == "__main__":
    import socket
    
    # Get local IP for display
    hostname = socket.gethostname()
    
    print("\n" + "="*60)
    print("🚀 Flask YOLO Detection Server - Egg Fertility Detection")
    print("="*60)
    print(f"📁 Upload folder: {UPLOAD_FOLDER}")
    print(f"🗃️ Database: {DB_NAME}")
    print(f"🤖 Model: {MODEL_PATH}")
    print(f"🌐 Server running on: http://0.0.0.0:9090")
    print("="*60)
    print("📡 API Endpoints:")
    print("   POST /upload        - Upload base64 image")
    print("   POST /upload-file   - Upload image file")
    print("   GET  /latest        - Get latest detection image")
    print("   GET  /result        - Get latest result JSON")
    print("   GET  /results       - List all results")
    print("   GET  /health        - Health check")
    print("="*60 + "\n")
    
    app.run(host="0.0.0.0", port=9090, debug=False)