#!/bin/bash

# True Concurrent Test - ALL streams launch simultaneously
# No batching, 1s monitoring intervals to catch true peak concurrency

STREAM_COUNT=${1:-30}
TEST_DURATION=${2:-90}
OUTPUT_DIR="true_concurrent_$(date +%Y%m%d_%H%M%S)"

# Colors
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

echo "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo "${GREEN}║          TRUE CONCURRENT GPU TEST             ║${NC}"
echo "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo ""
echo "${CYAN}Configuration:${NC}"
echo "  Streams: $STREAM_COUNT (ALL SIMULTANEOUS)"
echo "  Duration: ${TEST_DURATION}s"
echo "  Monitor: 1s intervals (high frequency)"
echo ""

mkdir -p "$OUTPUT_DIR"

# Verify GPU
echo "${GREEN}✅ GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader)${NC}"
echo ""

# Initialize monitoring
echo "timestamp,elapsed,active,gpu_util,gpu_mem,nvenc,cpu" > "$OUTPUT_DIR/monitoring.csv"

# Launch ALL streams simultaneously
launch_all_streams() {
    local pids=()
    local patterns=("testsrc2=size=1280x720:rate=30" "smptebars=size=1280x720:rate=30" "testsrc=size=1280x720:rate=30" "color=c=blue:size=1280x720:rate=30")

    echo "${YELLOW}=== SIMULTANEOUS LAUNCH ===${NC}"
    echo "Launching ALL $STREAM_COUNT streams immediately..."

    # Launch ALL streams with minimal delay
    for ((i=0; i<STREAM_COUNT; i++)); do
        local pattern="${patterns[$((i % ${#patterns[@]}))]}"

        ffmpeg -f lavfi -i "$pattern" \
            -t $TEST_DURATION \
            -c:v h264_nvenc \
            -preset p4 \
            -cq 36 \
            -g 60 \
            -f hls \
            -hls_time 6 \
            -hls_list_size 0 \
            -hls_segment_filename "$OUTPUT_DIR/stream${i}_%03d.ts" \
            -hls_playlist_type vod \
            "$OUTPUT_DIR/stream${i}.m3u8" \
            >"$OUTPUT_DIR/stream${i}.log" 2>&1 &

        pids[i]=$!
        sleep 0.01  # 10ms delay only
    done

    echo "${GREEN}✅ ALL $STREAM_COUNT streams launched!${NC}"
    echo ""

    # Immediate concurrent check
    sleep 0.5
    local immediate_count=0
    for pid in "${pids[@]}"; do
        if kill -0 $pid 2>/dev/null; then
            immediate_count=$((immediate_count + 1))
        fi
    done

    echo "${CYAN}Immediate count (0.5s): $immediate_count/$STREAM_COUNT${NC}"
    echo ""

    echo "${pids[*]}"
}

# High-frequency monitoring
monitor_streams() {
    local pids=($1)
    local start_time=$(date +%s)
    local max_concurrent=0

    echo "${YELLOW}=== HIGH FREQUENCY MONITORING ===${NC}"
    echo "Time | Active | Peak | GPU%  | VRAM  | NVENC | Status"
    echo "-----+--------+------+-------+-------+-------+-------------"

    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        # Count active processes
        local active=0
        for pid in "${pids[@]}"; do
            if kill -0 $pid 2>/dev/null; then
                active=$((active + 1))
            fi
        done

        # Track peak
        if [ $active -gt $max_concurrent ]; then
            max_concurrent=$active
        fi

        # Get GPU metrics
        local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")
        local gpu_mem=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")
        local nvenc=$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")
        local cpu=$(top -bn1 2>/dev/null | awk '/^%Cpu/ {print int(100-$8)}' | head -1 || echo "0")

        # Status indicator
        local status=""
        if [ $active -eq $STREAM_COUNT ]; then
            status="${GREEN}FULL-CONCURRENT${NC}"
        elif [ $active -eq $max_concurrent ] && [ $active -gt $((STREAM_COUNT * 80 / 100)) ]; then
            status="${YELLOW}HIGH-CONCURRENT${NC}"
        fi

        printf "%4ds | %6d | %4d | %4s%% | %4sMB | %5s | %s\\n" \
            $elapsed $active $max_concurrent $gpu_util $gpu_mem $nvenc "$status"

        # Log data
        echo "$(date +%s),$elapsed,$active,$gpu_util,$gpu_mem,$nvenc,$cpu" >> "$OUTPUT_DIR/monitoring.csv"

        # Check completion
        if [ $active -eq 0 ]; then
            echo ""
            echo "${GREEN}🎉 All completed at ${elapsed}s${NC}"
            echo "${CYAN}PEAK CONCURRENT: $max_concurrent/$STREAM_COUNT${NC}"
            break
        fi

        if [ $elapsed -gt $((TEST_DURATION + 30)) ]; then
            echo "${YELLOW}⚠️ Timeout reached${NC}"
            break
        fi

        sleep 1  # 1-second intervals
    done

    return $max_concurrent
}

# Results analysis
analyze_results() {
    local max_concurrent=$1

    echo ""
    echo "${CYAN}=== CONCURRENCY ANALYSIS ===${NC}"

    local playlists=$(find "$OUTPUT_DIR" -name "*.m3u8" | wc -l)
    local concurrency_rate=$(( max_concurrent * 100 / STREAM_COUNT ))

    echo "Target streams: $STREAM_COUNT"
    echo "Peak concurrent: $max_concurrent"
    echo "Concurrency rate: $concurrency_rate%"
    echo "Success rate: $(( playlists * 100 / STREAM_COUNT ))%"

    if [ $max_concurrent -eq $STREAM_COUNT ]; then
        echo "${GREEN}✅ PERFECT: All $STREAM_COUNT streams ran simultaneously${NC}"
    elif [ $max_concurrent -ge $((STREAM_COUNT * 90 / 100)) ]; then
        echo "${GREEN}✅ EXCELLENT: $concurrency_rate% concurrency${NC}"
    else
        echo "${YELLOW}⚠️ LIMITED: Only $concurrency_rate% concurrency${NC}"
    fi

    echo ""
    echo "Generated files:"
    echo "  Monitor data: $OUTPUT_DIR/monitoring.csv"
    echo "  HLS outputs: $OUTPUT_DIR/stream*.m3u8"
}

# Cleanup
cleanup() {
    pkill -f "ffmpeg.*h264_nvenc" 2>/dev/null || true
    sleep 2
}

trap cleanup EXIT INT TERM

# Main execution
main() {
    pids_string=$(launch_all_streams)
    monitor_streams "$pids_string"
    max_concurrent=$?
    analyze_results $max_concurrent

    echo ""
    echo "${GREEN}🚀 True concurrent test complete!${NC}"
}

main "$@"
