#!/bin/bash

# Generate Test Video Sources for GPU Testing
# Creates local test videos and RTSP simulation streams

set -e

# Configuration
TEST_VIDEOS_DIR="test_videos"
RTSP_SIMULATOR_PORT=8554

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Generating Test Video Sources ===${NC}"

# Create test videos directory
mkdir -p "$TEST_VIDEOS_DIR"

# Function to generate test video with FFmpeg
generate_test_video() {
    local name=$1
    local duration=$2
    local resolution=$3
    local pattern=$4
    local output="${TEST_VIDEOS_DIR}/${name}.mp4"

    if [ -f "$output" ]; then
        echo "  Skipping $name (already exists)"
        return
    fi

    echo -e "${YELLOW}Generating $name...${NC}"
    ffmpeg -f lavfi -i "$pattern" \
        -t $duration \
        -vf "scale=$resolution" \
        -c:v libx264 -preset ultrafast -crf 23 \
        -f mp4 "$output" \
        -y -loglevel error

    echo -e "${GREEN}  ✓ Generated $name${NC}"
}

# Generate various test patterns
echo -e "\n${YELLOW}Generating test patterns...${NC}"

# Different resolutions and patterns for variety
generate_test_video "test_1080p_testsrc" 120 "1920:1080" "testsrc2=rate=30:size=1920x1080"
generate_test_video "test_720p_smptebars" 120 "1280:720" "smptebars=rate=30:size=1280x720"
generate_test_video "test_720p_mandelbrot" 120 "1280:720" "mandelbrot=rate=30:size=1280x720"
generate_test_video "test_480p_testsrc" 120 "640:480" "testsrc=rate=30:size=640x480"
generate_test_video "test_360p_color" 120 "640:360" "color=c=blue:rate=30:size=640x360"

# Generate videos with motion for better testing
echo -e "\n${YELLOW}Generating motion test videos...${NC}"

for i in {1..5}; do
    pattern="testsrc2=rate=30:size=1280x720,rotate=angle=t*${i}:fillcolor=none"
    generate_test_video "motion_test_${i}" 120 "1280:720" "$pattern"
done

# Download sample videos if internet is available
echo -e "\n${YELLOW}Downloading sample videos...${NC}"

download_sample() {
    local url=$1
    local output=$2

    if [ -f "$output" ]; then
        echo "  Skipping $(basename $output) (already exists)"
        return
    fi

    if curl -o "$output" -L "$url" --connect-timeout 5 --max-time 30 2>/dev/null; then
        echo -e "${GREEN}  ✓ Downloaded $(basename $output)${NC}"
    else
        echo "  ⚠ Failed to download $(basename $output)"
    fi
}

# Public domain test videos
download_sample "https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4" \
    "${TEST_VIDEOS_DIR}/bigbuckbunny_320p.mp4"

download_sample "https://download.blender.org/durian/trailer/sintel_trailer-720p.mp4" \
    "${TEST_VIDEOS_DIR}/sintel_720p.mp4"

# Create RTSP URLs file for testing
echo -e "\n${YELLOW}Creating RTSP test URLs...${NC}"

cat > rtsp_test_sources.txt << 'EOF'
# Local test videos (will be served via RTSP server)
rtsp://localhost:8554/test_1080p_testsrc
rtsp://localhost:8554/test_720p_smptebars
rtsp://localhost:8554/test_720p_mandelbrot
rtsp://localhost:8554/test_480p_testsrc
rtsp://localhost:8554/motion_test_1
rtsp://localhost:8554/motion_test_2
rtsp://localhost:8554/motion_test_3
rtsp://localhost:8554/motion_test_4
rtsp://localhost:8554/motion_test_5
rtsp://localhost:8554/bigbuckbunny_320p
rtsp://localhost:8554/sintel_720p

# Public RTSP test streams (if available)
rtsp://wowzaec2demo.streamlock.net/vod/mp4:BigBuckBunny_115k.mp4
rtsp://wowzaec2demo.streamlock.net/vod/mp4:BigBuckBunny_175k.mp4
EOF

# Create file paths for direct file testing
echo -e "\n${YELLOW}Creating file paths list...${NC}"

ls -1 "$TEST_VIDEOS_DIR"/*.mp4 2>/dev/null | head -200 > test_file_sources.txt || true

# Note: Real camera URLs are NOT used to avoid network dependencies

# Create mixed sources file (combination of all)
cat test_file_sources.txt > mixed_test_sources.txt
cat rtsp_test_sources.txt | grep -v "^#" >> mixed_test_sources.txt

# Duplicate sources to reach 200+ entries
echo -e "\n${YELLOW}Expanding source list for high concurrency testing...${NC}"

touch expanded_test_sources.txt
for i in {1..20}; do
    cat test_file_sources.txt >> expanded_test_sources.txt
done

# Summary
echo -e "\n${GREEN}=== Test Sources Summary ===${NC}"
echo "Test videos directory: $TEST_VIDEOS_DIR"
echo "Generated videos: $(ls -1 $TEST_VIDEOS_DIR/*.mp4 2>/dev/null | wc -l)"
echo "RTSP URLs: $(grep -v "^#" rtsp_test_sources.txt | wc -l)"
echo "File sources: $(wc -l < test_file_sources.txt)"
echo "Expanded sources: $(wc -l < expanded_test_sources.txt)"
echo ""
echo "Files created:"
echo "  - rtsp_test_sources.txt    : RTSP stream URLs"
echo "  - test_file_sources.txt    : Direct file paths"
echo "  - mixed_test_sources.txt   : Combined sources"
echo "  - expanded_test_sources.txt: 200+ sources for stress testing"