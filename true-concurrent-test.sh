#!/bin/bash

# True Concurrent GPU Test - All streams start simultaneously
# No queues, no workers - pure concurrent processing

set -e

# Configuration
MAX_CONCURRENT=200
TEST_DURATION=60
OUTPUT_DIR="concurrent_test_$(date +%Y%m%d_%H%M%S)"
RESULTS_CSV="${OUTPUT_DIR}/concurrent_results.csv"
LAUNCH_TIMEOUT=30       # Max time to launch all streams

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Create directories
mkdir -p "$OUTPUT_DIR/streams"
mkdir -p "$OUTPUT_DIR/logs"

# System optimization
optimize_system() {
    echo -e "${YELLOW}Optimizing system for concurrent processing...${NC}"

    # Increase limits
    ulimit -n 65536 2>/dev/null || echo "Warning: Cannot increase file limit"
    ulimit -u 32768 2>/dev/null || echo "Warning: Cannot increase process limit"

    # Kernel parameters for high concurrency
    echo 1000000 > /proc/sys/fs/file-max 2>/dev/null || true
    echo 32768 > /proc/sys/kernel/pid_max 2>/dev/null || true

    # Show current limits
    echo "File descriptors: $(ulimit -n)"
    echo "Max processes: $(ulimit -u)"
    echo "Available memory: $(free -h | awk 'NR==2{print $7}')"
}

# Generate synthetic source
get_synthetic_source() {
    local stream_id=$1

    local patterns=(
        "testsrc2=size=1280x720:rate=30"
        "smptebars=size=1280x720:rate=30"
        "mandelbrot=size=1280x720:rate=30:maxiter=100"
        "life=size=1280x720:rate=30:ratio=0.1"
        "plasma=size=1280x720:rate=30"
        "cellauto=size=1280x720:rate=30:rule=30"
        "rgbtestsrc=size=1280x720:rate=30"
        "gradients=size=1280x720:rate=30"
    )

    # Add motion every few streams
    local base="${patterns[$((stream_id % ${#patterns[@]}))]}"
    if [ $((stream_id % 4)) -eq 0 ]; then
        echo "${base},rotate=angle=t*0.3:c=black"
    else
        echo "$base"
    fi
}

# Launch single FFmpeg stream (background process)
launch_stream() {
    local stream_id=$1
    local output_dir="${OUTPUT_DIR}/streams/stream_${stream_id}"

    mkdir -p "$output_dir"

    local source=$(get_synthetic_source $stream_id)

    # Direct FFmpeg execution (no shell wrapper to reduce overhead)
    ffmpeg \
        -hide_banner \
        -loglevel error \
        -nostats \
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
        -bf 2 \
        -an \
        -f hls \
        -hls_time 6 \
        -hls_list_size 0 \
        -hls_flags delete_segments+append_list \
        -hls_segment_filename "${output_dir}/seg_%05d.ts" \
        "${output_dir}/playlist.m3u8" \
        2>"${output_dir}/error.log" &

    echo $!  # Return PID
}

# Monitor all concurrent streams
monitor_concurrent_streams() {
    local pids=("${!1}")
    local target_count=$2
    local test_name=$3

    local start_time=$(date +%s)
    local launch_complete_time=$start_time

    echo -e "${GREEN}Monitoring ${#pids[@]} concurrent streams...${NC}"

    # Initialize CSV
    cat > "$RESULTS_CSV" << EOF
timestamp,elapsed,target_streams,active_streams,completed_streams,failed_streams,gpu_util,gpu_mem_mb,gpu_temp,nvenc_sessions,cpu_percent,load_avg,ram_used_mb
EOF

    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        # Count process states
        local active=0
        local completed=0
        local failed=0

        for pid in "${pids[@]}"; do
            if kill -0 $pid 2>/dev/null; then
                ((active++))
            else
                # Check if completed successfully
                wait $pid 2>/dev/null
                local exit_code=$?
                if [ $exit_code -eq 0 ]; then
                    ((completed++))
                else
                    ((failed++))
                fi
            fi
        done

        # Get system metrics
        local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
        local gpu_mem=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
        local gpu_temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
        local nvenc=$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
        local cpu=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 2>/dev/null || echo 0)
        local load_avg=$(uptime | awk '{print $(NF-2)}' | cut -d',' -f1 2>/dev/null || echo 0)
        local ram_used=$(free -m | awk 'NR==2{print $3}' 2>/dev/null || echo 0)

        # Real-time display
        printf "\r[%3ds] Active: %s%3d%s | Done: %s%3d%s | Failed: %s%2d%s | GPU: %s%3d%%%s(%d°C) | VRAM: %s%5dMB%s | NVENC: %s%2d%s | CPU: %3d%% | Load: %s" \
            $elapsed \
            "$GREEN" $active "$NC" \
            "$BLUE" $completed "$NC" \
            "$RED" $failed "$NC" \
            "$YELLOW" $gpu_util "$NC" $gpu_temp \
            "$CYAN" $gpu_mem "$NC" \
            "$MAGENTA" $nvenc "$NC" \
            $cpu "$load_avg"

        # Log to CSV
        echo "$current_time,$elapsed,$target_count,$active,$completed,$failed,$gpu_util,$gpu_mem,$gpu_temp,$nvenc,$cpu,$load_avg,$ram_used" >> "$RESULTS_CSV"

        # Check completion conditions
        if [ $active -eq 0 ]; then
            echo -e "\n${GREEN}All streams finished${NC}"
            break
        fi

        # Safety timeout
        if [ $elapsed -gt $((TEST_DURATION + 30)) ]; then
            echo -e "\n${YELLOW}Test timeout reached${NC}"
            break
        fi

        sleep 2
    done

    # Final summary
    local total_completed=$completed
    local total_failed=$failed
    local success_rate=$((total_completed * 100 / target_count))

    echo -e "\n${BLUE}Final Results:${NC}"
    echo "  Target streams: $target_count"
    echo "  Successful: $total_completed"
    echo "  Failed: $total_failed"
    echo "  Success rate: $success_rate%"

    return $success_rate
}

# Launch all streams simultaneously
launch_concurrent_streams() {
    local num_streams=$1

    echo -e "\n${YELLOW}=== Launching $num_streams Concurrent Streams ===${NC}"

    local pids=()
    local launch_start=$(date +%s)

    echo -e "${BLUE}Starting stream launches...${NC}"

    # Launch all streams as fast as possible
    for ((i=0; i<num_streams; i++)); do
        local pid=$(launch_stream $i)
        pids+=($pid)

        # Progress indicator (don't slow down with frequent prints)
        if [ $((i % 25)) -eq 0 ] || [ $i -eq $((num_streams-1)) ]; then
            printf "\r  Launched: %d/%d" $((i+1)) $num_streams
        fi

        # Micro-delay to prevent overwhelming (but keep it concurrent)
        if [ $((i % 50)) -eq 0 ] && [ $i -gt 0 ]; then
            sleep 0.05
        fi
    done

    local launch_end=$(date +%s)
    local launch_time=$((launch_end - launch_start))

    echo -e "\n${GREEN}All $num_streams streams launched in ${launch_time}s${NC}"
    echo "PIDs: ${#pids[@]} processes created"

    # Monitor the concurrent execution
    monitor_concurrent_streams pids[@] $num_streams "concurrent_$num_streams"
}

# Clean up any remaining processes
cleanup_processes() {
    echo -e "\n${YELLOW}Cleaning up processes...${NC}"

    # Kill all FFmpeg processes
    pkill -f "ffmpeg.*h264_nvenc" 2>/dev/null || true

    # Wait for cleanup
    sleep 3

    # Force kill if any remain
    pkill -9 -f "ffmpeg.*h264_nvenc" 2>/dev/null || true

    echo -e "${GREEN}Cleanup complete${NC}"
}

# Main test function
run_concurrent_test() {
    local target_streams=$1

    # Pre-test system check
    local available_ram=$(free -m | awk 'NR==2{print $7}')
    if [ $available_ram -lt 2000 ]; then
        echo -e "${RED}Warning: Low RAM ($available_ram MB). Test may fail.${NC}"
    fi

    # Check if target is reasonable
    if [ $target_streams -gt 500 ]; then
        echo -e "${RED}Warning: $target_streams streams may exceed system capacity${NC}"
        read -p "Continue? (y/N): " confirm
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    # Launch and monitor
    local success_rate
    success_rate=$(launch_concurrent_streams $target_streams)

    # Cleanup
    cleanup_processes

    return $success_rate
}

# Main execution
main() {
    echo -e "${GREEN}=== True Concurrent GPU Stream Test ===${NC}"
    echo "Target: Simultaneous launch of multiple FFmpeg processes"
    echo ""

    # System optimization
    optimize_system
    echo ""

    # GPU check
    if ! nvidia-smi &>/dev/null; then
        echo -e "${RED}ERROR: NVIDIA GPU not detected${NC}"
        exit 1
    fi

    echo -e "${BLUE}GPU Info:${NC}"
    nvidia-smi --query-gpu=name,memory.total,encoder.stats.sessionCountMax --format=csv
    echo ""

    # Test sequence - progressive concurrent load
    test_levels=(5 10 20 30 50 75 100 150 200)
    local max_successful=0

    for level in "${test_levels[@]}"; do
        success_rate=$(run_concurrent_test $level)

        if [ $success_rate -ge 85 ]; then
            max_successful=$level
        elif [ $success_rate -lt 50 ]; then
            echo -e "${YELLOW}Success rate dropped below 50%, stopping${NC}"
            break
        fi

        # Cool down between tests
        echo -e "\n${BLUE}Cooling down 15 seconds...${NC}"
        sleep 15
    done

    # Final summary
    echo -e "\n${GREEN}=== Test Complete ===${NC}"
    echo "Maximum successful concurrent streams: $max_successful"
    echo "Results saved in: $OUTPUT_DIR/"

    # Show peak performance
    if [ -f "$RESULTS_CSV" ]; then
        echo -e "\n${BLUE}Peak Performance:${NC}"
        echo "GPU Utilization: $(awk -F',' 'NR>1 {if($7>max) max=$7} END {print max"%"}' "$RESULTS_CSV")"
        echo "VRAM Usage: $(awk -F',' 'NR>1 {if($8>max) max=$8} END {print max"MB"}' "$RESULTS_CSV")"
        echo "NVENC Sessions: $(awk -F',' 'NR>1 {if($10>max) max=$10} END {print max}' "$RESULTS_CSV")"
    fi
}

# Cleanup on exit
trap cleanup_processes EXIT INT TERM

# Run
main "$@"