#!/bin/bash

# GPU Quality Optimization Test
# Tests different GPU encoding settings to find the best quality within 100-200KB segment range

CAMERA_URL="${1:-rtsp://admin:9LPY%23qPyD@78.188.37.56/cam/realmonitor?channel=3&subtype=0}"
TEST_DURATION="${2:-30}"  # 30 seconds
OUTPUT_DIR="./gpu_quality_test"

mkdir -p "$OUTPUT_DIR"

echo "GPU Quality Optimization Test"
echo "============================"
echo "Camera: $CAMERA_URL"
echo "Duration: ${TEST_DURATION}s"
echo "Target: 100-200KB per 6-second segment"
echo ""

# Test RTSP connection first
echo "🔍 Testing RTSP stream connectivity..."
timeout 10 ffprobe -rtsp_transport tcp -v quiet -print_format json -show_streams "$CAMERA_URL" > /dev/null 2>&1
if [[ $? -eq 0 ]]; then
    echo "✅ RTSP stream accessible"
    echo ""
else
    echo "❌ RTSP stream not accessible or timed out"
    exit 1
fi

# Function to run FFmpeg test with progress monitoring
run_gpu_quality_test() {
    local test_name="$1"
    local log_file="$2"
    local segment_prefix="$3"
    local playlist_file="$4"
    shift 4
    local ffmpeg_args=("$@")
    
    echo "🔄 Starting $test_name..."
    echo "📝 Log: $log_file"
    echo ""
    
    # Clean previous segments
    rm -f "${segment_prefix}"*.ts "${playlist_file}" 2>/dev/null
    
    # Run FFmpeg with progress monitoring
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
        
        # Show progress every 5 seconds
        if [[ $((elapsed % 5)) -eq 0 ]] && [[ $elapsed -gt 0 ]]; then
            echo "⏱️  $test_name: ${elapsed}s / ${TEST_DURATION}s"
        fi
        
        sleep 1
    done
    
    wait "$ffmpeg_pid"
    local exit_code=$?
    
    echo ""
    if [[ $exit_code -eq 0 ]]; then
        echo "✅ $test_name completed successfully!"
        
        # Analyze segment sizes
        if ls ${segment_prefix}*.ts 1> /dev/null 2>&1; then
            local segment_count=$(ls -1 ${segment_prefix}*.ts | wc -l)
            local avg_size_kb=$(ls -l ${segment_prefix}*.ts | awk '{sum+=$5; count++} END {if(count>0) printf "%.1f", sum/count/1024; else print 0}')
            local total_size_mb=$(du -sm ${segment_prefix}*.ts | awk '{sum+=$1} END {print sum}')
            
            echo "  📊 Results: $segment_count segments, avg ${avg_size_kb}KB each (${total_size_mb}MB total)"
            
            # Check if within target range
            if (( $(echo "$avg_size_kb >= 100 && $avg_size_kb <= 200" | bc -l) )); then
                echo "  🎯 ✅ Within target range (100-200KB)"
            elif (( $(echo "$avg_size_kb < 100" | bc -l) )); then
                echo "  📉 Under target (could increase quality)"
            else
                echo "  📈 Over target (need more compression)"
            fi
        else
            echo "  ❌ No segments created"
        fi
    elif [[ $exit_code -eq 124 ]]; then
        echo "⏰ $test_name timed out"
    else
        echo "❌ $test_name failed (exit code: $exit_code)"
    fi
    echo ""
    
    return $exit_code
}

# Test 1: Current working settings (baseline)
echo "1. Baseline Test - Current Maximum Compression"
echo "=============================================="

run_gpu_quality_test \
    "Baseline (CQ=45, 854x480)" \
    "${OUTPUT_DIR}/baseline.log" \
    "${OUTPUT_DIR}/baseline_segment" \
    "${OUTPUT_DIR}/baseline_playlist.m3u8" \
    -loglevel info \
    -rtsp_transport tcp \
    -stimeout 5000000 \
    -analyzeduration 1000000 \
    -probesize 2000000 \
    -hwaccel cuda \
    -hwaccel_output_format cuda \
    -i "$CAMERA_URL" \
    -t $TEST_DURATION \
    -vf "scale_cuda=854:480" \
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
    -hls_segment_filename "${OUTPUT_DIR}/baseline_segment_%03d.ts" \
    "${OUTPUT_DIR}/baseline_playlist.m3u8"

# Test 2: Better quality (CQ=42)
echo "2. Better Quality Test - CQ=42"
echo "==============================="

run_gpu_quality_test \
    "Better Quality (CQ=42, 854x480)" \
    "${OUTPUT_DIR}/quality.log" \
    "${OUTPUT_DIR}/quality_segment" \
    "${OUTPUT_DIR}/quality_playlist.m3u8" \
    -loglevel info \
    -rtsp_transport tcp \
    -stimeout 5000000 \
    -analyzeduration 1000000 \
    -probesize 2000000 \
    -hwaccel cuda \
    -hwaccel_output_format cuda \
    -i "$CAMERA_URL" \
    -t $TEST_DURATION \
    -vf "scale_cuda=854:480" \
    -c:v h264_nvenc \
    -preset p6 \
    -rc cbr \
    -cq 42 \
    -b:v 220k \
    -maxrate 270k \
    -bufsize 135k \
    -g 60 \
    -bf 3 \
    -refs 3 \
    -gpu 0 \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_flags append_list \
    -hls_segment_filename "${OUTPUT_DIR}/quality_segment_%03d.ts" \
    "${OUTPUT_DIR}/quality_playlist.m3u8"

# Test 3: Higher resolution (960x540)
echo "3. Higher Resolution Test - 960x540"
echo "===================================="

run_gpu_quality_test \
    "Higher Resolution (CQ=45, 960x540)" \
    "${OUTPUT_DIR}/highres.log" \
    "${OUTPUT_DIR}/highres_segment" \
    "${OUTPUT_DIR}/highres_playlist.m3u8" \
    -loglevel info \
    -rtsp_transport tcp \
    -stimeout 5000000 \
    -analyzeduration 1000000 \
    -probesize 2000000 \
    -hwaccel cuda \
    -hwaccel_output_format cuda \
    -i "$CAMERA_URL" \
    -t $TEST_DURATION \
    -vf "scale_cuda=960:540" \
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
    -hls_segment_filename "${OUTPUT_DIR}/highres_segment_%03d.ts" \
    "${OUTPUT_DIR}/highres_playlist.m3u8"

# Test 4: Balanced approach (CQ=42, 960x540)  
echo "4. Balanced Test - CQ=42 + 960x540"
echo "==================================="

run_gpu_quality_test \
    "Balanced (CQ=42, 960x540)" \
    "${OUTPUT_DIR}/balanced.log" \
    "${OUTPUT_DIR}/balanced_segment" \
    "${OUTPUT_DIR}/balanced_playlist.m3u8" \
    -loglevel info \
    -rtsp_transport tcp \
    -stimeout 5000000 \
    -analyzeduration 1000000 \
    -probesize 2000000 \
    -hwaccel cuda \
    -hwaccel_output_format cuda \
    -i "$CAMERA_URL" \
    -t $TEST_DURATION \
    -vf "scale_cuda=960:540" \
    -c:v h264_nvenc \
    -preset p6 \
    -rc cbr \
    -cq 42 \
    -b:v 220k \
    -maxrate 270k \
    -bufsize 135k \
    -g 60 \
    -bf 3 \
    -refs 3 \
    -gpu 0 \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_flags append_list \
    -hls_segment_filename "${OUTPUT_DIR}/balanced_segment_%03d.ts" \
    "${OUTPUT_DIR}/balanced_playlist.m3u8"

# Test 5: Premium quality with higher bitrate
echo "5. Premium Quality Test - CQ=40"
echo "================================"

run_gpu_quality_test \
    "Premium Quality (CQ=40, 960x540)" \
    "${OUTPUT_DIR}/premium.log" \
    "${OUTPUT_DIR}/premium_segment" \
    "${OUTPUT_DIR}/premium_playlist.m3u8" \
    -loglevel info \
    -rtsp_transport tcp \
    -stimeout 5000000 \
    -analyzeduration 1000000 \
    -probesize 2000000 \
    -hwaccel cuda \
    -hwaccel_output_format cuda \
    -i "$CAMERA_URL" \
    -t $TEST_DURATION \
    -vf "scale_cuda=960:540" \
    -c:v h264_nvenc \
    -preset p6 \
    -rc cbr \
    -cq 40 \
    -b:v 240k \
    -maxrate 290k \
    -bufsize 145k \
    -g 60 \
    -bf 3 \
    -refs 3 \
    -gpu 0 \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_flags append_list \
    -hls_segment_filename "${OUTPUT_DIR}/premium_segment_%03d.ts" \
    "${OUTPUT_DIR}/premium_playlist.m3u8"

echo "🎯 GPU Quality Test Summary"
echo "=========================="
echo ""
echo "📊 Results comparison:"
echo "Test                     | Avg Size | Within Target | Quality Level"
echo "-------------------------|----------|---------------|---------------"

for test in baseline quality highres balanced premium; do
    if ls "${OUTPUT_DIR}/${test}_segment"*.ts 1> /dev/null 2>&1; then
        avg_size=$(ls -l "${OUTPUT_DIR}/${test}_segment"*.ts | awk '{sum+=$5; count++} END {if(count>0) printf "%.1f", sum/count/1024; else print "N/A"}')
        if (( $(echo "$avg_size >= 100 && $avg_size <= 200" | bc -l 2>/dev/null || echo 0) )); then
            target_status="✅ YES"
        elif (( $(echo "$avg_size < 100" | bc -l 2>/dev/null || echo 0) )); then
            target_status="📉 Under"
        else
            target_status="📈 Over"
        fi
        
        case $test in
            baseline) quality_level="Baseline" ;;
            quality) quality_level="Better" ;;
            highres) quality_level="Higher Res" ;;
            balanced) quality_level="Balanced" ;;
            premium) quality_level="Premium" ;;
        esac
        
        printf "%-24s | %6sKB | %-13s | %s\n" "$quality_level" "$avg_size" "$target_status" "$quality_level"
    fi
done

echo ""
echo "📁 Files saved in: $OUTPUT_DIR"
echo "🎬 Play samples with: vlc $OUTPUT_DIR/[test_name]_playlist.m3u8"
echo ""
echo "💡 Recommendations:"
echo "   - Choose the highest quality test that stays within 100-200KB target"
echo "   - Premium Quality may exceed 200KB but offers best visual quality"
echo "   - Balanced is likely the sweet spot for quality vs size"