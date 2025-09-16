#!/bin/bash

# Concurrency Validator - True concurrent işlem doğrulaması
# Process'lerin gerçekten aynı anda çalışıp çalışmadığını test eder

set -e

STREAM_COUNT=${1:-20}
TEST_DURATION=${2:-30}
MONITOR_INTERVAL=1
OUTPUT_DIR="concurrency_test_$(date +%H%M%S)"

echo "=== Concurrency Validator ==="
echo "Streams: $STREAM_COUNT | Duration: ${TEST_DURATION}s"
echo "Output: $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR"

# Process tracking
PROCESS_LOG="$OUTPUT_DIR/process_timeline.csv"
CONCURRENCY_LOG="$OUTPUT_DIR/concurrency_analysis.csv"

# Initialize logs
echo "timestamp,elapsed,active_count,pids_snapshot,gpu_util,cpu_percent" > "$PROCESS_LOG"
echo "second,active_processes,new_starts,completions,gpu_util,cpu_load" > "$CONCURRENCY_LOG"

# Launch streams with precise timing
echo "Launching $STREAM_COUNT streams..."
pids=()
launch_times=()

start_time=$(date +%s.%N)

for ((i=0; i<STREAM_COUNT; i++)); do
    # Launch stream
    ffmpeg -f lavfi -i "testsrc2=size=1280x720:rate=30" \
        -t $TEST_DURATION \
        -c:v h264_nvenc \
        -preset p4 \
        -cq 36 \
        -f hls \
        -hls_time 4 \
        -hls_list_size 5 \
        -hls_segment_filename "${OUTPUT_DIR}/stream${i}_%03d.ts" \
        "${OUTPUT_DIR}/stream${i}.m3u8" \
        >"${OUTPUT_DIR}/stream${i}.log" 2>&1 &

    pid=$!
    pids[i]=$pid
    launch_times[i]=$(date +%s.%N)

    printf "\rLaunched: %d/%d (PID: %d)" $((i+1)) $STREAM_COUNT $pid

    # Minimal delay to prevent fork bomb
    if [ $((i % 10)) -eq 0 ] && [ $i -gt 0 ]; then
        sleep 0.05
    fi
done

echo ""
echo "✅ All streams launched in $(echo "$(date +%s.%N) - $start_time" | bc -l | cut -c1-5)s"

# Real-time concurrency monitoring
echo ""
echo "=== Concurrency Monitoring ==="
echo "Time | Active | New | Done | GPU% | CPU% | Details"
echo "-----+--------+-----+------+------+------+----------------"

monitor_start=$(date +%s)
prev_active=0
prev_completed=0

while true; do
    current_time=$(date +%s)
    elapsed=$((current_time - monitor_start))

    # Count active processes
    active=0
    active_pids=()
    for pid in "${pids[@]}"; do
        if kill -0 $pid 2>/dev/null; then
            active=$((active + 1))
            active_pids+=($pid)
        fi
    done

    completed=$((STREAM_COUNT - active))
    new_completions=$((completed - prev_completed))

    # Get system metrics
    gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo 0)
    cpu_percent=$(top -bn1 | awk '/^%Cpu/ {print 100-$8}' | cut -d'.' -f1 2>/dev/null | head -1 || echo 0)

    # Log detailed data
    pids_snapshot=$(IFS=,; echo "${active_pids[*]}")
    echo "$(date +%s),$elapsed,$active,\"$pids_snapshot\",$gpu_util,$cpu_percent" >> "$PROCESS_LOG"

    # Log concurrency analysis
    echo "$elapsed,$active,$((active - prev_active)),$new_completions,$gpu_util,$cpu_percent" >> "$CONCURRENCY_LOG"

    # Display status
    printf "%4ds | %6d | %3d | %4d | %3s%% | %3s%% | PIDs:%d\n" \
        $elapsed $active $((active - prev_active)) $new_completions $gpu_util $cpu_percent ${#active_pids[@]}

    # Update previous values
    prev_active=$active
    prev_completed=$completed

    # Check completion
    if [ $active -eq 0 ]; then
        echo ""
        echo "🎉 All streams completed at ${elapsed}s"
        break
    fi

    # Safety timeout
    if [ $elapsed -gt $((TEST_DURATION + 60)) ]; then
        echo ""
        echo "⚠️ Timeout reached, killing remaining processes"
        for pid in "${active_pids[@]}"; do
            kill -9 $pid 2>/dev/null || true
        done
        break
    fi

    sleep $MONITOR_INTERVAL
done

# Analysis
echo ""
echo "=== Concurrency Analysis ==="

# Peak concurrency
peak_concurrent=$(awk -F',' 'NR>1 {if($2>max) max=$2} END {print max+0}' "$CONCURRENCY_LOG")
avg_concurrent=$(awk -F',' 'NR>1 {sum+=$2; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}' "$CONCURRENCY_LOG")

# Timeline analysis
total_duration=$(tail -1 "$CONCURRENCY_LOG" | cut -d',' -f1)
peak_gpu=$(awk -F',' 'NR>1 {if($5>max) max=$5} END {print max+0}' "$CONCURRENCY_LOG")
avg_gpu=$(awk -F',' 'NR>1 {sum+=$5; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}' "$CONCURRENCY_LOG")

echo "Target streams: $STREAM_COUNT"
echo "Peak concurrent: $peak_concurrent"
echo "Average concurrent: $avg_concurrent"
echo "Concurrency ratio: $(echo "scale=1; $peak_concurrent * 100 / $STREAM_COUNT" | bc -l)%"
echo "Total test duration: ${total_duration}s"
echo "Peak GPU utilization: ${peak_gpu}%"
echo "Average GPU utilization: ${avg_gpu}%"

# Validate true concurrency
if [ $peak_concurrent -ge $((STREAM_COUNT * 80 / 100)) ]; then
    echo "✅ TRUE CONCURRENCY: >80% streams were active simultaneously"
else
    echo "⚠️  LIMITED CONCURRENCY: Only $((peak_concurrent * 100 / STREAM_COUNT))% peak concurrency"
fi

if [ $peak_gpu -ge 40 ]; then
    echo "✅ GPU UTILIZATION: Good GPU usage ($peak_gpu%)"
else
    echo "⚠️  GPU UNDERUTILIZED: Only ${peak_gpu}% peak usage"
fi

# Success analysis
successful=$(find "$OUTPUT_DIR" -name "*.m3u8" | wc -l)
echo "✅ Successful streams: $successful/$STREAM_COUNT ($(($successful * 100 / STREAM_COUNT))%)"

echo ""
echo "Data files:"
echo "  Timeline: $PROCESS_LOG"
echo "  Analysis: $CONCURRENCY_LOG"
echo "  Outputs: $OUTPUT_DIR"

echo ""
echo "🚀 Concurrency validation complete!"