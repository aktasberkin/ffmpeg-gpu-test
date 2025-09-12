#!/bin/bash

# Simple stream connectivity test
CAMERA_URL="${1:-rtsp://admin:9LPY%23qPyD@78.188.37.56/cam/realmonitor?channel=3&subtype=0}"

echo "Simple Stream Connectivity Test"
echo "================================"
echo "Camera: $CAMERA_URL"
echo ""

# Test 1: Just probe the stream (no recording)
echo "1. Probing stream info..."
echo "========================"
ffprobe -rtsp_transport tcp -analyzeduration 3000000 -probesize 5000000 "$CAMERA_URL" 2>&1 | head -20

echo ""

# Test 2: Basic CPU recording (no scaling, no special settings)
echo "2. Basic CPU recording test (10 seconds)..."
echo "============================================="
mkdir -p ./stream_test

timeout 15 ffmpeg -y \
    -rtsp_transport tcp \
    -i "$CAMERA_URL" \
    -t 10 \
    -c:v libx264 \
    -c:a aac \
    ./stream_test/basic_cpu_test.mp4

if [[ -f "./stream_test/basic_cpu_test.mp4" ]]; then
    FILE_SIZE=$(du -h ./stream_test/basic_cpu_test.mp4 | cut -f1)
    echo "✓ CPU recording successful: $FILE_SIZE"
    
    # Get video info
    ffprobe ./stream_test/basic_cpu_test.mp4 2>&1 | grep "Video\|Duration"
else
    echo "✗ CPU recording failed"
fi

echo ""

# Test 3: Basic GPU recording (no scaling, basic settings)
echo "3. Basic GPU recording test (10 seconds)..."
echo "============================================="

timeout 15 ffmpeg -y \
    -rtsp_transport tcp \
    -hwaccel cuda \
    -i "$CAMERA_URL" \
    -t 10 \
    -c:v h264_nvenc \
    -preset fast \
    ./stream_test/basic_gpu_test.mp4

if [[ -f "./stream_test/basic_gpu_test.mp4" ]]; then
    FILE_SIZE=$(du -h ./stream_test/basic_gpu_test.mp4 | cut -f1)
    echo "✓ GPU recording successful: $FILE_SIZE"
    
    # Get video info
    ffprobe ./stream_test/basic_gpu_test.mp4 2>&1 | grep "Video\|Duration"
else
    echo "✗ GPU recording failed"
fi

echo ""

# Test 4: CPU with your exact working command format
echo "4. CPU with exact working format (10 seconds)..."
echo "================================================"

timeout 15 ffmpeg -loglevel info \
    -i "$CAMERA_URL" \
    -t 10 \
    -vf scale=1280:720 \
    -c:v libx264 -crf 36 -preset medium \
    -f hls \
    -hls_time 6 \
    -hls_flags append_list \
    -hls_segment_filename "./stream_test/working_segment_%03d.ts" \
    "./stream_test/working_playlist.m3u8"

if ls ./stream_test/working_segment_*.ts 1> /dev/null 2>&1; then
    SEGMENT_COUNT=$(ls -1 ./stream_test/working_segment_*.ts | wc -l)
    TOTAL_SIZE=$(du -sm ./stream_test/working_segment_*.ts | awk '{sum+=$1} END {print sum}')
    AVG_SIZE=$(ls -l ./stream_test/working_segment_*.ts | awk '{sum+=$5; count++} END {if(count>0) printf "%.1f", sum/count/1024; else print 0}')
    
    echo "✓ Working format successful!"
    echo "  Segments: $SEGMENT_COUNT"
    echo "  Total Size: ${TOTAL_SIZE}MB"
    echo "  Average Segment: ${AVG_SIZE}KB"
else
    echo "✗ Working format failed"
fi

echo ""
echo "Summary:"
echo "========"
echo "Files created in: ./stream_test/"
echo ""
echo "Next steps:"
echo "- If basic tests work but HLS fails → HLS configuration issue"  
echo "- If CPU works but GPU fails → GPU/CUDA setup issue"
echo "- If all fail → Network/stream access issue"
echo ""
echo "Check with: ls -la ./stream_test/"