#!/bin/bash

# Compare different CQ values for file size optimization
# Tests various quality settings to find optimal size/quality balance

CAMERA_URL="${1:-rtsp://ttec:9LPYqPyD%21@192.168.1.101:554/}"
TEST_DURATION="${2:-30}"  # Shorter duration for comparison

# Test different CQ values
CQ_VALUES=(30 33 36 39 42 45)

echo "GPU Bitrate Comparison Test"
echo "============================"
echo "Testing CQ values: ${CQ_VALUES[@]}"
echo ""

for CQ in "${CQ_VALUES[@]}"; do
    OUTPUT_DIR="./output_cq${CQ}"
    mkdir -p "$OUTPUT_DIR"
    
    echo "Testing CQ=$CQ..."
    
    # Run FFmpeg with specific CQ value
    ffmpeg -hide_banner -loglevel error \
        -rtsp_transport tcp \
        -hwaccel cuda \
        -hwaccel_output_format cuda \
        -i "$CAMERA_URL" \
        -t $TEST_DURATION \
        -vf "scale_cuda=1280:720" \
        -c:v h264_nvenc \
        -preset p4 \
        -rc constqp \
        -cq $CQ \
        -b:v 500k \
        -maxrate 750k \
        -bufsize 1M \
        -an \
        -f hls \
        -hls_time 6 \
        -hls_segment_filename "${OUTPUT_DIR}/segment_%03d.ts" \
        "${OUTPUT_DIR}/playlist.m3u8"
    
    # Calculate size
    SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)
    SEGMENT_COUNT=$(ls -1 ${OUTPUT_DIR}/segment_*.ts 2>/dev/null | wc -l)
    AVG_SIZE=$(ls -l ${OUTPUT_DIR}/segment_*.ts 2>/dev/null | awk '{sum+=$5; count++} END {if(count>0) printf "%.1f KB", sum/count/1024; else print "N/A"}')
    
    echo "  CQ $CQ: Total=$SIZE, Segments=$SEGMENT_COUNT, Avg=$AVG_SIZE per segment"
done

echo ""
echo "Recommendation:"
echo "  CQ 36-39: Good balance of quality and size"
echo "  CQ 42+: Very small files, acceptable quality for monitoring"