# app.py
import os
import time
import base64
import sqlite3
import uuid
import json
import io
from flask import Flask, request, jsonify, send_file
from ultralytics import YOLO
import cv2
import numpy as np

# ==================== CONFIGURATION ====================
app = Flask(__name__)

# Folders & Paths
UPLOAD_FOLDER = "uploads"
MODEL_PATH = os.path.join("Model", "best (7).pt")
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
    
    # Create table if not exists
    conn.execute("""
        CREATE TABLE IF NOT EXISTS results(
            id TEXT PRIMARY KEY,
            device_id TEXT,
            ts INTEGER,
            file TEXT,
            pred TEXT
        );
    """)
    
    # Check if 'pred' column exists, if not migrate
    try:
        cursor = conn.execute("SELECT pred FROM results LIMIT 1")
    except sqlite3.OperationalError:
        # Column doesn't exist, need to migrate
        print("🔄 Migrating database: adding 'pred' column...")
        try:
            # Try to add column to existing table
            conn.execute("ALTER TABLE results ADD COLUMN pred TEXT")
            conn.commit()
            print("✅ Database migration completed")
        except sqlite3.OperationalError as e:
            # If table structure is too different, backup and recreate
            print(f"⚠️  Migration failed: {e}")
            print("🔄 Creating backup and recreating table...")
            
            # Backup existing data
            conn.execute("ALTER TABLE results RENAME TO results_backup")
            
            # Create new table with correct structure
            conn.execute("""
                CREATE TABLE results(
                    id TEXT PRIMARY KEY,
                    device_id TEXT,
                    ts INTEGER,
                    file TEXT,
                    pred TEXT
                );
            """)
            
            # Try to migrate data if possible
            try:
                conn.execute("""
                    INSERT INTO results(id, device_id, ts, file, pred)
                    SELECT id, device_id, ts, file, '[]' FROM results_backup
                """)
                print("✅ Data migrated successfully")
            except:
                print("⚠️  Could not migrate old data, starting fresh")
            
            conn.commit()
    
    return conn


def save_detection_to_db(record_id, device_id, timestamp, filename, predictions):
    """Save detection result to database."""
    conn = get_db_connection()
    conn.execute(
        "INSERT INTO results(id, device_id, ts, file, pred) VALUES(?, ?, ?, ?, ?)",
        (record_id, device_id, timestamp, filename, json.dumps(predictions))
    )
    conn.commit()
    conn.close()


def get_latest_result():
    """Get latest detection result from database."""
    conn = get_db_connection()
    cur = conn.execute(
        "SELECT id, device_id, ts, file, pred FROM results ORDER BY ts DESC LIMIT 1"
    )
    row = cur.fetchone()
    conn.close()
    return row


def get_results_list(limit=20, offset=0):
    """Get list of detection results with pagination."""
    conn = get_db_connection()
    cur = conn.execute(
        "SELECT id, device_id, ts, file, pred FROM results ORDER BY ts DESC LIMIT ? OFFSET ?",
        (limit, offset)
    )
    rows = cur.fetchall()
    conn.close()
    return rows


# ==================== YOLO INFERENCE ====================
def run_yolo_detection(image_path):
    """
    Run YOLO inference and draw bounding boxes on image.
    
    Returns:
        tuple: (predictions_list, image_with_boxes_base64)
    """
    # TAMBAHKAN CONF THRESHOLD DI SINI (0.5 = 50%)
    results = yolo_model.predict(source=image_path, save=False, verbose=True, conf=0.5)
    print(f"[YOLO] Running inference on: {image_path}")
    
    # Extract predictions
    predictions = []
    if results and results[0].boxes and len(results[0].boxes) > 0:
        for box in results[0].boxes:
            label = results[0].names[int(box.cls)]
            score = float(box.conf)
            xyxy = box.xyxy.cpu().numpy()[0].tolist()
            
            # FILTER TAMBAHAN: Hanya ambil confidence >= 0.6 (60%)
            if score >= 0.6:  # <-- TAMBAHKAN INI
                predictions.append({
                    "label": label,
                    "score": score,
                    "box": xyxy
                })
                print(f"[YOLO] Detected: {label} (confidence: {score:.2f})")
    
    # If no detection found
    if not predictions:
        print("[YOLO] No objects detected")
        predictions = [{"label": "unknown", "score": 0.0, "box": []}]
    
    # Draw boxes on image
    image_with_boxes = draw_boxes_on_image(image_path, predictions)
    
    return predictions, image_with_boxes


def draw_boxes_on_image(image_path, predictions):
    """
    Draw bounding boxes on image and return base64 encoded result.
    
    Args:
        image_path: Path to the image file
        predictions: List of prediction dictionaries
        
    Returns:
        str: Base64 encoded image with boxes
    """
    # Load image
    img = cv2.imread(image_path)
    if img is None:
        raise ValueError(f"Failed to load image: {image_path}")
    
    # Draw each bounding box
    for pred in predictions:
        if pred["box"]:
            x1, y1, x2, y2 = map(int, pred["box"])
            label_text = f"{pred['label']} {pred['score']:.2f}"
            
            # Draw rectangle (green) - thickness increased to 4
            cv2.rectangle(img, (x1, y1), (x2, y2), (0, 255, 0), 8)
            
            # Calculate label background size
            (text_width, text_height), _ = cv2.getTextSize(
                label_text, cv2.FONT_HERSHEY_SIMPLEX, 2.0, 4
            )
            
            # Draw label background (black)
            cv2.rectangle(
                img,
                (x1, y1 - text_height - 12),
                (x1 + text_width + 10, y1),
                (0, 0, 0),
                -1
            )
            
            # Draw label text (white) - thickness increased to 3
            cv2.putText(
                img,
                label_text,
                (x1 + 5, y1 - 6),
                cv2.FONT_HERSHEY_SIMPLEX,
                2.0,
                (255, 255, 255),
                4
            )
    
    # Encode to base64
    _, buffer = cv2.imencode(".jpg", img)
    img_base64 = base64.b64encode(buffer).decode('utf-8')
    
    return f"data:image/jpeg;base64,{img_base64}"


# ==================== HELPER FUNCTIONS ====================
def generate_record_id():
    """Generate unique record ID."""
    return f"rec_{uuid.uuid4().hex[:12]}"


def save_base64_image(image_b64, device_id, timestamp):
    """
    Save base64 encoded image to file.
    
    Returns:
        str: Path to saved file
    """
    raw = base64.b64decode(image_b64)
    filename = f"{device_id}_{timestamp}.jpg"
    filepath = os.path.join(UPLOAD_FOLDER, filename)
    
    with open(filepath, "wb") as f:
        f.write(raw)
    
    return filename, filepath


def get_image_url_for_host(host):
    """Generate image URL based on request host."""
    return f"http://{host}/latest"


# ==================== API ROUTES ====================
@app.route("/upload", methods=["POST"])
def upload_base64():
    """
    Upload image via JSON (ESP32-CAM base64).
    
    Expected JSON format:
    {
        "device_id": "esp32_01",
        "timestamp": 1234567890,
        "image": "base64_encoded_image"
    }
    """
    try:
        data = request.get_json(force=True)
        device_id = data.get("device_id", "unknown")
        timestamp = int(data.get("timestamp", time.time()))
        image_b64 = data.get("image")
        
        if not image_b64:
            return jsonify({"error": "No image data provided"}), 400
        
        # Save image
        filename, filepath = save_base64_image(image_b64, device_id, timestamp)
        
        # Run YOLO detection
        predictions, image_with_boxes = run_yolo_detection(filepath)
        
        # Save to database
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
    """
    Upload image via multipart file (Flutter/Web).
    
    Expected form-data:
    - file: image file
    """
    try:
        if "file" not in request.files:
            return jsonify({"error": "No file uploaded"}), 400
        
        file = request.files["file"]
        if file.filename == "":
            return jsonify({"error": "Empty filename"}), 400
        
        # Save file
        timestamp = int(time.time())
        filename = f"manual_{timestamp}_{file.filename}"
        filepath = os.path.join(UPLOAD_FOLDER, filename)
        file.save(filepath)
        
        # Run YOLO detection
        predictions, image_with_boxes = run_yolo_detection(filepath)
        
        # Save to database
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
    """
    Get latest detected image with bounding boxes.
    
    Returns:
        image/jpeg: Latest image with detection boxes
    """
    row = get_latest_result()
    if not row:
        return jsonify({"error": "No images found"}), 404
    
    filepath = os.path.join(UPLOAD_FOLDER, row[3])
    
    # Re-run detection to draw boxes (or use cached if optimized)
    _, image_with_boxes = run_yolo_detection(filepath)
    
    # Decode base64 and send as image
    image_data = base64.b64decode(image_with_boxes.split(',')[1])
    return send_file(io.BytesIO(image_data), mimetype="image/jpeg")


@app.route("/result", methods=["GET"])
def get_latest_result_json():
    """
    Get latest detection result as JSON.
    
    Returns:
        JSON with detection info and image URL
    """
    row = get_latest_result()
    if not row:
        return jsonify({"error": "No results found"}), 404
    
    predictions = json.loads(row[4])
    
    response = {
        "id": row[0],
        "device_id": row[1],
        "timestamp": row[2],
        "file": row[3],
        "pred": predictions,
        "image_url": get_image_url_for_host(request.host)
    }
    
    return jsonify(response)


@app.route("/results", methods=["GET"])
def list_detection_results():
    """
    Get list of detection results with pagination.
    
    Query params:
    - limit: Number of results (default: 20)
    - offset: Offset for pagination (default: 0)
    
    Returns:
        JSON list of detection results
    """
    limit = int(request.args.get("limit", 20))
    offset = int(request.args.get("offset", 0))
    
    rows = get_results_list(limit, offset)
    
    items = []
    for row in rows:
        items.append({
            "id": row[0],
            "device_id": row[1],
            "timestamp": row[2],
            "file": row[3],
            "pred": json.loads(row[4]),
            "image_url": get_image_url_for_host(request.host)
        })
    
    return jsonify({"items": items, "count": len(items)})


@app.route("/health", methods=["GET"])
def health_check():
    """Health check endpoint."""
    return jsonify({
        "status": "ok",
        "model": MODEL_PATH,
        "timestamp": int(time.time())
    })


# ==================== MAIN ====================
if __name__ == "__main__":
    # Run server accessible from LAN (ESP32 & Mobile)
    print("🚀 Starting Flask YOLO Detection Server...")
    print(f"📁 Upload folder: {UPLOAD_FOLDER}")
    print(f"🗃️ Database: {DB_NAME}")
    print(f"🌐 Server will be accessible on: http://0.0.0.0:9090")
    
    app.run(host="0.0.0.0", port=9090, debug=False)