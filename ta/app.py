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
from collections import defaultdict

# ==================== CONFIGURATION ====================
app = Flask(__name__)

# Folders & Paths
UPLOAD_FOLDER = "uploads"
MODEL_PATH = os.path.join("Model", "best (12).pt")
DB_NAME = "results.db"

# Create upload folder
os.makedirs(UPLOAD_FOLDER, exist_ok=True)

# ==================== MODEL LOADING ====================
print("🔄 Loading YOLO model...")
yolo_model = YOLO(MODEL_PATH)
print(f"✅ Model loaded: {MODEL_PATH}")


# ==================== DATABASE ====================
def get_db_connection():
    """Create and return database connection."""
    conn = sqlite3.connect(DB_NAME)
    conn.row_factory = sqlite3.Row
    
    # Create table with FLAT structure (satu baris = satu deteksi)
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
    
    # Create index untuk query cepat
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_results_id_ts 
        ON results(id, ts DESC);
    """)
    
    conn.commit()
    return conn


def save_detection_to_db(record_id, device_id, timestamp, filename, predictions):
    """Save detection result to database - FLAT structure."""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Hapus data lama dengan record_id yang sama (jika re-upload)
    cursor.execute("DELETE FROM results WHERE id = ?", (record_id,))
    
    # Insert setiap deteksi sebagai baris terpisah
    for pred in predictions:
        label = pred.get("label", "unknown")
        score = pred.get("score", 0.0)
        box = pred.get("box", [])
        
        # Skip unknown detections
        if label == "unknown":
            continue
        
        # Extract box coordinates
        x1, y1, x2, y2 = (box[0], box[1], box[2], box[3]) if len(box) == 4 else (0, 0, 0, 0)
        
        cursor.execute("""
            INSERT INTO results (id, device_id, ts, file, label, score, box_x1, box_y1, box_x2, box_y2)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            record_id,
            device_id,
            timestamp,
            filename,
            label,
            round(score, 4),
            round(x1, 2),
            round(y1, 2),
            round(x2, 2),
            round(y2, 2)
        ))
    
    # Jika tidak ada deteksi valid, simpan satu baris "no_detection"
    if not predictions or all(p.get("label") == "unknown" for p in predictions):
        cursor.execute("""
            INSERT INTO results (id, device_id, ts, file, label, score, box_x1, box_y1, box_x2, box_y2)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (record_id, device_id, timestamp, filename, "no_detection", 0.0, 0, 0, 0, 0))
    
    conn.commit()
    conn.close()


def get_latest_result():
    """Get latest detection result from database."""
    conn = get_db_connection()
    
    # Get latest timestamp
    cur = conn.execute("SELECT MAX(ts) as max_ts FROM results")
    row = cur.fetchone()
    
    if not row or not row["max_ts"]:
        conn.close()
        return None
    
    latest_ts = row["max_ts"]
    
    # Get all detections for that timestamp
    cur = conn.execute("""
        SELECT id, device_id, ts, file, label, score, box_x1, box_y1, box_x2, box_y2
        FROM results 
        WHERE ts = ?
        ORDER BY score DESC
    """, (latest_ts,))
    
    rows = cur.fetchall()
    conn.close()
    
    if not rows:
        return None
    
    # Group into single record with predictions array
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
    """Get list of detection results with pagination - GROUPED by record."""
    conn = get_db_connection()
    
    # Get unique records ordered by timestamp
    cur = conn.execute("""
        SELECT DISTINCT id, device_id, ts, file
        FROM results 
        GROUP BY id
        ORDER BY ts DESC
        LIMIT ? OFFSET ?
    """, (limit, offset))
    
    records = cur.fetchall()
    
    # For each record, get all its detections
    result_list = []
    for record in records:
        record_id = record["id"]
        
        # Get all detections for this record
        det_cur = conn.execute("""
            SELECT label, score, box_x1, box_y1, box_x2, box_y2
            FROM results
            WHERE id = ?
            ORDER BY score DESC
        """, (record_id,))
        
        detections = det_cur.fetchall()
        
        # Build predictions array
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
    """Run YOLO inference and draw bounding boxes on image."""
    results = yolo_model.predict(source=image_path, save=False, verbose=True, conf=0.5)
    print(f"[YOLO] Running inference on: {image_path}")
    
    predictions = []
    if results and results[0].boxes and len(results[0].boxes) > 0:
        for box in results[0].boxes:
            label = results[0].names[int(box.cls)]
            score = float(box.conf)
            xyxy = box.xyxy.cpu().numpy()[0].tolist()
            
            if score >= 0.6:
                predictions.append({
                    "label": label,
                    "score": score,
                    "box": xyxy
                })
                print(f"[YOLO] Detected: {label} (confidence: {score:.2f})")
    
    if not predictions:
        print("[YOLO] No objects detected")
        predictions = [{"label": "unknown", "score": 0.0, "box": []}]
    
    image_with_boxes = draw_boxes_on_image(image_path, predictions)
    
    return predictions, image_with_boxes


def draw_boxes_on_image(image_path, predictions):
    """Draw bounding boxes on image."""
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
    """Generate unique record ID."""
    return f"rec_{uuid.uuid4().hex[:12]}"


def save_base64_image(image_b64, device_id, timestamp):
    """Save base64 encoded image to file."""
    raw = base64.b64decode(image_b64)
    filename = f"{device_id}_{timestamp}.jpg"
    filepath = os.path.join(UPLOAD_FOLDER, filename)
    
    with open(filepath, "wb") as f:
        f.write(raw)
    
    return filename, filepath


# ==================== API ROUTES ====================
@app.route("/upload", methods=["POST"])
def upload_base64():
    """Upload image via JSON (ESP32-CAM base64)."""
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
        print(f"[ERROR] Upload base64 failed: {str(e)}")
        return jsonify({"error": str(e)}), 500


@app.route("/upload-file", methods=["POST"])
def upload_file():
    """Upload image via multipart file (Flutter/Web)."""
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


@app.route("/latest", methods=["GET"])
def get_latest_image():
    """Get latest detected image with bounding boxes."""
    result = get_latest_result()
    if not result:
        return jsonify({"error": "No images found"}), 404
    
    filepath = os.path.join(UPLOAD_FOLDER, result["file"])
    _, image_with_boxes = run_yolo_detection(filepath)
    
    image_data = base64.b64decode(image_with_boxes.split(',')[1])
    return send_file(io.BytesIO(image_data), mimetype="image/jpeg")


@app.route("/result", methods=["GET"])
def get_latest_result_json():
    """Get latest detection result as JSON."""
    result = get_latest_result()
    if not result:
        return jsonify({"error": "No results found"}), 404
    
    base_url = f"http://{request.host}"
    
    response = {
        "id": result["id"],
        "device_id": result["device_id"],
        "timestamp": result["timestamp"],
        "file": result["file"],
        "pred": result["pred"],
        "image_url": f"{base_url}/uploads/{result['file']}"
    }
    
    return jsonify(response)


@app.route("/results", methods=["GET"])
def list_detection_results():
    """Get list of detection results with pagination."""
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
    
    return jsonify({
        "items": items,
        "count": len(items)
    })


@app.route("/latest-detection", methods=["GET"])
def get_latest_detection():
    """Get latest detection with complete info."""
    result = get_latest_result()
    if not result:
        return jsonify({"error": "No detection found"}), 404
    
    filepath = os.path.join(UPLOAD_FOLDER, result["file"])
    _, image_with_boxes = run_yolo_detection(filepath)
    
    base_url = f"http://{request.host}"
    source = "camera" if result["device_id"].startswith("esp32") else "mobile"
    
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
        "total_detections": len([p for p in result["pred"] if p["label"] != "unknown" and p["label"] != "no_detection"])
    }), 200


@app.route("/health", methods=["GET"])
def health_check():
    """Health check endpoint."""
    return jsonify({
        "status": "ok",
        "model": MODEL_PATH,
        "timestamp": int(time.time())
    })


@app.route('/uploads/<path:filename>')
def serve_uploads(filename):
    """Serve uploaded images."""
    return send_from_directory(UPLOAD_FOLDER, filename)


# ==================== MAIN ====================
if __name__ == "__main__":
    print("🚀 Starting Flask YOLO Detection Server...")
    print(f"📁 Upload folder: {UPLOAD_FOLDER}")
    print(f"🗃️ Database: {DB_NAME}")
    print(f"🌐 Server will be accessible on: http://0.0.0.0:9090")
    
    app.run(host="0.0.0.0", port=9090, debug=False)