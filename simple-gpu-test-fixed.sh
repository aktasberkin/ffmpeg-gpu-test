#!/bin/bash

# Simple GPU Test - Fixed monitoring version

set -e

TEST_DIR="simple_test_$(date +%H%M%S)"
mkdir -p "$TEST_DIR"

echo "=== Simple GPU Test - Fixed ==="
echo "Output: $TEST_DIR"

# Launch 3 streams manually
pids=()
for i in {1..3}; do
    echo "Starting stream $i..."

    ffmpeg -f lavfi -i "testsrc2=size=1280x720:rate=30" \
        -t 10 \
        -c:v h264_nvenc \
        -preset p4 \
        -cq 36 \
        -f hls \
        -hls_time 2 \
        -hls_list_size 5 \
        -hls_segment_filename "${TEST_DIR}/stream${i}_seg_%03d.ts" \
        "${TEST_DIR}/stream${i}_playlist.m3u8" \
        >"${TEST_DIR}/stream${i}.log" 2>&1 &

    pids[i]=$!
    echo "  Stream $i PID: ${pids[i]}"
done

echo ""
echo "Waiting 10 seconds for encoding to complete..."
sleep 10

echo ""
echo "=== Process Check ==="
for i in {1..3}; do
    if kill -0 ${pids[i]} 2>/dev/null; then
        echo "Stream $i: STILL RUNNING"
    else
        echo "Stream $i: COMPLETED"
    fi
done

echo ""
echo "=== GPU Status ==="
nvidia-smi --query-gpu=utilization.gpu,memory.used,encoder.stats.sessionCount --format=csv

echo ""
echo "=== Results ==="

# Check outputs
total_files=0
for i in {1..3}; do
    if [ -f "${TEST_DIR}/stream${i}_playlist.m3u8" ]; then
        segments=$(ls ${TEST_DIR}/stream${i}_seg_*.ts 2>/dev/null | wc -l)
        size=$(du -sh ${TEST_DIR}/stream${i}_* 2>/dev/null | head -1 | cut -f1)
        echo "✓ Stream $i: playlist.m3u8 + $segments segments (${size})"
        ((total_files += segments + 1))
    else
        echo "✗ Stream $i: FAILED"
        echo "  Error log (first 3 lines):"
        head -3 "${TEST_DIR}/stream${i}.log" 2>/dev/null | sed 's/^/    /'
        echo "  Full log in: ${TEST_DIR}/stream${i}.log"
    fi
done

echo ""
echo "Total files created: $total_files"
echo "Directory contents:"
ls -la "$TEST_DIR/" | head -10

# Show sample playlist
echo ""
if [ -f "${TEST_DIR}/stream1_playlist.m3u8" ]; then
    echo "=== Sample Playlist ==="
    cat "${TEST_DIR}/stream1_playlist.m3u8"
fi

echo ""
echo "Test completed! Check directory: $TEST_DIR"