#!/bin/bash

# Final Concurrent GPU Test - Fixed based on working simple test
# Real file outputs with proper monitoring

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

# Initialize monitoring
init_monitoring() {
    echo -e "${BLUE}Initializing monitoring files...${NC}"

    cat > "$DETAILED_CSV" << EOF
timestamp,elapsed_sec,target_streams,active_streams,gpu_util_percent,gpu_mem_used_mb,nvenc_sessions,cpu_percent,streams_with_files,success_rate
EOF
}

# System optimization
optimize_system() {
    echo -e "${YELLOW}System optimization...${NC}"
    ulimit -n 65536 2>/dev/null || echo "Warning: Cannot increase file limit"
    ulimit -u 32768 2>/dev/null || echo "Warning: Cannot increase process limit"

    echo "Available RAM: $(free -h | awk 'NR==2{print $7}')"
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
    )

    echo "${patterns[$((stream_id % ${#patterns[@]}))]}"
}

# Launch single stream - WORKING VERSION FROM SIMPLE TEST
launch_stream_with_files() {
    local stream_id=$1
    local stream_dir="${STREAMS_DIR}/stream_$(printf "%04d" $stream_id)"
    local log_file="${LOGS_DIR}/stream_$(printf "%04d" $stream_id).log"

    mkdir -p "$stream_dir"
    local source=$(get_synthetic_source $stream_id)

    # Use the EXACT same command that worked in simple test
    ffmpeg -f lavfi -i "$source" \
        -t $TEST_DURATION \
        -c:v h264_nvenc \
        -preset p4 \
        -cq 36 \
        -f hls \
        -hls_time 6 \
        -hls_list_size 10 \
        -hls_flags append_list+delete_segments \
        -hls_segment_filename "${stream_dir}/segment_%05d.ts" \
        "${stream_dir}/playlist.m3u8" \
        >"$log_file" 2>&1 &

    echo $!
}

# FIXED: Collect system metrics without hanging
collect_system_metrics() {
    local timestamp=$1
    local elapsed=$2
    local target_streams=$3
    local active_streams=$4

    # SAFE GPU metrics collection
    local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo 0)
    local gpu_mem=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo 0)
    local nvenc=$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo 0)

    # SAFE CPU calculation
    local cpu_percent=$(top -bn1 2>/dev/null | awk '/^%Cpu/ {print 100-$8}' | cut -d'.' -f1 | head -1 || echo 0)

    # Count streams with files
    local streams_with_files=$(find "$STREAMS_DIR" -name "playlist.m3u8" 2>/dev/null | wc -l)
    local success_rate=0
    if [ $target_streams -gt 0 ]; then
        success_rate=$((streams_with_files * 100 / target_streams))
    fi

    # Log to CSV
    echo "$timestamp,$elapsed,$target_streams,$active_streams,$gpu_util,$gpu_mem,$nvenc,$cpu_percent,$streams_with_files,$success_rate" >> "$DETAILED_CSV"

    # Console display - SIMPLIFIED to avoid printf issues
    printf "\r[%3ds] Active:%3d/%d | GPU:%3s%% | VRAM:%4sMB | NVENC:%2s | CPU:%3s%% | Files:%3d (%d%%)" \
        "$elapsed" "$active_streams" "$target_streams" "$gpu_util" "$gpu_mem" "$nvenc" "$cpu_percent" "$streams_with_files" "$success_rate"
}

# Monitor execution - FIXED timing
monitor_concurrent_execution() {
    local pids=("${!1}")
    local target_count=$2

    local start_time=$(date +%s)
    echo -e "\n${GREEN}Monitoring ${#pids[@]} concurrent streams...${NC}"

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

        # Check completion
        if [ $active -eq 0 ]; then
            echo -e "\n${GREEN}All streams completed${NC}"
            break
        fi

        if [ $elapsed -gt $((TEST_DURATION + 30)) ]; then
            echo -e "\n${YELLOW}Test timeout${NC}"
            break
        fi

        sleep 3  # Increased from 2 to reduce monitoring overhead
    done

    echo ""
}

# Generate final report with proper averages
generate_final_report() {
    local target_streams=$1

    echo -e "${BLUE}Generating final report...${NC}"

    # Count results
    local total_playlists=$(find "$STREAMS_DIR" -name "playlist.m3u8" 2>/dev/null | wc -l)
    local total_segments=$(find "$STREAMS_DIR" -name "*.ts" 2>/dev/null | wc -l)
    local total_size=$(du -sh "$OUTPUT_BASE" 2>/dev/null | cut -f1)

    # Calculate averages from CSV (skip header)
    local avg_gpu=$(awk -F',' 'NR>1 && $5!="" {sum+=$5; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}' "$DETAILED_CSV")
    local peak_gpu=$(awk -F',' 'NR>1 && $5!="" {if($5>max) max=$5} END {print max+0}' "$DETAILED_CSV")
    local max_nvenc=$(awk -F',' 'NR>1 && $7!="" {if($7>max) max=$7} END {print max+0}' "$DETAILED_CSV")

    # Create summary
    cat > "$SUMMARY_REPORT" << EOF
=== GPU Concurrent Transcoding Test Summary ===

Test Configuration:
- Date: $(date)
- Target Streams: $target_streams
- Duration: ${TEST_DURATION}s per stream
- GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)

Results:
- Successful streams: $total_playlists/$target_streams ($(($total_playlists * 100 / target_streams))%)
- Total segments created: $total_segments
- Total output size: $total_size

Performance:
- GPU Utilization: Peak ${peak_gpu}% | Average ${avg_gpu}%
- Max NVENC Sessions: $max_nvenc

Output Files:
- Streams: $STREAMS_DIR
- Logs: $LOGS_DIR
- CSV: $DETAILED_CSV

Success Criteria:
$([ $total_playlists -ge $((target_streams * 90 / 100)) ] && echo "✅ PASSED: >90% success rate" || echo "⚠️  LOW: <90% success rate")
$([ $(echo "$peak_gpu > 50" | bc 2>/dev/null || echo 0) -eq 1 ] && echo "✅ GPU: Good utilization" || echo "⚠️  GPU: Low utilization")
EOF

    echo -e "${GREEN}Report saved: $SUMMARY_REPORT${NC}"
    cat "$SUMMARY_REPORT"
}

# Main test function
run_concurrent_test() {
    local target_streams=$1

    echo -e "\n${YELLOW}=== Testing $target_streams Concurrent GPU Streams ===${NC}"

    local pids=()
    local launch_start=$(date +%s)

    # Launch streams
    echo "Launching streams..."
    for ((i=0; i<target_streams; i++)); do
        local pid=$(launch_stream_with_files $i)
        pids+=($pid)

        # Progress indicator
        if [ $((i % 10)) -eq 0 ] || [ $i -eq $((target_streams-1)) ]; then
            printf "\r  Launched: %d/%d" $((i+1)) $target_streams
        fi

        # Small delay to prevent system overload
        if [ $((i % 25)) -eq 0 ] && [ $i -gt 0 ]; then
            sleep 0.2
        fi
    done

    echo -e "\n${GREEN}All streams launched${NC}"

    # Monitor execution
    monitor_concurrent_execution pids[@] $target_streams

    # Wait a bit for file system sync
    sleep 2

    # Generate report
    generate_final_report $target_streams
}

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    pkill -f "ffmpeg.*h264_nvenc" 2>/dev/null || true
    sleep 2
}

# Main execution
main() {
    echo -e "${GREEN}=== GPU Concurrent HLS Transcoding Test ===${NC}"
    echo "Output directory: $OUTPUT_BASE"

    # Check prerequisites
    if ! nvidia-smi &>/dev/null; then
        echo -e "${RED}ERROR: NVIDIA GPU not detected${NC}"
        exit 1
    fi

    if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_nvenc; then
        echo -e "${RED}ERROR: FFmpeg NVENC support not found${NC}"
        exit 1
    fi

    echo -e "${BLUE}GPU:${NC} $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader)"

    # Initialize
    init_monitoring
    optimize_system

    # Test sequence
    test_levels=(5 10 20 50 100 150 200)

    for level in "${test_levels[@]}"; do
        run_concurrent_test $level

        echo -e "\n${BLUE}Test Results Summary:${NC}"
        echo "- Output directory: $OUTPUT_BASE"
        echo "- Detailed metrics: $DETAILED_CSV"
        echo "- Full report: $SUMMARY_REPORT"

        if [ $level -lt 200 ]; then
            echo -e "\n${CYAN}Continue to next level ($((level*2))+)? (y/N):${NC}"
            read -t 15 -n 1 continue_test
            echo ""
            if [[ ! $continue_test =~ ^[Yy]$ ]]; then
                echo "Test sequence stopped by user"
                break
            fi

            # Clean up between tests
            cleanup
            rm -rf "$STREAMS_DIR"/* "$LOGS_DIR"/*
            sleep 5
        fi
    done

    echo -e "\n${GREEN}=== All Tests Complete ===${NC}"
    echo "Final results: $OUTPUT_BASE"
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Run main
main "$@"