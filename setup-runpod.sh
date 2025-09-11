#!/bin/bash

# RunPod GPU Setup Script
# Prepares the environment for GPU-accelerated FFmpeg testing

set -e

echo "RunPod GPU Test Environment Setup"
echo "================================="

# Update system
echo "Updating system packages..."
apt-get update

# Install required tools
echo "Installing required tools..."
apt-get install -y \
    wget \
    curl \
    git \
    bc \
    htop \
    nvtop \
    build-essential \
    pkg-config

# Check if FFmpeg with NVENC support is installed
echo "Checking FFmpeg installation..."
if ! command -v ffmpeg &> /dev/null; then
    echo "Installing FFmpeg with NVENC support..."
    apt-get install -y ffmpeg
fi

# Verify NVENC support
echo "Verifying NVENC support in FFmpeg..."
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_nvenc"; then
    echo "✓ FFmpeg has NVENC support"
else
    echo "⚠ FFmpeg doesn't have NVENC support. Building from source..."
    
    # Build FFmpeg with NVENC support
    apt-get install -y \
        yasm \
        libx264-dev \
        libx265-dev \
        libnuma-dev \
        libvpx-dev \
        libfdk-aac-dev \
        libmp3lame-dev \
        libopus-dev
    
    # Clone and build FFmpeg
    cd /tmp
    git clone https://github.com/FFmpeg/FFmpeg.git ffmpeg
    cd ffmpeg
    
    ./configure \
        --enable-nonfree \
        --enable-cuda-nvcc \
        --enable-libnpp \
        --extra-cflags=-I/usr/local/cuda/include \
        --extra-ldflags=-L/usr/local/cuda/lib64 \
        --enable-gpl \
        --enable-libx264 \
        --enable-libx265 \
        --enable-libvpx \
        --enable-libfdk-aac \
        --enable-libmp3lame \
        --enable-libopus \
        --enable-nvenc
    
    make -j$(nproc)
    make install
    ldconfig
fi

# Display GPU information
echo ""
echo "GPU Information:"
echo "---------------"
nvidia-smi

# Check NVENC session limits
echo ""
echo "Checking NVENC session limits..."
nvidia-smi --query-gpu=encoder.stats.sessionCount,encoder.stats.sessionCountMax --format=csv

# Download test videos if needed
echo ""
echo "Downloading test videos..."
mkdir -p /workspace/test_videos
cd /workspace/test_videos

# Download sample videos
if [ ! -f "BigBuckBunny.mp4" ]; then
    wget -q https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4
    echo "✓ Downloaded BigBuckBunny.mp4"
fi

if [ ! -f "ElephantsDream.mp4" ]; then
    wget -q https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4
    echo "✓ Downloaded ElephantsDream.mp4"
fi

# Create test script directory
mkdir -p /workspace/gpu-test
cd /workspace/gpu-test

echo ""
echo "Setup complete!"
echo ""
echo "Next steps:"
echo "1. Copy the gpu-test.sh script to /workspace/gpu-test/"
echo "2. Run: chmod +x gpu-test.sh"
echo "3. Run: ./gpu-test.sh"
echo ""
echo "Monitor GPU usage in another terminal with:"
echo "  watch -n 1 nvidia-smi"
echo "  or"
echo "  nvtop"