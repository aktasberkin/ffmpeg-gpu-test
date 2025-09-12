#!/bin/bash

# Quality Comparison: CPU vs GPU at same quality levels
# Shows the file size and quality differences between CPU and GPU encoding

CAMERA_URL="${1:-rtsp://admin:9LPY%23qPyD@78.188.37.56/cam/realmonitor?channel=3&subtype=0}"
TEST_DURATION="${2:-20}"  # 20 seconds for quick comparison
OUTPUT_DIR="./quality_comparison"

mkdir -p "$OUTPUT_DIR"

echo "CPU vs GPU Quality Comparison"
echo "============================="
echo "Camera: $CAMERA_URL"
echo "Duration: ${TEST_DURATION}s"
echo ""

# Test RTSP connection
echo "🔍 Testing RTSP stream..."
timeout 10 ffprobe -rtsp_transport tcp -v quiet -print_format json -show_streams "$CAMERA_URL" > /dev/null 2>&1
if [[ $? -ne 0 ]]; then
    echo "❌ RTSP stream not accessible"
    exit 1
fi
echo "✅ RTSP stream OK"
echo ""

# Function to run test
run_test() {
    local test_name="$1"
    local output_prefix="$2"
    shift 2
    
    echo "🎬 Running $test_name..."
    
    timeout $((TEST_DURATION + 10)) ffmpeg \
        "$@" \
        -progress pipe:1 2>&1 | \
        grep -E "out_time=|speed=" | tail -1
    
    if ls ${output_prefix}_segment*.ts 1> /dev/null 2>&1; then
        local avg_size=$(ls -l ${output_prefix}_segment*.ts | awk '{sum+=$5; count++} END {if(count>0) printf "%.1f", sum/count/1024; else print 0}')
        echo "  ✅ Avg segment size: ${avg_size}KB"
    else
        echo "  ❌ Failed"
    fi
    echo ""
}

# Test 1: CPU High Quality (CRF 23 - visually lossless)
echo "1. CPU High Quality (CRF 23, 1280x720)"
echo "======================================="
run_test "CPU CRF=23" "${OUTPUT_DIR}/cpu_crf23" \
    -loglevel error \
    -rtsp_transport tcp \
    -i "$CAMERA_URL" \
    -t $TEST_DURATION \
    -vf scale=1280:720 \
    -c:v libx264 \
    -crf 23 \
    -preset medium \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_segment_filename "${OUTPUT_DIR}/cpu_crf23_segment_%03d.ts" \
    "${OUTPUT_DIR}/cpu_crf23.m3u8"

# Test 2: GPU Equivalent Quality (CQ 23)
echo "2. GPU High Quality (CQ 23, 1280x720)"
echo "======================================"
run_test "GPU CQ=23" "${OUTPUT_DIR}/gpu_cq23" \
    -loglevel error \
    -rtsp_transport tcp \
    -hwaccel cuda \
    -hwaccel_output_format cuda \
    -i "$CAMERA_URL" \
    -t $TEST_DURATION \
    -vf "scale_cuda=1280:720" \
    -c:v h264_nvenc \
    -preset p2 \
    -rc constqp \
    -cq 23 \
    -gpu 0 \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_segment_filename "${OUTPUT_DIR}/gpu_cq23_segment_%03d.ts" \
    "${OUTPUT_DIR}/gpu_cq23.m3u8"

# Test 3: CPU Good Quality (CRF 28)
echo "3. CPU Good Quality (CRF 28, 1280x720)"
echo "======================================="
run_test "CPU CRF=28" "${OUTPUT_DIR}/cpu_crf28" \
    -loglevel error \
    -rtsp_transport tcp \
    -i "$CAMERA_URL" \
    -t $TEST_DURATION \
    -vf scale=1280:720 \
    -c:v libx264 \
    -crf 28 \
    -preset medium \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_segment_filename "${OUTPUT_DIR}/cpu_crf28_segment_%03d.ts" \
    "${OUTPUT_DIR}/cpu_crf28.m3u8"

# Test 4: GPU Good Quality (CQ 28)
echo "4. GPU Good Quality (CQ 28, 1280x720)"
echo "======================================"
run_test "GPU CQ=28" "${OUTPUT_DIR}/gpu_cq28" \
    -loglevel error \
    -rtsp_transport tcp \
    -hwaccel cuda \
    -hwaccel_output_format cuda \
    -i "$CAMERA_URL" \
    -t $TEST_DURATION \
    -vf "scale_cuda=1280:720" \
    -c:v h264_nvenc \
    -preset p2 \
    -rc constqp \
    -cq 28 \
    -gpu 0 \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_segment_filename "${OUTPUT_DIR}/gpu_cq28_segment_%03d.ts" \
    "${OUTPUT_DIR}/gpu_cq28.m3u8"

# Test 5: CPU Acceptable (CRF 36)
echo "5. CPU Acceptable Quality (CRF 36, 1280x720)"
echo "============================================"
run_test "CPU CRF=36" "${OUTPUT_DIR}/cpu_crf36" \
    -loglevel error \
    -rtsp_transport tcp \
    -i "$CAMERA_URL" \
    -t $TEST_DURATION \
    -vf scale=1280:720 \
    -c:v libx264 \
    -crf 36 \
    -preset medium \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_segment_filename "${OUTPUT_DIR}/cpu_crf36_segment_%03d.ts" \
    "${OUTPUT_DIR}/cpu_crf36.m3u8"

# Test 6: GPU Acceptable (CQ 36)
echo "6. GPU Acceptable Quality (CQ 36, 1280x720)"
echo "==========================================="
run_test "GPU CQ=36" "${OUTPUT_DIR}/gpu_cq36" \
    -loglevel error \
    -rtsp_transport tcp \
    -hwaccel cuda \
    -hwaccel_output_format cuda \
    -i "$CAMERA_URL" \
    -t $TEST_DURATION \
    -vf "scale_cuda=1280:720" \
    -c:v h264_nvenc \
    -preset p4 \
    -rc constqp \
    -cq 36 \
    -gpu 0 \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_segment_filename "${OUTPUT_DIR}/gpu_cq36_segment_%03d.ts" \
    "${OUTPUT_DIR}/gpu_cq36.m3u8"

echo "📊 Comparison Results"
echo "===================="
echo ""
echo "Quality Level | CPU (libx264) | GPU (h264_nvenc) | Difference"
echo "--------------|---------------|------------------|------------"

# Compare file sizes
for quality in "23:High" "28:Good" "36:Acceptable"; do
    IFS=':' read -r cq label <<< "$quality"
    
    cpu_size="N/A"
    gpu_size="N/A"
    
    if ls "${OUTPUT_DIR}/cpu_crf${cq}_segment"*.ts 1> /dev/null 2>&1; then
        cpu_size=$(ls -l "${OUTPUT_DIR}/cpu_crf${cq}_segment"*.ts | awk '{sum+=$5; count++} END {if(count>0) printf "%.1f", sum/count/1024; else print "N/A"}')
    fi
    
    if ls "${OUTPUT_DIR}/gpu_cq${cq}_segment"*.ts 1> /dev/null 2>&1; then
        gpu_size=$(ls -l "${OUTPUT_DIR}/gpu_cq${cq}_segment"*.ts | awk '{sum+=$5; count++} END {if(count>0) printf "%.1f", sum/count/1024; else print "N/A"}')
    fi
    
    if [[ "$cpu_size" != "N/A" ]] && [[ "$gpu_size" != "N/A" ]]; then
        diff=$(echo "scale=1; ($gpu_size - $cpu_size) / $cpu_size * 100" | bc -l)
        printf "%-13s | %10sKB | %13sKB | GPU is %+.1f%% larger\n" \
            "$label" "$cpu_size" "$gpu_size" "$diff"
    else
        printf "%-13s | %10sKB | %13sKB | N/A\n" \
            "$label" "$cpu_size" "$gpu_size"
    fi
done

echo ""
echo "💡 Key Insights:"
echo "   - GPU (h264_nvenc) typically produces 2-3x larger files than CPU (libx264)"
echo "   - For same visual quality, GPU needs lower CQ values"
echo "   - CPU is more efficient but slower"
echo "   - GPU is faster but less efficient"
echo ""
echo "🎯 To match quality levels:"
echo "   CPU CRF 23 ≈ GPU CQ 20-23 (High quality)"
echo "   CPU CRF 28 ≈ GPU CQ 25-28 (Good quality)"
echo "   CPU CRF 36 ≈ GPU CQ 32-36 (Acceptable)"
echo "   CPU CRF 45 ≈ GPU CQ 40-45 (Low quality)"
echo ""
echo "📁 Files in: $OUTPUT_DIR"
echo "🎬 Compare visually: vlc $OUTPUT_DIR/*.m3u8"