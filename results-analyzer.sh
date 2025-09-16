#!/bin/bash

# Advanced Results Analyzer - Comprehensive test analysis
# Averages, peaks, timeline, performance patterns

if [ -z "$1" ]; then
    echo "Usage: $0 <test_directory_or_monitoring_log>"
    echo "Example: $0 stable_test_141523"
    echo "         $0 stable_test_141523/monitoring.log"
    exit 1
fi

INPUT=$1
MONITOR_LOG=""

# Find monitoring log
if [ -d "$INPUT" ]; then
    MONITOR_LOG=$(find "$INPUT" -name "monitoring.log" -o -name "*timeline*.csv" -o -name "*analysis*.csv" | head -1)
    TEST_DIR="$INPUT"
elif [ -f "$INPUT" ]; then
    MONITOR_LOG="$INPUT"
    TEST_DIR=$(dirname "$INPUT")
else
    echo "Error: $INPUT not found"
    exit 1
fi

if [ ! -f "$MONITOR_LOG" ]; then
    echo "Error: No monitoring log found"
    exit 1
fi

echo "=== Advanced Results Analysis ==="
echo "Data source: $MONITOR_LOG"
echo "Test directory: $TEST_DIR"
echo ""

# Basic statistics
analyze_basic_stats() {
    echo "=== Basic Statistics ==="

    local total_records=$(wc -l < "$MONITOR_LOG")
    local test_duration=$(tail -1 "$MONITOR_LOG" | cut -d',' -f2)

    echo "Total monitoring records: $((total_records - 1))"
    echo "Test duration: ${test_duration}s"

    # Peak values
    local peak_active=$(awk -F',' 'NR>1 && $3!="" {if($3>max) max=$3} END {print max+0}' "$MONITOR_LOG")
    local peak_gpu=$(awk -F',' 'NR>1 && $5!="" && $5!="ERR" {if($5>max) max=$5} END {print max+0}' "$MONITOR_LOG")
    local peak_vram=$(awk -F',' 'NR>1 && $6!="" && $6!="ERR" {if($6>max) max=$6} END {print max+0}' "$MONITOR_LOG")
    local peak_nvenc=$(awk -F',' 'NR>1 && $7!="" && $7!="ERR" {if($7>max) max=$7} END {print max+0}' "$MONITOR_LOG")
    local peak_cpu=$(awk -F',' 'NR>1 && $8!="" {if($8>max) max=$8} END {print max+0}' "$MONITOR_LOG")

    echo "Peak concurrent processes: $peak_active"
    echo "Peak GPU utilization: ${peak_gpu}%"
    echo "Peak VRAM usage: ${peak_vram}MB"
    echo "Peak NVENC sessions: $peak_nvenc"
    echo "Peak CPU usage: ${peak_cpu}%"
    echo ""
}

# Average calculations
analyze_averages() {
    echo "=== Average Performance ==="

    # Average values during active period (when processes > 0)
    awk -F',' '
    NR>1 && $3>0 {
        if ($5!="ERR" && $5!="") gpu_sum += $5, gpu_count++
        if ($6!="ERR" && $6!="") vram_sum += $6, vram_count++
        if ($7!="ERR" && $7!="") nvenc_sum += $7, nvenc_count++
        if ($8!="" && $8!=0) cpu_sum += $8, cpu_count++
        active_sum += $3
        total_count++
    }
    END {
        if (gpu_count > 0) printf "Average GPU utilization: %.1f%%\n", gpu_sum/gpu_count
        if (vram_count > 0) printf "Average VRAM usage: %.0fMB\n", vram_sum/vram_count
        if (nvenc_count > 0) printf "Average NVENC sessions: %.1f\n", nvenc_sum/nvenc_count
        if (cpu_count > 0) printf "Average CPU usage: %.1f%%\n", cpu_sum/cpu_count
        if (total_count > 0) printf "Average active processes: %.1f\n", active_sum/total_count
    }' "$MONITOR_LOG"
    echo ""
}

# Timeline analysis
analyze_timeline() {
    echo "=== Timeline Analysis ==="

    # Time periods with high activity
    echo "High activity periods (>50% GPU):"
    awk -F',' 'NR>1 && $5!="ERR" && $5>50 {print "  " $2 "s: " $3 " processes, " $5 "% GPU, " $7 " NVENC"}' "$MONITOR_LOG" | head -10

    echo ""
    echo "Utilization over time (10s intervals):"
    awk -F',' '
    NR>1 && $5!="ERR" {
        interval = int($2/10) * 10
        gpu_sum[interval] += $5
        active_sum[interval] += $3
        count[interval]++
    }
    END {
        for (i in count) {
            printf "  %3ds-%3ds: %.1f%% GPU, %.1f processes\n",
                   i, i+9, gpu_sum[i]/count[i], active_sum[i]/count[i]
        }
    }' "$MONITOR_LOG" | sort -n | head -20
    echo ""
}

# Performance patterns
analyze_patterns() {
    echo "=== Performance Patterns ==="

    # GPU utilization distribution
    echo "GPU utilization distribution:"
    awk -F',' 'NR>1 && $5!="ERR" && $5!="" {
        if ($5 >= 80) high++
        else if ($5 >= 50) med++
        else if ($5 >= 20) low++
        else idle++
        total++
    }
    END {
        if (total > 0) {
            printf "  High (80%+):   %3d samples (%.1f%%)\n", high+0, (high+0)*100/total
            printf "  Medium (50-79%%): %3d samples (%.1f%%)\n", med+0, (med+0)*100/total
            printf "  Low (20-49%%):    %3d samples (%.1f%%)\n", low+0, (low+0)*100/total
            printf "  Idle (0-19%%):    %3d samples (%.1f%%)\n", idle+0, (idle+0)*100/total
        }
    }' "$MONITOR_LOG"

    echo ""

    # Concurrency efficiency
    echo "Concurrency efficiency analysis:"
    local target_streams=$(awk -F',' 'NR>1 {if($3>max) max=$3} END {print max+0}' "$MONITOR_LOG")

    awk -F',' -v target=$target_streams '
    NR>1 && $3>0 {
        efficiency = $3 * 100 / target
        if (efficiency >= 90) excellent++
        else if (efficiency >= 70) good++
        else if (efficiency >= 50) fair++
        else poor++
        total++
    }
    END {
        if (total > 0) {
            printf "  Excellent (90%+): %3d samples (%.1f%%)\n", excellent+0, (excellent+0)*100/total
            printf "  Good (70-89%%):   %3d samples (%.1f%%)\n", good+0, (good+0)*100/total
            printf "  Fair (50-69%%):   %3d samples (%.1f%%)\n", fair+0, (fair+0)*100/total
            printf "  Poor (<50%%):     %3d samples (%.1f%%)\n", poor+0, (poor+0)*100/total
        }
    }' "$MONITOR_LOG"
    echo ""
}

# Efficiency analysis
analyze_efficiency() {
    echo "=== Efficiency Analysis ==="

    # GPU efficiency (processes per GPU%)
    awk -F',' 'NR>1 && $5!="ERR" && $5>0 && $3>0 {
        efficiency = $3 / $5
        sum += efficiency
        count++
        if (efficiency > max_eff) {
            max_eff = efficiency
            max_streams = $3
            max_gpu = $5
        }
    }
    END {
        if (count > 0) {
            printf "Average efficiency: %.2f streams per GPU%%\n", sum/count
            printf "Peak efficiency: %.2f streams per GPU%% (at %d streams, %d%% GPU)\n",
                   max_eff, max_streams, max_gpu
        }
    }' "$MONITOR_LOG"

    # VRAM efficiency (streams per GB)
    awk -F',' 'NR>1 && $6!="ERR" && $6>0 && $3>0 {
        vram_gb = $6 / 1024
        efficiency = $3 / vram_gb
        sum += efficiency
        count++
        if (efficiency > max_eff) {
            max_eff = efficiency
            max_streams = $3
            max_vram = $6
        }
    }
    END {
        if (count > 0) {
            printf "Average VRAM efficiency: %.1f streams per GB\n", sum/count
            printf "Peak VRAM efficiency: %.1f streams per GB (at %d streams, %.1fGB)\n",
                   max_eff, max_streams, max_vram/1024
        }
    }' "$MONITOR_LOG"
    echo ""
}

# File output analysis
analyze_outputs() {
    echo "=== Output Analysis ==="

    if [ -d "$TEST_DIR" ]; then
        local playlists=$(find "$TEST_DIR" -name "*.m3u8" 2>/dev/null | wc -l)
        local segments=$(find "$TEST_DIR" -name "*.ts" 2>/dev/null | wc -l)
        local total_size=$(du -sh "$TEST_DIR" 2>/dev/null | cut -f1)

        echo "Generated files:"
        echo "  Playlist files (.m3u8): $playlists"
        echo "  Video segments (.ts): $segments"
        echo "  Total output size: $total_size"

        if [ $playlists -gt 0 ] && [ $segments -gt 0 ]; then
            local avg_segments=$((segments / playlists))
            echo "  Average segments per stream: $avg_segments"

            # Sample a few files for quality check
            echo ""
            echo "Sample output files:"
            find "$TEST_DIR" -name "*.m3u8" | head -3 | while read playlist; do
                local stream_segments=$(ls "$(dirname "$playlist")"/*.ts 2>/dev/null | wc -l)
                local stream_size=$(du -sh "$(dirname "$playlist")" 2>/dev/null | cut -f1)
                echo "  $(basename "$playlist"): $stream_segments segments, $stream_size"
            done
        fi
    fi
    echo ""
}

# Recommendations
generate_recommendations() {
    echo "=== Recommendations ==="

    # Analyze peak values for recommendations
    local peak_gpu=$(awk -F',' 'NR>1 && $5!="ERR" {if($5>max) max=$5} END {print max+0}' "$MONITOR_LOG")
    local avg_gpu=$(awk -F',' 'NR>1 && $5!="ERR" {sum+=$5; count++} END {if(count>0) printf "%.0f", sum/count; else print "0"}' "$MONITOR_LOG")
    local peak_concurrent=$(awk -F',' 'NR>1 {if($3>max) max=$3} END {print max+0}' "$MONITOR_LOG")

    # GPU utilization recommendations
    if [ $peak_gpu -lt 70 ]; then
        echo "📈 GPU UNDERUTILIZED: Peak $peak_gpu% - can handle more concurrent streams"
        local suggested=$((peak_concurrent * 130 / 100))
        echo "   Suggestion: Try $suggested concurrent streams"
    elif [ $peak_gpu -gt 95 ]; then
        echo "⚠️  GPU OVERLOADED: Peak $peak_gpu% - reduce concurrent streams"
        local suggested=$((peak_concurrent * 85 / 100))
        echo "   Suggestion: Reduce to $suggested concurrent streams"
    else
        echo "✅ GPU UTILIZATION: Good balance at $peak_gpu% peak"
        echo "   Optimal range: $peak_concurrent concurrent streams"
    fi

    # Efficiency recommendations
    if [ $avg_gpu -lt 40 ]; then
        echo "💡 EFFICIENCY: Low average GPU usage ($avg_gpu%) - workload too light"
        echo "   Consider: Increase stream count or use higher quality settings"
    elif [ $avg_gpu -gt 80 ]; then
        echo "💡 EFFICIENCY: High average GPU usage ($avg_gpu%) - near optimal"
        echo "   Consider: This is close to optimal utilization"
    fi

    echo ""
    echo "🎯 OPTIMAL CONFIGURATION:"
    echo "   Recommended concurrent streams: $peak_concurrent"
    echo "   Expected GPU utilization: ${peak_gpu}%"
    echo "   Expected average utilization: ${avg_gpu}%"
}

# Generate CSV summary
generate_summary_csv() {
    local summary_file="${TEST_DIR}/analysis_summary.csv"

    echo "metric,value" > "$summary_file"

    # Extract key metrics
    awk -F',' 'NR>1 {
        if ($3 > peak_active) peak_active = $3
        if ($5!="ERR" && $5 > peak_gpu) peak_gpu = $5
        if ($5!="ERR") gpu_sum += $5, gpu_count++
        if ($6!="ERR" && $6 > peak_vram) peak_vram = $6
        if ($7!="ERR" && $7 > peak_nvenc) peak_nvenc = $7
        if ($8 > peak_cpu) peak_cpu = $8
        test_duration = $2
    }
    END {
        print "peak_concurrent_streams," peak_active >> "'$summary_file'"
        print "peak_gpu_utilization," peak_gpu >> "'$summary_file'"
        print "average_gpu_utilization," (gpu_count>0 ? gpu_sum/gpu_count : 0) >> "'$summary_file'"
        print "peak_vram_usage_mb," peak_vram >> "'$summary_file'"
        print "peak_nvenc_sessions," peak_nvenc >> "'$summary_file'"
        print "peak_cpu_usage," peak_cpu >> "'$summary_file'"
        print "test_duration_seconds," test_duration >> "'$summary_file'"
    }' "$MONITOR_LOG"

    echo "📊 Summary CSV: $summary_file"
}

# Main execution
main() {
    analyze_basic_stats
    analyze_averages
    analyze_timeline
    analyze_patterns
    analyze_efficiency
    analyze_outputs
    generate_recommendations
    generate_summary_csv

    echo ""
    echo "🚀 Analysis complete!"
    echo "For graphical analysis, use: gnuplot or Excel with the CSV data"
}

main "$@"