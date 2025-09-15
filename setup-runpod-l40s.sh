#!/bin/bash

# RunPod L40S GPU Setup Script
# Prepares environment for GPU-accelerated FFmpeg HLS transcoding

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== RunPod L40S GPU Setup ===${NC}"
echo ""

# Function to print status
print_status() {
    echo -e "${2}[$(date +'%H:%M:%S')] ${1}${NC}"
}

# Update system
print_status "Updating system packages..." "$YELLOW"
apt-get update
apt-get upgrade -y

# Install essential tools
print_status "Installing essential tools..." "$YELLOW"
apt-get install -y \
    build-essential \
    git \
    curl \
    wget \
    htop \
    nvtop \
    iotop \
    net-tools \
    software-properties-common \
    python3-pip \
    screen \
    tmux

# Check NVIDIA driver
print_status "Checking NVIDIA driver..." "$BLUE"
if nvidia-smi &>/dev/null; then
    print_status "NVIDIA driver is installed" "$GREEN"
    nvidia-smi
else
    print_status "Installing NVIDIA driver..." "$YELLOW"
    apt-get install -y nvidia-driver-535
    print_status "Please reboot and run this script again" "$RED"
    exit 1
fi

# Install CUDA toolkit (if not present)
print_status "Checking CUDA..." "$BLUE"
if ! command -v nvcc &>/dev/null; then
    print_status "Installing CUDA toolkit..." "$YELLOW"
    wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
    dpkg -i cuda-keyring_1.1-1_all.deb
    apt-get update
    apt-get install -y cuda-toolkit-12-3
    echo 'export PATH=/usr/local/cuda/bin:$PATH' >> ~/.bashrc
    echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
    source ~/.bashrc
fi

# Install FFmpeg with NVENC support
print_status "Installing FFmpeg with NVENC support..." "$YELLOW"

# Remove old FFmpeg
apt-get remove -y ffmpeg

# Add FFmpeg PPA for latest version with NVENC
add-apt-repository ppa:savoury1/ffmpeg5 -y
add-apt-repository ppa:savoury1/ffmpeg4 -y
apt-get update

# Install FFmpeg with all codecs
apt-get install -y ffmpeg

# Verify NVENC support
print_status "Verifying FFmpeg NVENC support..." "$BLUE"
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_nvenc; then
    print_status "FFmpeg NVENC support confirmed" "$GREEN"
    ffmpeg -hide_banner -encoders 2>/dev/null | grep nvenc
else
    print_status "WARNING: FFmpeg NVENC not detected, building from source..." "$YELLOW"

    # Build FFmpeg from source with NVENC
    apt-get install -y \
        nasm \
        yasm \
        libx264-dev \
        libx265-dev \
        libnuma-dev \
        libvpx-dev \
        libfdk-aac-dev \
        libmp3lame-dev \
        libopus-dev

    cd /tmp
    git clone https://github.com/FFmpeg/FFmpeg.git ffmpeg
    cd ffmpeg
    ./configure \
        --enable-nonfree \
        --enable-cuda-nvcc \
        --enable-nvenc \
        --enable-cuda \
        --enable-cuvid \
        --enable-libnpp \
        --extra-cflags=-I/usr/local/cuda/include \
        --extra-ldflags=-L/usr/local/cuda/lib64 \
        --enable-gpl \
        --enable-libx264 \
        --enable-libx265 \
        --enable-libfdk-aac \
        --enable-libmp3lame \
        --enable-libopus \
        --enable-libvpx
    make -j$(nproc)
    make install
    ldconfig
fi

# Install monitoring tools
print_status "Installing GPU monitoring tools..." "$YELLOW"
pip3 install gpustat nvidia-ml-py3

# Create test directories
print_status "Creating test directories..." "$BLUE"
mkdir -p /workspace/ffmpeg-gpu-test
cd /workspace/ffmpeg-gpu-test

# Download test scripts
print_status "Downloading test scripts..." "$YELLOW"
cat > download-scripts.sh << 'SCRIPT'
#!/bin/bash
# Download test scripts from your repository or create them
echo "Place your test scripts here"
SCRIPT
chmod +x download-scripts.sh

# Setup performance tuning
print_status "Configuring performance settings..." "$YELLOW"

# Increase file descriptor limits
cat >> /etc/security/limits.conf << EOF
* soft nofile 1000000
* hard nofile 1000000
* soft nproc 1000000
* hard nproc 1000000
EOF

# Optimize network settings for RTSP streaming
cat >> /etc/sysctl.conf << EOF
# Network optimizations for streaming
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
EOF
sysctl -p

# Set GPU to persistence mode
nvidia-smi -pm 1

# Set GPU to maximum performance
nvidia-smi -ac 2619,1980 2>/dev/null || true

# Create monitoring script
print_status "Creating monitoring script..." "$BLUE"
cat > monitor-gpu.sh << 'MONITOR'
#!/bin/bash
# GPU Monitoring Script

while true; do
    clear
    echo "=== GPU Status ==="
    nvidia-smi --query-gpu=timestamp,name,temperature.gpu,utilization.gpu,utilization.memory,memory.used,memory.total,encoder.stats.sessionCount,encoder.stats.averageFps,encoder.stats.averageLatency --format=csv
    echo ""
    echo "=== Process List ==="
    nvidia-smi pmon -c 1
    sleep 2
done
MONITOR
chmod +x monitor-gpu.sh

# Create quick test script
print_status "Creating quick test script..." "$BLUE"
cat > quick-test.sh << 'TEST'
#!/bin/bash
# Quick GPU FFmpeg Test

echo "Testing GPU encoding..."

# Test NVENC
ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=30 \
    -t 10 \
    -c:v h264_nvenc \
    -preset p4 \
    -f null - \
    2>&1 | grep -E "fps|speed"

echo ""
echo "GPU Info:"
nvidia-smi --query-gpu=name,memory.total,encoder.stats.sessionCountMax --format=csv

echo ""
echo "NVENC Encoders available:"
ffmpeg -hide_banner -encoders 2>/dev/null | grep nvenc
TEST
chmod +x quick-test.sh

# Install additional utilities
print_status "Installing additional utilities..." "$YELLOW"
apt-get install -y \
    iftop \
    nethogs \
    dstat \
    sysstat \
    mediainfo \
    v4l-utils

# Create systemd service for monitoring (optional)
print_status "Creating monitoring service..." "$BLUE"
cat > /etc/systemd/system/gpu-monitor.service << 'SERVICE'
[Unit]
Description=GPU Performance Monitor
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/workspace/ffmpeg-gpu-test
ExecStart=/usr/bin/python3 -c "
import time
import subprocess
import csv
from datetime import datetime

with open('/var/log/gpu-metrics.csv', 'a', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(['timestamp', 'gpu_util', 'gpu_mem', 'nvenc_sessions', 'temperature'])

    while True:
        result = subprocess.run(['nvidia-smi', '--query-gpu=utilization.gpu,memory.used,encoder.stats.sessionCount,temperature.gpu', '--format=csv,noheader,nounits'], capture_output=True, text=True)
        if result.returncode == 0:
            metrics = result.stdout.strip().split(', ')
            writer.writerow([datetime.now().isoformat()] + metrics)
            f.flush()
        time.sleep(5)
"
Restart=always

[Install]
WantedBy=multi-user.target
SERVICE

# Summary
print_status "\n=== Setup Complete ===" "$GREEN"
echo ""
echo -e "${BLUE}System Information:${NC}"
echo "  OS: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "  Kernel: $(uname -r)"
echo "  CPU: $(lscpu | grep 'Model name' | cut -d':' -f2 | xargs)"
echo "  RAM: $(free -h | awk 'NR==2{print $2}')"
echo ""

echo -e "${GREEN}GPU Information:${NC}"
nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap --format=csv

echo ""
echo -e "${YELLOW}NVENC Capabilities:${NC}"
nvidia-smi --query-gpu=encoder.stats.sessionCount,encoder.stats.sessionCountMax --format=csv

echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo "1. Copy your test scripts to /workspace/ffmpeg-gpu-test/"
echo "2. Copy your camera URLs to cameras_test.txt"
echo "3. Run: ./generate-test-sources.sh"
echo "4. Run: ./ultimate-gpu-test.sh"
echo "5. Monitor GPU: ./monitor-gpu.sh"
echo ""
echo -e "${GREEN}Quick test: ./quick-test.sh${NC}"