#!/bin/bash

# Performance Bottleneck Identifier - Sistem limitlerini kapsamlı analiz
# GPU, CPU, Memory, I/O, Network ve sistem kaynak limitlerini tespit eder

set -e

STREAM_COUNT=${1:-40}
DURATION=${2:-60}
OUTPUT_DIR="bottleneck_test_$(date +%H%M%S)"
BOTTLENECK_LOG="$OUTPUT_DIR/bottleneck_analysis.csv"
SYSTEM_LOG="$OUTPUT_DIR/system_metrics.csv"
RESOURCE_LOG="$OUTPUT_DIR/resource_limits.csv"

# Colors
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

echo "${GREEN}=== Performance Bottleneck Identifier ===${NC}"
echo "Streams: $STREAM_COUNT | Duration: ${DURATION}s"
echo "Analyzing: GPU, CPU, Memory, I/O, Network limits"

mkdir -p "$OUTPUT_DIR"

# System information gathering
gather_system_info() {
    echo ""
    echo "${BLUE}=== System Configuration Analysis ===${NC}"

    # GPU Information
    echo "GPU Configuration:" | tee "$OUTPUT_DIR/system_info.txt"
    nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv,noheader 2>/dev/null | tee -a "$OUTPUT_DIR/system_info.txt" || echo "GPU info unavailable"

    # CPU Information
    echo "" >> "$OUTPUT_DIR/system_info.txt"
    echo "CPU Configuration:" | tee -a "$OUTPUT_DIR/system_info.txt"
    echo "  Cores: $(nproc) logical cores" | tee -a "$OUTPUT_DIR/system_info.txt"
    echo "  Architecture: $(uname -m)" | tee -a "$OUTPUT_DIR/system_info.txt"

    # Memory Information
    echo "" >> "$OUTPUT_DIR/system_info.txt"
    echo "Memory Configuration:" | tee -a "$OUTPUT_DIR/system_info.txt"
    echo "  Total RAM: $(free -h | awk 'NR==2{print $2}')" | tee -a "$OUTPUT_DIR/system_info.txt"
    echo "  Available RAM: $(free -h | awk 'NR==2{print $7}')" | tee -a "$OUTPUT_DIR/system_info.txt"

    # Storage Information
    echo "" >> "$OUTPUT_DIR/system_info.txt"
    echo "Storage Configuration:" | tee -a "$OUTPUT_DIR/system_info.txt"
    echo "  Disk space: $(df -h . | awk 'NR==2{print $2" total, "$4" available"}')" | tee -a "$OUTPUT_DIR/system_info.txt"

    # System Limits
    echo "" >> "$OUTPUT_DIR/system_info.txt"
    echo "System Limits:" | tee -a "$OUTPUT_DIR/system_info.txt"
    echo "  Max processes: $(ulimit -u)" | tee -a "$OUTPUT_DIR/system_info.txt"
    echo "  Max open files: $(ulimit -n)" | tee -a "$OUTPUT_DIR/system_info.txt"
    echo "  Max memory: $(ulimit -v) KB" | tee -a "$OUTPUT_DIR/system_info.txt"
}

# Initialize monitoring logs
initialize_logs() {
    # Main bottleneck analysis log
    echo "timestamp,elapsed,active_streams,gpu_util,gpu_mem_used,gpu_mem_total,nvenc_sessions,cpu_user,cpu_system,cpu_iowait,load_1m,load_5m,ram_used,ram_total,swap_used,disk_read_mb,disk_write_mb" > "$BOTTLENECK_LOG"

    # System metrics log
    echo "timestamp,metric_name,current_value,max_value,threshold,status" > "$SYSTEM_LOG"

    # Resource limits log
    echo "resource_type,current_usage,max_capacity,utilization_percent,bottleneck_risk" > "$RESOURCE_LOG"
}

# Advanced system monitoring
monitor_system_resources() {
    local timestamp=$1
    local elapsed=$2
    local active_streams=$3

    # GPU Metrics
    local gpu_metrics=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,encoder.stats.sessionCount --format=csv,noheader,nounits 2>/dev/null || echo "0,0,0,0")
    IFS=',' read -r gpu_util gpu_mem_used gpu_mem_total nvenc_sessions <<< "$gpu_metrics"

    # CPU Metrics (detailed)
    local cpu_metrics=$(top -bn1 | awk '/^%Cpu/ {gsub(/[^0-9.]/," ",$0); print $1","$3","$5}' 2>/dev/null || echo "0,0,0")
    IFS=',' read -r cpu_user cpu_system cpu_iowait <<< "$cpu_metrics"

    # Load averages
    local load_avg=$(uptime | awk '{print $(NF-2)","$(NF-1)}' | tr -d ',')
    IFS=',' read -r load_1m load_5m <<< "$load_avg"

    # Memory metrics
    local memory_info=$(free -m | awk 'NR==2{print $3","$2} NR==3{print $2}')
    local ram_used=$(echo "$memory_info" | head -1 | cut -d',' -f1)
    local ram_total=$(echo "$memory_info" | head -1 | cut -d',' -f2)
    local swap_used=$(echo "$memory_info" | tail -1)

    # Disk I/O (MB/s)
    local disk_stats=$(iostat -d 1 2 2>/dev/null | awk 'END {print $(NF-1)","$NF}' || echo "0,0")
    IFS=',' read -r disk_read_mb disk_write_mb <<< "$disk_stats"

    # Log comprehensive data
    echo "$timestamp,$elapsed,$active_streams,$gpu_util,$gpu_mem_used,$gpu_mem_total,$nvenc_sessions,$cpu_user,$cpu_system,$cpu_iowait,$load_1m,$load_5m,$ram_used,$ram_total,$swap_used,$disk_read_mb,$disk_write_mb" >> "$BOTTLENECK_LOG"

    # Analyze bottlenecks in real-time
    analyze_realtime_bottlenecks $gpu_util $gpu_mem_used $gpu_mem_total $cpu_user $cpu_system $load_1m $ram_used $ram_total
}

# Real-time bottleneck analysis
analyze_realtime_bottlenecks() {
    local gpu_util=$1
    local gpu_mem_used=$2
    local gpu_mem_total=$3
    local cpu_user=$4
    local cpu_system=$5
    local load_1m=$6
    local ram_used=$7
    local ram_total=$8
    local cpu_cores=$(nproc)

    # GPU bottleneck detection
    local gpu_mem_percent=$(( (gpu_mem_used * 100) / (gpu_mem_total + 1) ))
    if [ $gpu_util -gt 95 ]; then
        echo "$(date +%s),GPU_UTILIZATION,$gpu_util,100,95,CRITICAL" >> "$SYSTEM_LOG"
    elif [ $gpu_util -gt 80 ]; then
        echo "$(date +%s),GPU_UTILIZATION,$gpu_util,100,80,WARNING" >> "$SYSTEM_LOG"
    fi

    if [ $gpu_mem_percent -gt 90 ]; then
        echo "$(date +%s),GPU_MEMORY,$gpu_mem_percent,100,90,CRITICAL" >> "$SYSTEM_LOG"
    elif [ $gpu_mem_percent -gt 70 ]; then
        echo "$(date +%s),GPU_MEMORY,$gpu_mem_percent,100,70,WARNING" >> "$SYSTEM_LOG"
    fi

    # CPU bottleneck detection
    local total_cpu=$(echo "scale=0; $cpu_user + $cpu_system" | bc -l 2>/dev/null || echo 0)
    if [ $(echo "$total_cpu > 90" | bc -l 2>/dev/null || echo 0) -eq 1 ]; then
        echo "$(date +%s),CPU_USAGE,$total_cpu,100,90,CRITICAL" >> "$SYSTEM_LOG"
    elif [ $(echo "$total_cpu > 70" | bc -l 2>/dev/null || echo 0) -eq 1 ]; then
        echo "$(date +%s),CPU_USAGE,$total_cpu,100,70,WARNING" >> "$SYSTEM_LOG"
    fi

    # Load average bottleneck
    if [ $(echo "$load_1m > $(($cpu_cores * 2))" | bc -l 2>/dev/null || echo 0) -eq 1 ]; then
        echo "$(date +%s),SYSTEM_LOAD,$load_1m,$(($cpu_cores * 3)),$((cpu_cores * 2)),CRITICAL" >> "$SYSTEM_LOG"
    fi

    # Memory bottleneck detection
    local ram_percent=$(( (ram_used * 100) / (ram_total + 1) ))
    if [ $ram_percent -gt 90 ]; then
        echo "$(date +%s),RAM_USAGE,$ram_percent,100,90,CRITICAL" >> "$SYSTEM_LOG"
    elif [ $ram_percent -gt 70 ]; then
        echo "$(date +%s),RAM_USAGE,$ram_percent,100,70,WARNING" >> "$SYSTEM_LOG"
    fi
}

# Launch test streams
launch_test_streams() {
    local pids=()

    echo ""
    echo "${YELLOW}=== Launching Test Streams ===${NC}"

    for ((i=0; i<STREAM_COUNT; i++)); do
        # Variety of synthetic patterns
        local patterns=("testsrc2=size=1280x720:rate=30" "mandelbrot=size=1280x720:rate=30:maxiter=100" "plasma=size=1280x720:rate=30" "smptebars=size=1280x720:rate=30")
        local pattern="${patterns[$((i % ${#patterns[@]}))]}"

        ffmpeg -f lavfi -i "$pattern" \
            -t $DURATION \
            -c:v h264_nvenc \
            -preset p4 \
            -cq 36 \
            -g 60 \
            -f hls \
            -hls_time 6 \
            -hls_list_size 8 \
            -hls_segment_filename "$OUTPUT_DIR/stream${i}_%03d.ts" \
            "$OUTPUT_DIR/stream${i}.m3u8" \
            >"$OUTPUT_DIR/stream${i}.log" 2>&1 &

        pids[i]=$!

        # Progress indication
        if [ $((i % 10)) -eq 9 ]; then
            printf "\r${CYAN}Launched: %d/%d${NC}" $((i+1)) $STREAM_COUNT
        fi

        # Prevent system overload during launch
        if [ $((i % 20)) -eq 0 ] && [ $i -gt 0 ]; then
            sleep 0.1
        fi
    done

    echo ""
    echo "${GREEN}✅ All $STREAM_COUNT streams launched${NC}"
    echo "${pids[*]}"  # Return PIDs
}

# Main monitoring loop
main_monitoring() {
    local pids_array=($1)
    local start_time=$(date +%s)

    echo ""
    echo "${YELLOW}=== Comprehensive Monitoring Started ===${NC}"
    echo "Time | Active | GPU% | VRAM% | CPU% | Load | RAM% | Status"
    echo "-----+--------+------+-------+------+------+------+---------"

    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        # Count active processes
        local active=0
        for pid in "${pids_array[@]}"; do
            if kill -0 $pid 2>/dev/null; then
                active=$((active + 1))
            fi
        done

        # Monitor system resources
        monitor_system_resources $(date +%s.%N) $elapsed $active

        # Extract current metrics for display
        local last_line=$(tail -1 "$BOTTLENECK_LOG")
        IFS=',' read -r _ _ _ gpu_util gpu_mem_used gpu_mem_total _ cpu_user cpu_system _ load_1m _ ram_used ram_total _ _ _ <<< "$last_line"

        # Calculate percentages
        local gpu_mem_percent=$(( (gpu_mem_used * 100) / (gpu_mem_total + 1) ))
        local cpu_total=$(echo "scale=0; $cpu_user + $cpu_system" | bc -l 2>/dev/null || echo 0)
        local ram_percent=$(( (ram_used * 100) / (ram_total + 1) ))

        # Determine system status
        local status="OK"
        if [ $gpu_util -gt 95 ] || [ $gpu_mem_percent -gt 90 ]; then
            status="${RED}GPU${NC}"
        elif [ $(echo "$cpu_total > 90" | bc -l 2>/dev/null || echo 0) -eq 1 ]; then
            status="${RED}CPU${NC}"
        elif [ $ram_percent -gt 90 ]; then
            status="${RED}RAM${NC}"
        elif [ $(echo "$load_1m > $(nproc)" | bc -l 2>/dev/null || echo 0) -eq 1 ]; then
            status="${YELLOW}LOAD${NC}"
        fi

        printf "%4ds | %6d | %3d%% | %4d%% | %3.0f%% | %4.1f | %3d%% | %s\n" \
            $elapsed $active $gpu_util $gpu_mem_percent $cpu_total $load_1m $ram_percent "$status"

        # Check completion
        if [ $active -eq 0 ]; then
            echo ""
            echo "${GREEN}🎉 All streams completed at ${elapsed}s${NC}"
            break
        fi

        # Timeout check
        if [ $elapsed -gt $((DURATION + 120)) ]; then
            echo ""
            echo "${YELLOW}⚠️ Test timeout reached${NC}"
            break
        fi

        sleep 3
    done
}

# Comprehensive bottleneck analysis
analyze_bottlenecks() {
    echo ""
    echo "${BLUE}=== Bottleneck Analysis Results ===${NC}"

    # Analyze each resource type
    analyze_gpu_bottlenecks
    analyze_cpu_bottlenecks
    analyze_memory_bottlenecks
    analyze_system_bottlenecks

    # Generate resource limits summary
    generate_resource_summary

    # Performance recommendations
    generate_recommendations
}

analyze_gpu_bottlenecks() {
    echo ""
    echo "GPU Analysis:"

    local peak_gpu=$(awk -F',' 'NR>1 && $4!="" {if($4>max) max=$4} END {print max+0}' "$BOTTLENECK_LOG")
    local avg_gpu=$(awk -F',' 'NR>1 && $4!="" {sum+=$4; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}' "$BOTTLENECK_LOG")
    local peak_vram=$(awk -F',' 'NR>1 && $5!="" {if($5>max) max=$5} END {print max+0}' "$BOTTLENECK_LOG")
    local total_vram=$(awk -F',' 'NR>1 && $6!="" {print $6; exit}' "$BOTTLENECK_LOG")
    local vram_percent=$(( (peak_vram * 100) / (total_vram + 1) ))

    echo "  Peak GPU utilization: ${peak_gpu}%"
    echo "  Average GPU utilization: ${avg_gpu}%"
    echo "  Peak VRAM usage: ${peak_vram}MB (${vram_percent}%)"

    if [ $peak_gpu -lt 60 ]; then
        echo "  ${GREEN}✅ GPU UNDERUTILIZED${NC} - Can handle more streams"
        echo "GPU_UTILIZATION,$peak_gpu,100,60,LOW" >> "$RESOURCE_LOG"
    elif [ $peak_gpu -gt 95 ]; then
        echo "  ${RED}❌ GPU BOTTLENECK${NC} - Reduce concurrent streams"
        echo "GPU_UTILIZATION,$peak_gpu,100,95,HIGH" >> "$RESOURCE_LOG"
    else
        echo "  ${GREEN}✅ GPU OPTIMAL${NC} - Good utilization"
        echo "GPU_UTILIZATION,$peak_gpu,100,80,MEDIUM" >> "$RESOURCE_LOG"
    fi

    if [ $vram_percent -gt 85 ]; then
        echo "  ${RED}❌ VRAM BOTTLENECK${NC} - Memory constraint"
        echo "GPU_MEMORY,$vram_percent,100,85,HIGH" >> "$RESOURCE_LOG"
    else
        echo "  ${GREEN}✅ VRAM OK${NC} - Memory sufficient"
        echo "GPU_MEMORY,$vram_percent,100,85,LOW" >> "$RESOURCE_LOG"
    fi
}

analyze_cpu_bottlenecks() {
    echo ""
    echo "CPU Analysis:"

    local peak_cpu_user=$(awk -F',' 'NR>1 && $8!="" {if($8>max) max=$8} END {print max+0}' "$BOTTLENECK_LOG")
    local peak_cpu_system=$(awk -F',' 'NR>1 && $9!="" {if($9>max) max=$9} END {print max+0}' "$BOTTLENECK_LOG")
    local peak_cpu_total=$(echo "$peak_cpu_user + $peak_cpu_system" | bc -l)
    local peak_load=$(awk -F',' 'NR>1 && $11!="" {if($11>max) max=$11} END {printf "%.2f", max}' "$BOTTLENECK_LOG")
    local cpu_cores=$(nproc)

    echo "  Peak CPU user: ${peak_cpu_user}%"
    echo "  Peak CPU system: ${peak_cpu_system}%"
    echo "  Peak CPU total: ${peak_cpu_total}%"
    echo "  Peak load average: $peak_load (cores: $cpu_cores)"

    if [ $(echo "$peak_cpu_total > 90" | bc -l) -eq 1 ]; then
        echo "  ${RED}❌ CPU BOTTLENECK${NC} - High CPU usage"
        echo "CPU_USAGE,$peak_cpu_total,100,90,HIGH" >> "$RESOURCE_LOG"
    elif [ $(echo "$peak_cpu_total > 70" | bc -l) -eq 1 ]; then
        echo "  ${YELLOW}⚠️ CPU HIGH${NC} - Moderate CPU usage"
        echo "CPU_USAGE,$peak_cpu_total,100,70,MEDIUM" >> "$RESOURCE_LOG"
    else
        echo "  ${GREEN}✅ CPU OK${NC} - Low CPU usage"
        echo "CPU_USAGE,$peak_cpu_total,100,70,LOW" >> "$RESOURCE_LOG"
    fi

    if [ $(echo "$peak_load > $cpu_cores" | bc -l) -eq 1 ]; then
        echo "  ${RED}❌ SYSTEM OVERLOAD${NC} - Load exceeds cores"
        echo "SYSTEM_LOAD,$peak_load,$((cpu_cores * 2)),$cpu_cores,HIGH" >> "$RESOURCE_LOG"
    else
        echo "  ${GREEN}✅ SYSTEM LOAD OK${NC}"
        echo "SYSTEM_LOAD,$peak_load,$((cpu_cores * 2)),$cpu_cores,LOW" >> "$RESOURCE_LOG"
    fi
}

analyze_memory_bottlenecks() {
    echo ""
    echo "Memory Analysis:"

    local peak_ram=$(awk -F',' 'NR>1 && $13!="" {if($13>max) max=$13} END {print max+0}' "$BOTTLENECK_LOG")
    local total_ram=$(awk -F',' 'NR>1 && $14!="" {print $14; exit}' "$BOTTLENECK_LOG")
    local ram_percent=$(( (peak_ram * 100) / (total_ram + 1) ))
    local peak_swap=$(awk -F',' 'NR>1 && $15!="" {if($15>max) max=$15} END {print max+0}' "$BOTTLENECK_LOG")

    echo "  Peak RAM usage: ${peak_ram}MB (${ram_percent}%)"
    echo "  Peak swap usage: ${peak_swap}MB"

    if [ $ram_percent -gt 90 ]; then
        echo "  ${RED}❌ RAM BOTTLENECK${NC} - Memory exhaustion"
        echo "RAM_USAGE,$ram_percent,100,90,HIGH" >> "$RESOURCE_LOG"
    elif [ $ram_percent -gt 70 ]; then
        echo "  ${YELLOW}⚠️ RAM HIGH${NC} - Memory pressure"
        echo "RAM_USAGE,$ram_percent,100,70,MEDIUM" >> "$RESOURCE_LOG"
    else
        echo "  ${GREEN}✅ RAM OK${NC} - Sufficient memory"
        echo "RAM_USAGE,$ram_percent,100,70,LOW" >> "$RESOURCE_LOG"
    fi

    if [ $peak_swap -gt 1000 ]; then
        echo "  ${YELLOW}⚠️ SWAP USAGE${NC} - Memory swapping occurred"
    fi
}

analyze_system_bottlenecks() {
    echo ""
    echo "System Resources:"

    # I/O Analysis
    local peak_read=$(awk -F',' 'NR>1 && $16!="" {if($16>max) max=$16} END {printf "%.1f", max}' "$BOTTLENECK_LOG")
    local peak_write=$(awk -F',' 'NR>1 && $17!="" {if($17>max) max=$17} END {printf "%.1f", max}' "$BOTTLENECK_LOG")

    echo "  Peak disk read: ${peak_read} MB/s"
    echo "  Peak disk write: ${peak_write} MB/s"

    if [ $(echo "$peak_write > 100" | bc -l) -eq 1 ]; then
        echo "  ${YELLOW}⚠️ HIGH DISK I/O${NC} - Heavy write load"
    else
        echo "  ${GREEN}✅ DISK I/O OK${NC}"
    fi

    # Process count analysis
    local max_processes=$(pgrep -f "ffmpeg.*h264_nvenc" | wc -l 2>/dev/null || echo 0)
    local process_limit=$(ulimit -u)
    local process_percent=$(( (max_processes * 100) / (process_limit + 1) ))

    echo "  Max concurrent processes: $max_processes"
    echo "  Process limit: $process_limit (${process_percent}% used)"

    if [ $process_percent -gt 80 ]; then
        echo "  ${RED}❌ PROCESS LIMIT${NC} - Near process limit"
    else
        echo "  ${GREEN}✅ PROCESSES OK${NC}"
    fi
}

generate_resource_summary() {
    echo ""
    echo "${CYAN}=== Resource Summary ===${NC}"
    echo "Resource           | Usage  | Risk  | Status"
    echo "-------------------+--------+-------+---------"

    while IFS=',' read -r resource usage capacity percent risk; do
        if [ "$resource" != "resource_type" ]; then  # Skip header
            printf "%-18s | %5s%% | %-5s | " "$resource" "$percent" "$risk"
            case $risk in
                HIGH) echo "${RED}BOTTLENECK${NC}" ;;
                MEDIUM) echo "${YELLOW}CAUTION${NC}" ;;
                LOW) echo "${GREEN}OPTIMAL${NC}" ;;
                *) echo "OK" ;;
            esac
        fi
    done < "$RESOURCE_LOG"
}

generate_recommendations() {
    echo ""
    echo "${CYAN}=== Performance Recommendations ===${NC}"

    # Read bottleneck analysis
    local gpu_risk=$(awk -F',' '$1=="GPU_UTILIZATION" {print $5}' "$RESOURCE_LOG")
    local cpu_risk=$(awk -F',' '$1=="CPU_USAGE" {print $5}' "$RESOURCE_LOG")
    local ram_risk=$(awk -F',' '$1=="RAM_USAGE" {print $5}' "$RESOURCE_LOG")

    if [ "$gpu_risk" = "LOW" ]; then
        local suggested=$((STREAM_COUNT * 150 / 100))
        echo "📈 GPU SCALING: Can increase to ~$suggested concurrent streams"
    elif [ "$gpu_risk" = "HIGH" ]; then
        local suggested=$((STREAM_COUNT * 80 / 100))
        echo "⚠️ GPU LIMIT: Reduce to ~$suggested concurrent streams"
    else
        echo "✅ GPU OPTIMAL: Current stream count (~$STREAM_COUNT) is balanced"
    fi

    if [ "$cpu_risk" = "HIGH" ]; then
        echo "🔧 CPU OPTIMIZATION: Consider upgrading CPU or optimizing FFmpeg parameters"
        echo "   - Use faster presets (p1-p3) if quality allows"
        echo "   - Reduce frame rate or resolution"
    fi

    if [ "$ram_risk" = "HIGH" ]; then
        echo "💾 MEMORY: Add more RAM or reduce concurrent streams"
    fi

    echo ""
    echo "🎯 OPTIMAL CONFIGURATION:"
    local gpu_util=$(awk -F',' '$1=="GPU_UTILIZATION" {print $2}' "$RESOURCE_LOG")
    echo "   Current streams: $STREAM_COUNT"
    echo "   GPU utilization: ${gpu_util}%"

    if [ "$gpu_risk" = "LOW" ]; then
        echo "   Recommendation: Scale UP to maximize GPU usage"
    elif [ "$gpu_risk" = "HIGH" ]; then
        echo "   Recommendation: Scale DOWN to prevent bottlenecks"
    else
        echo "   Recommendation: Current configuration is optimal"
    fi
}

# Main execution
main() {
    gather_system_info
    initialize_logs

    # Launch test streams and get PIDs
    pids_string=$(launch_test_streams)

    # Start comprehensive monitoring
    main_monitoring "$pids_string"

    # Analyze bottlenecks
    analyze_bottlenecks

    echo ""
    echo "${GREEN}📊 Bottleneck analysis complete!${NC}"
    echo "Generated files:"
    echo "  System info: $OUTPUT_DIR/system_info.txt"
    echo "  Bottleneck data: $BOTTLENECK_LOG"
    echo "  System alerts: $SYSTEM_LOG"
    echo "  Resource summary: $RESOURCE_LOG"
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
echo "${GREEN}🚀 Performance bottleneck identification complete!${NC}"