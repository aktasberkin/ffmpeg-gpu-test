#!/bin/bash

# Process Pool GPU Test - Advanced concurrent management
# Solves fork bombing and resource exhaustion issues

set -e

# Configuration
MAX_CONCURRENT=200
TEST_DURATION=60
POOL_SIZE=50              # Maximum processes in pool at once
QUEUE_SIZE=1000           # Maximum queue size
WORKER_RESTART_INTERVAL=300  # Restart workers every 5 minutes
OUTPUT_DIR="pool_test_$(date +%Y%m%d_%H%M%S)"

# Directories
mkdir -p "$OUTPUT_DIR/streams"
mkdir -p "$OUTPUT_DIR/logs"
mkdir -p "$OUTPUT_DIR/workers"

# Files
METRICS_CSV="$OUTPUT_DIR/metrics.csv"
QUEUE_FILE="$OUTPUT_DIR/job_queue.txt"
WORKER_LOG="$OUTPUT_DIR/workers.log"
STATUS_FILE="$OUTPUT_DIR/status.txt"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Initialize
init_system() {
    echo -e "${GREEN}=== Process Pool GPU Test ===${NC}"

    # System limits
    ulimit -n 65536 2>/dev/null || true
    ulimit -u 32768 2>/dev/null || true

    # Initialize files
    cat > "$METRICS_CSV" << EOF
timestamp,active_workers,queued_jobs,completed_jobs,failed_jobs,gpu_util,gpu_mem,nvenc_sessions,cpu_percent,load_avg
EOF

    echo "0" > "$OUTPUT_DIR/job_counter.txt"
    echo "0" > "$OUTPUT_DIR/completed_counter.txt"
    echo "0" > "$OUTPUT_DIR/failed_counter.txt"
    touch "$QUEUE_FILE"

    echo -e "${BLUE}System initialized${NC}"
}

# Generate synthetic video sources
get_synthetic_source() {
    local job_id=$1

    local patterns=(
        "testsrc2=size=1280x720:rate=30:duration=300"
        "smptebars=size=1280x720:rate=30:duration=300"
        "mandelbrot=size=1280x720:rate=30:maxiter=100"
        "life=size=1280x720:rate=30:ratio=0.1:death_color=red"
        "plasma=size=1280x720:rate=30"
        "cellauto=size=1280x720:rate=30:rule=30"
        "rgbtestsrc=size=1280x720:rate=30"
        "gradients=size=1280x720:rate=30:speed=1"
    )

    # Add motion effects
    local motion_effects=(
        ""
        ",rotate=angle=t*PI/6:c=black"
        ",scale=1920:1080,scale=1280:720"
        ",crop=w=iw*0.9:h=ih*0.9:x=iw*0.05:y=ih*0.05"
    )

    local pattern="${patterns[$((job_id % ${#patterns[@]}))]}"
    local effect="${motion_effects[$((job_id % ${#motion_effects[@]}))]}"

    echo "${pattern}${effect}"
}

# Worker function - processes one job
process_job() {
    local job_id=$1
    local worker_id=$2
    local output_dir="$OUTPUT_DIR/streams/job_${job_id}"
    local worker_log="$OUTPUT_DIR/workers/worker_${worker_id}.log"

    mkdir -p "$output_dir"

    local source=$(get_synthetic_source $job_id)

    echo "[$(date)] Worker $worker_id processing job $job_id" >> "$worker_log"

    # GPU transcoding command
    timeout $((TEST_DURATION + 10)) ffmpeg \
        -hide_banner \
        -loglevel error \
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
        -an \
        -f hls \
        -hls_time 6 \
        -hls_list_size 0 \
        -hls_flags delete_segments+append_list \
        -hls_segment_filename "${output_dir}/segment_%05d.ts" \
        "${output_dir}/playlist.m3u8" \
        2>"${output_dir}/error.log"

    local result=$?

    if [ $result -eq 0 ] && [ -f "${output_dir}/playlist.m3u8" ]; then
        echo "[$(date)] Worker $worker_id completed job $job_id successfully" >> "$worker_log"
        echo $(($(cat "$OUTPUT_DIR/completed_counter.txt") + 1)) > "$OUTPUT_DIR/completed_counter.txt"
        return 0
    else
        echo "[$(date)] Worker $worker_id failed job $job_id (exit code: $result)" >> "$worker_log"
        echo $(($(cat "$OUTPUT_DIR/failed_counter.txt") + 1)) > "$OUTPUT_DIR/failed_counter.txt"
        return 1
    fi
}

# Worker process - continuously processes jobs from queue
worker_loop() {
    local worker_id=$1
    local worker_log="$OUTPUT_DIR/workers/worker_${worker_id}.log"
    local worker_start_time=$(date +%s)

    echo "[$(date)] Worker $worker_id started" >> "$worker_log"

    while true; do
        # Check if should restart (avoid memory leaks)
        local current_time=$(date +%s)
        if [ $((current_time - worker_start_time)) -gt $WORKER_RESTART_INTERVAL ]; then
            echo "[$(date)] Worker $worker_id restarting after ${WORKER_RESTART_INTERVAL}s" >> "$worker_log"
            exit 0
        fi

        # Get job from queue (atomic operation)
        local job_id
        (
            flock -x 200
            job_id=$(head -n1 "$QUEUE_FILE" 2>/dev/null)
            if [ -n "$job_id" ]; then
                tail -n +2 "$QUEUE_FILE" > "${QUEUE_FILE}.tmp"
                mv "${QUEUE_FILE}.tmp" "$QUEUE_FILE"
                echo "$job_id"
            fi
        ) 200>"$QUEUE_FILE.lock"

        if [ -n "$job_id" ]; then
            process_job "$job_id" "$worker_id"
        else
            # No jobs available, wait a bit
            sleep 1
        fi

        # Check if main test is finished
        if [ ! -f "$STATUS_FILE" ]; then
            echo "[$(date)] Worker $worker_id shutting down (test finished)" >> "$worker_log"
            break
        fi
    done
}

# Start worker pool
start_workers() {
    local num_workers=$1

    echo -e "${YELLOW}Starting $num_workers workers...${NC}"

    for ((i=1; i<=num_workers; i++)); do
        worker_loop $i &
        echo $! > "$OUTPUT_DIR/worker_${i}.pid"
    done

    echo -e "${GREEN}$num_workers workers started${NC}"
}

# Stop all workers
stop_workers() {
    echo -e "${YELLOW}Stopping workers...${NC}"

    # Remove status file to signal workers to stop
    rm -f "$STATUS_FILE"

    # Kill worker processes
    for pid_file in "$OUTPUT_DIR"/worker_*.pid; do
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file")
            kill $pid 2>/dev/null || true
            rm -f "$pid_file"
        fi
    done

    # Wait for graceful shutdown
    sleep 3

    # Force kill any remaining ffmpeg processes
    pkill -f "ffmpeg.*h264_nvenc" 2>/dev/null || true

    echo -e "${GREEN}Workers stopped${NC}"
}

# Add jobs to queue
queue_jobs() {
    local num_jobs=$1

    echo -e "${BLUE}Queuing $num_jobs jobs...${NC}"

    (
        flock -x 200
        for ((i=1; i<=num_jobs; i++)); do
            local job_id=$(cat "$OUTPUT_DIR/job_counter.txt")
            echo $((job_id + 1)) > "$OUTPUT_DIR/job_counter.txt"
            echo $((job_id + 1)) >> "$QUEUE_FILE"
        done
    ) 200>"$QUEUE_FILE.lock"

    echo -e "${GREEN}$num_jobs jobs queued${NC}"
}

# Monitor system and progress
monitor_progress() {
    local total_jobs=$1
    local start_time=$(date +%s)

    echo "active" > "$STATUS_FILE"

    while [ -f "$STATUS_FILE" ]; do
        sleep 3

        # Count metrics
        local active_workers=$(ls "$OUTPUT_DIR"/worker_*.pid 2>/dev/null | wc -l)
        local queued_jobs=$(wc -l < "$QUEUE_FILE" 2>/dev/null || echo 0)
        local completed_jobs=$(cat "$OUTPUT_DIR/completed_counter.txt")
        local failed_jobs=$(cat "$OUTPUT_DIR/failed_counter.txt")
        local processed_jobs=$((completed_jobs + failed_jobs))

        # GPU metrics
        local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
        local gpu_mem=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
        local nvenc=$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)

        # System metrics
        local cpu=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 || echo 0)
        local load_avg=$(uptime | awk '{print $(NF-2)}' | cut -d',' -f1)

        # Progress calculation
        local elapsed=$(($(date +%s) - start_time))
        local progress=$((processed_jobs * 100 / total_jobs))

        # Display status
        printf "\r[%3ds] Progress: %s%3d%%(%d/%d)%s | Queue: %s%3d%s | Workers: %s%2d%s | GPU: %s%3d%%%s | VRAM: %s%4dMB%s | NVENC: %s%2d%s | Failed: %s%d%s" \
            $elapsed \
            "$GREEN" $progress $processed_jobs $total_jobs "$NC" \
            "$YELLOW" $queued_jobs "$NC" \
            "$BLUE" $active_workers "$NC" \
            "$CYAN" $gpu_util "$NC" \
            "$BLUE" $gpu_mem "$NC" \
            "$CYAN" $nvenc "$NC" \
            "$RED" $failed_jobs "$NC"

        # Log metrics
        echo "$(date +%s),$active_workers,$queued_jobs,$completed_jobs,$failed_jobs,$gpu_util,$gpu_mem,$nvenc,$cpu,$load_avg" >> "$METRICS_CSV"

        # Check completion
        if [ $processed_jobs -ge $total_jobs ]; then
            break
        fi

        # Check timeout (safety)
        if [ $elapsed -gt $((TEST_DURATION + 60)) ]; then
            echo -e "\n${YELLOW}Test timeout, stopping...${NC}"
            break
        fi
    done

    echo ""
}

# Run concurrent test
run_pool_test() {
    local target_streams=$1

    echo -e "\n${YELLOW}=== Testing $target_streams concurrent streams with process pool ===${NC}"

    # Calculate optimal worker count (don't exceed GPU capability)
    local worker_count=$POOL_SIZE
    if [ $target_streams -lt $POOL_SIZE ]; then
        worker_count=$target_streams
    fi

    # Start workers
    start_workers $worker_count

    # Queue jobs
    queue_jobs $target_streams

    # Monitor progress
    monitor_progress $target_streams

    # Stop workers
    stop_workers

    # Results
    local completed=$(cat "$OUTPUT_DIR/completed_counter.txt")
    local failed=$(cat "$OUTPUT_DIR/failed_counter.txt")
    local success_rate=$((completed * 100 / target_streams))

    echo -e "${GREEN}Results: $completed successful, $failed failed ($success_rate% success rate)${NC}"

    return $success_rate
}

# Main test
main() {
    init_system

    # Test different concurrent levels
    test_levels=(10 25 50 75 100 150 200)
    local max_successful=0

    for level in "${test_levels[@]}"; do
        success_rate=$(run_pool_test $level)

        if [ $success_rate -ge 90 ]; then
            max_successful=$level
        elif [ $success_rate -lt 60 ]; then
            echo -e "${YELLOW}Success rate below 60%, stopping escalation${NC}"
            break
        fi

        # Clean up between tests
        rm -rf "$OUTPUT_DIR/streams/"*
        echo "0" > "$OUTPUT_DIR/completed_counter.txt"
        echo "0" > "$OUTPUT_DIR/failed_counter.txt"
        echo "" > "$QUEUE_FILE"

        echo "Cooling down 10 seconds..."
        sleep 10
    done

    # Final report
    echo -e "\n${GREEN}=== Test Complete ===${NC}"
    echo "Maximum reliable concurrent streams: $max_successful"
    echo "Results saved in: $OUTPUT_DIR/"
}

# Cleanup on exit
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    stop_workers
    rm -f "$QUEUE_FILE.lock"
}

trap cleanup EXIT INT TERM

# Run
main "$@"