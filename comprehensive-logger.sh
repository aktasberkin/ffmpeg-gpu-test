#!/bin/bash

# Comprehensive Logger - Her stream için detaylı log sistemi
# Individual stream tracking, error analysis, performance per stream

set -e

STREAM_COUNT=${1:-25}
DURATION=${2:-45}
OUTPUT_DIR="comprehensive_test_$(date +%H%M%S)"
MASTER_LOG="$OUTPUT_DIR/master.log"
STREAM_LOGS_DIR="$OUTPUT_DIR/stream_logs"
ERRORS_LOG="$OUTPUT_DIR/errors.log"
PERFORMANCE_LOG="$OUTPUT_DIR/performance.csv"
SUMMARY_LOG="$OUTPUT_DIR/summary.json"

# Colors
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

echo "${GREEN}=== Comprehensive Logging System ===${NC}"
echo "Streams: $STREAM_COUNT | Duration: ${DURATION}s"
echo "Output directory: $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR" "$STREAM_LOGS_DIR"

# Initialize logs
echo "timestamp,stream_id,status,fps,bitrate,gpu_util,cpu_percent,memory_kb" > "$PERFORMANCE_LOG"
cat > "$SUMMARY_LOG" << 'EOF'
{
  "test_config": {
    "stream_count": 0,
    "duration": 0,
    "start_time": "",
    "end_time": ""
  },
  "streams": {},
  "system_performance": {
    "peak_gpu": 0,
    "avg_gpu": 0,
    "peak_cpu": 0,
    "peak_memory": 0
  },
  "success_metrics": {
    "successful_streams": 0,
    "failed_streams": 0,
    "success_rate": 0
  }
}
EOF

# Logging functions
log_master() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$MASTER_LOG"
}

log_error() {
    echo "[$(date '+%H:%M:%S')] ERROR: $1" | tee -a "$ERRORS_LOG"
    echo "${RED}ERROR: $1${NC}"
}

log_stream() {
    local stream_id=$1
    local message=$2
    echo "[$(date '+%H:%M:%S')] Stream $stream_id: $message" >> "$STREAM_LOGS_DIR/stream_${stream_id}.log"
}

# Stream performance analyzer
analyze_stream_performance() {
    local stream_id=$1
    local log_file="$STREAM_LOGS_DIR/stream_${stream_id}.log"
    local ffmpeg_log="$OUTPUT_DIR/stream_${stream_id}.log"

    if [ ! -f "$ffmpeg_log" ]; then
        return 1
    fi

    # Extract performance metrics from FFmpeg log
    local fps=$(tail -50 "$ffmpeg_log" 2>/dev/null | grep -o "fps=[0-9.]*" | tail -1 | cut -d'=' -f2 || echo "0")
    local bitrate=$(tail -50 "$ffmpeg_log" 2>/dev/null | grep -o "bitrate=[0-9.]*kbits/s" | tail -1 | cut -d'=' -f2 | cut -d'k' -f1 || echo "0")
    local speed=$(tail -50 "$ffmpeg_log" 2>/dev/null | grep -o "speed=[0-9.]*x" | tail -1 | cut -d'=' -f2 | cut -d'x' -f1 || echo "0")

    # System metrics
    local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")
    local cpu_percent=$(top -bn1 | awk '/^%Cpu/ {print int(100-$8)}' 2>/dev/null | head -1 || echo "0")
    local memory_kb=$(ps -p $2 -o rss= 2>/dev/null || echo "0")

    # Log performance data
    echo "$(date +%s),$stream_id,RUNNING,$fps,$bitrate,$gpu_util,$cpu_percent,$memory_kb" >> "$PERFORMANCE_LOG"

    # Stream-specific log
    log_stream $stream_id "Performance - FPS: $fps, Bitrate: ${bitrate}kbps, Speed: ${speed}x, Memory: ${memory_kb}KB"

    echo "$fps $bitrate $speed"
}

# Stream launcher with detailed logging
launch_stream() {
    local stream_id=$1
    local start_delay=$2

    log_stream $stream_id "Preparing to launch with ${start_delay}s delay"

    if [ $start_delay -gt 0 ]; then
        sleep $start_delay
    fi

    # Choose different synthetic patterns for variety
    local patterns=("testsrc2=size=1280x720:rate=30" "smptebars=size=1280x720:rate=30" "mandelbrot=size=1280x720:rate=30" "plasma=size=1280x720:rate=30")
    local pattern_index=$((stream_id % ${#patterns[@]}))
    local input_pattern="${patterns[$pattern_index]}"

    log_stream $stream_id "Launching with pattern: $input_pattern"
    log_stream $stream_id "Target duration: ${DURATION}s"

    # Launch FFmpeg with comprehensive logging
    ffmpeg -f lavfi -i "$input_pattern" \
        -t $DURATION \
        -c:v h264_nvenc \
        -preset p4 \
        -cq 36 \
        -g 60 \
        -f hls \
        -hls_time 6 \
        -hls_list_size 10 \
        -hls_segment_filename "$OUTPUT_DIR/stream${stream_id}_%05d.ts" \
        -hls_playlist_type vod \
        "$OUTPUT_DIR/stream${stream_id}.m3u8" \
        -progress pipe:1 \
        -stats_period 5 \
        >"$OUTPUT_DIR/stream_${stream_id}.log" 2>&1 &

    local pid=$!
    log_stream $stream_id "Started with PID: $pid"
    echo $pid
}

# Stream monitor
monitor_stream() {
    local stream_id=$1
    local pid=$2

    log_stream $stream_id "Monitoring started for PID: $pid"

    while kill -0 $pid 2>/dev/null; do
        # Analyze performance every 10 seconds
        local perf_data=$(analyze_stream_performance $stream_id $pid)
        sleep 10
    done

    # Final analysis
    local exit_code=$?
    if wait $pid; then
        log_stream $stream_id "Completed successfully"
        echo "$(date +%s),$stream_id,SUCCESS,0,0,0,0,0" >> "$PERFORMANCE_LOG"
    else
        log_stream $stream_id "Failed with exit code: $exit_code"
        log_error "Stream $stream_id failed (PID: $pid, Exit: $exit_code)"
        echo "$(date +%s),$stream_id,FAILED,0,0,0,0,0" >> "$PERFORMANCE_LOG"
    fi
}

# Main execution
main() {
    local start_time=$(date +%s)
    local pids=()
    local monitor_pids=()

    log_master "Starting comprehensive test with $STREAM_COUNT streams"
    log_master "Test configuration saved to: $OUTPUT_DIR"

    # Update summary with test config
    jq --arg count "$STREAM_COUNT" --arg duration "$DURATION" --arg start "$(date -Iseconds)" \
       '.test_config.stream_count = ($count | tonumber) | .test_config.duration = ($duration | tonumber) | .test_config.start_time = $start' \
       "$SUMMARY_LOG" > "$SUMMARY_LOG.tmp" && mv "$SUMMARY_LOG.tmp" "$SUMMARY_LOG"

    echo ""
    echo "${YELLOW}=== Launching Streams ===${NC}"

    # Launch all streams with staggered start (prevent fork bomb)
    for ((i=0; i<STREAM_COUNT; i++)); do
        local delay=$((i / 10))  # 0.1s delay every 10 streams

        pid=$(launch_stream $i $delay)
        pids[i]=$pid

        # Start background monitor for this stream
        monitor_stream $i $pid &
        monitor_pids[i]=$!

        printf "\r${CYAN}Launched: %d/%d (PID: %d)${NC}" $((i+1)) $STREAM_COUNT $pid

        # Small delay between launches
        sleep 0.01
    done

    echo ""
    log_master "All $STREAM_COUNT streams launched"

    echo ""
    echo "${YELLOW}=== System Monitoring ===${NC}"
    echo "Time | Active | Success | Failed | GPU% | CPU% | Logs"
    echo "-----+--------+---------+--------+------+------+------"

    # Main monitoring loop
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        # Count active processes
        local active=0
        for pid in "${pids[@]}"; do
            if kill -0 $pid 2>/dev/null; then
                active=$((active + 1))
            fi
        done

        # Count success/failures
        local successful=$(grep -c ",SUCCESS," "$PERFORMANCE_LOG" 2>/dev/null || echo 0)
        local failed=$(grep -c ",FAILED," "$PERFORMANCE_LOG" 2>/dev/null || echo 0)

        # System metrics
        local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")
        local cpu_percent=$(top -bn1 | awk '/^%Cpu/ {print int(100-$8)}' 2>/dev/null | head -1 || echo "0")

        # Log counts
        local error_count=$(wc -l < "$ERRORS_LOG" 2>/dev/null || echo 0)

        printf "%4ds | %6d | %7d | %6d | %3s%% | %3s%% | %4d\n" \
            $elapsed $active $successful $failed $gpu_util $cpu_percent $error_count

        # Check completion
        if [ $active -eq 0 ]; then
            log_master "All streams completed"
            break
        fi

        # Timeout check
        if [ $elapsed -gt $((DURATION + 120)) ]; then
            log_error "Test timeout reached, killing remaining processes"
            for pid in "${pids[@]}"; do
                kill -9 $pid 2>/dev/null || true
            done
            break
        fi

        sleep 5
    done

    # Wait for all monitors to finish
    for monitor_pid in "${monitor_pids[@]}"; do
        wait $monitor_pid 2>/dev/null || true
    done

    # Final analysis
    analyze_final_results $start_time
}

# Final results analysis
analyze_final_results() {
    local start_time=$1
    local end_time=$(date +%s)
    local total_duration=$((end_time - start_time))

    echo ""
    echo "${GREEN}=== Final Analysis ===${NC}"

    # Count results
    local total_streams=$(find "$OUTPUT_DIR" -name "stream*.m3u8" 2>/dev/null | wc -l)
    local total_segments=$(find "$OUTPUT_DIR" -name "stream*_*.ts" 2>/dev/null | wc -l)
    local successful=$(grep -c ",SUCCESS," "$PERFORMANCE_LOG" 2>/dev/null || echo 0)
    local failed=$(grep -c ",FAILED," "$PERFORMANCE_LOG" 2>/dev/null || echo 0)
    local success_rate=$((successful * 100 / STREAM_COUNT))

    echo "Duration: ${total_duration}s"
    echo "Successful streams: $successful/$STREAM_COUNT ($success_rate%)"
    echo "Failed streams: $failed"
    echo "Generated playlists: $total_streams"
    echo "Generated segments: $total_segments"
    echo "Error count: $(wc -l < "$ERRORS_LOG" 2>/dev/null || echo 0)"

    # Performance averages
    local avg_gpu=$(awk -F',' 'NR>1 && $6!="" && $6!=0 {sum+=$6; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}' "$PERFORMANCE_LOG")
    local peak_gpu=$(awk -F',' 'NR>1 && $6!="" {if($6>max) max=$6} END {print max+0}' "$PERFORMANCE_LOG")

    echo "Peak GPU utilization: ${peak_gpu}%"
    echo "Average GPU utilization: ${avg_gpu}%"

    # Update final summary
    jq --arg end "$(date -Iseconds)" --arg success "$successful" --arg failed "$failed" --arg rate "$success_rate" \
       --arg peak_gpu "$peak_gpu" --arg avg_gpu "$avg_gpu" \
       '.test_config.end_time = $end |
        .success_metrics.successful_streams = ($success | tonumber) |
        .success_metrics.failed_streams = ($failed | tonumber) |
        .success_metrics.success_rate = ($rate | tonumber) |
        .system_performance.peak_gpu = ($peak_gpu | tonumber) |
        .system_performance.avg_gpu = ($avg_gpu | tonumber)' \
       "$SUMMARY_LOG" > "$SUMMARY_LOG.tmp" && mv "$SUMMARY_LOG.tmp" "$SUMMARY_LOG"

    echo ""
    echo "${CYAN}Generated Files:${NC}"
    echo "  Master log: $MASTER_LOG"
    echo "  Performance data: $PERFORMANCE_LOG"
    echo "  Error log: $ERRORS_LOG"
    echo "  Stream logs: $STREAM_LOGS_DIR/"
    echo "  Summary JSON: $SUMMARY_LOG"
    echo "  HLS outputs: $OUTPUT_DIR/stream*.m3u8"

    if [ $success_rate -ge 90 ]; then
        echo "${GREEN}✅ SUCCESS: >90% completion rate${NC}"
    elif [ $success_rate -ge 70 ]; then
        echo "${YELLOW}⚠️ PARTIAL SUCCESS: $success_rate% completion rate${NC}"
    else
        echo "${RED}❌ FAILED: Only $success_rate% completion rate${NC}"
    fi
}

# Cleanup function
cleanup() {
    echo ""
    echo "${YELLOW}Cleaning up...${NC}"
    pkill -f "ffmpeg.*h264_nvenc" 2>/dev/null || true
    sleep 2
}

# Set cleanup trap
trap cleanup EXIT INT TERM

# Run main function
main "$@"

echo ""
echo "${GREEN}🚀 Comprehensive logging test complete!${NC}"