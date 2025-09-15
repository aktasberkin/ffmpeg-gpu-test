#!/bin/bash

# Detailed Concurrent GPU Test with File Outputs and Monitoring
# Real file outputs for manual inspection

set -e

# Configuration
MAX_CONCURRENT=200
TEST_DURATION=60
OUTPUT_BASE="gpu_test_$(date +%Y%m%d_%H%M%S)"
STREAMS_DIR="${OUTPUT_BASE}/streams"
LOGS_DIR="${OUTPUT_BASE}/logs"
REPORTS_DIR="${OUTPUT_BASE}/reports"

# Results files
LIVE_METRICS="${REPORTS_DIR}/live_metrics.txt"
DETAILED_CSV="${REPORTS_DIR}/detailed_metrics.csv"
SUMMARY_REPORT="${REPORTS_DIR}/test_summary.txt"
DISK_USAGE_LOG="${REPORTS_DIR}/disk_usage.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Create directories
mkdir -p "$STREAMS_DIR" "$LOGS_DIR" "$REPORTS_DIR"

# Initialize monitoring files
init_monitoring() {
    echo -e "${BLUE}Initializing monitoring files...${NC}"

    # Live metrics for real-time viewing
    cat > "$LIVE_METRICS" << EOF
=== GPU Concurrent Test Live Metrics ===
Test started: $(date)
Target directory: $OUTPUT_BASE
EOF

    # Detailed CSV for analysis
    cat > "$DETAILED_CSV" << EOF
timestamp,elapsed_sec,target_streams,active_streams,gpu_util_percent,gpu_mem_used_mb,gpu_mem_total_mb,gpu_temp_celsius,nvenc_sessions,cpu_percent,ram_used_mb,ram_total_mb,disk_used_gb,disk_available_gb,streams_with_files
EOF

    # Disk usage tracking
    echo "=== Disk Usage During Test ===" > "$DISK_USAGE_LOG"
    df -h >> "$DISK_USAGE_LOG"
    echo "" >> "$DISK_USAGE_LOG"
}

# System optimization
optimize_system() {
    echo -e "${YELLOW}System optimization...${NC}"
    ulimit -n 65536 2>/dev/null || echo "Warning: Cannot increase file limit"
    ulimit -u 32768 2>/dev/null || echo "Warning: Cannot increase process limit"

    echo "File descriptors limit: $(ulimit -n)" | tee -a "$LIVE_METRICS"
    echo "Process limit: $(ulimit -u)" | tee -a "$LIVE_METRICS"
    echo "Available RAM: $(free -h | awk 'NR==2{print $7}')" | tee -a "$LIVE_METRICS"
    echo "" | tee -a "$LIVE_METRICS"
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

    local base="${patterns[$((stream_id % ${#patterns[@]}))]}"
    if [ $((stream_id % 4)) -eq 0 ]; then
        echo "${base},rotate=angle=t*0.3:c=black"
    else
        echo "$base"
    fi
}

# Launch single stream with REAL file outputs
launch_stream_with_files() {
    local stream_id=$1
    local stream_dir="${STREAMS_DIR}/stream_$(printf "%04d" $stream_id)"
    local log_file="${LOGS_DIR}/stream_$(printf "%04d" $stream_id).log"

    mkdir -p "$stream_dir"

    local source=$(get_synthetic_source $stream_id)

    # Launch FFmpeg with real HLS output
    ffmpeg \
        -hide_banner \
        -loglevel info \
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
        -c:a copy \
        -f hls \
        -hls_time 6 \
        -hls_list_size 10 \
        -hls_flags append_list+delete_segments \
        -hls_segment_filename "${stream_dir}/segment_%05d.ts" \
        -hls_playlist_type vod \
        "${stream_dir}/playlist.m3u8" \
        2>"$log_file" &

    echo $!
}

# Detailed system monitoring
collect_system_metrics() {
    local timestamp=$1
    local elapsed=$2
    local target_streams=$3
    local active_streams=$4

    # GPU metrics
    local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
    local gpu_mem_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
    local gpu_mem_total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
    local gpu_temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
    local nvenc_sessions=$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)

    # System metrics
    local cpu_percent=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 2>/dev/null || echo 0)
    local ram_used=$(free -m | awk 'NR==2{print $3}' 2>/dev/null || echo 0)
    local ram_total=$(free -m | awk 'NR==2{print $2}' 2>/dev/null || echo 0)

    # Disk metrics
    local disk_info=$(df -BG "$OUTPUT_BASE" | tail -1)
    local disk_used=$(echo "$disk_info" | awk '{print $3}' | tr -d 'G')
    local disk_available=$(echo "$disk_info" | awk '{print $4}' | tr -d 'G')

    # Count streams with actual files
    local streams_with_files=$(find "$STREAMS_DIR" -name "playlist.m3u8" | wc -l)

    # Log to CSV
    echo "$timestamp,$elapsed,$target_streams,$active_streams,$gpu_util,$gpu_mem_used,$gpu_mem_total,$gpu_temp,$nvenc_sessions,$cpu_percent,$ram_used,$ram_total,$disk_used,$disk_available,$streams_with_files" >> "$DETAILED_CSV"

    # Update live display
    {
        echo "=== LIVE METRICS [$(date '+%H:%M:%S')] ==="
        echo "Elapsed: ${elapsed}s / ${TEST_DURATION}s"
        echo "Streams: $active_streams/$target_streams active"
        echo ""
        echo "=== GPU ==="
        echo "Utilization: ${gpu_util}%"
        echo "Memory: ${gpu_mem_used}MB / ${gpu_mem_total}MB ($(( gpu_mem_used * 100 / gpu_mem_total ))%)"
        echo "Temperature: ${gpu_temp}°C"
        echo "NVENC Sessions: $nvenc_sessions"
        echo ""
        echo "=== SYSTEM ==="
        echo "CPU: ${cpu_percent}%"
        echo "RAM: ${ram_used}MB / ${ram_total}MB ($(( ram_used * 100 / ram_total ))%)"
        echo "Disk Used: ${disk_used}GB"
        echo "Disk Available: ${disk_available}GB"
        echo ""
        echo "=== OUTPUT FILES ==="
        echo "Streams with playlist.m3u8: $streams_with_files"
        echo "Total TS segments: $(find "$STREAMS_DIR" -name "*.ts" | wc -l)"
        echo "Output directory size: $(du -sh "$OUTPUT_BASE" | cut -f1)"
        echo ""
        echo "=== REALTIME CONSOLE ==="
    } > "$LIVE_METRICS"

    # Console display
    printf "\r%s[%3ds]%s GPU:%s%3d%%%s(%d°C) | VRAM:%s%4dMB%s/%dMB | NVENC:%s%2d%s | CPU:%s%3d%%%s | RAM:%s%4dMB%s | Disk:%s%3dGB%s | Files:%s%3d%s | Active:%s%3d%s/%d   " \
        "$CYAN" $elapsed "$NC" \
        "$YELLOW" $gpu_util "$NC" $gpu_temp \
        "$BLUE" $gpu_mem_used "$NC" $gpu_mem_total \
        "$MAGENTA" $nvenc_sessions "$NC" \
        "$RED" $cpu_percent "$NC" \
        "$GREEN" $ram_used "$NC" \
        "$CYAN" $disk_used "$NC" \
        "$BLUE" $streams_with_files "$NC" \
        "$GREEN" $active_streams "$NC" $target_streams
}

# Monitor concurrent execution with detailed metrics
monitor_concurrent_execution() {
    local pids=("${!1}")
    local target_count=$2

    local start_time=$(date +%s)
    echo -e "\n${GREEN}Monitoring ${#pids[@]} concurrent streams...${NC}"
    echo -e "${YELLOW}Real-time metrics: tail -f $LIVE_METRICS${NC}"
    echo -e "${YELLOW}Detailed CSV: $DETAILED_CSV${NC}"
    echo ""

    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        # Count active processes
        local active=0
        for pid in "${pids[@]}"; do
            if kill -0 $pid 2>/dev/null; then
                ((active++))
            fi
        done

        # Collect and display metrics
        collect_system_metrics $current_time $elapsed $target_count $active

        # Log disk usage periodically
        if [ $((elapsed % 15)) -eq 0 ]; then
            echo "[$(date)] Disk usage at ${elapsed}s:" >> "$DISK_USAGE_LOG"
            df -h "$OUTPUT_BASE" >> "$DISK_USAGE_LOG"
            echo "" >> "$DISK_USAGE_LOG"
        fi

        # Check completion
        if [ $active -eq 0 ]; then
            echo -e "\n${GREEN}All streams finished${NC}"
            break
        fi

        # Safety timeout
        if [ $elapsed -gt $((TEST_DURATION + 30)) ]; then
            echo -e "\n${YELLOW}Test timeout${NC}"
            break
        fi

        sleep 2
    done

    echo ""
}

# Generate final report
generate_final_report() {
    local target_streams=$1

    echo -e "${BLUE}Generating final report...${NC}"

    # Count final results
    local total_playlists=$(find "$STREAMS_DIR" -name "playlist.m3u8" | wc -l)
    local total_segments=$(find "$STREAMS_DIR" -name "*.ts" | wc -l)
    local total_size=$(du -sh "$OUTPUT_BASE" | cut -f1)

    # Peak and average metrics from CSV
    local peak_gpu=$(awk -F',' 'NR>1 {if($5>max) max=$5} END {print max}' "$DETAILED_CSV")
    local avg_gpu=$(awk -F',' 'NR>1 {sum+=$5; count++} END {printf "%.1f", sum/count}' "$DETAILED_CSV")
    local peak_vram=$(awk -F',' 'NR>1 {if($6>max) max=$6} END {print max}' "$DETAILED_CSV")
    local avg_vram=$(awk -F',' 'NR>1 {sum+=$6; count++} END {printf "%.0f", sum/count}' "$DETAILED_CSV")
    local peak_nvenc=$(awk -F',' 'NR>1 {if($9>max) max=$9} END {print max}' "$DETAILED_CSV")
    local avg_nvenc=$(awk -F',' 'NR>1 {sum+=$9; count++} END {printf "%.1f", sum/count}' "$DETAILED_CSV")
    local peak_cpu=$(awk -F',' 'NR>1 {if($10>max) max=$10} END {print max}' "$DETAILED_CSV")
    local avg_cpu=$(awk -F',' 'NR>1 {sum+=$10; count++} END {printf "%.1f", sum/count}' "$DETAILED_CSV")

    # Create summary report
    cat > "$SUMMARY_REPORT" << EOF
=== GPU Concurrent Transcoding Test Summary ===

Test Configuration:
- Date: $(date)
- Target Streams: $target_streams
- Duration: ${TEST_DURATION}s
- Output Format: HLS (1280x720, CQ36)
- GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)

Results:
- Successful streams (with playlist.m3u8): $total_playlists
- Success rate: $(( total_playlists * 100 / target_streams ))%
- Total TS segments generated: $total_segments
- Total output size: $total_size

Performance Metrics:
- GPU Utilization: Peak ${peak_gpu}% | Average ${avg_gpu}%
- VRAM Usage: Peak ${peak_vram}MB | Average ${avg_vram}MB
- NVENC Sessions: Peak $peak_nvenc | Average ${avg_nvenc}
- CPU Usage: Peak ${peak_cpu}% | Average ${avg_cpu}%

Output Files:
- Streams directory: $STREAMS_DIR
- Individual logs: $LOGS_DIR
- Live metrics: $LIVE_METRICS
- Detailed CSV: $DETAILED_CSV
- Disk usage log: $DISK_USAGE_LOG

Manual Inspection Commands:
- Check playlist files: find $STREAMS_DIR -name "playlist.m3u8" | head -10
- Check TS segments: find $STREAMS_DIR -name "*.ts" | head -10
- Check specific stream: ls -la $STREAMS_DIR/stream_0001/
- Check FFmpeg logs: ls -la $LOGS_DIR/
- Play test stream: ffplay $STREAMS_DIR/stream_0001/playlist.m3u8
EOF

    echo -e "${GREEN}Final report saved: $SUMMARY_REPORT${NC}"
    echo ""
    cat "$SUMMARY_REPORT"
}

# Main test execution
run_detailed_concurrent_test() {
    local target_streams=$1

    echo -e "\n${YELLOW}=== Launching $target_streams Concurrent Streams with File Outputs ===${NC}"

    local pids=()
    local launch_start=$(date +%s)

    # Launch all streams
    for ((i=0; i<target_streams; i++)); do
        local pid=$(launch_stream_with_files $i)
        pids+=($pid)

        # Progress
        if [ $((i % 20)) -eq 0 ] || [ $i -eq $((target_streams-1)) ]; then
            printf "\r  Launched: %d/%d" $((i+1)) $target_streams
        fi

        # Minimal delay to prevent system overload
        if [ $((i % 50)) -eq 0 ] && [ $i -gt 0 ]; then
            sleep 0.05
        fi
    done

    local launch_end=$(date +%s)
    local launch_time=$((launch_end - launch_start))
    echo -e "\n${GREEN}All $target_streams streams launched in ${launch_time}s${NC}"

    # Monitor execution
    monitor_concurrent_execution pids[@] $target_streams

    # Generate final report
    generate_final_report $target_streams
}

# Cleanup
cleanup() {
    echo -e "\n${YELLOW}Cleaning up processes...${NC}"
    pkill -f "ffmpeg.*h264_nvenc" 2>/dev/null || true
    sleep 3
    pkill -9 -f "ffmpeg.*h264_nvenc" 2>/dev/null || true
}

# Main
main() {
    echo -e "${GREEN}=== Detailed Concurrent GPU Test with File Outputs ===${NC}"
    echo "Output directory: $OUTPUT_BASE"
    echo ""

    init_monitoring
    optimize_system

    # GPU check
    if ! nvidia-smi &>/dev/null; then
        echo -e "${RED}ERROR: NVIDIA GPU not detected${NC}"
        exit 1
    fi

    echo -e "${BLUE}GPU:${NC} $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader)"
    echo ""

    # Test different levels
    test_levels=(5 10 20 50 100 150 200)

    for level in "${test_levels[@]}"; do
        run_detailed_concurrent_test $level

        echo -e "\n${YELLOW}View results:${NC}"
        echo "  Live metrics: tail -f $LIVE_METRICS"
        echo "  Summary: cat $SUMMARY_REPORT"
        echo "  Files: ls -la $STREAMS_DIR/"

        if [ $level -lt 200 ]; then
            echo -e "\n${BLUE}Continue to next test level? (y/N):${NC}"
            read -t 10 -n 1 continue_test
            echo ""
            if [[ ! $continue_test =~ ^[Yy]$ ]]; then
                break
            fi

            # Cleanup between tests
            cleanup
            rm -rf "$STREAMS_DIR"/* "$LOGS_DIR"/*
            sleep 10
        fi
    done

    echo -e "\n${GREEN}=== All tests complete ===${NC}"
    echo "Final results in: $OUTPUT_BASE/"
}

trap cleanup EXIT INT TERM

main "$@"