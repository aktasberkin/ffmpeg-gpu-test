#!/bin/bash

# Bottleneck Analyzer - GPU pattern ve CPU spike nedenlerini araştır

STREAM_COUNT=${1:-50}
DURATION=${2:-60}
OUTPUT_DIR="bottleneck_analysis_$(date +%H%M%S)"

mkdir -p "$OUTPUT_DIR"

echo "=== Performance Bottleneck Analysis ==="
echo "Analyzing GPU patterns and CPU spikes with $STREAM_COUNT streams"

# System baseline
echo "=== System Baseline (Before Test) ==="
echo "GPU:" $(nvidia-smi --query-gpu=utilization.gpu,memory.used,temperature.gpu --format=csv,noheader)
echo "CPU:" $(top -bn1 | grep "Cpu(s)" | awk '{print $2}')
echo "RAM:" $(free -m | awk 'NR==2{print $3"/"$2"MB"}')

# Launch streams with intensive monitoring
pids=()
MONITOR_LOG="$OUTPUT_DIR/intensive_monitor.csv"

echo "timestamp,elapsed,stream_count,active_pids,gpu_util,gpu_mem,gpu_temp,nvenc,cpu_user,cpu_system,cpu_wait,load_1m,ram_used" > "$MONITOR_LOG"

echo ""
echo "Launching streams with intensive monitoring..."

# Background monitoring
(
    while true; do
        timestamp=$(date +%s.%N)
        elapsed=$(echo "$timestamp - $(cat $OUTPUT_DIR/start_time 2>/dev/null || echo $timestamp)" | bc -l 2>/dev/null || echo 0)

        # Count active FFmpeg processes
        active_count=$(pgrep -f "ffmpeg.*h264_nvenc" | wc -l)

        # GPU metrics
        gpu_metrics=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,temperature.gpu,encoder.stats.sessionCount --format=csv,noheader,nounits 2>/dev/null || echo "0,0,0,0")

        # Detailed CPU metrics
        cpu_metrics=$(top -bn1 | awk '/^%Cpu/ {gsub(/[^0-9.]/," ",$0); print $1","$3","$5}' 2>/dev/null || echo "0,0,0")
        load_1m=$(uptime | awk '{print $(NF-2)}' | cut -d',' -f1)
        ram_used=$(free -m | awk 'NR==2{print $3}')

        echo "$timestamp,$elapsed,$STREAM_COUNT,$active_count,$gpu_metrics,$cpu_metrics,$load_1m,$ram_used" >> "$MONITOR_LOG"

        sleep 0.5  # High frequency monitoring
    done
) &
monitor_pid=$!

# Record start time
echo $(date +%s.%N) > "$OUTPUT_DIR/start_time"

# Launch streams in phases to analyze startup impact
echo "Phase 1: First 25% of streams..."
phase1_count=$((STREAM_COUNT / 4))
for ((i=0; i<phase1_count; i++)); do
    ffmpeg -f lavfi -i "mandelbrot=size=1280x720:rate=30:maxiter=100" \
        -t $DURATION -c:v h264_nvenc -preset p4 -cq 36 \
        -f hls "${OUTPUT_DIR}/stream${i}.m3u8" \
        >"${OUTPUT_DIR}/stream${i}.log" 2>&1 &
    pids[i]=$!

    # Small delay to see gradual impact
    sleep 0.02
done

echo "Monitoring phase 1 for 10 seconds..."
sleep 10

echo "Phase 2: Next 50% of streams..."
for ((i=phase1_count; i<$((STREAM_COUNT * 3 / 4)); i++)); do
    ffmpeg -f lavfi -i "testsrc2=size=1280x720:rate=30" \
        -t $DURATION -c:v h264_nvenc -preset p4 -cq 36 \
        -f hls "${OUTPUT_DIR}/stream${i}.m3u8" \
        >"${OUTPUT_DIR}/stream${i}.log" 2>&1 &
    pids[i]=$!
    sleep 0.01
done

echo "Monitoring phase 2 for 10 seconds..."
sleep 10

echo "Phase 3: Final 25% of streams..."
for ((i=$((STREAM_COUNT * 3 / 4)); i<STREAM_COUNT; i++)); do
    ffmpeg -f lavfi -i "plasma=size=1280x720:rate=30" \
        -t $DURATION -c:v h264_nvenc -preset p4 -cq 36 \
        -f hls "${OUTPUT_DIR}/stream${i}.m3u8" \
        >"${OUTPUT_DIR}/stream${i}.log" 2>&1 &
    pids[i]=$!
done

echo "All streams launched. Monitoring until completion..."

# Wait for completion
while [ $(pgrep -f "ffmpeg.*h264_nvenc" | wc -l) -gt 0 ]; do
    sleep 5
    echo "Active FFmpeg processes: $(pgrep -f "ffmpeg.*h264_nvenc" | wc -l)"
done

# Stop monitoring
kill $monitor_pid 2>/dev/null

echo ""
echo "=== Analysis Results ==="

# GPU Pattern Analysis
echo "GPU Utilization Pattern Analysis:"
awk -F',' '
NR>1 && $5!="" {
    if ($5 >= 80) high++
    else if ($5 >= 60) good++
    else if ($5 >= 40) medium++
    else if ($5 >= 20) low++
    else idle++

    if ($5 > max_gpu) max_gpu = $5
    gpu_sum += $5
    count++
}
END {
    printf "  Peak GPU: %d%%\n", max_gpu
    printf "  Average GPU: %.1f%%\n", gpu_sum/count
    printf "  High (80%%+): %d samples (%.1f%%)\n", high, high*100/(count+0.1)
    printf "  Good (60-79%%): %d samples (%.1f%%)\n", good, good*100/(count+0.1)
    printf "  Medium (40-59%%): %d samples (%.1f%%)\n", medium, medium*100/(count+0.1)
    printf "  Low (20-39%%): %d samples (%.1f%%)\n", low, low*100/(count+0.1)
    printf "  Idle (0-19%%): %d samples (%.1f%%)\n", idle, idle*100/(count+0.1)
}' "$MONITOR_LOG"

echo ""

# CPU Spike Analysis
echo "CPU Spike Analysis:"
awk -F',' '
NR>1 && $9!="" {
    cpu_total = $9 + $10 + $11
    if (cpu_total > max_cpu) {max_cpu = cpu_total; max_time = $2}
    if (cpu_total >= 90) extreme++
    else if (cpu_total >= 70) high++
    else if (cpu_total >= 50) medium++
    else normal++

    cpu_sum += cpu_total
    count++
}
END {
    printf "  Peak CPU: %.1f%% at %.1fs\n", max_cpu, max_time
    printf "  Average CPU: %.1f%%\n", cpu_sum/count
    printf "  Extreme (90%%+): %d samples\n", extreme
    printf "  High (70-89%%): %d samples\n", high
    printf "  Medium (50-69%%): %d samples\n", medium
    printf "  Normal (<50%%): %d samples\n", normal
}' "$MONITOR_LOG"

echo ""

# Bottleneck Identification
echo "Bottleneck Identification:"

# Check GPU memory constraint
max_gpu_mem=$(awk -F',' 'NR>1 && $6!="" {if($6>max) max=$6} END {print max+0}' "$MONITOR_LOG")
total_gpu_mem=46068  # L40S VRAM

if [ $max_gpu_mem -gt 40000 ]; then
    echo "  ⚠️  VRAM BOTTLENECK: Using ${max_gpu_mem}MB / ${total_gpu_mem}MB ($(( max_gpu_mem * 100 / total_gpu_mem ))%)"
else
    echo "  ✅ VRAM OK: Peak ${max_gpu_mem}MB / ${total_gpu_mem}MB"
fi

# Check NVENC sessions
max_nvenc=$(awk -F',' 'NR>1 && $8!="" {if($8>max) max=$8} END {print max+0}' "$MONITOR_LOG")
echo "  NVENC Sessions: Peak $max_nvenc (L40S has no limit)"

# System load analysis
max_load=$(awk -F',' 'NR>1 && $12!="" {if($12>max) max=$12} END {print max}' "$MONITOR_LOG")
cpu_cores=$(nproc)

if [ $(echo "$max_load > $cpu_cores" | bc 2>/dev/null || echo 0) -eq 1 ]; then
    echo "  ⚠️  SYSTEM OVERLOAD: Load $max_load on $cpu_cores cores"
else
    echo "  ✅ SYSTEM LOAD OK: Peak $max_load on $cpu_cores cores"
fi

# Performance recommendations
echo ""
echo "Performance Recommendations:"

avg_gpu=$(awk -F',' 'NR>1 && $5!="" {sum+=$5; count++} END {printf "%.0f", sum/count}' "$MONITOR_LOG")

if [ $avg_gpu -lt 60 ]; then
    echo "  📈 GPU underutilized ($avg_gpu% avg) - can handle more streams"
    echo "     Suggestion: Increase to $(( STREAM_COUNT * 130 / 100 )) concurrent streams"
elif [ $avg_gpu -gt 85 ]; then
    echo "  ⚠️  GPU near maximum ($avg_gpu% avg) - reduce streams for stability"
    echo "     Suggestion: Reduce to $(( STREAM_COUNT * 85 / 100 )) concurrent streams"
else
    echo "  ✅ GPU well utilized ($avg_gpu% avg) - good balance"
    echo "     Optimal: ~$STREAM_COUNT concurrent streams"
fi

echo ""
echo "📊 Detailed data: $MONITOR_LOG"
echo "🚀 Bottleneck analysis complete!"