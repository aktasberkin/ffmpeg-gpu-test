#!/bin/bash

# Manual Concurrent Control Test
# User controls stream count and can see real-time status

set -e

echo "=== Manual Concurrent GPU Test ==="
echo ""

# User input
read -p "How many concurrent streams to test? (5-200): " STREAM_COUNT
read -p "Test duration in seconds? (10-120): " DURATION

if [[ ! "$STREAM_COUNT" =~ ^[0-9]+$ ]] || [ "$STREAM_COUNT" -lt 1 ] || [ "$STREAM_COUNT" -gt 200 ]; then
    echo "Invalid stream count. Using 10."
    STREAM_COUNT=10
fi

if [[ ! "$DURATION" =~ ^[0-9]+$ ]] || [ "$DURATION" -lt 5 ] || [ "$DURATION" -gt 300 ]; then
    echo "Invalid duration. Using 30."
    DURATION=30
fi

TEST_DIR="manual_test_$(date +%H%M%S)_${STREAM_COUNT}streams"
mkdir -p "$TEST_DIR"

echo ""
echo "Configuration:"
echo "  Streams: $STREAM_COUNT"
echo "  Duration: ${DURATION}s"
echo "  Output: $TEST_DIR"
echo ""

# Launch streams
echo "Launching $STREAM_COUNT streams..."
pids=()

for ((i=0; i<STREAM_COUNT; i++)); do
    # Different test patterns for variety
    patterns=("testsrc2" "smptebars" "mandelbrot" "life" "plasma")
    pattern="${patterns[$((i % 5))]}"

    ffmpeg -f lavfi -i "${pattern}=size=1280x720:rate=30" \
        -t $DURATION \
        -c:v h264_nvenc \
        -preset p4 \
        -cq 36 \
        -f hls \
        -hls_time 4 \
        -hls_list_size 5 \
        -hls_segment_filename "${TEST_DIR}/stream${i}_seg_%03d.ts" \
        "${TEST_DIR}/stream${i}.m3u8" \
        >"${TEST_DIR}/stream${i}.log" 2>&1 &

    pids[i]=$!

    # Progress
    if [ $((i % 10)) -eq 0 ] || [ $i -eq $((STREAM_COUNT-1)) ]; then
        printf "\r  Launched: %d/%d (PID: %d)" $((i+1)) $STREAM_COUNT ${pids[i]}
    fi

    # Small delay to prevent overwhelming
    if [ $((i % 20)) -eq 0 ] && [ $i -gt 0 ]; then
        sleep 0.1
    fi
done

echo ""
echo -e "\n✅ All $STREAM_COUNT streams launched!"
echo ""

# Real-time monitoring
echo "=== Real-time Monitoring ==="
echo "Press Ctrl+C to stop monitoring (streams will continue)"
echo ""

start_time=$(date +%s)
monitor_count=0

while true; do
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))

    # Count active processes
    active=0
    completed=0
    for pid in "${pids[@]}"; do
        if kill -0 $pid 2>/dev/null; then
            ((active++))
        else
            ((completed++))
        fi
    done

    # Get GPU metrics (safe calls)
    gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' %' || echo 0)
    gpu_mem=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' MiB' || echo 0)
    nvenc=$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo 0)

    # Count output files
    files_count=$(find "$TEST_DIR" -name "*.m3u8" 2>/dev/null | wc -l)
    segments_count=$(find "$TEST_DIR" -name "*.ts" 2>/dev/null | wc -l)

    # Display status
    printf "\r[%3ds] Active: %s%3d%s | Done: %s%3d%s | GPU: %s%3s%%%s | VRAM: %s%4sMB%s | NVENC: %s%2s%s | Files: %d/%d | Segments: %d" \
        $elapsed \
        "\033[0;32m" $active "\033[0m" \
        "\033[0;34m" $completed "\033[0m" \
        "\033[1;33m" $gpu_util "\033[0m" \
        "\033[0;36m" $gpu_mem "\033[0m" \
        "\033[0;35m" $nvenc "\033[0m" \
        $files_count $STREAM_COUNT $segments_count

    # Check if all done
    if [ $active -eq 0 ]; then
        echo ""
        echo -e "\n🎉 All streams completed!"
        break
    fi

    # Safety timeout
    if [ $elapsed -gt $((DURATION + 30)) ]; then
        echo ""
        echo -e "\n⚠️ Timeout reached, some streams may still be running"
        break
    fi

    sleep 2
    ((monitor_count++))
done

echo ""
echo "=== Final Results ==="

# Analysis
successful=0
failed=0
total_size=0

for ((i=0; i<STREAM_COUNT; i++)); do
    if [ -f "${TEST_DIR}/stream${i}.m3u8" ]; then
        segments=$(ls "${TEST_DIR}"/stream${i}_seg_*.ts 2>/dev/null | wc -l)
        size=$(du -k "${TEST_DIR}"/stream${i}* 2>/dev/null | awk '{sum+=$1} END {print sum}')
        total_size=$((total_size + size))
        echo "✅ Stream $i: $segments segments"
        ((successful++))
    else
        echo "❌ Stream $i: FAILED"
        echo "   Error: $(head -1 "${TEST_DIR}/stream${i}.log" 2>/dev/null | cut -c1-80)"
        ((failed++))
    fi
done

echo ""
echo "Summary:"
echo "  Total streams: $STREAM_COUNT"
echo "  Successful: $successful"
echo "  Failed: $failed"
echo "  Success rate: $((successful * 100 / STREAM_COUNT))%"
echo "  Total output size: $((total_size / 1024))MB"
echo ""
echo "Test directory: $TEST_DIR"

# GPU final status
echo ""
echo "Final GPU status:"
nvidia-smi --query-gpu=utilization.gpu,memory.used,encoder.stats.sessionCount --format=csv

echo ""
echo "Test completed! 🚀"