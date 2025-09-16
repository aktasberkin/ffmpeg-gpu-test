#!/bin/bash

# Stable Real-time Monitor - Terminal output problemlerini çözer
# Printf ve pipe sorunlarını handle eder

set -e

# Configuration
STREAM_COUNT=${1:-30}
TEST_DURATION=${2:-45}
OUTPUT_DIR="stable_test_$(date +%H%M%S)"
MONITOR_LOG="$OUTPUT_DIR/monitoring.log"

# Colors with proper escape sequences
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

echo "${GREEN}=== Stable Real-time Monitor Test ===${NC}"
echo "Streams: $STREAM_COUNT | Duration: ${TEST_DURATION}s"

mkdir -p "$OUTPUT_DIR"

# Initialize monitoring log
echo "timestamp,elapsed,active,completed,gpu_util,gpu_mem,nvenc,cpu,pids_active" > "$MONITOR_LOG"

# Launch function with better error handling
launch_streams() {
    local pids=()

    echo "Launching streams..."
    for ((i=0; i<STREAM_COUNT; i++)); do
        ffmpeg -f lavfi -i "testsrc2=size=1280x720:rate=30" \
            -t $TEST_DURATION \
            -c:v h264_nvenc \
            -preset p4 \
            -cq 36 \
            -f hls \
            -hls_time 3 \
            -hls_list_size 8 \
            -hls_segment_filename "${OUTPUT_DIR}/s${i}_%03d.ts" \
            "${OUTPUT_DIR}/s${i}.m3u8" \
            >"${OUTPUT_DIR}/s${i}.log" 2>&1 &

        pids[i]=$!

        # Progress with safe output
        if [ $((i % 5)) -eq 4 ] || [ $i -eq $((STREAM_COUNT-1)) ]; then
            echo "  Launched: $((i+1))/$STREAM_COUNT"
        fi

        # Prevent system overload
        if [ $((i % 15)) -eq 0 ] && [ $i -gt 0 ]; then
            sleep 0.1
        fi
    done

    echo "${pids[*]}"  # Return PIDs
}

# Safe monitoring function
monitor_safe() {
    local pids_array=($1)
    local start_time=$(date +%s)

    echo ""
    echo "${YELLOW}=== Monitoring Started ===${NC}"
    echo "Monitor log: $MONITOR_LOG"
    echo ""

    # Header
    printf "%-8s %-8s %-8s %-8s %-8s %-8s %-8s\n" \
        "Time" "Active" "Done" "GPU%" "VRAM" "NVENC" "CPU%"
    echo "--------+--------+--------+--------+--------+--------+--------"

    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        # Count processes safely
        local active=0
        local active_pids=""

        for pid in "${pids_array[@]}"; do
            if kill -0 $pid 2>/dev/null; then
                active=$((active + 1))
                active_pids="$active_pids $pid"
            fi
        done

        local completed=$((STREAM_COUNT - active))

        # Get metrics with timeout protection
        local gpu_util
        local gpu_mem
        local nvenc
        local cpu

        # Safe GPU metrics (with timeout)
        if timeout 3s nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits &>/dev/null; then
            gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")
            gpu_mem=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")
            nvenc=$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")
        else
            gpu_util="ERR"
            gpu_mem="ERR"
            nvenc="ERR"
        fi

        # Safe CPU metric
        cpu=$(top -bn1 2>/dev/null | awk '/^%Cpu/ {print int(100-$8)}' | head -1 || echo "0")

        # Display with fixed width formatting
        printf "%-8s %-8d %-8d %-8s %-8s %-8s %-8s\n" \
            "${elapsed}s" "$active" "$completed" "$gpu_util" "$gpu_mem" "$nvenc" "$cpu"

        # Log to file
        echo "$(date +%s),$elapsed,$active,$completed,$gpu_util,$gpu_mem,$nvenc,$cpu,\"$active_pids\"" >> "$MONITOR_LOG"

        # Completion check
        if [ $active -eq 0 ]; then
            echo ""
            echo "${GREEN}✅ All streams completed at ${elapsed}s${NC}"
            break
        fi

        # Timeout check
        if [ $elapsed -gt $((TEST_DURATION + 30)) ]; then
            echo ""
            echo "${YELLOW}⏰ Timeout reached${NC}"
            break
        fi

        sleep 2
    done
}

# Results analysis
analyze_results() {
    echo ""
    echo "${BLUE}=== Results Analysis ===${NC}"

    # File count
    local playlists=$(find "$OUTPUT_DIR" -name "*.m3u8" 2>/dev/null | wc -l)
    local segments=$(find "$OUTPUT_DIR" -name "*.ts" 2>/dev/null | wc -l)
    local success_rate=$(( playlists * 100 / STREAM_COUNT ))

    echo "Success rate: $playlists/$STREAM_COUNT ($success_rate%)"
    echo "Total segments: $segments"

    # Performance analysis from log
    if [ -f "$MONITOR_LOG" ]; then
        local peak_gpu=$(awk -F',' 'NR>1 && $5!="ERR" {if($5>max) max=$5} END {print max+0}' "$MONITOR_LOG")
        local avg_gpu=$(awk -F',' 'NR>1 && $5!="ERR" {sum+=$5; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}' "$MONITOR_LOG")
        local peak_concurrent=$(awk -F',' 'NR>1 {if($3>max) max=$3} END {print max+0}' "$MONITOR_LOG")

        echo "Peak GPU utilization: ${peak_gpu}%"
        echo "Average GPU utilization: ${avg_gpu}%"
        echo "Peak concurrent processes: $peak_concurrent"
        echo "Concurrency efficiency: $(( peak_concurrent * 100 / STREAM_COUNT ))%"

        # Success criteria
        if [ $success_rate -ge 90 ]; then
            echo "${GREEN}✅ SUCCESS: >90% completion rate${NC}"
        else
            echo "${YELLOW}⚠️  PARTIAL: $success_rate% completion rate${NC}"
        fi

        if [ $peak_gpu -ge 50 ]; then
            echo "${GREEN}✅ GPU: Good utilization ($peak_gpu%)${NC}"
        else
            echo "${YELLOW}⚠️  GPU: Underutilized ($peak_gpu%)${NC}"
        fi

        if [ $peak_concurrent -ge $((STREAM_COUNT * 80 / 100)) ]; then
            echo "${GREEN}✅ CONCURRENCY: True concurrent execution${NC}"
        else
            echo "${YELLOW}⚠️  CONCURRENCY: Limited (${peak_concurrent}/$STREAM_COUNT)${NC}"
        fi
    fi

    echo ""
    echo "Output directory: $OUTPUT_DIR"
    echo "Monitor log: $MONITOR_LOG"
}

# Cleanup function
cleanup() {
    echo ""
    echo "${YELLOW}Cleaning up...${NC}"
    pkill -f "ffmpeg.*h264_nvenc" 2>/dev/null || true
    sleep 2
}

# Main execution
main() {
    # Launch streams
    pids_string=$(launch_streams)

    # Start monitoring
    monitor_safe "$pids_string"

    # Analyze results
    analyze_results

    echo ""
    echo "${GREEN}🚀 Stable monitor test complete!${NC}"
}

# Set cleanup trap
trap cleanup EXIT INT TERM

# Run main function
main "$@"