#!/bin/bash

# True Concurrent Test - ALL streams launch simultaneously
# No batching, 1s monitoring intervals to catch true peak concurrency

STREAM_COUNT=${1:-30}
TEST_DURATION=${2:-90}
OUTPUT_DIR="true_concurrent_$(date +%Y%m%d_%H%M%S)"

# Colors
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

echo "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo "${GREEN}║          TRUE CONCURRENT GPU TEST             ║${NC}"
echo "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo ""
echo "${CYAN}Configuration:${NC}"
echo "  Streams: $STREAM_COUNT (ALL SIMULTANEOUS)"
echo "  Duration: ${TEST_DURATION}s"
echo "  Monitor: 1s intervals (high frequency)"
echo ""

mkdir -p "$OUTPUT_DIR"

# Verify GPU
echo "${GREEN}✅ GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader)${NC}"
echo ""

# Initialize monitoring
echo "timestamp,elapsed,active,gpu_util,gpu_mem,nvenc,cpu" > "$OUTPUT_DIR/monitoring.csv"

# Launch ALL streams simultaneously
launch_all_streams() {
    local pids=()
    local patterns=("testsrc2=size=1280x720:rate=30" "smptebars=size=1280x720:rate=30" "testsrc=size=1280x720:rate=30" "color=c=blue:size=1280x720:rate=30")

    echo "${YELLOW}=== SIMULTANEOUS LAUNCH ===${NC}"
    echo "Launching ALL $STREAM_COUNT streams immediately..."

    # Launch ALL streams with minimal delay
    for ((i=0; i<STREAM_COUNT; i++)); do
        local pattern="${patterns[$((i % ${#patterns[@]}))]}"

        ffmpeg -f lavfi -i "$pattern" \
            -t $TEST_DURATION \
            -c:v h264_nvenc \
            -preset p4 \
            -cq 36 \
            -g 60 \
            -f hls \
            -hls_time 6 \
            -hls_list_size 0 \
            -hls_segment_filename "$OUTPUT_DIR/stream${i}_%03d.ts" \
            -hls_playlist_type vod \
            "$OUTPUT_DIR/stream${i}.m3u8" \
            >"$OUTPUT_DIR/stream${i}.log" 2>&1 &

        pids[i]=$!
        sleep 0.01  # 10ms delay only
    done

    echo "${GREEN}✅ ALL $STREAM_COUNT streams launched!${NC}"
    echo ""

    # Immediate concurrent check
    sleep 0.5
    local immediate_count=0
    for pid in "${pids[@]}"; do
        if kill -0 $pid 2>/dev/null; then
            immediate_count=$((immediate_count + 1))
        fi
    done

    echo "${CYAN}Immediate count (0.5s): $immediate_count/$STREAM_COUNT${NC}"
    echo ""

    echo "${pids[*]}"
}

# High-frequency monitoring
monitor_streams() {
    local pids=($1)
    local start_time=$(date +%s)
    local max_concurrent=0

    echo "${YELLOW}=== HIGH FREQUENCY MONITORING ===${NC}"
    echo "Time | Active | Peak | GPU%  | VRAM  | NVENC | CPU% | Status"
    echo "-----+--------+------+-------+-------+-------+------+-------------"

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

        # Track peak
        if [ $active -gt $max_concurrent ]; then
            max_concurrent=$active
        fi

        # Get GPU metrics
        local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")
        local gpu_mem=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")
        local nvenc=$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo "0")
        local cpu=$(top -bn1 2>/dev/null | awk '/^%Cpu/ {print int(100-$8)}' | head -1 || echo "0")

        # Status indicator
        local status=""
        if [ $active -eq $STREAM_COUNT ]; then
            status="${GREEN}FULL-CONCURRENT${NC}"
        elif [ $active -eq $max_concurrent ] && [ $active -gt $((STREAM_COUNT * 80 / 100)) ]; then
            status="${YELLOW}HIGH-CONCURRENT${NC}"
        fi

        printf "%4ds | %6d | %4d | %4s%% | %4sMB | %5s | %3s%% | %s\\n" \
            $elapsed $active $max_concurrent $gpu_util $gpu_mem $nvenc $cpu "$status"

        # Log data
        echo "$(date +%s),$elapsed,$active,$gpu_util,$gpu_mem,$nvenc,$cpu" >> "$OUTPUT_DIR/monitoring.csv"

        # Check completion
        if [ $active -eq 0 ]; then
            echo ""
            echo "${GREEN}🎉 All completed at ${elapsed}s${NC}"
            echo "${CYAN}PEAK CONCURRENT: $max_concurrent/$STREAM_COUNT${NC}"
            break
        fi

        if [ $elapsed -gt $((TEST_DURATION + 30)) ]; then
            echo "${YELLOW}⚠️ Timeout reached${NC}"
            break
        fi

        sleep 1  # 1-second intervals
    done

    return $max_concurrent
}

# Results analysis with detailed metrics
analyze_results() {
    local max_concurrent=$1

    echo ""
    echo "${CYAN}=== COMPREHENSIVE ANALYSIS ===${NC}"

    local playlists=$(find "$OUTPUT_DIR" -name "*.m3u8" | wc -l)
    local segments=$(find "$OUTPUT_DIR" -name "*.ts" | wc -l)
    local concurrency_rate=$(( max_concurrent * 100 / STREAM_COUNT ))

    echo "Stream Results:"
    echo "  Target streams: $STREAM_COUNT"
    echo "  Peak concurrent: $max_concurrent"
    echo "  Concurrency rate: $concurrency_rate%"
    echo "  Success rate: $(( playlists * 100 / STREAM_COUNT ))%"
    echo "  Total segments: $segments"

    # Segment analysis
    if [ $segments -gt 0 ] && [ $playlists -gt 0 ]; then
        local avg_segments_per_stream=$(( segments / playlists ))
        echo "  Average segments per stream: $avg_segments_per_stream"

        # Real average segment analysis
        echo "  Calculating average segment size..."
        local total_size=0
        local segment_count=0

        # Calculate total size of all segments
        while IFS= read -r -d '' segment_file; do
            if [ -f "$segment_file" ]; then
                local size=$(stat -f%z "$segment_file" 2>/dev/null || stat -c%s "$segment_file" 2>/dev/null || echo "0")
                total_size=$((total_size + size))
                segment_count=$((segment_count + 1))
            fi
        done < <(find "$OUTPUT_DIR" -name "*.ts" -print0)

        if [ $segment_count -gt 0 ]; then
            local avg_segment_size=$(( total_size / segment_count ))
            local avg_segment_size_kb=$(( avg_segment_size / 1024 ))
            local avg_segment_size_mb=$(echo "scale=1; $avg_segment_size / 1048576" | bc -l 2>/dev/null || echo "0")
            local total_size_mb=$(echo "scale=1; $total_size / 1048576" | bc -l 2>/dev/null || echo "0")

            echo "  Average segment size: ${avg_segment_size_kb}KB (${avg_segment_size_mb}MB)"
            echo "  Total segments analyzed: $segment_count"
            echo "  Total output size: ${total_size_mb}MB"
            echo "  Segment duration: 6 seconds (HLS setting)"
        else
            echo "  No segments found for analysis"
        fi
    fi

    # Performance metrics from monitoring log
    if [ -f "$OUTPUT_DIR/monitoring.csv" ]; then
        echo ""
        echo "Performance Metrics:"

        # GPU utilization analysis
        local avg_gpu=$(awk -F',' 'NR>1 && $4!="" {sum+=$4; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}' "$OUTPUT_DIR/monitoring.csv")
        local peak_gpu=$(awk -F',' 'NR>1 && $4!="" {if($4>max) max=$4} END {print max+0}' "$OUTPUT_DIR/monitoring.csv")

        # VRAM analysis
        local avg_vram=$(awk -F',' 'NR>1 && $5!="" {sum+=$5; count++} END {if(count>0) printf "%.0f", sum/count; else print "0"}' "$OUTPUT_DIR/monitoring.csv")
        local peak_vram=$(awk -F',' 'NR>1 && $5!="" {if($5>max) max=$5} END {print max+0}' "$OUTPUT_DIR/monitoring.csv")
        local avg_vram_gb=$(echo "scale=1; $avg_vram / 1024" | bc -l 2>/dev/null || echo "0")
        local peak_vram_gb=$(echo "scale=1; $peak_vram / 1024" | bc -l 2>/dev/null || echo "0")

        # CPU analysis
        local avg_cpu=$(awk -F',' 'NR>1 && $7!="" {sum+=$7; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}' "$OUTPUT_DIR/monitoring.csv")
        local peak_cpu=$(awk -F',' 'NR>1 && $7!="" {if($7>max) max=$7} END {print max+0}' "$OUTPUT_DIR/monitoring.csv")

        # NVENC sessions
        local avg_nvenc=$(awk -F',' 'NR>1 && $6!="" {sum+=$6; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}' "$OUTPUT_DIR/monitoring.csv")
        local peak_nvenc=$(awk -F',' 'NR>1 && $6!="" {if($6>max) max=$6} END {print max+0}' "$OUTPUT_DIR/monitoring.csv")

        echo "  GPU Utilization:"
        echo "    Average: ${avg_gpu}%"
        echo "    Peak: ${peak_gpu}%"
        echo "  GPU Memory (VRAM):"
        echo "    Average: ${avg_vram}MB (${avg_vram_gb}GB)"
        echo "    Peak: ${peak_vram}MB (${peak_vram_gb}GB)"
        echo "  CPU Utilization:"
        echo "    Average: ${avg_cpu}%"
        echo "    Peak: ${peak_cpu}%"
        echo "  NVENC Sessions:"
        echo "    Average: ${avg_nvenc}"
        echo "    Peak: ${peak_nvenc}"

        # Performance efficiency analysis
        echo ""
        echo "Efficiency Analysis:"
        if [ $(echo "$avg_gpu > 60" | bc -l 2>/dev/null || echo 0) -eq 1 ]; then
            echo "  ${GREEN}✅ GPU WELL UTILIZED: ${avg_gpu}% average${NC}"
        elif [ $(echo "$avg_gpu > 30" | bc -l 2>/dev/null || echo 0) -eq 1 ]; then
            echo "  ${YELLOW}⚠️ GPU MODERATE: ${avg_gpu}% average - can handle more${NC}"
        else
            echo "  ${YELLOW}⚠️ GPU UNDERUTILIZED: ${avg_gpu}% average - increase load${NC}"
        fi

        if [ $(echo "$avg_cpu > 70" | bc -l 2>/dev/null || echo 0) -eq 1 ]; then
            echo "  ${YELLOW}⚠️ CPU HIGH: ${avg_cpu}% average - near limit${NC}"
        else
            echo "  ${GREEN}✅ CPU BALANCED: ${avg_cpu}% average${NC}"
        fi

        # L40S specific analysis (48GB VRAM)
        local vram_usage_percent=$(echo "scale=1; $peak_vram * 100 / 46068" | bc -l 2>/dev/null || echo "0")
        echo "  ${GREEN}✅ VRAM USAGE: ${vram_usage_percent}% of L40S capacity${NC}"
    fi

    # Concurrency assessment
    echo ""
    if [ $max_concurrent -eq $STREAM_COUNT ]; then
        echo "${GREEN}✅ PERFECT CONCURRENCY: All $STREAM_COUNT streams ran simultaneously${NC}"
    elif [ $max_concurrent -ge $((STREAM_COUNT * 90 / 100)) ]; then
        echo "${GREEN}✅ EXCELLENT CONCURRENCY: $concurrency_rate% simultaneous execution${NC}"
    elif [ $max_concurrent -ge $((STREAM_COUNT * 70 / 100)) ]; then
        echo "${YELLOW}⚠️ GOOD CONCURRENCY: $concurrency_rate% simultaneous execution${NC}"
    else
        echo "${YELLOW}⚠️ LIMITED CONCURRENCY: Only $concurrency_rate% simultaneous execution${NC}"
    fi

    echo ""
    echo "Generated files:"
    echo "  Monitor data: $OUTPUT_DIR/monitoring.csv"
    echo "  HLS outputs: $OUTPUT_DIR/stream*.m3u8"
    echo "  Segment files: $OUTPUT_DIR/stream*_*.ts"
}

# Cleanup
cleanup() {
    pkill -f "ffmpeg.*h264_nvenc" 2>/dev/null || true
    sleep 2
}

trap cleanup EXIT INT TERM

# Main execution
main() {
    pids_string=$(launch_all_streams)
    monitor_streams "$pids_string"
    max_concurrent=$?
    analyze_results $max_concurrent

    echo ""
    echo "${GREEN}🚀 True concurrent test complete!${NC}"
}

main "$@"
