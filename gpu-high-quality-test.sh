#!/bin/bash

# GPU High Quality Test Script
# Tests higher quality settings, accepting larger file sizes for better visual quality

CAMERA_URL="${1:-rtsp://admin:9LPY%23qPyD@78.188.37.56/cam/realmonitor?channel=3&subtype=0}"
TEST_DURATION="${2:-30}"  # 30 seconds
OUTPUT_DIR="./gpu_high_quality"

mkdir -p "$OUTPUT_DIR"

echo "GPU High Quality Test"
echo "===================="
echo "Camera: $CAMERA_URL"
echo "Duration: ${TEST_DURATION}s"
echo "Focus: Visual quality over file size"
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

# Function to run quality test
run_quality_test() {
    local test_name="$1"
    local log_file="$2"
    local segment_prefix="$3"
    local playlist_file="$4"
    shift 4
    local ffmpeg_args=("$@")
    
    echo "🎬 Starting $test_name..."
    echo "📝 Log: $log_file"
    echo ""
    
    # Clean previous segments
    rm -f "${segment_prefix}"*.ts "${playlist_file}" 2>/dev/null
    
    # Run FFmpeg
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
        
        if [[ $((elapsed % 5)) -eq 0 ]] && [[ $elapsed -gt 0 ]]; then
            echo "⏱️  Progress: ${elapsed}s / ${TEST_DURATION}s"
        fi
        
        sleep 1
    done
    
    wait "$ffmpeg_pid"
    local exit_code=$?
    
    echo ""
    if [[ $exit_code -eq 0 ]]; then
        echo "✅ $test_name completed!"
        
        # Analyze results
        if ls ${segment_prefix}*.ts 1> /dev/null 2>&1; then
            local segment_count=$(ls -1 ${segment_prefix}*.ts | wc -l)
            local avg_size_kb=$(ls -l ${segment_prefix}*.ts | awk '{sum+=$5; count++} END {if(count>0) printf "%.1f", sum/count/1024; else print 0}')
            local total_size_mb=$(du -sm ${segment_prefix}*.ts | awk '{sum+=$1} END {print sum}')
            
            echo "  📊 Results: $segment_count segments, avg ${avg_size_kb}KB each"
            
            # Quality assessment based on size
            if (( $(echo "$avg_size_kb < 200" | bc -l) )); then
                echo "  ⚠️  Size: ${avg_size_kb}KB - Very compressed, quality may be low"
            elif (( $(echo "$avg_size_kb >= 200 && $avg_size_kb <= 400" | bc -l) )); then
                echo "  👍 Size: ${avg_size_kb}KB - Moderate compression"
            elif (( $(echo "$avg_size_kb >= 400 && $avg_size_kb <= 600" | bc -l) )); then
                echo "  🎯 Size: ${avg_size_kb}KB - Good quality/size balance"
            else
                echo "  💎 Size: ${avg_size_kb}KB - High quality"
            fi
        fi
    else
        echo "❌ $test_name failed (exit code: $exit_code)"
    fi
    echo ""
    
    return $exit_code
}

# Test 1: HD Resolution with moderate compression
echo "1. HD Resolution Test (1280x720, CQ=35)"
echo "========================================"

run_quality_test \
    "HD 720p CQ=35" \
    "${OUTPUT_DIR}/hd720_cq35.log" \
    "${OUTPUT_DIR}/hd720_cq35_segment" \
    "${OUTPUT_DIR}/hd720_cq35_playlist.m3u8" \
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
    -rc vbr \
    -cq 35 \
    -b:v 500k \
    -maxrate 750k \
    -bufsize 1000k \
    -g 60 \
    -bf 3 \
    -refs 3 \
    -gpu 0 \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_flags append_list \
    -hls_segment_filename "${OUTPUT_DIR}/hd720_cq35_segment_%03d.ts" \
    "${OUTPUT_DIR}/hd720_cq35_playlist.m3u8"

# Test 2: HD Resolution with better quality
echo "2. HD Resolution High Quality (1280x720, CQ=30)"
echo "==============================================="

run_quality_test \
    "HD 720p CQ=30" \
    "${OUTPUT_DIR}/hd720_cq30.log" \
    "${OUTPUT_DIR}/hd720_cq30_segment" \
    "${OUTPUT_DIR}/hd720_cq30_playlist.m3u8" \
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
    -rc vbr \
    -cq 30 \
    -b:v 800k \
    -maxrate 1200k \
    -bufsize 1600k \
    -g 60 \
    -bf 3 \
    -refs 3 \
    -gpu 0 \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_flags append_list \
    -hls_segment_filename "${OUTPUT_DIR}/hd720_cq30_segment_%03d.ts" \
    "${OUTPUT_DIR}/hd720_cq30_playlist.m3u8"

# Test 3: Full HD with compression
echo "3. Full HD Test (1920x1080, CQ=38)"
echo "==================================="

run_quality_test \
    "Full HD 1080p CQ=38" \
    "${OUTPUT_DIR}/fhd1080_cq38.log" \
    "${OUTPUT_DIR}/fhd1080_cq38_segment" \
    "${OUTPUT_DIR}/fhd1080_cq38_playlist.m3u8" \
    -loglevel info \
    -rtsp_transport tcp \
    -stimeout 5000000 \
    -analyzeduration 1000000 \
    -probesize 2000000 \
    -hwaccel cuda \
    -hwaccel_output_format cuda \
    -i "$CAMERA_URL" \
    -t $TEST_DURATION \
    -c:v h264_nvenc \
    -preset p4 \
    -rc vbr \
    -cq 38 \
    -b:v 600k \
    -maxrate 900k \
    -bufsize 1200k \
    -g 60 \
    -bf 3 \
    -refs 3 \
    -gpu 0 \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_flags append_list \
    -hls_segment_filename "${OUTPUT_DIR}/fhd1080_cq38_segment_%03d.ts" \
    "${OUTPUT_DIR}/fhd1080_cq38_playlist.m3u8"

# Test 4: Full HD high quality
echo "4. Full HD High Quality (1920x1080, CQ=28)"
echo "==========================================="

run_quality_test \
    "Full HD 1080p CQ=28" \
    "${OUTPUT_DIR}/fhd1080_cq28.log" \
    "${OUTPUT_DIR}/fhd1080_cq28_segment" \
    "${OUTPUT_DIR}/fhd1080_cq28_playlist.m3u8" \
    -loglevel info \
    -rtsp_transport tcp \
    -stimeout 5000000 \
    -analyzeduration 1000000 \
    -probesize 2000000 \
    -hwaccel cuda \
    -hwaccel_output_format cuda \
    -i "$CAMERA_URL" \
    -t $TEST_DURATION \
    -c:v h264_nvenc \
    -preset p2 \
    -rc vbr \
    -cq 28 \
    -b:v 1500k \
    -maxrate 2000k \
    -bufsize 3000k \
    -g 60 \
    -bf 3 \
    -refs 3 \
    -gpu 0 \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_flags append_list \
    -hls_segment_filename "${OUTPUT_DIR}/fhd1080_cq28_segment_%03d.ts" \
    "${OUTPUT_DIR}/fhd1080_cq28_playlist.m3u8"

# Test 5: Balanced HD for reasonable quality
echo "5. Balanced HD (1280x720, CQ=32, VBR)"
echo "======================================"

run_quality_test \
    "Balanced HD CQ=32" \
    "${OUTPUT_DIR}/balanced_hd.log" \
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
    -vf "scale_cuda=1280:720" \
    -c:v h264_nvenc \
    -preset p3 \
    -rc vbr \
    -cq 32 \
    -b:v 700k \
    -maxrate 1000k \
    -bufsize 1400k \
    -g 60 \
    -bf 3 \
    -refs 3 \
    -profile:v high \
    -level 4.1 \
    -gpu 0 \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_flags append_list \
    -hls_segment_filename "${OUTPUT_DIR}/balanced_segment_%03d.ts" \
    "${OUTPUT_DIR}/balanced_playlist.m3u8"

# Test 6: Minimum acceptable quality for comparison
echo "6. Minimum Acceptable Quality (960x540, CQ=38)"
echo "=============================================="

run_quality_test \
    "Minimum Acceptable" \
    "${OUTPUT_DIR}/minimum.log" \
    "${OUTPUT_DIR}/minimum_segment" \
    "${OUTPUT_DIR}/minimum_playlist.m3u8" \
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
    -preset p5 \
    -rc vbr \
    -cq 38 \
    -b:v 350k \
    -maxrate 450k \
    -bufsize 500k \
    -g 60 \
    -bf 3 \
    -refs 3 \
    -gpu 0 \
    -an \
    -f hls \
    -hls_time 6 \
    -hls_flags append_list \
    -hls_segment_filename "${OUTPUT_DIR}/minimum_segment_%03d.ts" \
    "${OUTPUT_DIR}/minimum_playlist.m3u8"

echo "📊 High Quality Test Summary"
echo "============================"
echo ""
echo "Test Name                    | Resolution | CQ  | Bitrate | Avg Size | Quality"
echo "-----------------------------|------------|-----|---------|----------|----------"

for test_info in \
    "hd720_cq35:HD_720p_CQ35:1280x720:35:500k" \
    "hd720_cq30:HD_720p_CQ30:1280x720:30:800k" \
    "fhd1080_cq38:FHD_1080p_CQ38:1920x1080:38:600k" \
    "fhd1080_cq28:FHD_1080p_CQ28:1920x1080:28:1500k" \
    "balanced:Balanced_HD:1280x720:32:700k" \
    "minimum:Minimum_Quality:960x540:38:350k"; do
    
    IFS=':' read -r prefix name resolution cq bitrate <<< "$test_info"
    
    if ls "${OUTPUT_DIR}/${prefix}_segment"*.ts 1> /dev/null 2>&1; then
        avg_size=$(ls -l "${OUTPUT_DIR}/${prefix}_segment"*.ts 2>/dev/null | awk '{sum+=$5; count++} END {if(count>0) printf "%.1f", sum/count/1024; else print "N/A"}')
        
        # Quality rating based on CQ value
        if [[ $cq -le 30 ]]; then
            quality="Excellent"
        elif [[ $cq -le 35 ]]; then
            quality="Good"
        elif [[ $cq -le 40 ]]; then
            quality="Fair"
        else
            quality="Low"
        fi
        
        printf "%-28s | %-10s | %-3s | %-7s | %7sKB | %s\n" \
            "$name" "$resolution" "$cq" "$bitrate" "$avg_size" "$quality"
    fi
done

echo ""
echo "💡 Quality Guidelines:"
echo "   CQ 23-28: Excellent quality (near lossless)"
echo "   CQ 29-35: Good quality (recommended for streaming)"
echo "   CQ 36-40: Fair quality (acceptable with visible compression)"
echo "   CQ 41-51: Low quality (heavy compression artifacts)"
echo ""
echo "📁 Files saved in: $OUTPUT_DIR"
echo "🎬 Play samples: vlc $OUTPUT_DIR/[test]_playlist.m3u8"
echo ""
echo "🎯 Recommendations:"
echo "   1. For best quality: Use HD 720p with CQ=30-32"
echo "   2. For balance: Use HD 720p with CQ=35"
echo "   3. For bandwidth saving: Use 960x540 with CQ=38"
echo ""
echo "⚠️  Note: File sizes will be larger than 200KB for good quality."
echo "    Quality requires trade-offs with file size!"