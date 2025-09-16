#!/bin/bash

# Simple Concurrent GPU Test - Fork bombing ve sed sorunlarını çözen basit versiyon

set -e

STREAM_COUNT=${1:-30}
TEST_DURATION=${2:-60}
QUALITY_CQ=${3:-36}
PRESET=${4:-p4}

OUTPUT_DIR="simple_gpu_test_$(date +%Y%m%d_%H%M%S)"
MONITOR_LOG="$OUTPUT_DIR/monitoring.csv"

# Colors
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

echo "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo "${GREEN}║         Simple Concurrent GPU Test            ║${NC}"
echo "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo ""
echo "${CYAN}Configuration:${NC}"
echo "  Streams: $STREAM_COUNT"
echo "  Duration: ${TEST_DURATION}s"
echo "  Quality: CQ $QUALITY_CQ"
echo "  Preset: $PRESET"
echo ""

mkdir -p "$OUTPUT_DIR"

# Verify GPU
if ! nvidia-smi &>/dev/null; then
    echo "${RED}❌ NVIDIA GPU not found${NC}"
    exit 1
fi

echo "${GREEN}✅ GPU detected: $(nvidia-smi --query-gpu=name --format=csv,noheader)${NC}"

# Check FFmpeg NVENC
if ! ffmpeg -encoders 2>/dev/null | grep -q h264_nvenc; then
    echo "${RED}❌ FFmpeg NVENC not available${NC}"
    exit 1
fi

echo "${GREEN}✅ FFmpeg NVENC support verified${NC}"
echo ""

# Initialize monitoring
echo "timestamp,elapsed,active,gpu_util,gpu_mem,nvenc,cpu" > "$MONITOR_LOG"

# Launch function with batch control
launch_streams() {
    local pids=()
    local patterns=("testsrc2=size=1280x720:rate=30" "smptebars=size=1280x720:rate=30" "testsrc=size=1280x720:rate=30" "color=c=blue:size=1280x720:rate=30")

    echo "${YELLOW}=== Launching Streams ===${NC}"

    # Batch size to prevent fork bombing
    local batch_size=8
    local batches=$(( (STREAM_COUNT + batch_size - 1) / batch_size ))

    for ((batch=0; batch<batches; batch++)); do
        local start_idx=$((batch * batch_size))
        local end_idx=$((start_idx + batch_size))
        if [ $end_idx -gt $STREAM_COUNT ]; then
            end_idx=$STREAM_COUNT
        fi

        echo "Batch $((batch+1))/$batches: streams $start_idx-$((end_idx-1))"

        # Launch batch
        for ((i=start_idx; i<end_idx; i++)); do
            local pattern="${patterns[$((i % ${#patterns[@]}))]}"

            ffmpeg -f lavfi -i "$pattern" \
                -t $TEST_DURATION \
                -c:v h264_nvenc \
                -preset $PRESET \
                -cq $QUALITY_CQ \
                -g 60 \
                -f hls \
                -hls_time 6 \
                -hls_list_size 0 \
                -hls_segment_filename "$OUTPUT_DIR/stream${i}_%03d.ts" \
                -hls_playlist_type vod \
                "$OUTPUT_DIR/stream${i}.m3u8" \
                >"$OUTPUT_DIR/stream${i}.log" 2>&1 &

            pids[i]=$!
            sleep 0.05  # Small delay between launches
        done

        # Wait between batches
        if [ $batch -lt $((batches - 1)) ]; then
            echo "  Stabilizing..."
            sleep 1
        fi
    done

    echo "${GREEN}✅ All $STREAM_COUNT streams launched${NC}"
    echo "${pids[*]}"
}

# Simple monitoring function
monitor_streams() {
    local pids=($1)
    local start_time=$(date +%s)

    echo ""
    echo "${YELLOW}=== Monitoring Started ===${NC}"
    echo "Time | Active | GPU%  | VRAM  | NVENC | CPU%"
    echo "-----+--------+-------+-------+-------+------"

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

        # Get metrics safely
        local gpu_util=0
        local gpu_mem=0
        local nvenc=0
        local cpu=0

        if timeout 3s nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits &>/dev/null; then
            gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")
            gpu_mem=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")
            nvenc=$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")
        fi

        cpu=$(top -bn1 2>/dev/null | awk '/^%Cpu/ {print int(100-$8)}' | head -1 || echo "0")

        # Display
        printf "%4ds | %6d | %4s%% | %4sMB | %5s | %3s%%\\n" \
            $elapsed $active $gpu_util $gpu_mem $nvenc $cpu

        # Log data
        echo "$(date +%s),$elapsed,$active,$gpu_util,$gpu_mem,$nvenc,$cpu" >> "$MONITOR_LOG"

        # Check completion
        if [ $active -eq 0 ]; then
            echo ""
            echo "${GREEN}🎉 All streams completed at ${elapsed}s${NC}"
            break
        fi

        # Timeout check
        if [ $elapsed -gt $((TEST_DURATION + 120)) ]; then
            echo ""
            echo "${YELLOW}⚠️ Timeout reached${NC}"
            for pid in "${pids[@]}"; do
                kill -9 $pid 2>/dev/null || true
            done
            break
        fi

        sleep 3
    done
}

# Results analysis
analyze_results() {
    echo ""
    echo "${CYAN}=== Results Analysis ===${NC}"

    local playlists=$(find "$OUTPUT_DIR" -name "*.m3u8" | wc -l)
    local segments=$(find "$OUTPUT_DIR" -name "*.ts" | wc -l)
    local success_rate=$(( playlists * 100 / STREAM_COUNT ))

    echo "Generated playlists: $playlists/$STREAM_COUNT"
    echo "Generated segments: $segments"
    echo "Success rate: $success_rate%"

    if [ -f "$MONITOR_LOG" ]; then
        local peak_gpu=$(awk -F',' 'NR>1 && $4!="" {if($4>max) max=$4} END {print max+0}' "$MONITOR_LOG")
        local avg_gpu=$(awk -F',' 'NR>1 && $4!="" {sum+=$4; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}' "$MONITOR_LOG")
        local peak_concurrent=$(awk -F',' 'NR>1 {if($3>max) max=$3} END {print max+0}' "$MONITOR_LOG")

        echo "Peak GPU utilization: ${peak_gpu}%"
        echo "Average GPU utilization: ${avg_gpu}%"
        echo "Peak concurrent streams: $peak_concurrent"

        # Performance assessment
        if [ $success_rate -ge 95 ]; then
            echo "${GREEN}✅ EXCELLENT: >95% success rate${NC}"
        elif [ $success_rate -ge 85 ]; then
            echo "${YELLOW}⚠️ GOOD: $success_rate% success rate${NC}"
        else
            echo "${RED}❌ NEEDS IMPROVEMENT: $success_rate% success rate${NC}"
        fi

        if [ $peak_gpu -ge 60 ]; then
            echo "${GREEN}✅ GPU WELL UTILIZED: $peak_gpu% peak${NC}"
        else
            echo "${YELLOW}⚠️ GPU UNDERUTILIZED: $peak_gpu% peak - can handle more streams${NC}"
        fi
    fi

    echo ""
    echo "Generated files:"
    echo "  Monitoring data: $MONITOR_LOG"
    echo "  HLS outputs: $OUTPUT_DIR/stream*.m3u8"
    echo "  FFmpeg logs: $OUTPUT_DIR/stream*.log"
}

# Cleanup function
cleanup() {
    echo ""
    echo "${YELLOW}Cleaning up processes...${NC}"
    pkill -f "ffmpeg.*h264_nvenc" 2>/dev/null || true
    sleep 2
}

trap cleanup EXIT INT TERM

# Main execution
main() {
    # Launch streams and get PIDs
    pids_string=$(launch_streams)

    # Monitor execution
    monitor_streams "$pids_string"

    # Analyze results
    analyze_results

    echo ""
    echo "${GREEN}🚀 Test completed successfully!${NC}"
    echo "Output directory: $OUTPUT_DIR"
}

main "$@"