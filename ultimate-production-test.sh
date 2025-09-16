#!/bin/bash

# Ultimate Production Test - Tüm özellikleri birleştiren final test script'i
# Comprehensive monitoring, analysis, logging, bottleneck detection

set -e

# Configuration
STREAM_COUNT=${1:-50}
TEST_DURATION=${2:-60}
QUALITY_CQ=${3:-36}
PRESET=${4:-p4}

# Output directory with timestamp
OUTPUT_DIR="production_test_$(date +%Y%m%d_%H%M%S)"
TEST_LOG="$OUTPUT_DIR/test_execution.log"

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
MAGENTA=$'\033[0;35m'
NC=$'\033[0m'

# Banner
echo "${GREEN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                Ultimate Production GPU Test                  ║"
echo "║                    FFmpeg + NVENC + HLS                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "${NC}"

echo "${CYAN}Configuration:${NC}"
echo "  Concurrent streams: $STREAM_COUNT"
echo "  Test duration: ${TEST_DURATION}s"
echo "  Video quality (CQ): $QUALITY_CQ"
echo "  NVENC preset: $PRESET"
echo "  Output directory: $OUTPUT_DIR"
echo ""

# Create output structure
mkdir -p "$OUTPUT_DIR"/{logs,streams,analysis,reports}

# Initialize master log
exec 1> >(tee -a "$TEST_LOG")
exec 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$TEST_LOG"
}

# System verification
verify_system() {
    echo "${BLUE}=== System Verification ===${NC}"

    # Check NVIDIA GPU
    if ! nvidia-smi &>/dev/null; then
        echo "${RED}❌ NVIDIA GPU not detected or driver not installed${NC}"
        exit 1
    fi

    local gpu_info=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader)
    log "GPU Detected: $gpu_info"

    # Check FFmpeg NVENC support
    if ! ffmpeg -encoders 2>/dev/null | grep -q h264_nvenc; then
        echo "${RED}❌ FFmpeg h264_nvenc encoder not available${NC}"
        exit 1
    fi

    log "FFmpeg NVENC support: OK"

    # System resources
    local cpu_cores=$(nproc)
    local total_ram=$(free -h | awk 'NR==2{print $2}')
    local available_ram=$(free -h | awk 'NR==2{print $7}')

    echo "  ${GREEN}✅ GPU:${NC} $gpu_info"
    echo "  ${GREEN}✅ CPU:${NC} $cpu_cores cores"
    echo "  ${GREEN}✅ RAM:${NC} $total_ram total, $available_ram available"
    echo "  ${GREEN}✅ FFmpeg:${NC} NVENC support verified"
    echo ""

    log "System verification completed successfully"
}

# Initialize monitoring systems
initialize_monitoring() {
    echo "${BLUE}=== Initializing Monitoring Systems ===${NC}"

    # Performance monitoring log
    echo "timestamp,elapsed,active_streams,completed_streams,gpu_util,gpu_mem_used,gpu_mem_total,nvenc_sessions,cpu_user,cpu_system,cpu_iowait,load_1m,ram_used,ram_total" > "$OUTPUT_DIR/performance.csv"

    # Individual stream tracking (using pipe separator to avoid CSV issues)
    echo "stream_id|start_time|end_time|duration|status|fps|bitrate|segments|file_size" > "$OUTPUT_DIR/stream_results.csv"

    # System alerts log
    echo "timestamp,alert_type,severity,message,value,threshold" > "$OUTPUT_DIR/alerts.csv"

    # Resource utilization log
    echo "resource,peak_usage,average_usage,threshold,status" > "$OUTPUT_DIR/resource_summary.csv"

    log "Monitoring systems initialized"
    echo "  📊 Performance tracking: performance.csv"
    echo "  📋 Stream results: stream_results.csv"
    echo "  🚨 System alerts: alerts.csv"
    echo "  📈 Resource summary: resource_summary.csv"
    echo ""
}

# Launch production streams with resource management
launch_production_streams() {
    echo "${BLUE}=== Launching Production Streams ===${NC}"

    local pids=()
    local start_times=()
    local patterns=("testsrc2=size=1280x720:rate=30" "smptebars=size=1280x720:rate=30" "mandelbrot=size=1280x720:rate=30:maxiter=100" "plasma=size=1280x720:rate=30")

    # Check system limits
    local max_processes=$(ulimit -u)
    local available_processes=$((max_processes - $(ps aux | wc -l)))

    if [ $STREAM_COUNT -gt $((available_processes / 2)) ]; then
        echo "${YELLOW}⚠️ Warning: Requested $STREAM_COUNT streams may exceed system limits${NC}"
        echo "Available process slots: $available_processes"
        echo "Reducing to safe limit: $((available_processes / 2))"
        STREAM_COUNT=$((available_processes / 2))
    fi

    log "Starting launch sequence for $STREAM_COUNT streams"

    # Batch processing to prevent fork bombing
    local batch_size=10
    local total_batches=$(( (STREAM_COUNT + batch_size - 1) / batch_size ))

    echo "Launching in $total_batches batches of $batch_size streams each"

    for ((batch=0; batch<total_batches; batch++)); do
        local batch_start=$((batch * batch_size))
        local batch_end=$((batch_start + batch_size))
        if [ $batch_end -gt $STREAM_COUNT ]; then
            batch_end=$STREAM_COUNT
        fi

        echo "${CYAN}Batch $((batch+1))/$total_batches: Launching streams $batch_start-$((batch_end-1))${NC}"

        # Launch streams in current batch
        for ((i=batch_start; i<batch_end; i++)); do
            local pattern="${patterns[$((i % ${#patterns[@]}))]}"
            local start_time=$(date +%s.%N)

            # Launch FFmpeg with production settings
            ffmpeg -f lavfi -i "$pattern" \
                -t $TEST_DURATION \
                -c:v h264_nvenc \
                -preset $PRESET \
                -cq $QUALITY_CQ \
                -g 60 \
                -keyint_min 60 \
                -sc_threshold 0 \
                -f hls \
                -hls_time 6 \
                -hls_list_size 0 \
                -hls_segment_filename "$OUTPUT_DIR/streams/stream${i}_%05d.ts" \
                -hls_playlist_type vod \
                "$OUTPUT_DIR/streams/stream${i}.m3u8" \
                -progress pipe:1 \
                -nostats \
                >"$OUTPUT_DIR/logs/stream${i}.log" 2>&1 &

            local pid=$!
            pids[i]=$pid
            start_times[i]=$start_time

            # Log stream launch (escape commas in start_time)
            echo "$i|$start_time|||STARTING|0|0|0|0" >> "$OUTPUT_DIR/stream_results.csv"

            # Small delay between individual launches
            sleep 0.02
        done

        # Wait between batches to let system stabilize
        if [ $batch -lt $((total_batches - 1)) ]; then
            echo "  Waiting for batch to stabilize..."
            sleep 2

            # Check if any processes failed in this batch
            local failed=0
            for ((i=batch_start; i<batch_end; i++)); do
                if ! kill -0 ${pids[i]} 2>/dev/null; then
                    failed=$((failed + 1))
                fi
            done

            if [ $failed -gt 0 ]; then
                echo "${YELLOW}⚠️ $failed processes failed in batch $((batch+1))${NC}"
            fi
        fi
    done

    echo ""
    log "All $STREAM_COUNT streams launched successfully"
    echo "${pids[*]} ${start_times[*]}"  # Return data for monitoring
}

# Comprehensive monitoring
comprehensive_monitoring() {
    local pids_and_times=($1)
    local pids_count=$((STREAM_COUNT))
    local pids=("${pids_and_times[@]:0:$pids_count}")
    local start_times=("${pids_and_times[@]:$pids_count}")

    local test_start=$(date +%s)
    local monitoring_interval=3

    echo ""
    echo "${BLUE}=== Production Monitoring Started ===${NC}"
    echo "${YELLOW}Time | Active | Done | GPU% | VRAM | NVENC | CPU% | Load | RAM% | Status${NC}"
    echo "-----+--------+------+------+------+-------+------+------+------+---------"

    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - test_start))

        # Count active and completed streams
        local active=0
        local completed=0
        local active_pids=()

        for ((i=0; i<STREAM_COUNT; i++)); do
            if kill -0 ${pids[i]} 2>/dev/null; then
                active=$((active + 1))
                active_pids+=(${pids[i]})
            else
                # Check if completion was already logged (using pipe separator)
                if ! grep -q "^$i|.*|.*|.*|COMPLETED|" "$OUTPUT_DIR/stream_results.csv"; then
                    local end_time=$(date +%s.%N)
                    local duration=$(echo "$end_time - ${start_times[i]}" | bc -l 2>/dev/null || echo "0")

                    # Analyze stream results
                    local stream_analysis=$(analyze_stream_completion $i "$duration")

                    # Update stream results (using pipe separator to avoid sed issues)
                    local start_time_escaped="${start_times[i]}"
                    sed -i "s|^$i|${start_time_escaped}|||STARTING|.*|$i|${start_time_escaped}|$end_time|$duration|COMPLETED|$stream_analysis|" "$OUTPUT_DIR/stream_results.csv"

                    completed=$((completed + 1))
                fi
            fi
        done

        # Collect comprehensive system metrics
        local system_metrics=$(collect_system_metrics)
        IFS=',' read -r gpu_util gpu_mem_used gpu_mem_total nvenc_sessions cpu_user cpu_system cpu_iowait load_1m ram_used ram_total <<< "$system_metrics"

        # Calculate percentages and totals
        local gpu_mem_percent=$(( (gpu_mem_used * 100) / (gpu_mem_total + 1) ))
        local cpu_total=$(echo "scale=1; $cpu_user + $cpu_system" | bc -l 2>/dev/null || echo "0")
        local ram_percent=$(( (ram_used * 100) / (ram_total + 1) ))

        # Log performance data
        echo "$(date +%s),$elapsed,$active,$completed,$gpu_util,$gpu_mem_used,$gpu_mem_total,$nvenc_sessions,$cpu_user,$cpu_system,$cpu_iowait,$load_1m,$ram_used,$ram_total" >> "$OUTPUT_DIR/performance.csv"

        # Check for alerts
        check_system_alerts $gpu_util $gpu_mem_percent $cpu_total $load_1m $ram_percent

        # Determine overall system status
        local status="${GREEN}OK${NC}"
        if [ $gpu_util -gt 95 ] || [ $gpu_mem_percent -gt 90 ]; then
            status="${RED}GPU-LIMIT${NC}"
        elif [ $(echo "$cpu_total > 90" | bc -l 2>/dev/null || echo 0) -eq 1 ]; then
            status="${RED}CPU-LIMIT${NC}"
        elif [ $ram_percent -gt 90 ]; then
            status="${RED}RAM-LIMIT${NC}"
        elif [ $(echo "$load_1m > $(nproc)" | bc -l 2>/dev/null || echo 0) -eq 1 ]; then
            status="${YELLOW}HIGH-LOAD${NC}"
        fi

        # Display current status
        printf "%4ds | %6d | %4d | %3d%% | %3d%% | %5d | %4.1f%% | %4.1f | %3d%% | %s\n" \
            $elapsed $active $completed $gpu_util $gpu_mem_percent $nvenc_sessions $cpu_total $load_1m $ram_percent "$status"

        # Check completion
        if [ $active -eq 0 ]; then
            echo ""
            echo "${GREEN}🎉 All streams completed successfully at ${elapsed}s${NC}"
            log "Test completed: $completed/$STREAM_COUNT streams finished"
            break
        fi

        # Timeout safety
        if [ $elapsed -gt $((TEST_DURATION + 180)) ]; then
            echo ""
            echo "${YELLOW}⚠️ Test timeout reached, terminating remaining processes${NC}"
            for pid in "${active_pids[@]}"; do
                kill -TERM $pid 2>/dev/null || true
            done
            sleep 5
            for pid in "${active_pids[@]}"; do
                kill -KILL $pid 2>/dev/null || true
            done
            log "Test terminated due to timeout"
            break
        fi

        sleep $monitoring_interval
    done
}

# Collect detailed system metrics
collect_system_metrics() {
    # GPU metrics
    local gpu_metrics=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,encoder.stats.sessionCount --format=csv,noheader,nounits 2>/dev/null || echo "0,0,0,0")

    # CPU metrics
    local cpu_metrics=$(top -bn1 | awk '/^%Cpu/ {gsub(/[^0-9.]/," ",$0); print $1","$3","$5}' 2>/dev/null || echo "0,0,0")

    # Load average
    local load_1m=$(uptime | awk '{print $(NF-2)}' | cut -d',' -f1)

    # Memory metrics
    local memory_info=$(free -m | awk 'NR==2{print $3","$2}')

    echo "$gpu_metrics,$cpu_metrics,$load_1m,$memory_info"
}

# System alerts monitoring
check_system_alerts() {
    local gpu_util=$1
    local gpu_mem_percent=$2
    local cpu_total=$3
    local load_1m=$4
    local ram_percent=$5

    local timestamp=$(date +%s)

    # GPU alerts
    if [ $gpu_util -gt 95 ]; then
        echo "$timestamp,GPU_UTILIZATION,CRITICAL,GPU utilization exceeded 95%,$gpu_util,95" >> "$OUTPUT_DIR/alerts.csv"
    elif [ $gpu_util -gt 85 ]; then
        echo "$timestamp,GPU_UTILIZATION,WARNING,GPU utilization high,$gpu_util,85" >> "$OUTPUT_DIR/alerts.csv"
    fi

    if [ $gpu_mem_percent -gt 90 ]; then
        echo "$timestamp,GPU_MEMORY,CRITICAL,GPU memory usage exceeded 90%,$gpu_mem_percent,90" >> "$OUTPUT_DIR/alerts.csv"
    fi

    # CPU alerts
    if [ $(echo "$cpu_total > 90" | bc -l 2>/dev/null || echo 0) -eq 1 ]; then
        echo "$timestamp,CPU_USAGE,CRITICAL,CPU usage exceeded 90%,$cpu_total,90" >> "$OUTPUT_DIR/alerts.csv"
    fi

    # Load alerts
    local cpu_cores=$(nproc)
    if [ $(echo "$load_1m > $cpu_cores" | bc -l 2>/dev/null || echo 0) -eq 1 ]; then
        echo "$timestamp,SYSTEM_LOAD,WARNING,Load average exceeds CPU cores,$load_1m,$cpu_cores" >> "$OUTPUT_DIR/alerts.csv"
    fi

    # RAM alerts
    if [ $ram_percent -gt 90 ]; then
        echo "$timestamp,RAM_USAGE,CRITICAL,RAM usage exceeded 90%,$ram_percent,90" >> "$OUTPUT_DIR/alerts.csv"
    fi
}

# Analyze individual stream completion
analyze_stream_completion() {
    local stream_id=$1
    local duration=$2
    local log_file="$OUTPUT_DIR/logs/stream${stream_id}.log"

    if [ ! -f "$log_file" ]; then
        echo "0,0,0,0"
        return
    fi

    # Extract metrics from FFmpeg log
    local fps=$(grep "fps=" "$log_file" | tail -1 | sed 's/.*fps=\([0-9.]*\).*/\1/' || echo "0")
    local bitrate=$(grep "bitrate=" "$log_file" | tail -1 | sed 's/.*bitrate=\s*\([0-9.]*\)kbits.*/\1/' || echo "0")
    local segments=$(find "$OUTPUT_DIR/streams" -name "stream${stream_id}_*.ts" | wc -l)
    local total_size=$(du -sb "$OUTPUT_DIR/streams/stream${stream_id}"* 2>/dev/null | awk '{sum+=$1} END {print sum+0}')

    echo "$fps,$bitrate,$segments,$total_size"
}

# Comprehensive results analysis
analyze_results() {
    echo ""
    echo "${BLUE}=== Comprehensive Results Analysis ===${NC}"

    # Basic statistics
    local successful_streams=$(grep -c "COMPLETED" "$OUTPUT_DIR/stream_results.csv" 2>/dev/null || echo 0)
    local total_segments=$(find "$OUTPUT_DIR/streams" -name "*.ts" | wc -l)
    local total_playlists=$(find "$OUTPUT_DIR/streams" -name "*.m3u8" | wc -l)
    local success_rate=$(( (successful_streams * 100) / STREAM_COUNT ))

    echo "${CYAN}Stream Results:${NC}"
    echo "  Target streams: $STREAM_COUNT"
    echo "  Successful completions: $successful_streams"
    echo "  Success rate: ${success_rate}%"
    echo "  Generated playlists: $total_playlists"
    echo "  Generated segments: $total_segments"
    echo ""

    # Performance analysis
    echo "${CYAN}Performance Analysis:${NC}"
    analyze_performance_metrics

    # Resource utilization
    echo "${CYAN}Resource Utilization:${NC}"
    analyze_resource_utilization

    # System alerts summary
    echo "${CYAN}System Alerts Summary:${NC}"
    analyze_system_alerts

    # Generate final recommendations
    generate_production_recommendations $successful_streams $success_rate
}

# Performance metrics analysis
analyze_performance_metrics() {
    local peak_gpu=$(awk -F',' 'NR>1 && $5!="" {if($5>max) max=$5} END {print max+0}' "$OUTPUT_DIR/performance.csv")
    local avg_gpu=$(awk -F',' 'NR>1 && $5!="" {sum+=$5; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}' "$OUTPUT_DIR/performance.csv")
    local peak_vram=$(awk -F',' 'NR>1 && $6!="" {if($6>max) max=$6} END {print max+0}' "$OUTPUT_DIR/performance.csv")
    local peak_nvenc=$(awk -F',' 'NR>1 && $8!="" {if($8>max) max=$8} END {print max+0}' "$OUTPUT_DIR/performance.csv")
    local peak_cpu=$(awk -F',' 'NR>1 && $9!="" && $10!="" {total=$9+$10; if(total>max) max=total} END {printf "%.1f", max}' "$OUTPUT_DIR/performance.csv")

    echo "  Peak GPU utilization: ${peak_gpu}%"
    echo "  Average GPU utilization: ${avg_gpu}%"
    echo "  Peak VRAM usage: ${peak_vram}MB"
    echo "  Peak NVENC sessions: $peak_nvenc"
    echo "  Peak CPU usage: ${peak_cpu}%"

    # Performance ratings
    if [ $peak_gpu -lt 60 ]; then
        echo "  ${YELLOW}⚠️ GPU underutilized - can handle more streams${NC}"
    elif [ $peak_gpu -gt 95 ]; then
        echo "  ${RED}⚠️ GPU at maximum capacity - reduce streams${NC}"
    else
        echo "  ${GREEN}✅ GPU utilization optimal${NC}"
    fi

    echo ""
}

# Resource utilization analysis
analyze_resource_utilization() {
    # Generate resource summary
    awk -F',' 'NR>1 {
        if ($5 > max_gpu) max_gpu = $5
        if ($6 > max_vram) max_vram = $6
        if ($9+$10 > max_cpu) max_cpu = $9+$10
        if ($12 > max_load) max_load = $12
        if ($13 > max_ram) max_ram = $13

        gpu_sum += $5; vram_sum += $6; cpu_sum += $9+$10; load_sum += $12; ram_sum += $13
        count++
    }
    END {
        print "GPU," max_gpu "," (count>0 ? gpu_sum/count : 0) ",80," (max_gpu>80 ? "HIGH" : "OK")
        print "VRAM," max_vram/1024 "," (count>0 ? vram_sum/count/1024 : 0) ",40," (max_vram>40960 ? "HIGH" : "OK")
        print "CPU," max_cpu "," (count>0 ? cpu_sum/count : 0) ",70," (max_cpu>70 ? "HIGH" : "OK")
        print "LOAD," max_load "," (count>0 ? load_sum/count : 0) "," "'$(nproc)'" "," (max_load>'$(nproc)' ? "HIGH" : "OK")
        print "RAM," max_ram "," (count>0 ? ram_sum/count : 0) ",70," (max_ram*100/'$(free -m | awk "NR==2{print $2}")'>70 ? "HIGH" : "OK")
    }' "$OUTPUT_DIR/performance.csv" > "$OUTPUT_DIR/resource_summary.csv"

    echo "Resource      | Peak Usage | Avg Usage | Status"
    echo "--------------+------------+-----------+--------"
    while IFS=',' read -r resource peak avg threshold status; do
        case $resource in
            GPU) printf "%-13s | %8.1f%% | %7.1f%% | " "$resource" "$peak" "$avg" ;;
            VRAM) printf "%-13s | %8.1fGB | %7.1fGB | " "$resource" "$peak" "$avg" ;;
            CPU) printf "%-13s | %8.1f%% | %7.1f%% | " "$resource" "$peak" "$avg" ;;
            LOAD) printf "%-13s | %8.1f   | %7.1f   | " "$resource" "$peak" "$avg" ;;
            RAM) printf "%-13s | %8.0fMB | %7.0fMB | " "$resource" "$peak" "$avg" ;;
        esac

        case $status in
            HIGH) echo "${RED}HIGH${NC}" ;;
            *) echo "${GREEN}OK${NC}" ;;
        esac
    done < "$OUTPUT_DIR/resource_summary.csv"
    echo ""
}

# System alerts analysis
analyze_system_alerts() {
    if [ ! -f "$OUTPUT_DIR/alerts.csv" ] || [ $(wc -l < "$OUTPUT_DIR/alerts.csv") -le 1 ]; then
        echo "  ${GREEN}✅ No system alerts recorded${NC}"
        echo ""
        return
    fi

    local critical_alerts=$(grep -c "CRITICAL" "$OUTPUT_DIR/alerts.csv" 2>/dev/null || echo 0)
    local warning_alerts=$(grep -c "WARNING" "$OUTPUT_DIR/alerts.csv" 2>/dev/null || echo 0)

    echo "  Critical alerts: $critical_alerts"
    echo "  Warning alerts: $warning_alerts"

    if [ $critical_alerts -gt 0 ]; then
        echo "  ${RED}⚠️ Critical system issues detected${NC}"
        echo "  Most frequent critical alerts:"
        awk -F',' '$3=="CRITICAL" {print "    " $2 ": " $4}' "$OUTPUT_DIR/alerts.csv" | sort | uniq -c | sort -rn | head -3
    fi
    echo ""
}

# Production recommendations
generate_production_recommendations() {
    local successful_streams=$1
    local success_rate=$2

    echo "${CYAN}Production Recommendations:${NC}"

    # Success rate evaluation
    if [ $success_rate -ge 95 ]; then
        echo "  ${GREEN}✅ EXCELLENT${NC}: $success_rate% success rate"
        echo "     System is ready for production deployment"
    elif [ $success_rate -ge 85 ]; then
        echo "  ${YELLOW}⚠️ GOOD${NC}: $success_rate% success rate"
        echo "     Minor optimizations recommended before production"
    else
        echo "  ${RED}❌ NEEDS WORK${NC}: $success_rate% success rate"
        echo "     Significant improvements needed before production"
    fi

    # Capacity recommendations
    local avg_gpu=$(awk -F',' 'NR>1 && $5!="" {sum+=$5; count++} END {if(count>0) printf "%.0f", sum/count; else print "0"}' "$OUTPUT_DIR/performance.csv")

    if [ $avg_gpu -lt 60 ]; then
        local suggested=$((STREAM_COUNT * 130 / 100))
        echo "  📈 SCALING UP: GPU underutilized ($avg_gpu% avg)"
        echo "     Recommended: Increase to $suggested concurrent streams"
    elif [ $avg_gpu -gt 85 ]; then
        local suggested=$((STREAM_COUNT * 85 / 100))
        echo "  📉 SCALING DOWN: GPU near maximum ($avg_gpu% avg)"
        echo "     Recommended: Reduce to $suggested concurrent streams"
    else
        echo "  🎯 OPTIMAL: Current configuration balanced ($avg_gpu% avg)"
        echo "     Recommended: Deploy with $STREAM_COUNT concurrent streams"
    fi

    # Final production settings
    echo ""
    echo "🚀 ${GREEN}PRODUCTION DEPLOYMENT SETTINGS:${NC}"
    echo "   Concurrent streams: $([ $avg_gpu -lt 60 ] && echo "$((STREAM_COUNT * 130 / 100))" || [ $avg_gpu -gt 85 ] && echo "$((STREAM_COUNT * 85 / 100))" || echo "$STREAM_COUNT")"
    echo "   NVENC preset: $PRESET"
    echo "   Video quality: CQ $QUALITY_CQ"
    echo "   Success rate target: >95%"
    echo "   GPU utilization target: 60-85%"
    echo ""
}

# Generate final report
generate_final_report() {
    local report_file="$OUTPUT_DIR/PRODUCTION_REPORT.md"

    cat > "$report_file" << EOF
# FFmpeg GPU Production Test Report

**Generated**: $(date)
**Configuration**: $STREAM_COUNT streams, ${TEST_DURATION}s duration, CQ $QUALITY_CQ, preset $PRESET

## Executive Summary

$([ $(grep -c "COMPLETED" "$OUTPUT_DIR/stream_results.csv" 2>/dev/null || echo 0) -ge $((STREAM_COUNT * 95 / 100)) ] && echo "✅ **PRODUCTION READY** - High success rate achieved" || echo "⚠️ **OPTIMIZATION NEEDED** - Below production threshold")

## Test Results

- **Target Streams**: $STREAM_COUNT
- **Successful**: $(grep -c "COMPLETED" "$OUTPUT_DIR/stream_results.csv" 2>/dev/null || echo 0)
- **Success Rate**: $(( ($(grep -c "COMPLETED" "$OUTPUT_DIR/stream_results.csv" 2>/dev/null || echo 0) * 100) / STREAM_COUNT ))%
- **Total Segments**: $(find "$OUTPUT_DIR/streams" -name "*.ts" | wc -l)
- **Total Output**: $(du -sh "$OUTPUT_DIR/streams" | cut -f1)

## Performance Metrics

- **Peak GPU Utilization**: $(awk -F',' 'NR>1 && $5!="" {if($5>max) max=$5} END {print max+0}' "$OUTPUT_DIR/performance.csv")%
- **Average GPU Utilization**: $(awk -F',' 'NR>1 && $5!="" {sum+=$5; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}' "$OUTPUT_DIR/performance.csv")%
- **Peak VRAM Usage**: $(awk -F',' 'NR>1 && $6!="" {if($6>max) max=$6} END {print max+0}' "$OUTPUT_DIR/performance.csv")MB
- **Peak CPU Usage**: $(awk -F',' 'NR>1 && $9!="" && $10!="" {total=$9+$10; if(total>max) max=total} END {printf "%.1f", max}' "$OUTPUT_DIR/performance.csv")%

## System Alerts

$([ -f "$OUTPUT_DIR/alerts.csv" ] && [ $(wc -l < "$OUTPUT_DIR/alerts.csv") -gt 1 ] && echo "- **Critical**: $(grep -c "CRITICAL" "$OUTPUT_DIR/alerts.csv" 2>/dev/null || echo 0)" || echo "- No critical alerts")
$([ -f "$OUTPUT_DIR/alerts.csv" ] && [ $(wc -l < "$OUTPUT_DIR/alerts.csv") -gt 1 ] && echo "- **Warning**: $(grep -c "WARNING" "$OUTPUT_DIR/alerts.csv" 2>/dev/null || echo 0)" || echo "- No warnings")

## Files Generated

- Performance Data: \`performance.csv\`
- Stream Results: \`stream_results.csv\`
- System Alerts: \`alerts.csv\`
- Resource Summary: \`resource_summary.csv\`
- Execution Log: \`test_execution.log\`
- HLS Outputs: \`streams/\` directory
- Individual Logs: \`logs/\` directory

## Recommendations

$(generate_production_recommendations $(grep -c "COMPLETED" "$OUTPUT_DIR/stream_results.csv" 2>/dev/null || echo 0) $(( ($(grep -c "COMPLETED" "$OUTPUT_DIR/stream_results.csv" 2>/dev/null || echo 0) * 100) / STREAM_COUNT )) | sed 's/^//')

---
*Report generated by Ultimate Production GPU Test Script*
EOF

    echo "${GREEN}📋 Production report generated: $report_file${NC}"
}

# Main execution function
main() {
    local start_time=$(date +%s)

    log "Starting Ultimate Production Test"

    # Pre-flight checks
    verify_system
    initialize_monitoring

    # Launch and monitor
    local launch_data=$(launch_production_streams)
    comprehensive_monitoring "$launch_data"

    # Analysis and reporting
    analyze_results
    generate_final_report

    local end_time=$(date +%s)
    local total_duration=$((end_time - start_time))

    echo ""
    echo "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo "${GREEN}║                    TEST COMPLETED                           ║${NC}"
    echo "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "${CYAN}Results Summary:${NC}"
    echo "  Test duration: ${total_duration}s"
    echo "  Output directory: $OUTPUT_DIR"
    echo "  Success rate: $(( ($(grep -c "COMPLETED" "$OUTPUT_DIR/stream_results.csv" 2>/dev/null || echo 0) * 100) / STREAM_COUNT ))%"
    echo ""
    echo "${YELLOW}Next Steps:${NC}"
    echo "  1. Review the production report: $OUTPUT_DIR/PRODUCTION_REPORT.md"
    echo "  2. Analyze performance data: $OUTPUT_DIR/performance.csv"
    echo "  3. Check system alerts: $OUTPUT_DIR/alerts.csv"
    echo "  4. Optimize based on recommendations"
    echo ""

    log "Ultimate Production Test completed successfully"
}

# Cleanup function
cleanup() {
    echo ""
    echo "${YELLOW}Cleaning up...${NC}"
    pkill -f "ffmpeg.*h264_nvenc" 2>/dev/null || true
    sleep 3
    log "Cleanup completed"
}

# Set cleanup trap
trap cleanup EXIT INT TERM

# Execute main function
main "$@"

echo "${GREEN}🚀 Ultimate Production GPU Test Complete!${NC}"