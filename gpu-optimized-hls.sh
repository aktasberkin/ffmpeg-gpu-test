#!/bin/bash

# GPU-Optimized HLS Transcoding Test for L40S
# Replicates your exact use case with GPU acceleration

set -e

# Configuration matching your requirements
MAX_CONCURRENT=200
TEST_DURATION=60
BASE_OUTPUT_DIR="hls_output"
RESULTS_FILE="gpu_hls_results.csv"

# Your original settings
HLS_TIME=6
HLS_LIST_SIZE=10
OUTPUT_WIDTH=1280
OUTPUT_HEIGHT=720
TARGET_CRF=36  # Your original quality level

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Clean previous runs
rm -rf "$BASE_OUTPUT_DIR"
mkdir -p "$BASE_OUTPUT_DIR"

# Initialize results
echo "test_id,timestamp,concurrent_streams,gpu_util,gpu_mem_mb,nvenc_sessions,cpu_percent,success_rate,avg_bitrate_kbps,quality_score" > "$RESULTS_FILE"

# Function to get video source
get_source() {
    local index=$1

    # First try real cameras
    if [ -f "cameras_test.txt" ]; then
        local camera_count=$(wc -l < cameras_test.txt)
        if [ $index -lt $camera_count ]; then
            sed -n "$((index + 1))p" cameras_test.txt
            return
        fi
    fi

    # Then use test files
    if [ -f "expanded_test_sources.txt" ]; then
        local line_num=$((index + 1))
        sed -n "${line_num}p" expanded_test_sources.txt
    elif [ -f "test_file_sources.txt" ]; then
        # Rotate through available test files
        local file_count=$(wc -l < test_file_sources.txt)
        local file_index=$((index % file_count + 1))
        sed -n "${file_index}p" test_file_sources.txt
    else
        # Fallback to test pattern
        echo "testsrc2=rate=30:size=1280x720"
    fi
}

# GPU-optimized FFmpeg command matching your quality requirements
run_gpu_hls_stream() {
    local stream_id=$1
    local source=$2
    local output_dir="${BASE_OUTPUT_DIR}/stream_${stream_id}"

    mkdir -p "$output_dir"

    # Determine input type
    local input_args=""
    if [[ "$source" == rtsp://* ]]; then
        input_args="-rtsp_transport tcp -i \"$source\""
    elif [[ "$source" == *.mp4 ]] || [[ "$source" == *.ts ]]; then
        input_args="-re -stream_loop -1 -i \"$source\""
    else
        input_args="-f lavfi -i \"$source\""
    fi

    # GPU-accelerated command optimized for quality and performance
    eval ffmpeg -loglevel error -stats_period 10 \
        -hwaccel cuda \
        -hwaccel_output_format cuda \
        $input_args \
        -t $TEST_DURATION \
        -vf "scale_cuda=${OUTPUT_WIDTH}:${OUTPUT_HEIGHT}:interp_algo=lanczos" \
        -c:v h264_nvenc \
        -preset p4 \
        -profile:v high \
        -level:v 4.1 \
        -rc:v vbr \
        -cq:v $TARGET_CRF \
        -qmin 25 -qmax 40 \
        -b:v 2M -maxrate:v 3M -bufsize:v 6M \
        -spatial-aq 1 -temporal-aq 1 \
        -b_ref_mode 2 \
        -g 60 -keyint_min 30 \
        -c:a copy \
        -f hls \
        -hls_time $HLS_TIME \
        -hls_list_size $HLS_LIST_SIZE \
        -hls_flags append_list+delete_segments+program_date_time \
        -hls_segment_type mpegts \
        -hls_segment_filename "${output_dir}/segment_%Y%m%d_%H%M%S_%03d.ts" \
        -master_pl_name "master.m3u8" \
        "${output_dir}/playlist.m3u8" \
        2>"${output_dir}/ffmpeg.log" &

    echo $!
}

# Compare with CPU version for reference
run_cpu_hls_stream() {
    local stream_id=$1
    local source=$2
    local output_dir="${BASE_OUTPUT_DIR}/cpu_stream_${stream_id}"

    mkdir -p "$output_dir"

    # Your original CPU command
    ffmpeg -loglevel error \
        -re -i "$source" \
        -t 30 \
        -vf scale=${OUTPUT_WIDTH}:${OUTPUT_HEIGHT} \
        -c:v libx264 -crf $TARGET_CRF -preset medium \
        -f hls \
        -hls_time $HLS_TIME \
        -hls_flags append_list \
        -hls_segment_filename "${output_dir}/segment_%Y%m%d_%H%M%S.ts" \
        "${output_dir}/playlist.m3u8" \
        2>"${output_dir}/ffmpeg.log" &

    echo $!
}

# Monitor system metrics
monitor_system() {
    local test_id=$1
    local num_streams=$2
    local pids=("${!3}")

    local start_time=$(date +%s)
    local elapsed=0

    while [ $elapsed -lt $TEST_DURATION ]; do
        sleep 5
        elapsed=$(($(date +%s) - start_time))

        # GPU metrics
        local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | head -1)
        local gpu_mem=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
        local nvenc_sessions=$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader,nounits | head -1)

        # CPU metrics
        local cpu_percent=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)

        # Count active streams
        local active=0
        for pid in "${pids[@]}"; do
            if kill -0 $pid 2>/dev/null; then
                ((active++))
            fi
        done

        local success_rate=$((active * 100 / num_streams))

        echo -e "  [${elapsed}/${TEST_DURATION}s] Active: ${GREEN}$active/$num_streams${NC} | GPU: ${YELLOW}${gpu_util}%${NC} | VRAM: ${BLUE}${gpu_mem}MB${NC} | NVENC: ${nvenc_sessions} | CPU: ${cpu_percent}%"

        # Log metrics
        echo "$test_id,$(date +%s),$num_streams,$gpu_util,$gpu_mem,$nvenc_sessions,$cpu_percent,$success_rate,0,0" >> "$RESULTS_FILE"
    done
}

# Test function
run_concurrent_test() {
    local num_streams=$1
    local test_type=$2  # "gpu" or "cpu"

    echo -e "\n${YELLOW}=== Testing $num_streams concurrent $test_type streams ===${NC}"

    local pids=()
    local start_time=$(date +%s)

    # Generate test sources if needed
    if [ ! -f "test_file_sources.txt" ] && [ ! -f "cameras_test.txt" ]; then
        echo -e "${YELLOW}Generating test sources...${NC}"
        bash generate-test-sources.sh
    fi

    # Start streams
    echo -e "${BLUE}Starting streams...${NC}"
    for ((i=0; i<num_streams; i++)); do
        source=$(get_source $i)

        if [ "$test_type" == "gpu" ]; then
            pid=$(run_gpu_hls_stream $i "$source")
        else
            pid=$(run_cpu_hls_stream $i "$source")
        fi

        pids+=($pid)

        # Progress indicator
        if [ $((i % 10)) -eq 0 ]; then
            echo -ne "\r  Started: $i/$num_streams"
        fi

        # Small delay to avoid overwhelming
        if [ $((i % 20)) -eq 0 ] && [ $i -gt 0 ]; then
            sleep 0.2
        fi
    done
    echo -e "\r  Started: ${GREEN}$num_streams/$num_streams${NC}"

    # Monitor the test
    monitor_system "${test_type}_${num_streams}" $num_streams pids[@]

    # Stop streams
    echo -e "${YELLOW}Stopping streams...${NC}"
    for pid in "${pids[@]}"; do
        kill $pid 2>/dev/null || true
    done
    wait

    # Analyze results
    local successful=0
    local total_size=0
    for ((i=0; i<num_streams; i++)); do
        if [ "$test_type" == "gpu" ]; then
            dir="${BASE_OUTPUT_DIR}/stream_${i}"
        else
            dir="${BASE_OUTPUT_DIR}/cpu_stream_${i}"
        fi

        if [ -f "${dir}/playlist.m3u8" ]; then
            ((successful++))
            local size=$(du -sk "$dir" | cut -f1)
            total_size=$((total_size + size))
        fi
    done

    local avg_size=0
    if [ $successful -gt 0 ]; then
        avg_size=$((total_size / successful))
    fi

    echo -e "${GREEN}Results:${NC}"
    echo "  Successful streams: $successful/$num_streams"
    echo "  Success rate: $((successful * 100 / num_streams))%"
    echo "  Average output size: ${avg_size}KB per stream"

    # Cool down
    sleep 5
}

# Main execution
main() {
    echo -e "${GREEN}=== GPU-Optimized HLS Transcoding Test ===${NC}"
    echo "Target: L40S GPU on RunPod"
    echo "Goal: 100-200 concurrent HLS streams"
    echo ""

    # Check GPU
    if ! nvidia-smi &>/dev/null; then
        echo -e "${RED}ERROR: No NVIDIA GPU detected${NC}"
        exit 1
    fi

    echo -e "${BLUE}GPU Information:${NC}"
    nvidia-smi --query-gpu=name,memory.total,encoder.stats.sessionCountMax --format=csv,noheader
    echo ""

    # Check FFmpeg NVENC support
    if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_nvenc; then
        echo -e "${RED}ERROR: FFmpeg NVENC support not found${NC}"
        exit 1
    fi

    # Progressive test sequence
    test_sequence=(2 5 10 20 30 50 75 100 150 200)

    echo -e "${YELLOW}Starting progressive load test...${NC}"

    for count in "${test_sequence[@]}"; do
        run_concurrent_test $count "gpu"

        # Check if we're hitting limits
        local last_nvenc=$(tail -1 "$RESULTS_FILE" | cut -d',' -f6)
        if [ "$last_nvenc" == "0" ] && [ $count -ge 100 ]; then
            echo -e "${YELLOW}Warning: NVENC session limit reached${NC}"
            break
        fi
    done

    # Optional: Run CPU comparison with small number
    echo -e "\n${YELLOW}Running CPU comparison test (5 streams)...${NC}"
    run_concurrent_test 5 "cpu"

    # Summary
    echo -e "\n${GREEN}=== Test Complete ===${NC}"
    echo "Results saved to: $RESULTS_FILE"
    echo ""
    echo "Peak GPU performance:"
    sort -t',' -k3 -nr "$RESULTS_FILE" | head -5 | column -t -s','
}

# Run
main "$@"