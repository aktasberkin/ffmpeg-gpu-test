#!/bin/bash

# Monitor Helper - Real-time monitoring tools for GPU tests

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

show_usage() {
    echo "Monitor Helper - GPU Test Monitoring Tools"
    echo ""
    echo "Usage:"
    echo "  $0 live [test_dir]     - Real-time monitoring"
    echo "  $0 files [test_dir]    - Check output files"
    echo "  $0 disk [test_dir]     - Disk usage monitoring"
    echo "  $0 gpu                 - GPU-only monitoring"
    echo "  $0 summary [test_dir]  - Quick summary"
    echo ""
    echo "Examples:"
    echo "  $0 live gpu_test_20250115_143022"
    echo "  $0 files gpu_test_20250115_143022"
    echo "  $0 gpu"
}

# Real-time live monitoring
monitor_live() {
    local test_dir=${1:-"."}
    local live_file="$test_dir/reports/live_metrics.txt"

    if [ ! -f "$live_file" ]; then
        echo -e "${YELLOW}Live metrics file not found. Showing GPU-only monitoring.${NC}"
        monitor_gpu_only
        return
    fi

    echo -e "${GREEN}=== Live Test Monitoring ===${NC}"
    echo -e "${YELLOW}File: $live_file${NC}"
    echo -e "${CYAN}Press Ctrl+C to exit${NC}"
    echo ""

    # Follow live metrics file
    tail -f "$live_file" 2>/dev/null &
    local tail_pid=$!

    # Also show GPU stats
    while true; do
        sleep 5
        echo -e "\n${BLUE}[$(date '+%H:%M:%S')] GPU Status:${NC}"
        nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,encoder.stats.sessionCount --format=csv,noheader,nounits | \
        awk -F',' '{printf "GPU: %s%% | VRAM: %sMB/%sMB | Temp: %s°C | NVENC: %s\n", $1, $2, $3, $4, $5}'
    done

    kill $tail_pid 2>/dev/null
}

# Check output files
check_files() {
    local test_dir=${1:-"."}
    local streams_dir="$test_dir/streams"

    if [ ! -d "$streams_dir" ]; then
        echo -e "${YELLOW}Streams directory not found: $streams_dir${NC}"
        return 1
    fi

    echo -e "${GREEN}=== Output Files Check ===${NC}"
    echo -e "${BLUE}Directory: $streams_dir${NC}"
    echo ""

    # Count files
    local total_streams=$(ls -1d "$streams_dir"/stream_* 2>/dev/null | wc -l)
    local playlists=$(find "$streams_dir" -name "playlist.m3u8" | wc -l)
    local segments=$(find "$streams_dir" -name "*.ts" | wc -l)

    echo "Total stream directories: $total_streams"
    echo "Playlist files (m3u8): $playlists"
    echo "Video segments (ts): $segments"
    echo ""

    # Sample file sizes
    echo -e "${YELLOW}Sample file sizes:${NC}"
    find "$streams_dir" -name "playlist.m3u8" | head -5 | while read playlist; do
        local dir=$(dirname "$playlist")
        local stream_name=$(basename "$dir")
        local segment_count=$(ls -1 "$dir"/*.ts 2>/dev/null | wc -l)
        local total_size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        echo "  $stream_name: $segment_count segments, $total_size total"
    done

    echo ""
    echo -e "${CYAN}Manual check commands:${NC}"
    echo "  ls -la $streams_dir/stream_0001/"
    echo "  ffprobe $streams_dir/stream_0001/playlist.m3u8"
    echo "  ffplay $streams_dir/stream_0001/playlist.m3u8"
}

# Disk usage monitoring
monitor_disk() {
    local test_dir=${1:-"."}

    echo -e "${GREEN}=== Disk Usage Monitoring ===${NC}"
    echo -e "${CYAN}Press Ctrl+C to exit${NC}"
    echo ""

    while true; do
        clear
        echo -e "${BLUE}[$(date)] Disk Usage:${NC}"
        df -h "$test_dir" 2>/dev/null || df -h .

        echo ""
        if [ -d "$test_dir" ]; then
            echo -e "${YELLOW}Test directory size:${NC}"
            du -sh "$test_dir" 2>/dev/null || echo "Directory not found"

            if [ -d "$test_dir/streams" ]; then
                echo -e "${YELLOW}Top 10 largest stream directories:${NC}"
                du -sh "$test_dir"/streams/stream_* 2>/dev/null | sort -hr | head -10
            fi
        fi

        echo ""
        echo -e "${CYAN}Updating every 10 seconds...${NC}"
        sleep 10
    done
}

# GPU-only monitoring
monitor_gpu_only() {
    echo -e "${GREEN}=== GPU Monitoring ===${NC}"
    echo -e "${CYAN}Press Ctrl+C to exit${NC}"
    echo ""

    while true; do
        clear
        echo -e "${BLUE}[$(date)] GPU Status:${NC}"
        nvidia-smi

        echo ""
        echo -e "${YELLOW}Encoder Statistics:${NC}"
        nvidia-smi --query-gpu=encoder.stats.sessionCount,encoder.stats.averageFps,encoder.stats.averageLatency --format=csv,noheader

        echo -e "${CYAN}Updating every 3 seconds...${NC}"
        sleep 3
    done
}

# Quick summary
show_summary() {
    local test_dir=${1:-"."}

    echo -e "${GREEN}=== Test Summary ===${NC}"

    # Check if test directory exists
    if [ ! -d "$test_dir" ]; then
        echo -e "${YELLOW}Test directory not found: $test_dir${NC}"
        echo "Available test directories:"
        ls -1d gpu_test_* 2>/dev/null | head -5
        return 1
    fi

    echo -e "${BLUE}Directory: $test_dir${NC}"

    # Summary report
    if [ -f "$test_dir/reports/test_summary.txt" ]; then
        echo ""
        cat "$test_dir/reports/test_summary.txt"
    else
        echo -e "${YELLOW}Summary report not found, generating quick stats...${NC}"

        # Quick stats
        if [ -d "$test_dir/streams" ]; then
            local playlists=$(find "$test_dir/streams" -name "playlist.m3u8" | wc -l)
            local segments=$(find "$test_dir/streams" -name "*.ts" | wc -l)
            local size=$(du -sh "$test_dir" | cut -f1)

            echo ""
            echo "Successful streams: $playlists"
            echo "Total segments: $segments"
            echo "Total size: $size"
        fi
    fi

    # Latest and average CSV data
    if [ -f "$test_dir/reports/detailed_metrics.csv" ]; then
        echo ""
        echo -e "${YELLOW}Latest metrics:${NC}"
        tail -1 "$test_dir/reports/detailed_metrics.csv" | awk -F',' '
        {
            printf "GPU: %s%% | VRAM: %sMB | NVENC: %s | CPU: %s%% | Disk: %sGB\n",
            $5, $6, $9, $10, $13
        }'

        echo -e "${YELLOW}Average metrics during test:${NC}"
        awk -F',' 'NR>1 {gpu+=$5; vram+=$6; nvenc+=$9; cpu+=$10; count++}
                    END {
                        if(count>0) printf "GPU: %.1f%% | VRAM: %.0fMB | NVENC: %.1f | CPU: %.1f%%\n",
                        gpu/count, vram/count, nvenc/count, cpu/count
                    }' "$test_dir/reports/detailed_metrics.csv"
    fi
}

# Main execution
main() {
    local command=${1:-help}
    local test_dir=$2

    case $command in
        "live")
            monitor_live "$test_dir"
            ;;
        "files")
            check_files "$test_dir"
            ;;
        "disk")
            monitor_disk "$test_dir"
            ;;
        "gpu")
            monitor_gpu_only
            ;;
        "summary")
            show_summary "$test_dir"
            ;;
        "help"|*)
            show_usage
            ;;
    esac
}

# Handle Ctrl+C gracefully
trap 'echo -e "\n${GREEN}Monitoring stopped${NC}"; exit 0' INT

main "$@"