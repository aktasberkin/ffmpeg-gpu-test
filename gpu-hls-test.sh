#!/bin/bash

# GPU-Optimized HLS Streaming Test Script for L40S
# Tests concurrent RTSP to HLS transcoding using NVIDIA hardware acceleration

set -e

# Configuration
MAX_CONCURRENT_STREAMS=200
TEST_DURATION=60
OUTPUT_DIR="test_results/gpu_hls_$(date +%Y%m%d_%H%M%S)"
RESULTS_CSV="${OUTPUT_DIR}/results.csv"
GPU_LOG="${OUTPUT_DIR}/gpu_metrics.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Create output directory
mkdir -p "$OUTPUT_DIR"
mkdir -p "${OUTPUT_DIR}/streams"

# Initialize CSV
echo "timestamp,concurrent_streams,gpu_util,gpu_mem_mb,nvenc_sessions,cpu_percent,successful_streams,failed_streams,avg_fps,avg_bitrate_kbps" > "$RESULTS_CSV"

# Function to monitor GPU
monitor_gpu() {
    while true; do
        nvidia-smi --query-gpu=timestamp,utilization.gpu,memory.used,encoder.stats.sessionCount \
                   --format=csv,noheader >> "$GPU_LOG" 2>/dev/null || true
        sleep 2
    done
}

# Function to get test video sources
get_video_source() {
    local index=$1
    local sources=(
        "https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4"
        "https://download.blender.org/durian/trailer/sintel_trailer-720p.mp4"
        "https://sample-videos.com/video321/mp4/720/big_buck_bunny_720p_1mb.mp4"
        "rtsp://wowzaec2demo.streamlock.net/vod/mp4:BigBuckBunny_115k.mp4"
    )

    # If we have real camera URLs, use them first
    if [ -f "cameras_test.txt" ]; then
        local camera_count=$(wc -l < cameras_test.txt)
        if [ $index -lt $camera_count ]; then
            sed -n "$((index + 1))p" cameras_test.txt
            return
        fi
    fi

    # Use test sources with rotation
    echo "${sources[$((index % ${#sources[@]}))]}"
}

# Function to run single stream with GPU acceleration
run_gpu_stream() {
    local stream_id=$1
    local source=$2
    local output_dir="${OUTPUT_DIR}/streams/stream_${stream_id}"

    mkdir -p "$output_dir"

    # GPU-optimized FFmpeg command for HLS
    ffmpeg -loglevel error \
        -hwaccel cuda \
        -hwaccel_output_format cuda \
        -re \
        -i "$source" \
        -t $TEST_DURATION \
        -vf "scale_cuda=1280:720" \
        -c:v h264_nvenc \
        -preset p4 \
        -tune hq \
        -rc vbr \
        -cq 35 \
        -b:v 2M \
        -maxrate 3M \
        -bufsize 6M \
        -g 60 \
        -c:a copy \
        -f hls \
        -hls_time 6 \
        -hls_list_size 10 \
        -hls_flags append_list \
        -hls_segment_filename "${output_dir}/segment_%03d.ts" \
        "${output_dir}/playlist.m3u8" \
        2>"${output_dir}/ffmpeg.log" &

    echo $!
}

# Function to test concurrent streams
test_concurrent_streams() {
    local num_streams=$1
    echo -e "${YELLOW}Testing $num_streams concurrent streams...${NC}"

    local pids=()
    local start_time=$(date +%s)

    # Start streams
    for ((i=0; i<num_streams; i++)); do
        source=$(get_video_source $i)
        if [ -n "$source" ]; then
            pid=$(run_gpu_stream $i "$source")
            pids+=($pid)
            echo -e "  Started stream $i (PID: $pid)"
        fi

        # Small delay to avoid overwhelming the system
        if [ $((i % 10)) -eq 0 ] && [ $i -gt 0 ]; then
            sleep 0.5
        fi
    done

    echo -e "${GREEN}All $num_streams streams started${NC}"

    # Monitor for test duration
    local elapsed=0
    while [ $elapsed -lt $TEST_DURATION ]; do
        sleep 5
        elapsed=$(($(date +%s) - start_time))

        # Get current metrics
        local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
        local gpu_mem=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)
        local nvenc_sessions=$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader,nounits 2>/dev/null | head -1)
        local cpu_percent=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)

        # Count active streams
        local active_count=0
        for pid in "${pids[@]}"; do
            if kill -0 $pid 2>/dev/null; then
                ((active_count++))
            fi
        done

        echo -e "  [${elapsed}s] Active: $active_count/$num_streams | GPU: ${gpu_util}% | GPU Mem: ${gpu_mem}MB | NVENC: ${nvenc_sessions} | CPU: ${cpu_percent}%"

        # Log to CSV
        echo "$(date +%s),$num_streams,$gpu_util,$gpu_mem,$nvenc_sessions,$cpu_percent,$active_count,$((num_streams - active_count)),0,0" >> "$RESULTS_CSV"
    done

    # Stop all streams
    echo -e "${YELLOW}Stopping streams...${NC}"
    for pid in "${pids[@]}"; do
        kill $pid 2>/dev/null || true
    done

    # Wait for cleanup
    sleep 2

    # Count successful streams
    local successful=0
    for ((i=0; i<num_streams; i++)); do
        if [ -f "${OUTPUT_DIR}/streams/stream_${i}/playlist.m3u8" ]; then
            ((successful++))
        fi
    done

    echo -e "${GREEN}Test complete: $successful/$num_streams streams successful${NC}"
    echo ""
}

# Function to verify GPU support
verify_gpu_support() {
    echo -e "${YELLOW}Verifying GPU support...${NC}"

    # Check NVIDIA driver
    if ! nvidia-smi &>/dev/null; then
        echo -e "${RED}ERROR: nvidia-smi not found. Please install NVIDIA drivers.${NC}"
        exit 1
    fi

    # Check FFmpeg NVENC support
    if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_nvenc; then
        echo -e "${RED}ERROR: FFmpeg doesn't have NVENC support.${NC}"
        echo "Please install FFmpeg with NVENC: apt install ffmpeg"
        exit 1
    fi

    # Display GPU info
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader

    # Check NVENC capabilities
    echo -e "\n${GREEN}NVENC Capabilities:${NC}"
    nvidia-smi --query-gpu=encoder.stats.sessionCount,encoder.stats.sessionCountMax --format=csv,noheader

    echo ""
}

# Main execution
main() {
    echo -e "${GREEN}=== GPU-Optimized HLS Streaming Test ===${NC}"
    echo "Output directory: $OUTPUT_DIR"
    echo ""

    # Verify GPU support
    verify_gpu_support

    # Start GPU monitoring in background
    monitor_gpu &
    MONITOR_PID=$!

    # Test different concurrent stream counts
    test_counts=(2 5 10 20 30 50 75 100 125 150 175 200)

    for count in "${test_counts[@]}"; do
        test_concurrent_streams $count

        # Cool down between tests
        echo "Cooling down for 10 seconds..."
        sleep 10

        # Check if we're hitting limits
        if [ -f "$GPU_LOG" ]; then
            local last_nvenc=$(tail -1 "$GPU_LOG" | cut -d',' -f4)
            if [ "$last_nvenc" == "0" ] && [ $count -gt 50 ]; then
                echo -e "${YELLOW}Warning: NVENC sessions exhausted. Consider stopping test.${NC}"
            fi
        fi
    done

    # Stop GPU monitoring
    kill $MONITOR_PID 2>/dev/null || true

    # Generate summary
    echo -e "\n${GREEN}=== Test Summary ===${NC}"
    echo "Results saved to: $RESULTS_CSV"
    echo "GPU metrics saved to: $GPU_LOG"

    # Show peak performance
    echo -e "\n${YELLOW}Peak Performance:${NC}"
    sort -t',' -k3 -nr "$RESULTS_CSV" | head -5 | column -t -s','
}

# Run main function
main "$@"