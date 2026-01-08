# 🥚 YOLO Egg Fertility Detection API

A Flask-based API server for detecting egg fertility using YOLOv8 object detection.

## 🐳 Docker Deployment (Recommended)

### Prerequisites
- Docker & Docker Compose installed on your server
- At least 4GB RAM available

### Quick Start

1. **Clone/Copy the project to your server:**
   ```bash
   # Copy the 'ta' folder to your server
   scp -r ta/ user@your-server:/path/to/deployment/
   ```

2. **Navigate to the project directory:**
   ```bash
   cd /path/to/deployment/ta
   ```

3. **Set up ngrok (for public URL):**
   ```bash
   # Copy and edit environment file
   cp .env.example .env
   nano .env  # Add your NGROK_AUTHTOKEN
   ```
   
   Get your free token at: https://dashboard.ngrok.com/get-started/your-authtoken

4. **Build and run with Docker Compose:**
   ```bash
   docker compose up -d --build
   ```

5. **Get your public ngrok URL:**
   ```bash
   docker compose logs ngrok
   ```
   Look for the line: `url=https://xxxx-xx-xx-xx-xx.ngrok-free.app`

6. **Verify the API:**
   ```bash
   curl http://localhost:9090/health
   # Or use ngrok URL:
   curl https://your-ngrok-url.ngrok-free.app/health
   ```

### Docker Commands

| Command | Description |
|---------|-------------|
| `docker-compose up -d --build` | Build and start the container |
| `docker-compose down` | Stop the container |
| `docker-compose logs -f` | View real-time logs |
| `docker-compose restart` | Restart the container |
| `docker-compose ps` | Check container status |

### Updating the Application

```bash
# Pull latest changes (if using git)
git pull

# Rebuild and restart
docker-compose up -d --build
```

---

## 💻 Local Development (Without Docker)

### Prerequisites
- Python 3.9+
- pip

### Installation

1. **Create virtual environment:**
   ```bash
   cd ta
   python -m venv venv
   source venv/bin/activate  # On Windows: venv\Scripts\activate
   ```

2. **Install dependencies:**
   ```bash
   pip install -r requirements.txt
   ```

3. **Run the server:**
   ```bash
   python app.py
   ```

---

## 📡 API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/upload` | Upload base64-encoded image (from ESP32/Raspberry Pi) |
| `POST` | `/upload-file` | Upload image file (from Flutter app) |
| `POST` | `/trigger-camera` | Trigger camera capture notification |
| `GET` | `/latest` | Get latest detection image with bounding boxes |
| `GET` | `/result` | Get latest detection result as JSON |
| `GET` | `/results?limit=20&offset=0` | List all detection results (paginated) |
| `GET` | `/latest-detection` | Get detailed latest detection info |
| `GET` | `/health` | Health check endpoint |
| `GET` | `/uploads/<filename>` | Serve uploaded images |

### Example API Calls

**Upload a file:**
```bash
curl -X POST -F "file=@image.jpg" http://localhost:9090/upload-file
```

**Get latest result:**
```bash
curl http://localhost:9090/result
```

**List all results:**
```bash
curl http://localhost:9090/results?limit=10
```

---

## 📁 Project Structure

```
ta/
├── app.py              # Main Flask application
├── requirements.txt    # Python dependencies
├── Dockerfile          # Docker build instructions
├── docker-compose.yml  # Docker Compose configuration
├── .dockerignore       # Files to exclude from Docker build
├── Model/              # YOLO model weights
│   └── best (12).pt    # Trained model
├── uploads/            # Uploaded images (created automatically)
└── results.db          # SQLite database (created automatically)
```

---

## ⚙️ Configuration

Environment variables (optional):

| Variable | Default | Description |
|----------|---------|-------------|
| `UPLOAD_FOLDER` | `./uploads` | Directory for uploaded images |
| `MODEL_PATH` | `./Model/best (12).pt` | Path to YOLO model |
| `DB_NAME` | `./results.db` | SQLite database path |

---

## 🔧 Troubleshooting

### Container won't start
```bash
# Check logs for errors
docker-compose logs yolo-api

# Check if port 9090 is available
lsof -i :9090
```

### Out of memory
The YOLO model requires significant memory. Ensure your server has at least 4GB RAM. You can adjust memory limits in `docker-compose.yml`.

### Model not loading
Ensure the model file `Model/best (12).pt` exists and has the correct permissions.

---

## 📝 License

This project is part of a final thesis (Tugas Akhir) project.
