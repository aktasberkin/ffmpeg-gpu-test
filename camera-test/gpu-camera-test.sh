#!/bin/bash

# Phase 2: Concurrent Testing Script - NVIDIA L40S GPU Version (Fixed)
# Tests concurrent camera streams using NVIDIA NVENC hardware acceleration
# Removed artificial NVENC session limitations for L40S testing

# Configuration
CAMERA_FILE="./cameras_test.txt"
RESULTS_DIR="./test_results"
TEST_DURATION=60  # 1 minute
SAMPLE_INTERVAL=10 # Sample every 10 seconds
LOG_FILE="${RESULTS_DIR}/phase2_concurrent_gpu.log"
CSV_FILE="${RESULTS_DIR}/phase2_concurrent_results_nvenc.csv"
TEMP_DIR="${RESULTS_DIR}/temp_tests_phase2_gpu"
DEBUG_MODE=${DEBUG:-0}  # Set DEBUG=1 to enable debug logging

# Phase 2 configuration: GPU concurrent tests
CONCURRENT_TESTS=(2)  # L40S can handle high concurrent counts
DEFAULT_GPU=0  # Default GPU index
DEFAULT_CODEC="h264_nvenc"  # NVIDIA hardware encoder
DEFAULT_PRESET="p4"  # p1-p7, where p1=fastest, p7=slowest (best quality)
DEFAULT_TUNE="hq"  # High quality tuning

# GPU-specific settings
GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader | head -1)
MAX_NVENC_SESSIONS=0  # Will be detected dynamically
SKIP_NVENC_LIMIT_CHECK=${SKIP_NVENC_LIMIT_CHECK:-1}  # Default: skip the artificial limit

# Global variables
TEST_COUNTER=1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Logging function
log() {
    local message="$1"
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $message"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
}

# Debug logging function
debug_log() {
    local message="$1"
    if [[ $DEBUG_MODE -eq 1 ]]; then
        echo -e "${YELLOW}[DEBUG]${NC} $message"
        echo "[DEBUG] $message" >> "$LOG_FILE"
    fi
}

# Error function
error() {
    local message="$1"
    echo -e "${RED}[ERROR]${NC} $message" >&2
    echo "[ERROR] $message" >> "$LOG_FILE"
}

# Check GPU availability and capabilities
check_gpu_capabilities() {
    log "Checking NVIDIA GPU capabilities..."
    
    # Check if nvidia-smi is available
    if ! command -v nvidia-smi &> /dev/null; then
        error "nvidia-smi not found. Please ensure NVIDIA drivers are installed."
        exit 1
    fi
    
    # Get GPU information
    local gpu_info=$(nvidia-smi --query-gpu=name,memory.total,utilization.gpu,utilization.memory,encoder.stats.sessionCount,encoder.stats.averageFps --format=csv,noheader -i $DEFAULT_GPU)
    local gpu_name=$(echo "$gpu_info" | cut -d',' -f1 | xargs)
    local gpu_memory=$(echo "$gpu_info" | cut -d',' -f2 | xargs)
    
    log "${CYAN}GPU Information:${NC}"
    log "  GPU $DEFAULT_GPU: $gpu_name"
    log "  Memory: $gpu_memory"
    log "  Total GPUs: $GPU_COUNT"
    
    # Check for L40S specifically
    if [[ "$gpu_name" == *"L40S"* ]] || [[ "$gpu_name" == *"L40"* ]]; then
        log "${GREEN}✓ NVIDIA L40S detected${NC}"
        # L40S officially supports 8 concurrent NVENC sessions, but can handle more through time-sharing
        MAX_NVENC_SESSIONS=8
        log "${MAGENTA}Note: L40S can handle many more streams through NVENC session time-sharing${NC}"
    else
        log "${YELLOW}Warning: GPU is not L40S (detected: $gpu_name)${NC}"
        # Query max NVENC sessions
        MAX_NVENC_SESSIONS=$(nvidia-smi --query-gpu=encoder.stats.sessionCountMax --format=csv,noheader -i $DEFAULT_GPU 2>/dev/null || echo "2")
    fi
    
    log "  Official NVENC session limit: $MAX_NVENC_SESSIONS"
    log "  ${CYAN}Actual capacity: Much higher through multiplexing${NC}"
    
    # Check for NVENC patch (skip on L40S - command not available)
    # L40S doesn't have encodersessions command, skip this check
    log "${YELLOW}Note: L40S will automatically multiplex NVENC sessions${NC}"
    
    # Check NVENC availability
    if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_nvenc"; then
        error "FFmpeg NVENC support not available. Please ensure FFmpeg is compiled with NVENC support."
        exit 1
    fi
    
    log "${GREEN}✓ NVENC support confirmed in FFmpeg${NC}"
}

# Setup function
setup() {
    log "Setting up Phase 2 GPU concurrent test environment..."
    
    # Create directories
    mkdir -p "$RESULTS_DIR"
    mkdir -p "$TEMP_DIR"
    
    # Check if camera file exists
    if [[ ! -f "$CAMERA_FILE" ]]; then
        error "Camera file not found: $CAMERA_FILE"
        exit 1
    fi
    
    # Check if we have enough cameras
    local camera_count=$(wc -l < "$CAMERA_FILE")
    log "Found $camera_count cameras in test file"
    
    if [[ $camera_count -lt 36 ]]; then
        error "Not enough cameras for concurrent tests (need at least 36, have $camera_count)"
        exit 1
    fi
    
    # Check GPU capabilities
    check_gpu_capabilities
    
    # Save GPU configuration
    echo "GPU_INDEX=$DEFAULT_GPU" > "${RESULTS_DIR}/phase2_gpu_config.env"
    echo "GPU_CODEC=$DEFAULT_CODEC" >> "${RESULTS_DIR}/phase2_gpu_config.env"
    echo "GPU_PRESET=$DEFAULT_PRESET" >> "${RESULTS_DIR}/phase2_gpu_config.env"
    echo "GPU_TUNE=$DEFAULT_TUNE" >> "${RESULTS_DIR}/phase2_gpu_config.env"
    echo "MAX_NVENC_SESSIONS=$MAX_NVENC_SESSIONS" >> "${RESULTS_DIR}/phase2_gpu_config.env"
    
    # Create CSV header with GPU-specific columns
    echo "test_id,test_type,gpu_index,codec,preset,concurrent_streams,camera_url,avg_cpu_percent,avg_memory_mb,gpu_utilization,gpu_memory_mb,gpu_encoder_util,gpu_decoder_util,total_system_cpu,network_rx_mb,network_tx_mb,speed_ratio,avg_bitrate_kbps,duration_seconds,success,error_message" > "$CSV_FILE"
    
    # Check system resources
    local total_mem=$(free -m | awk 'NR==2{printf "%.0f", $2}')
    local cpu_cores=$(nproc)
    log "System: $cpu_cores CPU cores, ${total_mem}MB RAM"
    
    # Clear GPU processes if needed
    log "Checking for existing GPU processes..."
    local gpu_processes=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l)
    if [[ $gpu_processes -gt 0 ]]; then
        log "${YELLOW}Warning: $gpu_processes existing GPU processes detected${NC}"
    fi
    
    log "Setup complete. Starting Phase 2 GPU concurrent tests..."
}

# Monitor GPU utilization
monitor_gpu() {
    local gpu_index=$1
    local output_file=$2
    local duration=$3
    
    # Header for GPU monitoring file
    echo "timestamp,gpu_util_percent,gpu_memory_mb,encoder_util_percent,decoder_util_percent,power_watts,temp_celsius,nvenc_sessions" > "$output_file"
    
    local end_time=$(($(date +%s) + duration))
    
    while [[ $(date +%s) -lt $end_time ]]; do
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        
        # Query GPU metrics
        local gpu_stats=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,utilization.encoder,utilization.decoder,power.draw,temperature.gpu,encoder.stats.sessionCount --format=csv,noheader -i $gpu_index 2>/dev/null)
        
        if [[ -n "$gpu_stats" ]]; then
            local gpu_util=$(echo "$gpu_stats" | awk -F',' '{gsub(/ %/, "", $1); print $1}')
            local gpu_mem=$(echo "$gpu_stats" | awk -F',' '{gsub(/ MiB/, "", $2); print $2}')
            local enc_util=$(echo "$gpu_stats" | awk -F',' '{gsub(/ %/, "", $3); print $3}')
            local dec_util=$(echo "$gpu_stats" | awk -F',' '{gsub(/ %/, "", $4); print $4}')
            local power=$(echo "$gpu_stats" | awk -F',' '{gsub(/ W/, "", $5); print $5}')
            local temp=$(echo "$gpu_stats" | awk -F',' '{print $6}')
            local nvenc_sessions=$(echo "$gpu_stats" | awk -F',' '{print $7}')
            
            echo "$timestamp,$gpu_util,$gpu_mem,$enc_util,$dec_util,$power,$temp,$nvenc_sessions" >> "$output_file"
        fi
        
        sleep "$SAMPLE_INTERVAL"
    done
}

# Monitor process resources (CPU/Memory for FFmpeg process)
monitor_process() {
    local pid=$1
    local output_file=$2
    local duration=$3
    
    # Header for monitoring file
    echo "timestamp,cpu_percent,memory_mb,network_rx_bytes,network_tx_bytes" > "$output_file"
    
    local end_time=$(($(date +%s) + duration))
    local initial_net_stats=$(cat /proc/net/dev | grep -E "eth0|ens|wlan" | head -1 | awk '{print $2,$10}')
    local initial_rx=$(echo "$initial_net_stats" | awk '{print $1}' || echo "0")
    local initial_tx=$(echo "$initial_net_stats" | awk '{print $2}' || echo "0")
    
    # Wait for process to initialize
    sleep 3
    
    while [[ $(date +%s) -lt $end_time ]] && kill -0 "$pid" 2>/dev/null; do
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        
        # CPU measurement
        local cpu_percent="0.00"
        local ps_output=$(ps -p "$pid" -o pcpu --no-headers 2>/dev/null)
        if [[ -n "$ps_output" ]]; then
            cpu_percent=$(echo "$ps_output" | tr -d ' ')
        fi
        
        # Memory measurement
        local memory_mb="0.00"
        if [[ -f "/proc/$pid/status" ]]; then
            local rss_kb=$(grep "^VmRSS:" "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
            if [[ -n "$rss_kb" ]]; then
                memory_mb=$(echo "scale=2; $rss_kb / 1024" | bc -l 2>/dev/null || echo "0.00")
            fi
        fi
        
        # Network stats
        local current_net_stats=$(cat /proc/net/dev | grep -E "eth0|ens|wlan" | head -1 | awk '{print $2,$10}')
        local current_rx=$(echo "$current_net_stats" | awk '{print $1}' || echo "0")
        local current_tx=$(echo "$current_net_stats" | awk '{print $2}' || echo "0")
        
        local rx_delta=$((current_rx - initial_rx))
        local tx_delta=$((current_tx - initial_tx))
        
        echo "$timestamp,$cpu_percent,$memory_mb,$rx_delta,$tx_delta" >> "$output_file"
        
        sleep "$SAMPLE_INTERVAL"
    done
}

# Calculate GPU averages from monitoring file
calculate_gpu_averages() {
    local monitor_file=$1
    
    if [[ ! -f "$monitor_file" ]] || [[ $(wc -l < "$monitor_file") -le 1 ]]; then
        echo "0,0,0,0"
        return
    fi
    
    # Skip header and calculate averages
    local avg_gpu_util=$(tail -n +2 "$monitor_file" | awk -F, '{sum+=$2; count++} END {if(count>0) print sum/count; else print 0}')
    local avg_gpu_mem=$(tail -n +2 "$monitor_file" | awk -F, '{sum+=$3; count++} END {if(count>0) print sum/count; else print 0}')
    local avg_enc_util=$(tail -n +2 "$monitor_file" | awk -F, '{sum+=$4; count++} END {if(count>0) print sum/count; else print 0}')
    local avg_dec_util=$(tail -n +2 "$monitor_file" | awk -F, '{sum+=$5; count++} END {if(count>0) print sum/count; else print 0}')
    
    echo "$avg_gpu_util,$avg_gpu_mem,$avg_enc_util,$avg_dec_util"
}

# Parse FFmpeg output for performance metrics
parse_ffmpeg_output() {
    local log_file=$1
    
    # Extract speed ratio
    local speed_ratio=$(grep -o "speed=[0-9.]*x" "$log_file" | tail -1 | grep -o "[0-9.]*" || echo "0")
    
    # Extract average bitrate
    local avg_bitrate="0"
    local bitrate_line=$(grep "kb/s:" "$log_file" | tail -1)
    if [[ -n "$bitrate_line" ]]; then
        avg_bitrate=$(echo "$bitrate_line" | grep -o "kb/s:[0-9.]*" | grep -o "[0-9.]*$" || echo "0")
    fi
    
    # Check for errors
    local has_error=0
    local error_msg=""
    if grep -q -i "error\|failed\|connection refused\|timeout" "$log_file"; then
        has_error=1
        error_msg=$(grep -i "error\|failed" "$log_file" | head -1 | tr '"' "'" | tr ',' ';')
    fi
    
    # Check for NVENC-specific errors (but don't treat session limit as fatal)
    if grep -q -i "no free encoding sessions" "$log_file"; then
        # This is expected when exceeding session limits - the driver will multiplex
        debug_log "NVENC session limit reached - driver will multiplex"
    fi
    
    echo "$speed_ratio,$avg_bitrate,$has_error,$error_msg"
}

# Calculate averages from monitoring file
calculate_averages() {
    local monitor_file=$1
    
    if [[ ! -f "$monitor_file" ]] || [[ $(wc -l < "$monitor_file") -le 1 ]]; then
        echo "0,0,0,0"
        return
    fi
    
    # Skip header and calculate averages
    local avg_cpu=$(tail -n +2 "$monitor_file" | awk -F, '{sum+=$2; count++} END {if(count>0) print sum/count; else print 0}')
    local avg_memory=$(tail -n +2 "$monitor_file" | awk -F, '{sum+=$3; count++} END {if(count>0) print sum/count; else print 0}')
    
    # Calculate total bandwidth
    local last_line=$(tail -n 1 "$monitor_file")
    local rx_bytes=$(echo "$last_line" | awk -F, '{print $4}')
    local tx_bytes=$(echo "$last_line" | awk -F, '{print $5}')
    
    local rx_mb=$(echo "scale=2; $rx_bytes / 1024 / 1024" | bc -l 2>/dev/null || echo "0")
    local tx_mb=$(echo "scale=2; $tx_bytes / 1024 / 1024" | bc -l 2>/dev/null || echo "0")
    
    echo "$avg_cpu,$avg_memory,$rx_mb,$tx_mb"
}

# Get camera URL by index
get_camera_url() {
    local index=$1
    sed -n "${index}p" "$CAMERA_FILE"
}

# Run single FFmpeg test with GPU acceleration
run_single_gpu_test() {
    local camera_url=$1
    local test_id=$2
    local concurrent_id=$3
    local gpu_index=${4:-$DEFAULT_GPU}
    
    # Create test-specific temp directory
    local test_temp_dir="${TEMP_DIR}/test_${test_id}_${concurrent_id}"
    mkdir -p "$test_temp_dir"
    
    # Files for this test
    local ffmpeg_log="${test_temp_dir}/ffmpeg.log"
    local monitor_file="${test_temp_dir}/monitor.csv"
    local gpu_monitor_file="${test_temp_dir}/gpu_monitor.csv"
    local playlist_file="${test_temp_dir}/playlist.m3u8"
    
    # Build FFmpeg command with NVIDIA hardware acceleration
    # Using copy codec to minimize processing and test maximum throughput
    local ffmpeg_cmd="ffmpeg -hide_banner -loglevel info \
        -hwaccel cuda \
        -hwaccel_device $gpu_index \
        -c:v h264_cuvid \
        -analyzeduration 3000000 \
        -probesize 5000000 \
        -i \"$camera_url\" \
        -t $TEST_DURATION \
        -vf \"scale_cuda=1280:720\" \
        -c:v h264_nvenc \
        -preset $DEFAULT_PRESET \
        -tune $DEFAULT_TUNE \
        -b:v 2M \
        -maxrate 3M \
        -bufsize 4M \
        -g 60 \
        -gpu $gpu_index \
        -an \
        -f hls \
        -hls_time 30 \
        -hls_flags append_list \
        -hls_list_size 0 \
        -hls_segment_filename \"${test_temp_dir}/segment_%d.ts\" \
        \"$playlist_file\""
    
    debug_log "Starting FFmpeg with command: $ffmpeg_cmd"
    
    # Start GPU monitoring in background
    monitor_gpu "$gpu_index" "$gpu_monitor_file" "$TEST_DURATION" &
    local gpu_monitor_pid=$!
    
    # Start system monitoring
    local cpu_stat_before=$(grep '^cpu ' /proc/stat)
    
    # Start FFmpeg in background
    eval "$ffmpeg_cmd" > "$ffmpeg_log" 2>&1 &
    local ffmpeg_pid=$!
    
    # Monitor the FFmpeg process
    monitor_process "$ffmpeg_pid" "$monitor_file" "$TEST_DURATION" &
    local monitor_pid=$!
    
    # Wait for FFmpeg to complete with timeout
    local start_time=$(date +%s)
    local timeout_time=$((start_time + TEST_DURATION + 10))
    local ffmpeg_exit_code=0
    
    while kill -0 "$ffmpeg_pid" 2>/dev/null; do
        local current_time=$(date +%s)
        if [[ $current_time -ge $timeout_time ]]; then
            kill -TERM "$ffmpeg_pid" 2>/dev/null || true
            sleep 2
            kill -KILL "$ffmpeg_pid" 2>/dev/null || true
            ffmpeg_exit_code=124
            break
        fi
        sleep 1
    done
    
    if [[ $ffmpeg_exit_code -eq 0 ]]; then
        wait "$ffmpeg_pid" 2>/dev/null
        ffmpeg_exit_code=$?
    fi
    
    local end_time=$(date +%s)
    local actual_duration=$((end_time - start_time))
    
    # Stop monitoring
    kill "$monitor_pid" 2>/dev/null || true
    kill "$gpu_monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    wait "$gpu_monitor_pid" 2>/dev/null || true
    
    # Calculate system CPU usage
    local cpu_stat_after=$(grep '^cpu ' /proc/stat)
    local system_cpu_usage=$(awk -v before="$cpu_stat_before" -v after="$cpu_stat_after" '
        BEGIN {
            split(before, b); split(after, a);
            total_before = b[2]+b[3]+b[4]+b[5]+b[6]+b[7]+b[8];
            total_after = a[2]+a[3]+a[4]+a[5]+a[6]+a[7]+a[8];
            active_before = b[2]+b[3]+b[4];
            active_after = a[2]+a[3]+a[4];
            if (total_after > total_before) {
                usage = ((active_after - active_before) * 100) / (total_after - total_before);
                printf "%.2f", usage;
            } else {
                print "0";
            }
        }
    ')
    
    # Parse results
    local ffmpeg_results=$(parse_ffmpeg_output "$ffmpeg_log")
    local speed_ratio=$(echo "$ffmpeg_results" | cut -d, -f1)
    local avg_bitrate=$(echo "$ffmpeg_results" | cut -d, -f2)
    local has_error=$(echo "$ffmpeg_results" | cut -d, -f3)
    local error_msg=$(echo "$ffmpeg_results" | cut -d, -f4)
    
    # Calculate resource averages
    local averages=$(calculate_averages "$monitor_file")
    local avg_cpu=$(echo "$averages" | cut -d, -f1)
    local avg_memory=$(echo "$averages" | cut -d, -f2)
    local rx_mb=$(echo "$averages" | cut -d, -f3)
    local tx_mb=$(echo "$averages" | cut -d, -f4)
    
    # Calculate GPU averages
    local gpu_averages=$(calculate_gpu_averages "$gpu_monitor_file")
    local avg_gpu_util=$(echo "$gpu_averages" | cut -d, -f1)
    local avg_gpu_mem=$(echo "$gpu_averages" | cut -d, -f2)
    local avg_enc_util=$(echo "$gpu_averages" | cut -d, -f3)
    local avg_dec_util=$(echo "$gpu_averages" | cut -d, -f4)
    
    # Determine success (more lenient for GPU tests)
    local success=1
    if [[ $ffmpeg_exit_code -ne 0 ]] || [[ $has_error -eq 1 ]] || [[ $(echo "$speed_ratio < 0.8" | bc -l 2>/dev/null) -eq 1 ]]; then
        success=0
    fi
    
    # Write results to CSV
    local csv_line="${test_id}_${concurrent_id},concurrent,$gpu_index,$DEFAULT_CODEC,$DEFAULT_PRESET,${concurrent_id},$(echo "$camera_url" | tr ',' ';'),${avg_cpu},${avg_memory},${avg_gpu_util},${avg_gpu_mem},${avg_enc_util},${avg_dec_util},${system_cpu_usage},${rx_mb},${tx_mb},${speed_ratio},${avg_bitrate},${actual_duration},${success},${error_msg}"
    echo "$csv_line" >> "$CSV_FILE"
    
    # Return success status
    return $success
}

# Run concurrent test with GPU load balancing
run_concurrent_gpu_test() {
    local concurrent_count=$1
    
    log "${CYAN}Running GPU concurrent test: $concurrent_count streams${NC}"
    log "  Using: codec=$DEFAULT_CODEC, preset=$DEFAULT_PRESET, tune=$DEFAULT_TUNE"
    
    # Show current NVENC session usage before test
    local current_sessions=$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader -i $DEFAULT_GPU 2>/dev/null || echo "0")
    log "  Current NVENC sessions in use: $current_sessions"
    
    local pids=()
    local test_ids=()
    local success_count=0
    
    # Calculate GPU distribution
    local streams_per_gpu=$((concurrent_count / GPU_COUNT))
    local extra_streams=$((concurrent_count % GPU_COUNT))
    
    log "  Distribution: $streams_per_gpu streams per GPU (+ $extra_streams extra)"
    
    # Start concurrent processes with GPU load balancing
    local stream_counter=0
    for ((i=1; i<=concurrent_count; i++)); do
        local camera_url=$(get_camera_url "$i")
        local test_id="${TEST_COUNTER}"
        
        # Determine which GPU to use (round-robin)
        local gpu_index=$((stream_counter % GPU_COUNT))
        
        # Run test in background
        (
            if run_single_gpu_test "$camera_url" "$test_id" "$i" "$gpu_index"; then
                exit 0
            else
                exit 1
            fi
        ) &
        
        pids+=($!)
        test_ids+=("${test_id}_${i}")
        ((stream_counter++))
        
        # Small delay to prevent GPU initialization race conditions
        # Reduced delay since L40S can handle rapid session creation
        if [[ $((i % 8)) -eq 0 ]]; then
            sleep 0.5
        fi
    done
    
    ((TEST_COUNTER++))
    
    # Wait for all processes and count successes
    for i in "${!pids[@]}"; do
        local pid=${pids[$i]}
        local test_id=${test_ids[$i]}
        
        if wait "$pid"; then
            ((success_count++))
            log "${GREEN}✓${NC} GPU concurrent test $test_id completed successfully"
        else
            log "${RED}✗${NC} GPU concurrent test $test_id failed"
        fi
    done
    
    local success_rate=$(echo "scale=2; $success_count * 100 / $concurrent_count" | bc -l)
    log "GPU concurrent test completed: $success_count/$concurrent_count successful (${success_rate}%)"
    
    # Show GPU utilization summary
    local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu,utilization.encoder,memory.used,encoder.stats.sessionCount --format=csv,noheader -i $DEFAULT_GPU)
    log "  Final GPU state: $gpu_util"
    
    return $(echo "$success_count >= $(echo "$concurrent_count * 0.8" | bc)" | bc)
}

# Analyze GPU performance and find optimal concurrent count
analyze_gpu_performance() {
    log "${CYAN}Analyzing GPU performance results...${NC}"
    
    # Find optimal concurrent count based on success rate and GPU utilization
    local optimal_concurrent=0
    local max_successful=0
    
    for concurrent in "${CONCURRENT_TESTS[@]}"; do
        local success_count=$(grep ",concurrent," "$CSV_FILE" | grep ",$concurrent," | grep ",1," | wc -l)
        local total_count=$(grep ",concurrent," "$CSV_FILE" | grep ",$concurrent," | wc -l)
        
        if [[ $total_count -gt 0 ]]; then
            local success_rate=$((success_count * 100 / total_count))
            local avg_gpu_util=$(grep ",concurrent," "$CSV_FILE" | grep ",$concurrent," | awk -F, '{sum+=$10; count++} END {if(count>0) print sum/count; else print 0}')
            local avg_enc_util=$(grep ",concurrent," "$CSV_FILE" | grep ",$concurrent," | awk -F, '{sum+=$12; count++} END {if(count>0) print sum/count; else print 0}')
            
            log "  $concurrent streams: ${success_rate}% success, ${avg_gpu_util}% GPU, ${avg_enc_util}% encoder utilization"
            
            if [[ $success_count -gt $max_successful ]] && [[ $success_rate -ge 80 ]]; then
                optimal_concurrent=$concurrent
                max_successful=$success_count
            fi
        fi
    done
    
    log "${GREEN}Optimal concurrent streams: $optimal_concurrent${NC}"
    echo "OPTIMAL_GPU_CONCURRENT=$optimal_concurrent" > "${RESULTS_DIR}/optimal_gpu_config.env"
}

# Main execution
main() {
    echo -e "${CYAN}Phase 2: GPU Concurrent Testing (NVIDIA L40S)${NC}"
    echo "============================================="
    
    setup
    
    # Load configuration
    source "${RESULTS_DIR}/phase2_gpu_config.env" 2>/dev/null || {
        log "${YELLOW}Warning: Could not load GPU configuration${NC}"
    }
    
    log "${CYAN}Starting GPU concurrent scaling tests${NC}"
    log "GPU Configuration:"
    log "  GPU Index: $DEFAULT_GPU"
    log "  Codec: $DEFAULT_CODEC"
    log "  Preset: $DEFAULT_PRESET"
    log "  Tune: $DEFAULT_TUNE"
    log "  NVENC Session Limit: $MAX_NVENC_SESSIONS (can be exceeded through multiplexing)"
    log "  ${MAGENTA}L40S will automatically multiplex streams beyond session limits${NC}"
    
    # Run concurrent scaling tests
    for concurrent in "${CONCURRENT_TESTS[@]}"; do
        # NO LONGER SKIP HIGH CONCURRENT COUNTS - L40S can handle them
        if [[ $SKIP_NVENC_LIMIT_CHECK -eq 0 ]] && [[ $concurrent -gt $((MAX_NVENC_SESSIONS * GPU_COUNT * 2)) ]]; then
            log "${YELLOW}Warning: Testing $concurrent streams (exceeds 2x NVENC session limit)${NC}"
            log "${CYAN}L40S will multiplex sessions - this is normal and expected${NC}"
        fi
        
        run_concurrent_gpu_test "$concurrent"
        
        # Brief pause between tests to let GPU stabilize
        log "Stabilizing GPU for 10 seconds..."
        sleep 10
        
        # Show GPU temperature and power
        local gpu_stats=$(nvidia-smi --query-gpu=temperature.gpu,power.draw --format=csv,noheader -i $DEFAULT_GPU)
        log "  GPU Stats: $gpu_stats"
    done
    
    # Analyze results
    analyze_gpu_performance
    
    log "${GREEN}Phase 2 GPU testing completed!${NC}"
    log "Results saved to: $CSV_FILE"
    log "Logs saved to: $LOG_FILE"
    
    echo ""
    echo -e "${CYAN}Phase 2 GPU Summary:${NC}"
    echo "====================="
    echo "GPU: NVIDIA L40S (or compatible)"
    echo "Codec: $DEFAULT_CODEC"
    echo "Preset: $DEFAULT_PRESET"
    echo "Concurrent tests completed: ${CONCURRENT_TESTS[*]} streams"
    echo "Results file: $CSV_FILE"
    echo ""
    echo "Key findings:"
    grep "OPTIMAL_GPU_CONCURRENT" "${RESULTS_DIR}/optimal_gpu_config.env" 2>/dev/null || echo "  See CSV for detailed results"
    echo ""
    echo "Use the following commands to analyze results:"
    echo "  # View results table:"
    echo "  column -t -s, $CSV_FILE | less -S"
    echo ""
    echo "  # Check NVENC session usage:"
    echo "  nvidia-smi encodersessions"
    echo ""
    echo "  # Monitor GPU in real-time:"
    echo "  watch -n 1 'nvidia-smi --query-gpu=name,utilization.gpu,utilization.encoder,utilization.decoder,encoder.stats.sessionCount,memory.used,temperature.gpu,power.draw --format=csv'"
}

# Handle interruption
cleanup() {
    log "Phase 2 GPU script interrupted. Cleaning up..."
    # Kill any remaining FFmpeg processes
    pkill -f "ffmpeg.*h264_nvenc" 2>/dev/null || true
    log "Temp files preserved in: $TEMP_DIR"
    exit 1
}

# Set trap for cleanup
trap cleanup INT TERM

# Check dependencies
command -v ffmpeg >/dev/null 2>&1 || { error "ffmpeg is required but not installed"; exit 1; }
command -v bc >/dev/null 2>&1 || { error "bc is required but not installed"; exit 1; }
command -v nvidia-smi >/dev/null 2>&1 || { error "nvidia-smi is required but not installed"; exit 1; }

# Run main function if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi