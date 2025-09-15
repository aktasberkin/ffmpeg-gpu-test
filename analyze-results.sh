#!/bin/bash

# Results Analyzer - Detailed analysis of GPU test results

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

show_usage() {
    echo "Results Analyzer - Analyze GPU test results"
    echo ""
    echo "Usage:"
    echo "  $0 [test_directory]"
    echo ""
    echo "Example:"
    echo "  $0 gpu_test_20250115_143022"
    echo ""
    echo "Analysis includes:"
    echo "  - Performance statistics (peak/average/min)"
    echo "  - Utilization over time"
    echo "  - Resource efficiency analysis"
    echo "  - Optimal concurrent stream recommendation"
}

# Analyze performance metrics
analyze_performance() {
    local csv_file=$1

    echo -e "${BLUE}=== Performance Analysis ===${NC}"

    # GPU metrics
    awk -F',' '
    NR==1 { print; next }
    NR>1 {
        # Collect data
        gpu[NR-1] = $5; vram[NR-1] = $6; temp[NR-1] = $8; nvenc[NR-1] = $9; cpu[NR-1] = $10; streams[NR-1] = $4

        # Running calculations
        gpu_sum += $5; vram_sum += $6; temp_sum += $8; nvenc_sum += $9; cpu_sum += $10

        if($5 > gpu_max) gpu_max = $5; if(gpu_min == 0 || $5 < gpu_min) gpu_min = $5
        if($6 > vram_max) vram_max = $6; if(vram_min == 0 || $6 < vram_min) vram_min = $6
        if($8 > temp_max) temp_max = $8; if(temp_min == 0 || $8 < temp_min) temp_min = $8
        if($9 > nvenc_max) nvenc_max = $9; if(nvenc_min == 0 || $9 < nvenc_min) nvenc_min = $9
        if($10 > cpu_max) cpu_max = $10; if(cpu_min == 0 || $10 < cpu_min) cpu_min = $10
        if($4 > streams_max) streams_max = $4

        count++
    }
    END {
        if(count > 0) {
            gpu_avg = gpu_sum / count
            vram_avg = vram_sum / count
            temp_avg = temp_sum / count
            nvenc_avg = nvenc_sum / count
            cpu_avg = cpu_sum / count

            printf "%-15s | %8s | %8s | %8s\n", "Metric", "Peak", "Average", "Minimum"
            printf "%-15s-+----------+----------+----------\n", "---------------"
            printf "%-15s | %7.1f%% | %7.1f%% | %7.1f%%\n", "GPU Utilization", gpu_max, gpu_avg, gpu_min
            printf "%-15s | %7.0fMB | %7.0fMB | %7.0fMB\n", "VRAM Usage", vram_max, vram_avg, vram_min
            printf "%-15s | %7.0f°C | %7.1f°C | %7.0f°C\n", "GPU Temperature", temp_max, temp_avg, temp_min
            printf "%-15s | %7.0f   | %7.1f   | %7.0f\n", "NVENC Sessions", nvenc_max, nvenc_avg, nvenc_min
            printf "%-15s | %7.1f%% | %7.1f%% | %7.1f%%\n", "CPU Usage", cpu_max, cpu_avg, cpu_min
            printf "%-15s | %7.0f   | %7.1f   | %7.0f\n", "Active Streams", streams_max, streams_sum/count, streams_min
        }
    }' "$csv_file"

    echo ""
}

# Analyze utilization over time
analyze_timeline() {
    local csv_file=$1

    echo -e "${BLUE}=== Timeline Analysis ===${NC}"

    echo "GPU Utilization over time (10-second intervals):"
    awk -F',' '
    NR>1 {
        interval = int($2 / 10) * 10
        gpu_sum[interval] += $5
        count[interval]++
        streams[interval] = $4
    }
    END {
        for(i in gpu_sum) {
            printf "%3ds-%3ds: %5.1f%% GPU | %3d streams\n",
                   i, i+9, gpu_sum[i]/count[i], streams[i]
        }
    }' "$csv_file" | sort -n

    echo ""
}

# Analyze resource efficiency
analyze_efficiency() {
    local csv_file=$1

    echo -e "${BLUE}=== Resource Efficiency Analysis ===${NC}"

    # GPU efficiency (streams per GPU%)
    echo "GPU Efficiency (Active Streams per GPU%):"
    awk -F',' '
    NR>1 && $5 > 0 {
        efficiency = $4 / $5
        if(efficiency > max_eff) { max_eff = efficiency; max_streams = $4; max_gpu = $5 }
        sum_eff += efficiency; count++
    }
    END {
        if(count > 0) {
            printf "Best efficiency: %.2f streams per GPU%% (at %d streams, %d%% GPU)\n", max_eff, max_streams, max_gpu
            printf "Average efficiency: %.2f streams per GPU%%\n", sum_eff/count
        }
    }' "$csv_file"

    # VRAM efficiency
    echo ""
    echo "VRAM Efficiency (Active Streams per GB VRAM):"
    awk -F',' '
    NR>1 && $6 > 0 {
        vram_gb = $6 / 1024
        efficiency = $4 / vram_gb
        if(efficiency > max_eff) { max_eff = efficiency; max_streams = $4; max_vram = $6 }
        sum_eff += efficiency; count++
    }
    END {
        if(count > 0) {
            printf "Best efficiency: %.1f streams per GB VRAM (at %d streams, %.1fGB VRAM)\n", max_eff, max_streams, max_vram/1024
            printf "Average efficiency: %.1f streams per GB VRAM\n", sum_eff/count
        }
    }' "$csv_file"

    echo ""
}

# Find optimal configuration
find_optimal() {
    local csv_file=$1

    echo -e "${BLUE}=== Optimal Configuration Recommendation ===${NC}"

    # Find sweet spot (high GPU utilization with stable performance)
    awk -F',' '
    NR>1 {
        # Consider only stable periods (GPU > 50%, good stream count)
        if($5 >= 50 && $4 > 10) {
            score = ($5 * 0.4) + ($4 * 0.4) + ((100 - $10) * 0.2)  # GPU% + streams + (100-CPU%)
            if(score > max_score) {
                max_score = score
                opt_streams = $4
                opt_gpu = $5
                opt_vram = $6
                opt_nvenc = $9
                opt_cpu = $10
            }
        }
    }
    END {
        if(max_score > 0) {
            printf "Recommended concurrent streams: %d\n", opt_streams
            printf "Expected GPU utilization: %.1f%%\n", opt_gpu
            printf "Expected VRAM usage: %.0fMB (%.1fGB)\n", opt_vram, opt_vram/1024
            printf "Expected NVENC sessions: %.0f\n", opt_nvenc
            printf "Expected CPU usage: %.1f%%\n", opt_cpu
            printf "Performance score: %.1f\n", max_score
        } else {
            print "No optimal configuration found in data"
        }
    }' "$csv_file"

    echo ""
}

# Generate performance graph data
generate_graph_data() {
    local csv_file=$1
    local output_dir=$(dirname "$csv_file")

    echo -e "${BLUE}=== Generating Graph Data Files ===${NC}"

    # GPU utilization over time
    awk -F',' 'NR>1 {print $2, $5}' "$csv_file" > "$output_dir/gpu_utilization.dat"
    echo "GPU utilization data: $output_dir/gpu_utilization.dat"

    # VRAM usage over time
    awk -F',' 'NR>1 {print $2, $6}' "$csv_file" > "$output_dir/vram_usage.dat"
    echo "VRAM usage data: $output_dir/vram_usage.dat"

    # Streams vs GPU correlation
    awk -F',' 'NR>1 {print $4, $5}' "$csv_file" > "$output_dir/streams_vs_gpu.dat"
    echo "Streams vs GPU data: $output_dir/streams_vs_gpu.dat"

    echo ""
    echo -e "${CYAN}Plot with gnuplot:${NC}"
    echo "  gnuplot -e \"plot '$output_dir/gpu_utilization.dat' with lines title 'GPU %'\""
    echo "  gnuplot -e \"plot '$output_dir/streams_vs_gpu.dat' with points title 'Streams vs GPU'\""
}

# Main analysis
main() {
    local test_dir=${1:-"."}

    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        show_usage
        exit 0
    fi

    # Find CSV file
    local csv_file
    if [ -f "$test_dir" ]; then
        csv_file="$test_dir"
    elif [ -f "$test_dir/reports/detailed_metrics.csv" ]; then
        csv_file="$test_dir/reports/detailed_metrics.csv"
    else
        echo -e "${RED}Error: Cannot find CSV file${NC}"
        echo "Looking for:"
        echo "  $test_dir/reports/detailed_metrics.csv"
        echo "  or direct CSV file: $test_dir"
        echo ""
        echo "Available test directories:"
        ls -1d gpu_test_* 2>/dev/null | head -5
        exit 1
    fi

    if [ ! -f "$csv_file" ]; then
        echo -e "${RED}Error: CSV file not found: $csv_file${NC}"
        exit 1
    fi

    echo -e "${GREEN}=== GPU Test Results Analysis ===${NC}"
    echo -e "${YELLOW}Data source: $csv_file${NC}"
    echo -e "${YELLOW}Records: $(wc -l < "$csv_file") lines${NC}"
    echo ""

    # Run analysis
    analyze_performance "$csv_file"
    analyze_timeline "$csv_file"
    analyze_efficiency "$csv_file"
    find_optimal "$csv_file"
    generate_graph_data "$csv_file"

    echo -e "${GREEN}Analysis complete!${NC}"
}

main "$@"