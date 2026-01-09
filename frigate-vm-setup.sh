#!/usr/bin/env bash

# Frigate NVR - Ubuntu VM Setup Script
# Run this inside the Ubuntu VM after OS installation

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

function msg_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

function msg_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

function msg_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

function msg_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Check if running as regular user
if [[ $EUID -eq 0 ]]; then
   msg_error "Don't run this script as root - it will use sudo when needed"
   exit 1
fi

echo "============================================"
echo "Frigate NVR - Ubuntu VM Setup"
echo "============================================"
echo ""

msg_info "This script will:"
echo "  1. Update system and install NVIDIA drivers"
echo "  2. Install Docker and NVIDIA Container Toolkit"
echo "  3. Setup storage and mount points"
echo "  4. Deploy Frigate with GPU acceleration"
echo ""

read -p "Continue? (y/n): " CONFIRM
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    msg_info "Setup cancelled"
    exit 0
fi

# Configuration
msg_info "Configuration:"
read -p "Enter Frigate RTSP password [changeme123]: " RTSP_PASS
RTSP_PASS=${RTSP_PASS:-changeme123}

read -p "Enter storage disk device [/dev/sdb]: " STORAGE_DISK
STORAGE_DISK=${STORAGE_DISK:-/dev/sdb}

read -p "Enter mount point [/mnt/frigate-storage]: " MOUNT_POINT
MOUNT_POINT=${MOUNT_POINT:-/mnt/frigate-storage}

echo ""
msg_step "Step 1/8: Updating system..."
sudo apt update
sudo apt upgrade -y
msg_info "System updated"

echo ""
msg_step "Step 2/8: Checking for NVIDIA GPU..."
if ! lspci | grep -i nvidia > /dev/null; then
    msg_error "No NVIDIA GPU detected! Check GPU passthrough configuration."
    exit 1
fi

GPU_INFO=$(lspci | grep -i nvidia | grep -i vga)
msg_info "GPU detected: $GPU_INFO"

echo ""
msg_step "Step 3/8: Installing NVIDIA drivers..."
if command -v nvidia-smi &> /dev/null; then
    msg_info "NVIDIA drivers already installed"
    nvidia-smi
else
    sudo apt install -y nvidia-driver-550 nvidia-utils-550
    msg_warn "NVIDIA drivers installed - reboot required"
    echo ""
    read -p "Reboot now and re-run this script after? (y/n): " REBOOT_NOW
    if [[ $REBOOT_NOW =~ ^[Yy]$ ]]; then
        sudo reboot
    else
        msg_info "Please reboot manually and re-run this script"
        exit 0
    fi
fi

echo ""
msg_step "Step 4/8: Installing Docker..."
if command -v docker &> /dev/null; then
    msg_info "Docker already installed"
else
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    rm get-docker.sh
    sudo usermod -aG docker $USER
    msg_info "Docker installed"
fi

echo ""
msg_step "Step 5/8: Installing NVIDIA Container Toolkit..."
if dpkg -l | grep -q nvidia-container-toolkit; then
    msg_info "NVIDIA Container Toolkit already installed"
else
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    
    sudo apt update
    sudo apt install -y nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
    msg_info "NVIDIA Container Toolkit installed"
fi

echo ""
msg_step "Step 6/8: Testing GPU in Docker..."
if docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi; then
    msg_info "GPU working in Docker!"
else
    msg_error "GPU test failed!"
    exit 1
fi

echo ""
msg_step "Step 7/8: Setting up storage..."

if [ -b "$STORAGE_DISK" ]; then
    msg_info "Storage disk found: $STORAGE_DISK"
    
    # Check if disk is already formatted
    if sudo blkid "$STORAGE_DISK" | grep -q "TYPE="; then
        msg_warn "Disk appears to be formatted already"
        DISK_UUID=$(sudo blkid -s UUID -o value "$STORAGE_DISK")
    else
        msg_warn "Formatting $STORAGE_DISK - THIS WILL ERASE ALL DATA!"
        read -p "Continue? (y/n): " FORMAT_CONFIRM
        if [[ ! $FORMAT_CONFIRM =~ ^[Yy]$ ]]; then
            msg_error "Setup cancelled"
            exit 1
        fi
        
        sudo mkfs.ext4 -F "$STORAGE_DISK"
        DISK_UUID=$(sudo blkid -s UUID -o value "$STORAGE_DISK")
        msg_info "Disk formatted with UUID: $DISK_UUID"
    fi
    
    # Create mount point
    sudo mkdir -p "$MOUNT_POINT"
    
    # Add to fstab if not already there
    if ! grep -q "$DISK_UUID" /etc/fstab; then
        echo "UUID=$DISK_UUID $MOUNT_POINT ext4 defaults,noatime 0 2" | sudo tee -a /etc/fstab
        msg_info "Added to /etc/fstab"
    fi
    
    # Mount
    sudo mount -a
    
    # Set permissions
    sudo chown -R $USER:$USER "$MOUNT_POINT"
    
    msg_info "Storage mounted at $MOUNT_POINT"
else
    msg_error "Storage disk $STORAGE_DISK not found!"
    msg_warn "Continuing without storage setup - you'll need to configure this manually"
    MOUNT_POINT="/tmp/frigate-storage"
    mkdir -p "$MOUNT_POINT"
fi

echo ""
msg_step "Step 8/8: Deploying Frigate..."

# Create Frigate directory
FRIGATE_DIR="/opt/frigate"
sudo mkdir -p "$FRIGATE_DIR/config"
sudo chown -R $USER:$USER "$FRIGATE_DIR"

# Create docker-compose.yml
cat > "$FRIGATE_DIR/docker-compose.yml" << EOF
version: "3.9"
services:
  frigate:
    container_name: frigate
    privileged: true
    restart: unless-stopped
    image: ghcr.io/blakeblackshear/frigate:stable
    shm_size: "512mb"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - $FRIGATE_DIR/config:/config
      - $MOUNT_POINT:/media/frigate
      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: 2000000000
    ports:
      - "5000:5000"
      - "8554:8554"
      - "8555:8555/tcp"
      - "8555:8555/udp"
    environment:
      FRIGATE_RTSP_PASSWORD: "$RTSP_PASS"
      NVIDIA_VISIBLE_DEVICES: "all"
      NVIDIA_DRIVER_CAPABILITIES: "all"
EOF

msg_info "Docker Compose file created"

# Create config.yml with example camera
cat > "$FRIGATE_DIR/config/config.yml" << 'EOF'
mqtt:
  enabled: false

detectors:
  tensorrt:
    type: tensorrt
    device: 0

model:
  path: /config/model_cache/tensorrt/yolov7-320.trt
  input_tensor: nchw
  input_pixel_format: rgb
  width: 320
  height: 320

# Example camera configuration - replace with your UniFi Protect cameras
cameras:
  example_camera:
    enabled: false  # Set to true after adding your camera details
    ffmpeg:
      inputs:
        # High quality stream for recording
        - path: rtsps://username:password@nvr-ip:7441/CAMERA_ID_HIGH
          roles:
            - record
        # Lower quality stream for detection
        - path: rtsps://username:password@nvr-ip:7441/CAMERA_ID_LOW
          roles:
            - detect
    detect:
      width: 640
      height: 480
      fps: 5
    record:
      enabled: true
      retain:
        days: 7
        mode: motion
      events:
        retain:
          default: 14
          mode: active_objects
    snapshots:
      enabled: true
      retain:
        default: 14
    objects:
      track:
        - person
        - car
        - dog
        - cat
EOF

msg_info "Config file created"

# Start Frigate
cd "$FRIGATE_DIR"
docker compose up -d

msg_info "Frigate starting..."
sleep 5

# Show logs
echo ""
msg_info "Checking Frigate logs..."
docker logs frigate --tail 50

echo ""
echo "============================================"
echo "INSTALLATION COMPLETE!"
echo "============================================"
echo ""
echo "Frigate is now running!"
echo ""
echo "Access URLs:"
echo "  Web UI: http://$(hostname -I | awk '{print $1}'):5000"
echo "  go2rtc: http://$(hostname -I | awk '{print $1}'):1984"
echo ""
echo "Next Steps:"
echo "1. Edit camera configuration:"
echo "   nano $FRIGATE_DIR/config/config.yml"
echo ""
echo "2. Add your UniFi Protect camera RTSP URLs"
echo ""
echo "3. Restart Frigate:"
echo "   docker restart frigate"
echo ""
echo "Useful Commands:"
echo "  View logs: docker logs -f frigate"
echo "  Restart: docker restart frigate"
echo "  Stop: docker stop frigate"
echo "  Monitor GPU: watch -n 1 nvidia-smi"
echo "  Check storage: df -h $MOUNT_POINT"
echo ""
msg_info "Setup complete! Visit the Web UI to configure your cameras."
