#!/bin/bash

# Robust GPU Concurrent Transcoding Test
# Fixes fork/resource issues and ensures true concurrent processing

set -e

# Configuration
MAX_CONCURRENT=200
TEST_DURATION=60
BASE_OUTPUT_DIR="robust_test_$(date +%Y%m%d_%H%M%S)"
RESULTS_CSV="${BASE_OUTPUT_DIR}/concurrent_results.csv"
PROCESS_LOG="${BASE_OUTPUT_DIR}/processes.log"

# System limits
MAX_PROCESSES_PER_BATCH=25  # Prevent fork bombing
BATCH_DELAY=2               # Seconds between batches
MONITORING_INTERVAL=3       # Seconds between monitoring

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Create directories
mkdir -p "$BASE_OUTPUT_DIR/streams"
mkdir -p "$BASE_OUTPUT_DIR/logs"

# System resource check
check_system_limits() {
    echo -e "${YELLOW}Checking system limits...${NC}"

    # Check ulimit
    local max_processes=$(ulimit -u)
    local max_files=$(ulimit -n)

    echo "Max user processes: $max_processes"
    echo "Max open files: $max_files"

    # Increase limits if possible
    ulimit -n 65536 2>/dev/null || echo "Warning: Could not increase file limit"
    ulimit -u 32768 2>/dev/null || echo "Warning: Could not increase process limit"

    # Check available memory
    local available_ram=$(free -m | awk 'NR==2{print $7}')
    echo "Available RAM: ${available_ram}MB"

    if [ $available_ram -lt 4000 ]; then
        echo -e "${RED}Warning: Low available RAM. Consider reducing concurrent streams.${NC}"
    fi
}

# Initialize results
init_results() {
    cat > "$RESULTS_CSV" << EOF
timestamp,batch_id,target_streams,launched_streams,active_streams,failed_streams,gpu_util,gpu_mem_mb,nvenc_sessions,cpu_percent,load_avg,ram_used_mb
EOF

    echo "=== Process Log ===" > "$PROCESS_LOG"
    echo "Timestamp: $(date)" >> "$PROCESS_LOG"
    echo "" >> "$PROCESS_LOG"
}

# Generate synthetic video source
get_synthetic_source() {
    local index=$1
    local patterns=(
        "testsrc2=rate=30:size=1280x720:duration=300"
        "smptebars=rate=30:size=1280x720:duration=300"
        "mandelbrot=rate=30:size=1280x720:maxiter=50"
        "life=rate=30:size=1280x720:ratio=0.1:death_color=red"
        "cellauto=rate=30:size=1280x720:rule=30"
        "gradients=rate=30:size=1280x720:speed=1"
        "plasma=rate=30:size=1280x720"
        "rgbtestsrc=rate=30:size=1280x720"
    )

    # Add motion to make it more realistic
    local base_pattern="${patterns[$((index % ${#patterns[@]}))]}"
    local motion_effects=(
        ""
        ",rotate=angle=t*0.5:c=none"
        ",crop=w=iw*0.8:h=ih*0.8:x=iw*0.1:y=ih*0.1"
        ",scale=1920:1080,scale=1280:720"
    )

    echo "${base_pattern}${motion_effects[$((index % ${#motion_effects[@]}))]}"
}

# Launch single GPU stream with error handling
launch_gpu_stream() {
    local stream_id=$1
    local batch_id=$2
    local output_dir="${BASE_OUTPUT_DIR}/streams/batch_${batch_id}_stream_${stream_id}"

    mkdir -p "$output_dir"

    local source=$(get_synthetic_source $stream_id)

    # Use exec to avoid shell overhead
    exec ffmpeg \
        -hide_banner \
        -loglevel error \
        -stats_period 30 \
        -f lavfi \
        -i "$source" \
        -t $TEST_DURATION \
        -vf "scale_cuda=1280:720" \
        -hwaccel cuda \
        -hwaccel_output_format cuda \
        -c:v h264_nvenc \
        -preset p4 \
        -profile:v high \
        -rc vbr \
        -cq 36 \
        -b:v 2M \
        -maxrate 3M \
        -bufsize 6M \
        -g 60 \
        -bf 3 \
        -an \
        -f hls \
        -hls_time 6 \
        -hls_list_size 0 \
        -hls_flags delete_segments+append_list \
        -hls_segment_filename "${output_dir}/seg_%05d.ts" \
        "${output_dir}/playlist.m3u8" \
        2>"${output_dir}/error.log"
}

# Launch batch of streams with proper process management
launch_stream_batch() {
    local batch_size=$1
    local batch_id=$2

    echo -e "${BLUE}Launching batch $batch_id: $batch_size streams${NC}"

    local pids=()
    local launched=0
    local failed=0

    # Launch streams in smaller sub-batches to avoid overwhelming
    for ((i=0; i<batch_size; i++)); do
        local stream_global_id=$((batch_id * 1000 + i))

        # Fork wrapper script to handle stream
        (
            launch_gpu_stream $stream_global_id $batch_id
        ) &

        local pid=$!
        pids+=($pid)

        echo "$(date '+%H:%M:%S') - Batch $batch_id Stream $i PID: $pid" >> "$PROCESS_LOG"

        ((launched++))

        # Small delay every few streams to prevent resource exhaustion
        if [ $((i % 5)) -eq 4 ]; then
            sleep 0.1
        fi
    done

    echo -e "  ${GREEN}Launched $launched streams${NC}"
    echo "${pids[@]}"  # Return PIDs
}

# Monitor system and streams
monitor_streams() {
    local pids=("${!1}")
    local batch_id=$2
    local target_count=$3

    local start_time=$(date +%s)
    local monitoring_count=0

    while [ $(($(date +%s) - start_time)) -lt $TEST_DURATION ]; do
        sleep $MONITORING_INTERVAL
        ((monitoring_count++))

        # Count active processes
        local active=0
        local failed=0

        for pid in "${pids[@]}"; do
            if kill -0 $pid 2>/dev/null; then
                ((active++))
            else
                ((failed++))
            fi
        done

        # Get system metrics
        local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
        local gpu_mem=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
        local nvenc=$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
        local cpu=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 || echo 0)
        local load_avg=$(uptime | awk '{print $(NF-2)}' | cut -d',' -f1)
        local ram_used=$(free -m | awk 'NR==2{print $3}')

        # Progress display
        local elapsed=$(($(date +%s) - start_time))
        printf "\r  [%3ds] Active: %s%3d%s/%d | Failed: %s%2d%s | GPU: %s%3d%%%s | VRAM: %s%4dMB%s | NVENC: %s%2d%s | CPU: %3d%% | Load: %s" \
            $elapsed \
            "$GREEN" $active "$NC" $target_count \
            "$RED" $failed "$NC" \
            "$YELLOW" $gpu_util "$NC" \
            "$BLUE" $gpu_mem "$NC" \
            "$CYAN" $nvenc "$NC" \
            $cpu "$load_avg"

        # Log metrics
        echo "$(date +%s),$batch_id,$target_count,${#pids[@]},$active,$failed,$gpu_util,$gpu_mem,$nvenc,$cpu,$load_avg,$ram_used" >> "$RESULTS_CSV"

        # Check if all streams failed
        if [ $active -eq 0 ] && [ $elapsed -gt 10 ]; then
            echo -e "\n${RED}All streams failed, stopping test${NC}"
            break
        fi
    done

    echo ""
}

# Clean up processes
cleanup_batch() {
    local pids=("${!1}")

    echo -e "${YELLOW}Cleaning up batch...${NC}"

    # First try graceful termination
    for pid in "${pids[@]}"; do
        kill -TERM $pid 2>/dev/null || true
    done

    sleep 3

    # Force kill remaining
    for pid in "${pids[@]}"; do
        kill -KILL $pid 2>/dev/null || true
    done

    # Wait for cleanup
    sleep 2
}

# Main concurrent test function
run_concurrent_test() {
    local target_streams=$1

    echo -e "\n${YELLOW}=== Testing $target_streams Concurrent Streams ===${NC}"

    # Calculate batches to avoid resource exhaustion
    local batches=1
    local streams_per_batch=$target_streams

    if [ $target_streams -gt $MAX_PROCESSES_PER_BATCH ]; then
        batches=$(( (target_streams + MAX_PROCESSES_PER_BATCH - 1) / MAX_PROCESSES_PER_BATCH ))
        streams_per_batch=$MAX_PROCESSES_PER_BATCH
    fi

    echo "Will launch in $batches batch(es) of max $streams_per_batch streams each"

    local all_pids=()

    # Launch batches
    for ((batch=0; batch<batches; batch++)); do
        local remaining=$((target_streams - batch * streams_per_batch))
        local this_batch_size=$(( remaining < streams_per_batch ? remaining : streams_per_batch ))

        if [ $this_batch_size -le 0 ]; then
            break
        fi

        # Launch batch
        local batch_pids
        batch_pids=($(launch_stream_batch $this_batch_size $batch))
        all_pids+=("${batch_pids[@]}")

        # Delay between batches
        if [ $batch -lt $((batches - 1)) ]; then
            echo "  Waiting ${BATCH_DELAY}s before next batch..."
            sleep $BATCH_DELAY
        fi
    done

    echo -e "${GREEN}Total launched: ${#all_pids[@]} streams${NC}"

    # Monitor all streams
    monitor_streams all_pids[@] "multi" $target_streams

    # Cleanup
    cleanup_batch all_pids[@]

    # Count successful outputs
    local successful=$(find "${BASE_OUTPUT_DIR}/streams" -name "playlist.m3u8" | wc -l)
    echo -e "${GREEN}Successful streams: $successful/$target_streams${NC}"

    return $successful
}

# Generate test report
generate_report() {
    local max_successful=$1

    echo -e "\n${BLUE}Generating test report...${NC}"

    cat > "${BASE_OUTPUT_DIR}/test_report.md" << EOF
# GPU Concurrent Transcoding Test Report

**Date**: $(date)
**System**: $(uname -a)
**GPU**: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)

## Test Configuration
- Test Duration: ${TEST_DURATION}s per test
- Max Batch Size: $MAX_PROCESSES_PER_BATCH
- Output: HLS (1280x720, CQ36)
- Sources: Synthetic patterns only

## Results Summary
- Maximum successful concurrent streams: **$max_successful**
- Peak GPU utilization: $(awk -F',' 'NR>1 {if($7>max) max=$7} END {print max"%"}' "$RESULTS_CSV")
- Peak VRAM usage: $(awk -F',' 'NR>1 {if($8>max) max=$8} END {print max"MB"}' "$RESULTS_CSV")
- Peak NVENC sessions: $(awk -F',' 'NR>1 {if($9>max) max=$9} END {print max}' "$RESULTS_CSV")

## Files Generated
- Results CSV: $RESULTS_CSV
- Process Log: $PROCESS_LOG
- Stream Outputs: ${BASE_OUTPUT_DIR}/streams/
EOF

    echo "Report saved: ${BASE_OUTPUT_DIR}/test_report.md"
}

# Main execution
main() {
    echo -e "${GREEN}=== Robust GPU Concurrent Transcoding Test ===${NC}"

    # System checks
    check_system_limits

    # Initialize
    init_results

    # Test sequence
    test_counts=(5 10 20 30 50 75 100 150 200)
    local max_successful=0

    for count in "${test_counts[@]}"; do
        successful=$(run_concurrent_test $count)

        if [ $successful -ge $((count * 90 / 100)) ]; then
            max_successful=$count
        elif [ $successful -lt $((count * 50 / 100)) ]; then
            echo -e "${YELLOW}Success rate below 50%, stopping escalation${NC}"
            break
        fi

        # Cool down
        echo "Cooling down 15s..."
        sleep 15
    done

    # Generate report
    generate_report $max_successful

    echo -e "\n${GREEN}=== Test Complete ===${NC}"
    echo "Maximum reliable concurrent streams: $max_successful"
}

# Cleanup on exit
cleanup_on_exit() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    pkill -f "ffmpeg.*h264_nvenc" 2>/dev/null || true
    sleep 2
}

trap cleanup_on_exit EXIT INT TERM

# Run main
main "$@"