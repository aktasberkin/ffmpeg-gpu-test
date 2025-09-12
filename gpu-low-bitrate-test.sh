#!/bin/bash

# GPU-accelerated low bitrate streaming script
# Optimized for minimal file size while maintaining quality

# Configuration
CAMERA_URL="${1:-rtsp://ttec:9LPYqPyD%21@192.168.1.101:554/}"
OUTPUT_DIR="${2:-./output}"
TEST_DURATION="${3:-60}"  # Default 60 seconds
SEGMENT_TIME="${4:-6}"    # Default 6 second segments

# GPU Settings
GPU_INDEX="${GPU_INDEX:-0}"
GPU_ENCODER="h264_nvenc"
GPU_PRESET="${GPU_PRESET:-medium}"  # p1-p7 for NVENC (p4 = medium equivalent)
GPU_CQ="${GPU_CQ:-36}"  # Constant Quality (higher = lower quality/smaller files)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Create output directory
mkdir -p "$OUTPUT_DIR"

echo -e "${BLUE}GPU Low-Bitrate Streaming Test${NC}"
echo "================================"
echo "Camera URL: $CAMERA_URL"
echo "Output Dir: $OUTPUT_DIR"
echo "Duration: ${TEST_DURATION}s"
echo "Segment Time: ${SEGMENT_TIME}s"
echo ""

# Check GPU availability
if ! nvidia-smi &> /dev/null; then
    echo -e "${RED}Error: NVIDIA GPU not available${NC}"
    exit 1
fi

# Get GPU info
GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader -i $GPU_INDEX)
echo -e "${GREEN}GPU Detected: $GPU_INFO${NC}"

# Check NVENC support
if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_nvenc"; then
    echo -e "${RED}Error: NVENC not available in FFmpeg${NC}"
    exit 1
fi

echo -e "${GREEN}✓ NVENC support confirmed${NC}"
echo ""

# Generate timestamp for unique filenames
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
PLAYLIST_FILE="${OUTPUT_DIR}/playlist_${TIMESTAMP}.m3u8"
SEGMENT_PREFIX="${OUTPUT_DIR}/segment_${TIMESTAMP}"

# Build FFmpeg command with GPU acceleration and low bitrate settings
# Using similar quality settings as CPU version but with GPU acceleration
FFMPEG_CMD="ffmpeg -hide_banner -loglevel info \
    -rtsp_transport tcp \
    -analyzeduration 5000000 \
    -probesize 10000000 \
    -hwaccel cuda \
    -hwaccel_device $GPU_INDEX \
    -hwaccel_output_format cuda \
    -i \"$CAMERA_URL\" \
    -t $TEST_DURATION \
    -vf \"scale_cuda=1280:720\" \
    -c:v $GPU_ENCODER \
    -preset p4 \
    -rc constqp \
    -cq $GPU_CQ \
    -b:v 500k \
    -maxrate 750k \
    -bufsize 1M \
    -g 120 \
    -gpu $GPU_INDEX \
    -an \
    -f hls \
    -hls_time $SEGMENT_TIME \
    -hls_flags append_list \
    -hls_list_size 0 \
    -hls_segment_filename \"${SEGMENT_PREFIX}_%03d.ts\" \
    \"$PLAYLIST_FILE\""

echo -e "${CYAN}Starting GPU-accelerated low-bitrate streaming...${NC}"
echo -e "${YELLOW}Command: $FFMPEG_CMD${NC}"
echo ""

# Monitor GPU usage in background
(
    while true; do
        GPU_STATS=$(nvidia-smi --query-gpu=utilization.gpu,utilization.encoder,memory.used,temperature.gpu --format=csv,noheader -i $GPU_INDEX 2>/dev/null)
        if [[ -n "$GPU_STATS" ]]; then
            echo -e "${BLUE}[$(date '+%H:%M:%S')] GPU Stats: $GPU_STATS${NC}"
        fi
        sleep 5
    done
) &
MONITOR_PID=$!

# Run FFmpeg
START_TIME=$(date +%s)
eval "$FFMPEG_CMD"
EXIT_CODE=$?
END_TIME=$(date +%s)

# Stop monitoring
kill $MONITOR_PID 2>/dev/null

DURATION=$((END_TIME - START_TIME))

echo ""
echo -e "${BLUE}Test Results:${NC}"
echo "=============="
echo "Duration: ${DURATION}s"
echo "Exit Code: $EXIT_CODE"

if [[ $EXIT_CODE -eq 0 ]]; then
    echo -e "${GREEN}✓ Streaming successful${NC}"
    
    # Calculate file sizes
    TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)
    SEGMENT_COUNT=$(ls -1 ${SEGMENT_PREFIX}_*.ts 2>/dev/null | wc -l)
    
    if [[ $SEGMENT_COUNT -gt 0 ]]; then
        AVG_SEGMENT_SIZE=$(ls -l ${SEGMENT_PREFIX}_*.ts | awk '{sum+=$5; count++} END {if(count>0) printf "%.2f KB", sum/count/1024}')
        TOTAL_TS_SIZE=$(ls -l ${SEGMENT_PREFIX}_*.ts | awk '{sum+=$5} END {printf "%.2f MB", sum/1024/1024}')
        
        echo ""
        echo -e "${CYAN}Output Statistics:${NC}"
        echo "  Segments created: $SEGMENT_COUNT"
        echo "  Average segment size: $AVG_SEGMENT_SIZE"
        echo "  Total TS files size: $TOTAL_TS_SIZE"
        echo "  Total directory size: $TOTAL_SIZE"
        echo ""
        echo "  Playlist: $PLAYLIST_FILE"
        echo "  Segments: ${SEGMENT_PREFIX}_*.ts"
        
        # Compare with expected CPU sizes
        echo ""
        echo -e "${YELLOW}Size Comparison:${NC}"
        echo "  CPU (CRF 36): ~1-2 MB per 6s segment"
        echo "  GPU (CQ 36): Actual sizes above"
    fi
else
    echo -e "${RED}✗ Streaming failed${NC}"
fi

echo ""
echo -e "${CYAN}Tips for reducing file size:${NC}"
echo "  - Increase CQ value: GPU_CQ=40 (lower quality, smaller files)"
echo "  - Lower bitrate: Change -b:v 500k to -b:v 300k"
echo "  - Use HEVC: Change h264_nvenc to hevc_nvenc"
echo "  - Adjust GOP: Increase -g value for better compression"
echo ""
echo "Example for ultra-low bitrate:"
echo "  GPU_CQ=42 ./$(basename $0) \"$CAMERA_URL\""