#!/bin/bash

# Simple GPU Test - Debug version
# Minimal test to isolate the problem

set -e

TEST_DIR="simple_test_$(date +%H%M%S)"
mkdir -p "$TEST_DIR"

echo "=== Simple GPU Test ==="
echo "Output: $TEST_DIR"

# Launch 3 streams manually
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
echo "Monitoring for 12 seconds..."

# Monitor
for sec in {1..12}; do
    active=0
    for i in {1..3}; do
        if kill -0 ${pids[i]} 2>/dev/null; then
            ((active++))
        fi
    done

    gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits)
    nvenc=$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader,nounits)

    printf "\r[%2ds] Active: %d/3 | GPU: %s%% | NVENC: %s" $sec $active $gpu_util $nvenc
    sleep 1
done

echo ""
echo ""
echo "=== Results ==="

# Check outputs
for i in {1..3}; do
    if [ -f "${TEST_DIR}/stream${i}_playlist.m3u8" ]; then
        segments=$(ls ${TEST_DIR}/stream${i}_seg_*.ts 2>/dev/null | wc -l)
        echo "✓ Stream $i: playlist.m3u8 + $segments segments"
    else
        echo "✗ Stream $i: FAILED"
        echo "  Log:"
        cat "${TEST_DIR}/stream${i}.log" | head -3
    fi
done

echo ""
echo "Total files created: $(ls $TEST_DIR | wc -l)"
echo "Test directory: $TEST_DIR"