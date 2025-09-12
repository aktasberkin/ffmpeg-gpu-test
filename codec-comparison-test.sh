#!/bin/bash

# Codec Comparison Test: CPU vs GPU encoding
# Tests the same RTSP stream with both codecs to compare file sizes

CAMERA_URL="${1:-rtsp://ttec:9LPYqPyD%21@192.168.1.101:554/}"
TEST_DURATION="${2:-60}"  # 60 seconds
OUTPUT_DIR="./codec_comparison"

mkdir -p "$OUTPUT_DIR"

echo "Codec Comparison Test"
echo "===================="
echo "Camera: $CAMERA_URL"
echo "Duration: ${TEST_DURATION}s"
echo ""

# Test 1: CPU libx264 (Original working command)
echo "1. Testing CPU (libx264) - Original Command"
echo "============================================"

CPU_CMD="ffmpeg -loglevel info \
    -i \"$CAMERA_URL\" \
    -t $TEST_DURATION \
    -vf scale=1280:720 \
    -c:v libx264 -crf 36 -preset medium \
    -f hls \
    -hls_time 6 \
    -hls_flags append_list \
    -hls_segment_filename \"${OUTPUT_DIR}/cpu_segment_%03d.ts\" \
    \"${OUTPUT_DIR}/cpu_playlist.m3u8\""

echo "Command: $CPU_CMD"
echo ""

eval "$CPU_CMD"
CPU_EXIT_CODE=$?

if [[ $CPU_EXIT_CODE -eq 0 ]]; then
    CPU_SEGMENTS=$(ls -1 ${OUTPUT_DIR}/cpu_segment_*.ts 2>/dev/null | wc -l)
    CPU_TOTAL_SIZE=$(du -sm ${OUTPUT_DIR}/cpu_segment_*.ts 2>/dev/null | awk '{sum+=$1} END {print sum}')
    CPU_AVG_SIZE=$(ls -l ${OUTPUT_DIR}/cpu_segment_*.ts 2>/dev/null | awk '{sum+=$5; count++} END {if(count>0) printf "%.1f", sum/count/1024; else print 0}')
    
    echo "CPU Results:"
    echo "  Segments: $CPU_SEGMENTS"
    echo "  Total Size: ${CPU_TOTAL_SIZE}MB"
    echo "  Average Segment: ${CPU_AVG_SIZE}KB"
    echo ""
else
    echo "CPU encoding failed!"
    echo ""
fi

# Test 2: GPU h264_nvenc (Current script)
echo "2. Testing GPU (h264_nvenc) - Current Script"
echo "============================================="

GPU_CMD="ffmpeg -loglevel info \
    -rtsp_transport tcp \
    -hwaccel cuda \
    -hwaccel_output_format cuda \
    -i \"$CAMERA_URL\" \
    -t $TEST_DURATION \
    -vf \"scale_cuda=854x480\" \
    -c:v h264_nvenc \
    -preset p6 \
    -rc cbr \
    -cq 45 \
    -b:v 200k \
    -maxrate 250k \
    -bufsize 125k \
    -g 60 \
    -bf 3 \
    -refs 3 \
    -gpu 0 \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_flags append_list \
    -hls_segment_filename \"${OUTPUT_DIR}/gpu_segment_%03d.ts\" \
    \"${OUTPUT_DIR}/gpu_playlist.m3u8\""

echo "Command: $GPU_CMD"
echo ""

eval "$GPU_CMD"
GPU_EXIT_CODE=$?

if [[ $GPU_EXIT_CODE -eq 0 ]]; then
    GPU_SEGMENTS=$(ls -1 ${OUTPUT_DIR}/gpu_segment_*.ts 2>/dev/null | wc -l)
    GPU_TOTAL_SIZE=$(du -sm ${OUTPUT_DIR}/gpu_segment_*.ts 2>/dev/null | awk '{sum+=$1} END {print sum}')
    GPU_AVG_SIZE=$(ls -l ${OUTPUT_DIR}/gpu_segment_*.ts 2>/dev/null | awk '{sum+=$5; count++} END {if(count>0) printf "%.1f", sum/count/1024; else print 0}')
    
    echo "GPU Results:"
    echo "  Segments: $GPU_SEGMENTS"
    echo "  Total Size: ${GPU_TOTAL_SIZE}MB"
    echo "  Average Segment: ${GPU_AVG_SIZE}KB"
    echo ""
else
    echo "GPU encoding failed!"
    echo ""
fi

# Test 3: GPU with exact CPU settings (but GPU codec)
echo "3. Testing GPU (h264_nvenc) - CPU Settings Equivalent"
echo "====================================================="

GPU_CPU_EQUIV_CMD="ffmpeg -loglevel info \
    -rtsp_transport tcp \
    -hwaccel cuda \
    -hwaccel_output_format cuda \
    -i \"$CAMERA_URL\" \
    -t $TEST_DURATION \
    -vf \"scale_cuda=1280:720\" \
    -c:v h264_nvenc \
    -preset p4 \
    -rc constqp \
    -cq 36 \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_flags append_list \
    -hls_segment_filename \"${OUTPUT_DIR}/gpu_equiv_segment_%03d.ts\" \
    \"${OUTPUT_DIR}/gpu_equiv_playlist.m3u8\""

echo "Command: $GPU_CPU_EQUIV_CMD"
echo ""

eval "$GPU_CPU_EQUIV_CMD"
GPU_EQUIV_EXIT_CODE=$?

if [[ $GPU_EQUIV_EXIT_CODE -eq 0 ]]; then
    GPU_EQUIV_SEGMENTS=$(ls -1 ${OUTPUT_DIR}/gpu_equiv_segment_*.ts 2>/dev/null | wc -l)
    GPU_EQUIV_TOTAL_SIZE=$(du -sm ${OUTPUT_DIR}/gpu_equiv_segment_*.ts 2>/dev/null | awk '{sum+=$1} END {print sum}')
    GPU_EQUIV_AVG_SIZE=$(ls -l ${OUTPUT_DIR}/gpu_equiv_segment_*.ts 2>/dev/null | awk '{sum+=$5; count++} END {if(count>0) printf "%.1f", sum/count/1024; else print 0}')
    
    echo "GPU (CPU Equivalent) Results:"
    echo "  Segments: $GPU_EQUIV_SEGMENTS"
    echo "  Total Size: ${GPU_EQUIV_TOTAL_SIZE}MB"
    echo "  Average Segment: ${GPU_EQUIV_AVG_SIZE}KB"
    echo ""
else
    echo "GPU (CPU equivalent) encoding failed!"
    echo ""
fi

# Summary
echo "================="
echo "COMPARISON SUMMARY"
echo "================="
echo ""

if [[ $CPU_EXIT_CODE -eq 0 ]]; then
    echo "CPU (libx264):           ${CPU_AVG_SIZE}KB per segment"
fi

if [[ $GPU_EQUIV_EXIT_CODE -eq 0 ]]; then
    echo "GPU (CPU equivalent):    ${GPU_EQUIV_AVG_SIZE}KB per segment"
fi

if [[ $GPU_EXIT_CODE -eq 0 ]]; then
    echo "GPU (maximum compress):  ${GPU_AVG_SIZE}KB per segment"
fi

echo ""
echo "Analysis:"
echo "  If CPU produces smallest files, there's a codec efficiency difference"
echo "  If GPU equivalent is similar to CPU, our compression settings need adjustment"
echo "  If GPU maximum compress is still large, we need more aggressive settings"
echo ""

echo "Files saved in: $OUTPUT_DIR"
echo "Play with: vlc $OUTPUT_DIR/cpu_playlist.m3u8"