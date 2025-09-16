#!/bin/bash

# Process Lifecycle Tracker - Başlatma/bitirme zamanlarını kaydet

STREAM_COUNT=${1:-20}
DURATION=${2:-30}
OUTPUT_DIR="lifecycle_test_$(date +%H%M%S)"
LIFECYCLE_LOG="$OUTPUT_DIR/lifecycle.csv"

mkdir -p "$OUTPUT_DIR"

echo "timestamp,event,stream_id,pid,elapsed_since_start,gpu_util,cpu_percent" > "$LIFECYCLE_LOG"

pids=()
start_time=$(date +%s.%N)

echo "=== Process Lifecycle Tracking ==="
echo "Tracking $STREAM_COUNT streams for ${DURATION}s"

# Launch with precise timing
for ((i=0; i<STREAM_COUNT; i++)); do
    current_time=$(date +%s.%N)
    elapsed=$(echo "$current_time - $start_time" | bc -l)

    ffmpeg -f lavfi -i "testsrc2=size=1280x720:rate=30" \
        -t $DURATION -c:v h264_nvenc -preset p4 -cq 36 \
        -f hls -hls_time 4 \
        "${OUTPUT_DIR}/stream${i}.m3u8" \
        >"${OUTPUT_DIR}/stream${i}.log" 2>&1 &

    pid=$!
    pids[i]=$pid

    # Log start event
    gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo 0)
    cpu_percent=$(top -bn1 | awk '/^%Cpu/ {print int(100-$8)}' 2>/dev/null | head -1 || echo 0)

    echo "$(date +%s.%N),START,$i,$pid,$elapsed,$gpu_util,$cpu_percent" >> "$LIFECYCLE_LOG"

    if [ $((i % 10)) -eq 9 ]; then
        printf "\rLaunched: %d/%d" $((i+1)) $STREAM_COUNT
    fi
done

echo -e "\n✅ All processes launched"

# Monitor completion
while true; do
    all_done=true

    for ((i=0; i<STREAM_COUNT; i++)); do
        if kill -0 ${pids[i]} 2>/dev/null; then
            all_done=false
        else
            # Check if already logged completion
            if ! grep -q "END,$i,${pids[i]}" "$LIFECYCLE_LOG"; then
                current_time=$(date +%s.%N)
                elapsed=$(echo "$current_time - $start_time" | bc -l)
                gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo 0)
                cpu_percent=$(top -bn1 | awk '/^%Cpu/ {print int(100-$8)}' 2>/dev/null | head -1 || echo 0)

                echo "$(date +%s.%N),END,$i,${pids[i]},$elapsed,$gpu_util,$cpu_percent" >> "$LIFECYCLE_LOG"
                echo "Stream $i completed at ${elapsed}s"
            fi
        fi
    done

    if $all_done; then
        break
    fi

    sleep 1
done

echo ""
echo "=== Lifecycle Analysis ==="
awk -F',' '
BEGIN {print "Stream | Start Time | End Time | Duration | Status"}
NR>1 {
    if ($2=="START") start_time[$3] = $5
    if ($2=="END") {
        end_time[$3] = $5
        duration = end_time[$3] - start_time[$3]
        printf "%6d | %9.2fs | %8.2fs | %7.2fs | Complete\n", $3, start_time[$3], end_time[$3], duration
    }
}' "$LIFECYCLE_LOG" | head -20

echo ""
echo "📊 Lifecycle data: $LIFECYCLE_LOG"