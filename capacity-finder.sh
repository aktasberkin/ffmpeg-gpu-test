#!/bin/bash

# GPU Capacity Finder - Optimal concurrent stream sayısını bulur
# Incremental testing ile sistem limitini belirler

START_STREAMS=${1:-20}
MAX_STREAMS=${2:-150}
TEST_DURATION=${3:-45}
INCREMENT=${4:-10}

OUTPUT_DIR="capacity_finder_$(date +%Y%m%d_%H%M%S)"

# Colors
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

echo "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo "${GREEN}║           GPU CAPACITY FINDER                 ║${NC}"
echo "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo ""
echo "${CYAN}Configuration:${NC}"
echo "  Start: $START_STREAMS streams"
echo "  Max: $MAX_STREAMS streams"
echo "  Increment: +$INCREMENT per test"
echo "  Duration: ${TEST_DURATION}s per test"
echo ""

mkdir -p "$OUTPUT_DIR"

# System limits check
echo "System Limits:"
echo "  Max processes: $(ulimit -u)"
echo "  Max open files: $(ulimit -n)"
echo "  Current processes: $(ps aux | wc -l)"
echo ""

# Test function
test_concurrent_capacity() {
    local stream_count=$1
    local test_dir="$OUTPUT_DIR/test_${stream_count}_streams"
    mkdir -p "$test_dir"

    echo "${YELLOW}Testing $stream_count concurrent streams...${NC}"

    local pids=()
    local launch_failures=0
    local patterns=("testsrc2=size=1280x720:rate=30" "smptebars=size=1280x720:rate=30" "testsrc=size=1280x720:rate=30" "color=c=blue:size=1280x720:rate=30")

    # Launch with failure detection
    for ((i=0; i<stream_count; i++)); do
        local pattern="${patterns[$((i % ${#patterns[@]}))]}"

        # Launch stream in background
        ffmpeg -f lavfi -i "$pattern" \
            -t $TEST_DURATION \
            -c:v h264_nvenc \
            -preset p4 \
            -cq 36 \
            -g 60 \
            -f hls \
            -hls_time 6 \
            -hls_list_size 0 \
            -hls_segment_filename "$test_dir/stream${i}_%03d.ts" \
            -hls_playlist_type vod \
            "$test_dir/stream${i}.m3u8" \
            >"$test_dir/stream${i}.log" 2>&1 &

        local launch_pid=$!

        # Check if process started successfully
        sleep 0.1  # Give it time to start

        if kill -0 $launch_pid 2>/dev/null; then
            # Process is running
            pids[i]=$launch_pid
        else
            # Process failed to start
            launch_failures=$((launch_failures + 1))
            echo "  Launch failure #$launch_failures at stream $i"

            # If too many failures, abort this test
            if [ $launch_failures -ge 5 ]; then
                echo "  ${RED}Too many launch failures, aborting test${NC}"
                break
            fi
        fi

        sleep 0.01
    done

    # Wait a moment for startup
    sleep 3

    # Count successful launches
    local active=0
    for pid in "${pids[@]}"; do
        if [ -n "$pid" ] && kill -0 $pid 2>/dev/null; then
            active=$((active + 1))
        fi
    done

    # Get peak metrics
    local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")
    local gpu_mem=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")
    local nvenc=$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")

    # Monitor progress with feedback
    echo "  Running test..."
    local elapsed=0
    local monitor_interval=5

    while [ $elapsed -lt $TEST_DURATION ]; do
        sleep $monitor_interval
        elapsed=$((elapsed + monitor_interval))

        # Count still active
        local still_active=0
        for pid in "${pids[@]}"; do
            if [ -n "$pid" ] && kill -0 $pid 2>/dev/null; then
                still_active=$((still_active + 1))
            fi
        done

        # Get current metrics
        local current_gpu=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")
        local current_mem=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")

        printf "    [%d/%ds] Active: %d/%d, GPU: %s%%, VRAM: %sMB\r" \
            $elapsed $TEST_DURATION $still_active $active $current_gpu $current_mem
    done

    echo ""  # New line after progress
    echo "  Finalizing..."
    sleep 5  # Short final wait

    # Kill any remaining processes
    for pid in "${pids[@]}"; do
        if [ -n "$pid" ]; then
            kill -9 $pid 2>/dev/null || true
        fi
    done

    # Count successful outputs
    local successful=$(find "$test_dir" -name "*.m3u8" | wc -l)
    local success_rate=$(( successful * 100 / stream_count ))

    # Log results
    echo "$stream_count,$active,$successful,$success_rate,$launch_failures,$gpu_util,$gpu_mem,$nvenc" >> "$OUTPUT_DIR/capacity_results.csv"

    printf "  ${CYAN}Result: %d/%d launched, %d/%d completed (%d%%), GPU: %s%%, VRAM: %sMB${NC}\n" \
        $active $stream_count $successful $stream_count $success_rate $gpu_util $gpu_mem

    # Return success status
    if [ $launch_failures -ge 5 ]; then
        return 1  # Failed due to launch issues
    elif [ $success_rate -lt 80 ]; then
        return 2  # Failed due to low success rate
    else
        return 0  # Success
    fi
}

# Initialize results log
echo "target_streams,launched_streams,completed_streams,success_rate,launch_failures,gpu_util,gpu_mem,nvenc_sessions" > "$OUTPUT_DIR/capacity_results.csv"

# Run incremental tests
current_streams=$START_STREAMS
max_successful=0
optimal_streams=0

echo "${YELLOW}=== Incremental Capacity Testing ===${NC}"

while [ $current_streams -le $MAX_STREAMS ]; do
    if test_concurrent_capacity $current_streams; then
        echo "  ${GREEN}✅ $current_streams streams: SUCCESS${NC}"
        max_successful=$current_streams
        optimal_streams=$current_streams
    else
        local exit_code=$?
        if [ $exit_code -eq 1 ]; then
            echo "  ${RED}❌ $current_streams streams: LAUNCH FAILURES${NC}"
            break  # System limit reached
        else
            echo "  ${YELLOW}⚠️ $current_streams streams: LOW SUCCESS RATE${NC}"
        fi
    fi

    current_streams=$((current_streams + INCREMENT))
    echo ""
done

# Analysis
echo ""
echo "${CYAN}=== CAPACITY ANALYSIS ===${NC}"

if [ $max_successful -gt 0 ]; then
    echo "Maximum successful streams: $max_successful"
    echo "Recommended optimal: $optimal_streams"

    # Extract metrics for optimal configuration
    local optimal_data=$(grep "^$optimal_streams," "$OUTPUT_DIR/capacity_results.csv" | head -1)
    if [ -n "$optimal_data" ]; then
        IFS=',' read -r streams launched completed rate failures gpu_util gpu_mem nvenc <<< "$optimal_data"

        echo ""
        echo "Optimal Configuration Metrics:"
        echo "  Concurrent streams: $streams"
        echo "  Launch success: $launched/$streams"
        echo "  Completion success: $completed/$streams ($rate%)"
        echo "  GPU utilization: ${gpu_util}%"
        echo "  VRAM usage: ${gpu_mem}MB ($(echo "scale=1; $gpu_mem / 1024" | bc -l)GB)"
        echo "  NVENC sessions: $nvenc"

        # Recommendations
        echo ""
        echo "Production Recommendations:"
        echo "  Conservative: $(( optimal_streams * 80 / 100 )) concurrent streams"
        echo "  Optimal: $optimal_streams concurrent streams"
        echo "  Aggressive: $(( optimal_streams * 110 / 100 )) concurrent streams"
    fi
else
    echo "${RED}No successful configurations found!${NC}"
    echo "System may have very restrictive limits or GPU issues."
fi

echo ""
echo "Generated files:"
echo "  Results: $OUTPUT_DIR/capacity_results.csv"
echo "  Test data: $OUTPUT_DIR/test_*_streams/"

echo ""
echo "${GREEN}🚀 Capacity finding complete!${NC}"