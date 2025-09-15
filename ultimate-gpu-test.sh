#!/bin/bash

# Ultimate GPU Concurrent Stream Test for L40S
# Tests maximum concurrent HLS transcoding capacity

set -e

# Configuration
TARGET_STREAMS=200      # Ultimate target
TEST_DURATION=60        # Duration per test
WARMUP_DURATION=10      # Warmup period
OUTPUT_BASE="gpu_test_$(date +%Y%m%d_%H%M%S)"
RESULTS_DIR="${OUTPUT_BASE}_results"
STREAMS_DIR="${OUTPUT_BASE}_streams"
REPORT_FILE="${RESULTS_DIR}/test_report.md"
METRICS_CSV="${RESULTS_DIR}/metrics.csv"

# Your specific requirements
HLS_TIME=6
HLS_SEGMENT_TYPE="mpegts"
OUTPUT_RESOLUTION="1280:720"
TARGET_QUALITY=36  # CRF equivalent for NVENC

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Create directories
mkdir -p "$RESULTS_DIR" "$STREAMS_DIR"

# Initialize CSV
cat > "$METRICS_CSV" << EOF
timestamp,test_name,target_streams,active_streams,gpu_util,gpu_mem_mb,gpu_temp,nvenc_sessions,cpu_percent,ram_mb,success_rate,avg_fps,avg_bitrate_kbps
EOF

# Function to print colored status
print_status() {
    echo -e "${2}${1}${NC}"
}

# Function to check system requirements
check_requirements() {
    print_status "=== System Requirements Check ===" "$CYAN"

    # Check GPU
    if ! command -v nvidia-smi &> /dev/null; then
        print_status "ERROR: nvidia-smi not found. Please install NVIDIA drivers." "$RED"
        exit 1
    fi

    # Get GPU info
    local gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
    local gpu_memory=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -1)
    local max_nvenc=$(nvidia-smi --query-gpu=encoder.stats.sessionCountMax --format=csv,noheader | head -1)

    print_status "GPU: $gpu_name" "$GREEN"
    print_status "VRAM: $gpu_memory" "$GREEN"
    print_status "Max NVENC Sessions: $max_nvenc" "$GREEN"

    # Check FFmpeg
    if ! command -v ffmpeg &> /dev/null; then
        print_status "ERROR: ffmpeg not found" "$RED"
        exit 1
    fi

    # Check NVENC support
    if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_nvenc; then
        print_status "ERROR: FFmpeg NVENC support not found" "$RED"
        exit 1
    fi

    print_status "FFmpeg NVENC: Available" "$GREEN"
    echo ""
}

# Function to generate video source
get_video_source() {
    local index=$1

    # Use only synthetic patterns and test videos (NO cameras)
    # Priority order:
    # 1. Generated test videos (if available)
    # 2. FFmpeg synthetic patterns

    if [ -f "test_file_sources.txt" ]; then
        local file_count=$(wc -l < test_file_sources.txt 2>/dev/null || echo 0)
        if [ $file_count -gt 0 ]; then
            local file_index=$((index % file_count + 1))
            sed -n "${file_index}p" test_file_sources.txt
            return
        fi
    fi

    # Use synthetic patterns with variety and motion
    local patterns=(
        "testsrc2=rate=30:size=1280x720"
        "smptebars=rate=30:size=1280x720"
        "mandelbrot=rate=30:size=1280x720:maxiter=100"
        "life=rate=30:size=1280x720:ratio=0.1"
        "cellauto=rate=30:size=1280x720:rule=30"
        "plasma=rate=30:size=1280x720"
        "rgbtestsrc=rate=30:size=1280x720"
        "gradients=rate=30:size=1280x720"
    )

    # Add some motion to make it more realistic
    local base_pattern="${patterns[$((index % ${#patterns[@]}))]}"
    if [ $((index % 3)) -eq 0 ]; then
        echo "${base_pattern},rotate=angle=t*0.5:c=none"
    else
        echo "$base_pattern"
    fi
}

# Optimized GPU FFmpeg command
launch_gpu_stream() {
    local stream_id=$1
    local source=$2
    local output_dir="${STREAMS_DIR}/stream_${stream_id}"

    mkdir -p "$output_dir"

    # Determine input type and arguments
    local input_cmd=""
    if [[ "$source" == rtsp://* ]]; then
        input_cmd="-rtsp_transport tcp -buffer_size 1024000 -i '$source'"
    elif [[ -f "$source" ]]; then
        input_cmd="-re -stream_loop -1 -i '$source'"
    else
        input_cmd="-f lavfi -i '$source'"
    fi

    # Launch FFmpeg with GPU acceleration
    eval ffmpeg -hide_banner -loglevel error \
        -hwaccel cuda \
        -hwaccel_output_format cuda \
        $input_cmd \
        -t $TEST_DURATION \
        -vf "scale_cuda=$OUTPUT_RESOLUTION:interp_algo=lanczos" \
        -c:v h264_nvenc \
        -preset p4 \
        -profile:v high \
        -rc vbr \
        -cq $TARGET_QUALITY \
        -b:v 2M \
        -maxrate 3M \
        -bufsize 6M \
        -g 60 \
        -c:a copy \
        -f hls \
        -hls_time $HLS_TIME \
        -hls_list_size 10 \
        -hls_flags append_list+delete_segments \
        -hls_segment_type $HLS_SEGMENT_TYPE \
        -hls_segment_filename "'${output_dir}/seg_%03d.ts'" \
        "'${output_dir}/playlist.m3u8'" \
        2>"'${output_dir}/error.log'" &

    echo $!
}

# Monitor system during test
monitor_performance() {
    local test_name=$1
    local target=$2
    local pids=("${!3}")
    local duration=$4

    local start_time=$(date +%s)
    local elapsed=0

    while [ $elapsed -lt $duration ]; do
        sleep 2
        elapsed=$(($(date +%s) - start_time))

        # Collect metrics
        local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
        local gpu_mem=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
        local gpu_temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
        local nvenc=$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
        local cpu=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 || echo 0)
        local ram=$(free -m | awk 'NR==2{print $3}')

        # Count active streams
        local active=0
        for pid in "${pids[@]}"; do
            if kill -0 $pid 2>/dev/null; then
                ((active++))
            fi
        done

        local success_rate=$((active * 100 / target))

        # Display status
        printf "\r  [%3ds/%3ds] Streams: %s%3d/%3d%s | GPU: %s%3d%%%s | VRAM: %s%4dMB%s | Temp: %s%2d°C%s | NVENC: %s%2d%s | CPU: %3d%%  " \
            $elapsed $duration \
            "$GREEN" $active $target "$NC" \
            "$YELLOW" $gpu_util "$NC" \
            "$BLUE" $gpu_mem "$NC" \
            "$MAGENTA" $gpu_temp "$NC" \
            "$CYAN" $nvenc "$NC" \
            $cpu

        # Log to CSV
        echo "$(date +%s),$test_name,$target,$active,$gpu_util,$gpu_mem,$gpu_temp,$nvenc,$cpu,$ram,$success_rate,0,0" >> "$METRICS_CSV"
    done
    echo ""
}

# Run concurrent stream test
run_stream_test() {
    local num_streams=$1
    local test_name="test_${num_streams}_streams"

    print_status "\n=== Testing $num_streams Concurrent Streams ===" "$YELLOW"

    local pids=()

    # Launch streams
    print_status "Launching streams..." "$BLUE"
    for ((i=0; i<num_streams; i++)); do
        source=$(get_video_source $i)
        pid=$(launch_gpu_stream $i "$source")
        pids+=($pid)

        # Progress indicator
        if [ $((i % 10)) -eq 0 ]; then
            printf "\r  Launched: %d/%d" $i $num_streams
        fi

        # Stagger launches to avoid overwhelming
        if [ $((i % 25)) -eq 0 ] && [ $i -gt 0 ]; then
            sleep 0.5
        fi
    done
    printf "\r  Launched: %s%d/%d%s\n" "$GREEN" $num_streams $num_streams "$NC"

    # Monitor performance
    monitor_performance "$test_name" $num_streams pids[@] $TEST_DURATION

    # Cleanup
    print_status "Stopping streams..." "$YELLOW"
    for pid in "${pids[@]}"; do
        kill $pid 2>/dev/null || true
    done
    wait

    # Analyze results
    local successful=0
    local total_segments=0
    for ((i=0; i<num_streams; i++)); do
        if [ -f "${STREAMS_DIR}/stream_${i}/playlist.m3u8" ]; then
            ((successful++))
            local segments=$(ls "${STREAMS_DIR}/stream_${i}/"*.ts 2>/dev/null | wc -l)
            total_segments=$((total_segments + segments))
        fi
    done

    local success_rate=$((successful * 100 / num_streams))
    local avg_segments=0
    if [ $successful -gt 0 ]; then
        avg_segments=$((total_segments / successful))
    fi

    print_status "Results:" "$GREEN"
    echo "  Successful: $successful/$num_streams ($success_rate%)"
    echo "  Average segments per stream: $avg_segments"

    # Clean stream files to save space
    rm -rf "${STREAMS_DIR:?}/"*

    return $success_rate
}

# Generate test report
generate_report() {
    cat > "$REPORT_FILE" << EOF
# GPU Concurrent Stream Test Report

**Date**: $(date)
**System**: $(uname -a)
**GPU**: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)

## Test Configuration
- Target Quality: CRF $TARGET_QUALITY equivalent
- Output Resolution: $OUTPUT_RESOLUTION
- HLS Segment Time: ${HLS_TIME}s
- Test Duration: ${TEST_DURATION}s per test

## Test Results

| Streams | Success Rate | Max GPU% | Max VRAM (MB) | Max NVENC | Avg CPU% |
|---------|-------------|----------|---------------|-----------|----------|
EOF

    # Parse CSV for summary
    tail -n +2 "$METRICS_CSV" | awk -F',' '
    {
        streams[$2] = $3
        if ($5 > max_gpu[$2]) max_gpu[$2] = $5
        if ($6 > max_vram[$2]) max_vram[$2] = $6
        if ($8 > max_nvenc[$2]) max_nvenc[$2] = $8
        cpu_sum[$2] += $9
        cpu_count[$2]++
        success[$2] = $11
    }
    END {
        for (test in streams) {
            avg_cpu = cpu_sum[test] / cpu_count[test]
            printf "| %d | %d%% | %d%% | %d | %d | %.1f%% |\n",
                streams[test], success[test], max_gpu[test],
                max_vram[test], max_nvenc[test], avg_cpu
        }
    }' >> "$REPORT_FILE"

    echo "" >> "$REPORT_FILE"
    echo "## Recommendations" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    # Find optimal stream count
    local optimal=$(tail -n +2 "$METRICS_CSV" | awk -F',' '$11 >= 95 {print $3}' | sort -n | tail -1)
    echo "- Optimal concurrent streams: **$optimal**" >> "$REPORT_FILE"
    echo "- Full report: $REPORT_FILE" >> "$REPORT_FILE"
    echo "- Metrics data: $METRICS_CSV" >> "$REPORT_FILE"
}

# Main test execution
main() {
    print_status "=== Ultimate GPU Concurrent Stream Test ===" "$GREEN"
    echo ""

    # Check requirements
    check_requirements

    # Generate test sources if needed
    if [ ! -f "expanded_test_sources.txt" ] && [ ! -f "test_file_sources.txt" ]; then
        print_status "Generating test sources..." "$YELLOW"
        if [ -f "generate-test-sources.sh" ]; then
            bash generate-test-sources.sh
        fi
    fi

    # Test sequence - progressive load
    test_counts=(2 5 10 20 30 50 75 100 125 150 175 200)

    print_status "Starting progressive load tests..." "$CYAN"
    echo ""

    local max_successful=0
    for count in "${test_counts[@]}"; do
        success_rate=$(run_stream_test $count)

        if [ $success_rate -ge 95 ]; then
            max_successful=$count
        elif [ $success_rate -lt 50 ]; then
            print_status "Stopping tests - success rate below 50%" "$YELLOW"
            break
        fi

        # Cool down between tests
        print_status "Cooling down..." "$BLUE"
        sleep 10
    done

    # Generate final report
    print_status "\nGenerating report..." "$CYAN"
    generate_report

    # Display summary
    print_status "\n=== Test Complete ===" "$GREEN"
    echo "Maximum successful concurrent streams: $max_successful"
    echo "Results saved to: $RESULTS_DIR/"
    echo ""
    cat "$REPORT_FILE"
}

# Handle cleanup on exit
cleanup() {
    print_status "\nCleaning up..." "$YELLOW"
    pkill -f "ffmpeg.*h264_nvenc" 2>/dev/null || true
    exit 0
}

trap cleanup INT TERM

# Run main
main "$@"