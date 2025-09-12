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

# Test RTSP connection first
echo "🔍 Testing RTSP stream connectivity..."
timeout 10 ffprobe -rtsp_transport tcp -v quiet -print_format json -show_streams "$CAMERA_URL" > /dev/null 2>&1
if [[ $? -eq 0 ]]; then
    echo "✅ RTSP stream accessible"
    echo ""
else
    echo "❌ RTSP stream not accessible or timed out"
    echo "   Please check:"
    echo "   - Camera URL: $CAMERA_URL"
    echo "   - Network connectivity"
    echo "   - Camera credentials"
    echo ""
    exit 1
fi

# Function to run FFmpeg with better progress output and error handling
run_ffmpeg_test() {
    local test_name="$1"
    local log_file="$2"
    shift 2
    local ffmpeg_args=("$@")
    
    echo "Starting $test_name..."
    echo "Log file: $log_file"
    echo "Command: timeout $((TEST_DURATION + 15)) ffmpeg ${ffmpeg_args[*]}"
    echo ""
    
    # Run FFmpeg with progress output
    timeout $((TEST_DURATION + 15)) ffmpeg \
        "${ffmpeg_args[@]}" \
        -progress pipe:1 \
        > "$log_file" 2>&1 &
    
    local ffmpeg_pid=$!
    local start_time=$(date +%s)
    
    # Monitor progress
    while kill -0 "$ffmpeg_pid" 2>/dev/null; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [[ $elapsed -gt $((TEST_DURATION + 10)) ]]; then
            echo "⚠️  Process taking longer than expected (${elapsed}s), but still running..."
        fi
        
        # Show progress every 5 seconds
        if [[ $((elapsed % 5)) -eq 0 ]] && [[ $elapsed -gt 0 ]]; then
            echo "⏱️  Elapsed: ${elapsed}s / ${TEST_DURATION}s target"
        fi
        
        sleep 1
    done
    
    wait "$ffmpeg_pid"
    local exit_code=$?
    
    echo ""
    if [[ $exit_code -eq 0 ]]; then
        echo "✅ $test_name completed successfully!"
    elif [[ $exit_code -eq 124 ]]; then
        echo "⏰ $test_name timed out after $((TEST_DURATION + 15)) seconds"
    else
        echo "❌ $test_name failed with exit code $exit_code"
        echo "Last 10 lines of log:"
        tail -10 "$log_file" 2>/dev/null | sed 's/^/    /'
    fi
    echo ""
    
    return $exit_code
}

# Test 1: CPU libx264 (Original working command with RTSP fixes)
echo "1. Testing CPU (libx264) - Original Command"
echo "============================================"

CPU_LOG_FILE="${OUTPUT_DIR}/cpu_test.log"

run_ffmpeg_test "CPU encoding" "$CPU_LOG_FILE" \
    -loglevel info \
    -rtsp_transport tcp \
    -stimeout 5000000 \
    -analyzeduration 1000000 \
    -probesize 2000000 \
    -i "$CAMERA_URL" \
    -t $TEST_DURATION \
    -vf scale=1280:720 \
    -c:v libx264 -crf 36 -preset medium \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_flags append_list \
    -hls_segment_filename "${OUTPUT_DIR}/cpu_segment_%03d.ts" \
    "${OUTPUT_DIR}/cpu_playlist.m3u8"

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

# Test 2: GPU h264_nvenc (Current script with timeout)
echo "2. Testing GPU (h264_nvenc) - Current Script"
echo "============================================="

GPU_LOG_FILE="${OUTPUT_DIR}/gpu_test.log"

run_ffmpeg_test "GPU encoding" "$GPU_LOG_FILE" \
    -loglevel info \
    -rtsp_transport tcp \
    -stimeout 5000000 \
    -analyzeduration 1000000 \
    -probesize 2000000 \
    -hwaccel cuda \
    -hwaccel_output_format cuda \
    -i "$CAMERA_URL" \
    -t $TEST_DURATION \
    -vf "scale_cuda=854x480" \
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
    -hls_segment_filename "${OUTPUT_DIR}/gpu_segment_%03d.ts" \
    "${OUTPUT_DIR}/gpu_playlist.m3u8"

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

GPU_EQUIV_LOG_FILE="${OUTPUT_DIR}/gpu_equiv_test.log"

run_ffmpeg_test "GPU (CPU equivalent)" "$GPU_EQUIV_LOG_FILE" \
    -loglevel info \
    -rtsp_transport tcp \
    -stimeout 5000000 \
    -analyzeduration 1000000 \
    -probesize 2000000 \
    -hwaccel cuda \
    -hwaccel_output_format cuda \
    -i "$CAMERA_URL" \
    -t $TEST_DURATION \
    -vf "scale_cuda=1280:720" \
    -c:v h264_nvenc \
    -preset p4 \
    -rc constqp \
    -cq 36 \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_flags append_list \
    -hls_segment_filename "${OUTPUT_DIR}/gpu_equiv_segment_%03d.ts" \
    "${OUTPUT_DIR}/gpu_equiv_playlist.m3u8"

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