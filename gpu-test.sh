#!/bin/bash

# GPU Concurrent Testing Script for RunPod
# Tests concurrent camera streams using NVIDIA GPU encoding

# Configuration
RESULTS_DIR="./test_results"
TEST_DURATION=60  # 1 minute per test
SAMPLE_INTERVAL=5  # Sample every 5 seconds
LOG_FILE="${RESULTS_DIR}/gpu_concurrent.log"
CSV_FILE="${RESULTS_DIR}/gpu_concurrent_results.csv"
TEMP_DIR="${RESULTS_DIR}/temp_tests_gpu"
DEBUG_MODE=${DEBUG:-0}

# Test configuration
CONCURRENT_TESTS=(2 5 10 20 30 50 75 100 125 150)
MAX_RETRIES=3

# GPU encoding parameters
GPU_ENCODER="h264_nvenc"  # or hevc_nvenc for H.265
GPU_PRESET="p1"  # p1 (fastest) to p7 (slowest)
GPU_TUNE="ll"  # low latency
GPU_RC="vbr"  # rate control: vbr, cbr
GPU_CQ="30"  # constant quality (23-51, lower = better quality)

# Test stream sources
declare -a TEST_STREAMS

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local message="$1"
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $message"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
}

error() {
    local message="$1"
    echo -e "${RED}[ERROR]${NC} $message" >&2
    echo "[ERROR] $message" >> "$LOG_FILE"
}

# Generate test streams
generate_test_streams() {
    log "Generating test stream URLs..."
    
    # Method 1: Use public test streams
    TEST_STREAMS+=(
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4"
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4"
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4"
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4"
    )
    
    # Method 2: Generate synthetic streams using FFmpeg test sources
    # These will be created as needed during tests
    for i in {1..150}; do
        # Use different test patterns for variety
        case $((i % 5)) in
            0) pattern="testsrc2" ;;
            1) pattern="smptebars" ;;
            2) pattern="rgbtestsrc" ;;
            3) pattern="yuvtestsrc" ;;
            4) pattern="mandelbrot" ;;
        esac
        TEST_STREAMS+=("synthetic:${pattern}:${i}")
    done
    
    log "Generated ${#TEST_STREAMS[@]} test stream sources"
}

# Get stream URL by index
get_stream_url() {
    local index=$1
    local stream_count=${#TEST_STREAMS[@]}
    
    # Wrap around if we need more streams than available
    local actual_index=$(( (index - 1) % stream_count ))
    local stream="${TEST_STREAMS[$actual_index]}"
    
    # Check if it's a synthetic stream
    if [[ "$stream" == synthetic:* ]]; then
        # Parse synthetic stream format
        local pattern=$(echo "$stream" | cut -d: -f2)
        local id=$(echo "$stream" | cut -d: -f3)
        
        # Return FFmpeg test source as input
        echo "-f lavfi -i ${pattern}=duration=${TEST_DURATION}:size=1920x1080:rate=30"
    else
        # Return regular URL
        echo "-stream_loop -1 -i \"$stream\""
    fi
}

# Check GPU availability
check_gpu() {
    log "Checking GPU availability..."
    
    if ! command -v nvidia-smi &> /dev/null; then
        error "nvidia-smi not found. Please ensure NVIDIA drivers are installed."
        return 1
    fi
    
    # Get GPU info
    local gpu_info=$(nvidia-smi --query-gpu=name,memory.total,memory.free,utilization.gpu,encoder.stats.sessionCount --format=csv,noheader,nounits 2>/dev/null)
    
    if [[ -z "$gpu_info" ]]; then
        error "No NVIDIA GPU detected"
        return 1
    fi
    
    log "GPU detected: $gpu_info"
    
    # Check if NVENC is available
    if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "${GPU_ENCODER}"; then
        error "FFmpeg ${GPU_ENCODER} encoder not available. Please ensure FFmpeg is built with NVENC support."
        return 1
    fi
    
    log "${GREEN}✓${NC} GPU and NVENC encoder available"
    return 0
}

# Monitor GPU usage
monitor_gpu() {
    local output_file=$1
    local duration=$2
    local pid=$3
    
    echo "timestamp,gpu_util,gpu_mem_used,gpu_mem_total,encoder_sessions,cpu_percent,ram_mb" > "$output_file"
    
    local end_time=$(($(date +%s) + duration))
    
    while [[ $(date +%s) -lt $end_time ]]; do
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        
        # Get GPU metrics
        local gpu_stats=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,encoder.stats.sessionCount --format=csv,noheader,nounits 2>/dev/null | head -1)
        local gpu_util=$(echo "$gpu_stats" | cut -d',' -f1 | tr -d ' ')
        local gpu_mem_used=$(echo "$gpu_stats" | cut -d',' -f2 | tr -d ' ')
        local gpu_mem_total=$(echo "$gpu_stats" | cut -d',' -f3 | tr -d ' ')
        local encoder_sessions=$(echo "$gpu_stats" | cut -d',' -f4 | tr -d ' ')
        
        # Get CPU metrics for comparison
        local cpu_percent="0"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            cpu_percent=$(ps -p "$pid" -o pcpu --no-headers 2>/dev/null | tr -d ' ' || echo "0")
        fi
        
        # Get RAM usage
        local ram_mb=$(free -m | awk 'NR==2{print $3}')
        
        echo "$timestamp,$gpu_util,$gpu_mem_used,$gpu_mem_total,$encoder_sessions,$cpu_percent,$ram_mb" >> "$output_file"
        
        sleep "$SAMPLE_INTERVAL"
    done
}

# Run single GPU test
run_single_gpu_test() {
    local stream_input=$1
    local test_id=$2
    local concurrent_id=$3
    
    local test_temp_dir="${TEMP_DIR}/test_${test_id}_${concurrent_id}"
    mkdir -p "$test_temp_dir"
    
    local ffmpeg_log="${test_temp_dir}/ffmpeg.log"
    local monitor_file="${test_temp_dir}/monitor.csv"
    local output_file="${test_temp_dir}/output.mp4"
    
    # Build FFmpeg command with GPU encoding
    local ffmpeg_cmd="ffmpeg -hide_banner -loglevel info \
        ${stream_input} \
        -t $TEST_DURATION \
        -vf scale=1280:720 \
        -c:v ${GPU_ENCODER} \
        -preset ${GPU_PRESET} \
        -tune ${GPU_TUNE} \
        -rc ${GPU_RC} \
        -cq ${GPU_CQ} \
        -b:v 2M \
        -maxrate 3M \
        -bufsize 4M \
        -g 60 \
        -an \
        -f mp4 \
        -movflags +faststart \
        \"$output_file\""
    
    # Start FFmpeg
    eval "$ffmpeg_cmd" > "$ffmpeg_log" 2>&1 &
    local ffmpeg_pid=$!
    
    # Monitor GPU usage
    monitor_gpu "$monitor_file" "$TEST_DURATION" "$ffmpeg_pid" &
    local monitor_pid=$!
    
    # Wait for FFmpeg to complete
    local start_time=$(date +%s)
    wait "$ffmpeg_pid"
    local ffmpeg_exit_code=$?
    local end_time=$(date +%s)
    local actual_duration=$((end_time - start_time))
    
    # Stop monitoring
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    
    # Parse results
    local speed_ratio=$(grep -o "speed=[0-9.]*x" "$ffmpeg_log" | tail -1 | grep -o "[0-9.]*" || echo "0")
    local fps=$(grep -o "fps=[0-9.]*" "$ffmpeg_log" | tail -1 | grep -o "[0-9.]*" || echo "0")
    
    # Calculate GPU averages
    local avg_gpu_util=$(tail -n +2 "$monitor_file" | awk -F, '{sum+=$2; count++} END {if(count>0) printf "%.2f", sum/count; else print 0}')
    local avg_gpu_mem=$(tail -n +2 "$monitor_file" | awk -F, '{sum+=$3; count++} END {if(count>0) printf "%.2f", sum/count; else print 0}')
    local max_encoder_sessions=$(tail -n +2 "$monitor_file" | awk -F, '{if($5>max) max=$5} END {print max+0}')
    local avg_cpu=$(tail -n +2 "$monitor_file" | awk -F, '{sum+=$6; count++} END {if(count>0) printf "%.2f", sum/count; else print 0}')
    
    # Check success
    local success=1
    if [[ $ffmpeg_exit_code -ne 0 ]] || [[ $(echo "$speed_ratio < 0.9" | bc -l 2>/dev/null) -eq 1 ]]; then
        success=0
    fi
    
    # Write to CSV
    echo "${test_id}_${concurrent_id},${concurrent_id},$GPU_ENCODER,$GPU_PRESET,$speed_ratio,$fps,$avg_gpu_util,$avg_gpu_mem,$max_encoder_sessions,$avg_cpu,$actual_duration,$success" >> "$CSV_FILE"
    
    return $success
}

# Run concurrent GPU test
run_concurrent_gpu_test() {
    local concurrent_count=$1
    
    log "${YELLOW}Starting concurrent GPU test: $concurrent_count streams${NC}"
    
    # Check current GPU usage before test
    local gpu_before=$(nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits | head -1)
    log "GPU state before test: $gpu_before"
    
    local pids=()
    local success_count=0
    
    # Start concurrent processes
    for ((i=1; i<=concurrent_count; i++)); do
        local stream_input=$(get_stream_url "$i")
        
        (
            if run_single_gpu_test "$stream_input" "test_${concurrent_count}" "$i"; then
                exit 0
            else
                exit 1
            fi
        ) &
        
        pids+=($!)
        
        # Small delay to avoid overwhelming the system
        if [[ $((i % 10)) -eq 0 ]]; then
            sleep 0.5
        fi
    done
    
    # Wait for all processes
    for pid in "${pids[@]}"; do
        if wait "$pid"; then
            ((success_count++))
        fi
    done
    
    local success_rate=$(echo "scale=2; $success_count * 100 / $concurrent_count" | bc -l)
    log "Concurrent test completed: $success_count/$concurrent_count successful (${success_rate}%)"
    
    # Check GPU state after test
    local gpu_after=$(nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits | head -1)
    log "GPU state after test: $gpu_after"
    
    # Brief cooldown
    sleep 5
    
    return 0
}

# Setup function
setup() {
    log "Setting up GPU test environment..."
    
    mkdir -p "$RESULTS_DIR"
    mkdir -p "$TEMP_DIR"
    
    # Check GPU availability
    if ! check_gpu; then
        exit 1
    fi
    
    # Generate test streams
    generate_test_streams
    
    # Create CSV header
    echo "test_id,concurrent_streams,encoder,preset,speed_ratio,fps,avg_gpu_util,avg_gpu_mem_mb,max_encoder_sessions,avg_cpu_percent,duration_seconds,success" > "$CSV_FILE"
    
    # System info
    log "System Information:"
    log "  CPU: $(lscpu | grep 'Model name' | cut -d: -f2 | xargs)"
    log "  RAM: $(free -h | awk 'NR==2{print $2}')"
    log "  GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
    log "  FFmpeg: $(ffmpeg -version | head -1)"
    
    log "Setup complete!"
}

# Main execution
main() {
    echo -e "${BLUE}GPU Concurrent Stream Testing${NC}"
    echo "=============================="
    
    setup
    
    # Warm-up test
    log "Running warm-up test..."
    run_concurrent_gpu_test 1
    
    # Run scaling tests
    for concurrent in "${CONCURRENT_TESTS[@]}"; do
        log "\n${BLUE}Testing $concurrent concurrent streams${NC}"
        
        # Retry logic for failed tests
        local retry_count=0
        while [[ $retry_count -lt $MAX_RETRIES ]]; do
            if run_concurrent_gpu_test "$concurrent"; then
                break
            else
                ((retry_count++))
                if [[ $retry_count -lt $MAX_RETRIES ]]; then
                    log "${YELLOW}Retrying test (attempt $((retry_count + 1))/$MAX_RETRIES)${NC}"
                    sleep 10
                fi
            fi
        done
    done
    
    log "\n${GREEN}Testing completed!${NC}"
    log "Results saved to: $CSV_FILE"
    
    # Generate summary
    echo -e "\n${BLUE}Test Summary:${NC}"
    echo "=================="
    echo "GPU Encoder: $GPU_ENCODER"
    echo "Preset: $GPU_PRESET"
    echo "Quality (CQ): $GPU_CQ"
    echo "Concurrent tests: ${CONCURRENT_TESTS[*]}"
    echo ""
    echo "View results with:"
    echo "  cat $CSV_FILE | column -t -s,"
}

# Cleanup function
cleanup() {
    log "Cleaning up..."
    pkill -f "ffmpeg.*${GPU_ENCODER}" 2>/dev/null || true
    exit 1
}

# Set trap
trap cleanup INT TERM

# Check dependencies
command -v ffmpeg >/dev/null 2>&1 || { error "ffmpeg is required"; exit 1; }
command -v bc >/dev/null 2>&1 || { error "bc is required"; exit 1; }

# Run main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi