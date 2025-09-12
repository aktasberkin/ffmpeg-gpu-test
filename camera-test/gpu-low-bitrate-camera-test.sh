#!/bin/bash

# GPU Low-Bitrate Concurrent Camera Testing Script
# Tests multiple camera streams with low bitrate settings using NVIDIA GPU
# Optimized for minimal file size while maintaining acceptable quality

# Configuration
CAMERA_FILE="./cameras_test.txt"
RESULTS_DIR="./test_results_lowbitrate"
TEST_DURATION=60  # 1 minute
SAMPLE_INTERVAL=10 # Sample every 10 seconds
LOG_FILE="${RESULTS_DIR}/lowbitrate_gpu.log"
CSV_FILE="${RESULTS_DIR}/lowbitrate_gpu_results.csv"
TEMP_DIR="${RESULTS_DIR}/temp_lowbitrate"
DEBUG_MODE=${DEBUG:-0}

# Test configuration
CONCURRENT_TESTS=(2 5 10 20 30)  # Test with different concurrent counts
DEFAULT_GPU=0
DEFAULT_CODEC="h264_nvenc"

# Maximum compression settings for 100-200KB segments (6 seconds each)
# Target: 100-200KB = ~133-267 kbps effective bitrate
GPU_CQ=${GPU_CQ:-45}  # Constant Quality (45 = maximum compression, 42 = high compression)
GPU_PRESET="p6"  # p6 = slower preset for better compression efficiency
GPU_BITRATE="200k"  # Target bitrate - significantly reduced for small segments
GPU_MAXRATE="250k"  # Max bitrate - kept close to target for consistent sizes
GPU_BUFSIZE="125k"  # Small buffer size forces aggressive compression
GPU_RESOLUTION="854x480"  # Reduced resolution for better compression (was 1280x720)
SEGMENT_TIME=6  # HLS segment duration

# Global variables
TEST_COUNTER=1

# Colors
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

# Debug logging
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

# Check GPU availability
check_gpu_capabilities() {
    log "Checking NVIDIA GPU capabilities..."
    
    if ! command -v nvidia-smi &> /dev/null; then
        error "nvidia-smi not found. Please ensure NVIDIA drivers are installed."
        exit 1
    fi
    
    local gpu_info=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader -i $DEFAULT_GPU)
    local gpu_name=$(echo "$gpu_info" | cut -d',' -f1 | xargs)
    local gpu_memory=$(echo "$gpu_info" | cut -d',' -f2 | xargs)
    
    log "${CYAN}GPU Information:${NC}"
    log "  GPU $DEFAULT_GPU: $gpu_name"
    log "  Memory: $gpu_memory"
    
    # Check NVENC availability
    if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_nvenc"; then
        error "FFmpeg NVENC support not available."
        exit 1
    fi
    
    log "${GREEN}✓ NVENC support confirmed${NC}"
    log "${MAGENTA}Maximum compression mode: CQ=$GPU_CQ, Bitrate=$GPU_BITRATE, Resolution=$GPU_RESOLUTION${NC}"
}

# Setup function
setup() {
    log "Setting up Low-Bitrate GPU test environment..."
    
    # Create directories
    mkdir -p "$RESULTS_DIR"
    mkdir -p "$TEMP_DIR"
    
    # Check camera file
    if [[ ! -f "$CAMERA_FILE" ]]; then
        error "Camera file not found: $CAMERA_FILE"
        exit 1
    fi
    
    local camera_count=$(wc -l < "$CAMERA_FILE")
    log "Found $camera_count cameras in test file"
    
    if [[ $camera_count -lt 30 ]]; then
        log "${YELLOW}Warning: Only $camera_count cameras available${NC}"
        # Adjust concurrent tests based on available cameras
        CONCURRENT_TESTS=(2 5 10 $camera_count)
    fi
    
    # Check GPU
    check_gpu_capabilities
    
    # Create CSV header
    echo "test_id,test_type,concurrent_streams,camera_url,gpu_util,gpu_memory_mb,encoder_util,avg_cpu_percent,avg_memory_mb,speed_ratio,output_size_mb,segment_count,avg_segment_kb,duration_seconds,success,error_message" > "$CSV_FILE"
    
    log "Setup complete!"
}

# Get camera URL by index
get_camera_url() {
    local index=$1
    sed -n "${index}p" "$CAMERA_FILE"
}

# Monitor GPU utilization
monitor_gpu() {
    local output_file=$1
    local duration=$2
    
    echo "timestamp,gpu_util,gpu_memory_mb,encoder_util,temp_celsius" > "$output_file"
    
    local end_time=$(($(date +%s) + duration))
    
    while [[ $(date +%s) -lt $end_time ]]; do
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        local gpu_stats=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,utilization.encoder,temperature.gpu --format=csv,noheader -i $DEFAULT_GPU 2>/dev/null)
        
        if [[ -n "$gpu_stats" ]]; then
            local gpu_util=$(echo "$gpu_stats" | awk -F',' '{gsub(/ %/, "", $1); print $1}')
            local gpu_mem=$(echo "$gpu_stats" | awk -F',' '{gsub(/ MiB/, "", $2); print $2}')
            local enc_util=$(echo "$gpu_stats" | awk -F',' '{gsub(/ %/, "", $3); print $3}')
            local temp=$(echo "$gpu_stats" | awk -F',' '{print $4}')
            
            echo "$timestamp,$gpu_util,$gpu_mem,$enc_util,$temp" >> "$output_file"
        fi
        
        sleep "$SAMPLE_INTERVAL"
    done
}

# Monitor process resources
monitor_process() {
    local pid=$1
    local output_file=$2
    local duration=$3
    
    echo "timestamp,cpu_percent,memory_mb" > "$output_file"
    
    local end_time=$(($(date +%s) + duration))
    
    while [[ $(date +%s) -lt $end_time ]] && kill -0 "$pid" 2>/dev/null; do
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        
        local cpu_percent="0.00"
        local ps_output=$(ps -p "$pid" -o pcpu --no-headers 2>/dev/null)
        if [[ -n "$ps_output" ]]; then
            cpu_percent=$(echo "$ps_output" | tr -d ' ')
        fi
        
        local memory_mb="0.00"
        if [[ -f "/proc/$pid/status" ]]; then
            local rss_kb=$(grep "^VmRSS:" "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
            if [[ -n "$rss_kb" ]]; then
                memory_mb=$(echo "scale=2; $rss_kb / 1024" | bc -l 2>/dev/null || echo "0.00")
            fi
        fi
        
        echo "$timestamp,$cpu_percent,$memory_mb" >> "$output_file"
        sleep "$SAMPLE_INTERVAL"
    done
}

# Calculate averages from monitoring file
calculate_averages() {
    local monitor_file=$1
    
    if [[ ! -f "$monitor_file" ]] || [[ $(wc -l < "$monitor_file") -le 1 ]]; then
        echo "0,0"
        return
    fi
    
    local avg_cpu=$(tail -n +2 "$monitor_file" | awk -F, '{sum+=$2; count++} END {if(count>0) print sum/count; else print 0}')
    local avg_memory=$(tail -n +2 "$monitor_file" | awk -F, '{sum+=$3; count++} END {if(count>0) print sum/count; else print 0}')
    
    echo "$avg_cpu,$avg_memory"
}

# Calculate GPU averages
calculate_gpu_averages() {
    local monitor_file=$1
    
    if [[ ! -f "$monitor_file" ]] || [[ $(wc -l < "$monitor_file") -le 1 ]]; then
        echo "0,0,0"
        return
    fi
    
    local avg_gpu_util=$(tail -n +2 "$monitor_file" | awk -F, '{sum+=$2; count++} END {if(count>0) print sum/count; else print 0}')
    local avg_gpu_mem=$(tail -n +2 "$monitor_file" | awk -F, '{sum+=$3; count++} END {if(count>0) print sum/count; else print 0}')
    local avg_enc_util=$(tail -n +2 "$monitor_file" | awk -F, '{sum+=$4; count++} END {if(count>0) print sum/count; else print 0}')
    
    echo "$avg_gpu_util,$avg_gpu_mem,$avg_enc_util"
}

# Parse FFmpeg output
parse_ffmpeg_output() {
    local log_file=$1
    
    local speed_ratio=$(grep -o "speed=[0-9.]*x" "$log_file" | tail -1 | grep -o "[0-9.]*" || echo "0")
    
    local has_error=0
    local error_msg=""
    if grep -q -i "error\|failed\|connection refused\|timeout" "$log_file"; then
        has_error=1
        error_msg=$(grep -i "error\|failed" "$log_file" | head -1 | tr '"' "'" | tr ',' ';')
    fi
    
    echo "$speed_ratio,$has_error,$error_msg"
}

# Run single low-bitrate GPU test
run_single_lowbitrate_test() {
    local camera_url=$1
    local test_id=$2
    local concurrent_id=$3
    
    local test_temp_dir="${TEMP_DIR}/test_${test_id}_${concurrent_id}"
    mkdir -p "$test_temp_dir"
    
    local ffmpeg_log="${test_temp_dir}/ffmpeg.log"
    local monitor_file="${test_temp_dir}/monitor.csv"
    local gpu_monitor_file="${test_temp_dir}/gpu_monitor.csv"
    local playlist_file="${test_temp_dir}/playlist.m3u8"
    local segment_prefix="${test_temp_dir}/segment"
    
    # Build FFmpeg command with maximum compression settings
    # 
    # COMPRESSION OPTIMIZATION EXPLANATIONS:
    # =====================================
    # 
    # 1. RESOLUTION REDUCTION (854x480 vs 1280x720):
    #    - Reduces pixel count by ~55%, directly impacting file size
    #    - Still maintains 16:9 aspect ratio for compatibility
    # 
    # 2. RATE CONTROL (CBR vs constqp):
    #    - CBR (Constant Bitrate) provides more predictable file sizes
    #    - constqp can vary widely in output size
    # 
    # 3. CONSTANT QUALITY (CQ=45):
    #    - Higher CQ values = more compression/smaller files
    #    - CQ 45 provides maximum compression with acceptable quality loss
    #    - Trade-off: Lower visual quality for smaller file sizes
    # 
    # 4. BITRATE SETTINGS (200k target, 250k max):
    #    - Significantly reduced from 500k/750k to achieve target file sizes
    #    - 200kbps * 6 seconds = ~150KB theoretical minimum
    #    - Small buffer (125k) prevents bitrate spikes
    # 
    # 5. GOP SIZE (60 vs 120):
    #    - Smaller GOP = more I-frames = better compression efficiency
    #    - More frequent keyframes help with rate control
    # 
    # 6. B-FRAMES AND REFERENCES:
    #    - bf 3: Uses 3 B-frames for better compression
    #    - refs 3: Uses 3 reference frames for motion prediction
    #    - Both improve compression efficiency at cost of encoding time
    # 
    # 7. PRESET (p6 vs p4):
    #    - p6 = slower encoding but better compression efficiency
    #    - More thorough motion estimation and rate-distortion optimization
    local ffmpeg_cmd="ffmpeg -hide_banner -loglevel info \
        -rtsp_transport tcp \
        -stimeout 10000000 \
        -analyzeduration 5000000 \
        -probesize 10000000 \
        -hwaccel cuda \
        -hwaccel_device $DEFAULT_GPU \
        -hwaccel_output_format cuda \
        -i \"$camera_url\" \
        -t $TEST_DURATION \
        -vf \"scale_cuda=${GPU_RESOLUTION}\" \
        -c:v $DEFAULT_CODEC \
        -preset $GPU_PRESET \
        -rc cbr \
        -cq $GPU_CQ \
        -b:v $GPU_BITRATE \
        -maxrate $GPU_MAXRATE \
        -bufsize $GPU_BUFSIZE \
        -g 60 \
        -bf 3 \
        -refs 3 \
        -gpu $DEFAULT_GPU \
        -an \
        -f hls \
        -hls_time $SEGMENT_TIME \
        -hls_flags append_list \
        -hls_list_size 0 \
        -hls_segment_filename \"${segment_prefix}_%03d.ts\" \
        \"$playlist_file\""
    
    debug_log "Starting FFmpeg with maximum compression: CQ=$GPU_CQ, Bitrate=$GPU_BITRATE, Resolution=$GPU_RESOLUTION"
    
    # Start GPU monitoring
    monitor_gpu "$gpu_monitor_file" "$TEST_DURATION" &
    local gpu_monitor_pid=$!
    
    # Start FFmpeg
    local start_time=$(date +%s)
    eval "$ffmpeg_cmd" > "$ffmpeg_log" 2>&1 &
    local ffmpeg_pid=$!
    
    # Monitor process
    monitor_process "$ffmpeg_pid" "$monitor_file" "$TEST_DURATION" &
    local monitor_pid=$!
    
    # Wait for FFmpeg
    local timeout_time=$((start_time + TEST_DURATION + 10))
    local ffmpeg_exit_code=0
    
    while kill -0 "$ffmpeg_pid" 2>/dev/null; do
        if [[ $(date +%s) -ge $timeout_time ]]; then
            kill -TERM "$ffmpeg_pid" 2>/dev/null || true
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
    
    # Parse results
    local ffmpeg_results=$(parse_ffmpeg_output "$ffmpeg_log")
    local speed_ratio=$(echo "$ffmpeg_results" | cut -d, -f1)
    local has_error=$(echo "$ffmpeg_results" | cut -d, -f2)
    local error_msg=$(echo "$ffmpeg_results" | cut -d, -f3)
    
    # Calculate averages
    local averages=$(calculate_averages "$monitor_file")
    local avg_cpu=$(echo "$averages" | cut -d, -f1)
    local avg_memory=$(echo "$averages" | cut -d, -f2)
    
    local gpu_averages=$(calculate_gpu_averages "$gpu_monitor_file")
    local avg_gpu_util=$(echo "$gpu_averages" | cut -d, -f1)
    local avg_gpu_mem=$(echo "$gpu_averages" | cut -d, -f2)
    local avg_enc_util=$(echo "$gpu_averages" | cut -d, -f3)
    
    # Calculate output size
    local output_size_mb="0"
    local segment_count=0
    local avg_segment_kb="0"
    
    if ls ${segment_prefix}_*.ts 1> /dev/null 2>&1; then
        segment_count=$(ls -1 ${segment_prefix}_*.ts | wc -l)
        output_size_mb=$(du -sm "$test_temp_dir" | cut -f1)
        avg_segment_kb=$(ls -l ${segment_prefix}_*.ts | awk '{sum+=$5; count++} END {if(count>0) printf "%.1f", sum/count/1024; else print 0}')
        
        debug_log "Created $segment_count segments, avg size: ${avg_segment_kb}KB"
    fi
    
    # Determine success
    local success=1
    if [[ $ffmpeg_exit_code -ne 0 ]] || [[ $has_error -eq 1 ]] || [[ $(echo "$speed_ratio < 0.8" | bc -l 2>/dev/null) -eq 1 ]]; then
        success=0
    fi
    
    # Write to CSV
    local csv_line="${test_id}_${concurrent_id},lowbitrate,${concurrent_id},$(echo "$camera_url" | tr ',' ';'),${avg_gpu_util},${avg_gpu_mem},${avg_enc_util},${avg_cpu},${avg_memory},${speed_ratio},${output_size_mb},${segment_count},${avg_segment_kb},${actual_duration},${success},${error_msg}"
    echo "$csv_line" >> "$CSV_FILE"
    
    return $success
}

# Run concurrent low-bitrate test
run_concurrent_lowbitrate_test() {
    local concurrent_count=$1
    
    log "${CYAN}Running low-bitrate GPU test: $concurrent_count streams (CQ=$GPU_CQ)${NC}"
    
    local pids=()
    local success_count=0
    
    # Start concurrent processes
    for ((i=1; i<=concurrent_count; i++)); do
        local camera_url=$(get_camera_url "$i")
        local test_id="${TEST_COUNTER}"
        
        (
            if run_single_lowbitrate_test "$camera_url" "$test_id" "$i"; then
                exit 0
            else
                exit 1
            fi
        ) &
        
        pids+=($!)
        
        # Stagger start for large concurrent counts
        if [[ $concurrent_count -gt 10 ]] && [[ $((i % 5)) -eq 0 ]]; then
            sleep 1
        fi
    done
    
    ((TEST_COUNTER++))
    
    # Wait for all processes
    for pid in "${pids[@]}"; do
        if wait "$pid"; then
            ((success_count++))
        fi
    done
    
    local success_rate=$(echo "scale=2; $success_count * 100 / $concurrent_count" | bc -l)
    log "Test completed: $success_count/$concurrent_count successful (${success_rate}%)"
    
    # Show GPU state
    local gpu_stats=$(nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader -i $DEFAULT_GPU)
    log "  GPU state: $gpu_stats"
    
    # Calculate average segment size for this test
    local total_size_mb=$(du -sm "${TEMP_DIR}/test_${TEST_COUNTER}"* 2>/dev/null | awk '{sum+=$1} END {print sum}')
    local total_segments=$(find "${TEMP_DIR}/test_${TEST_COUNTER}"* -name "*.ts" 2>/dev/null | wc -l)
    
    if [[ $total_segments -gt 0 ]]; then
        local avg_segment_size_kb=$(echo "scale=2; $total_size_mb * 1024 / $total_segments" | bc -l)
        log "${GREEN}  Average segment size: ${avg_segment_size_kb}KB (Target: 100-200KB for maximum compression)${NC}"
    fi
}

# Analyze results
analyze_results() {
    log "${CYAN}Analyzing low-bitrate test results...${NC}"
    
    echo ""
    echo "Size Analysis:"
    echo "=============="
    
    for concurrent in "${CONCURRENT_TESTS[@]}"; do
        local avg_size=$(grep ",lowbitrate,$concurrent," "$CSV_FILE" | awk -F, '{sum+=$13; count++} END {if(count>0) printf "%.1f", sum/count; else print 0}')
        local success_rate=$(grep ",lowbitrate,$concurrent," "$CSV_FILE" | awk -F, '{success+=$15; total++} END {if(total>0) printf "%.0f", success*100/total; else print 0}')
        
        echo "  $concurrent streams: Avg segment=${avg_size}KB, Success=${success_rate}%"
    done
    
    echo ""
    echo "Comparison with targets:"
    echo "  Target: 100-200KB per 6s segment (maximum compression)"
    echo "  Current GPU results: See above"
    
    echo ""
    echo "${YELLOW}Optimization tips:${NC}"
    echo "  For even smaller files: GPU_CQ=48 ./$(basename $0)"
    echo "  For higher quality: GPU_CQ=42 ./$(basename $0)"
    echo "  For different resolution: GPU_RESOLUTION=\"640x360\" ./$(basename $0)"
}

# Main execution
main() {
    echo -e "${CYAN}GPU Low-Bitrate Camera Testing${NC}"
    echo "================================"
    
    setup
    
    log "Configuration (Maximum Compression Mode):"
    log "  GPU: $DEFAULT_GPU"
    log "  Codec: $DEFAULT_CODEC"
    log "  Quality (CQ): $GPU_CQ (higher = more compression)"
    log "  Bitrate: $GPU_BITRATE (max: $GPU_MAXRATE)"
    log "  Resolution: $GPU_RESOLUTION (reduced for compression)"
    log "  Preset: $GPU_PRESET (slower for better compression)"
    log "  Segment time: ${SEGMENT_TIME}s"
    log "  Target size: 100-200KB per segment"
    
    # Run tests
    for concurrent in "${CONCURRENT_TESTS[@]}"; do
        run_concurrent_lowbitrate_test "$concurrent"
        sleep 10  # Pause between tests
    done
    
    # Analyze results
    analyze_results
    
    log "${GREEN}Testing completed!${NC}"
    log "Results saved to: $CSV_FILE"
    
    echo ""
    echo "Commands to check output:"
    echo "  # View results:"
    echo "  column -t -s, $CSV_FILE | less -S"
    echo ""
    echo "  # Check segment sizes:"
    echo "  ls -lah ${TEMP_DIR}/test_*/segment_*.ts | head -20"
    echo ""
    echo "  # Play sample output:"
    echo "  vlc ${TEMP_DIR}/test_1_1/playlist.m3u8"
}

# Cleanup
cleanup() {
    log "Cleaning up..."
    pkill -f "ffmpeg.*${DEFAULT_CODEC}" 2>/dev/null || true
    exit 1
}

trap cleanup INT TERM

# Check dependencies
command -v ffmpeg >/dev/null 2>&1 || { error "ffmpeg is required"; exit 1; }
command -v bc >/dev/null 2>&1 || { error "bc is required"; exit 1; }
command -v nvidia-smi >/dev/null 2>&1 || { error "nvidia-smi is required"; exit 1; }

# Run main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi