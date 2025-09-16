#!/bin/bash

# FAST Test Video Source Generator - No GPU, minimal processing
# Creates lightweight test patterns quickly

set -e

# Configuration
TEST_VIDEOS_DIR="test_videos"
DURATION=30  # Shorter duration for faster generation
PRESET="ultrafast"  # Fastest encoding

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Fast Test Source Generator ===${NC}"
echo "Creating minimal test sources for GPU testing..."

# Create directory
mkdir -p "$TEST_VIDEOS_DIR"

# Function to generate MINIMAL test video
generate_minimal_video() {
    local name=$1
    local pattern=$2
    local output="${TEST_VIDEOS_DIR}/${name}.mp4"

    if [ -f "$output" ]; then
        echo "  ✓ $name already exists"
        return
    fi

    echo -e "${YELLOW}Generating $name (minimal quality for speed)...${NC}"

    # Use CPU encoding with minimal quality for FAST generation
    ffmpeg -f lavfi -i "$pattern" \
        -t $DURATION \
        -vf "scale=640:360" \
        -c:v libx264 \
        -preset ultrafast \
        -crf 40 \
        -pix_fmt yuv420p \
        -an \
        -f mp4 "$output" \
        -y -loglevel warning

    echo -e "${GREEN}  ✓ Generated $name${NC}"
}

# Generate just 3-4 test patterns (enough for testing)
echo -e "\n${YELLOW}Generating minimal test set...${NC}"

generate_minimal_video "test_pattern_1" "testsrc2=size=640x360:rate=15"
generate_minimal_video "test_pattern_2" "smptebars=size=640x360:rate=15"
generate_minimal_video "test_pattern_3" "mandelbrot=size=640x360:rate=15:maxiter=20"

# Create file list for testing
ls -1 "$TEST_VIDEOS_DIR"/*.mp4 > test_file_sources.txt 2>/dev/null || true

# Duplicate entries for high concurrency
echo -e "\n${YELLOW}Expanding source list...${NC}"
touch expanded_test_sources.txt
for i in {1..70}; do
    cat test_file_sources.txt >> expanded_test_sources.txt
done

# Summary
echo -e "\n${GREEN}=== Quick Generation Complete ===${NC}"
echo "Generated videos: $(ls -1 $TEST_VIDEOS_DIR/*.mp4 2>/dev/null | wc -l)"
echo "File list: test_file_sources.txt"
echo "Expanded list: expanded_test_sources.txt (200+ entries)"
echo ""
echo -e "${GREEN}Ready for GPU testing!${NC}"
echo "Note: These are minimal quality sources just for load testing."