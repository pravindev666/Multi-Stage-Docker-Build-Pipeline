#!/bin/bash

###############################################################################
# Docker Image Optimization Script
# Analyzes Docker images and provides optimization recommendations
# Identifies large layers, unnecessary files, and improvement opportunities
###############################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Default values
IMAGE_NAME="${1:-multi-stage-app:latest}"
THRESHOLD_MB=50  # Threshold for large layer warning
OUTPUT_FILE=""

# Function to print colored output
print_color() {
    local color=$1
    shift
    echo -e "${color}$@${NC}"
}

# Function to print section header
print_header() {
    echo ""
    print_color "$CYAN" "=========================================="
    print_color "$CYAN" "$1"
    print_color "$CYAN" "=========================================="
    echo ""
}

# Function to print error and exit
error_exit() {
    print_color "$RED" "Error: $1"
    exit 1
}

# Function to check if image exists
check_image_exists() {
    local image=$1
    if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${image}$"; then
        error_exit "Image $image not found. Please build it first."
    fi
}

# Function to get image size in bytes
get_image_size_bytes() {
    docker inspect --format='{{.Size}}' "$IMAGE_NAME"
}

# Function to convert bytes to MB
bytes_to_mb() {
    echo "scale=2; $1 / 1024 / 1024" | bc
}

# Function to get image metadata
get_image_info() {
    print_header "Image Information"
    
    local size=$(docker images "$IMAGE_NAME" --format "{{.Size}}")
    local id=$(docker images "$IMAGE_NAME" --format "{{.ID}}")
    local created=$(docker images "$IMAGE_NAME" --format "{{.CreatedAt}}")
    
    echo "Image:       $IMAGE_NAME"
    echo "ID:          $id"
    echo "Size:        $size"
    echo "Created:     $created"
    echo ""
}

# Function to analyze layers
analyze_layers() {
    print_header "Layer Analysis"
    
    local total_layers=$(docker history "$IMAGE_NAME" --no-trunc | tail -n +2 | wc -l)
    local image_size_bytes=$(get_image_size_bytes)
    
    echo "Total Layers: $total_layers"
    echo "Total Size:   $(bytes_to_mb $image_size_bytes) MB"
    echo ""
    
    print_color "$YELLOW" "Analyzing individual layers..."
    echo ""
    
    printf "%-12s %-15s %-50s\n" "LAYER #" "SIZE" "COMMAND"
    echo "--------------------------------------------------------------------------------"
    
    local layer_num=1
    local large_layers=0
    
    while IFS=$'\t' read -r size command; do
        # Extract numeric size in bytes
        local size_display="$size"
        local size_bytes=0
        
        if [[ "$size" =~ ^([0-9.]+)([KMGT]?B)$ ]]; then
            local num="${BASH_REMATCH[1]}"
            local unit="${BASH_REMATCH[2]}"
            
            case "$unit" in
                "B")   size_bytes=$(echo "$num" | bc) ;;
                "KB")  size_bytes=$(echo "$num * 1024" | bc) ;;
                "MB")  size_bytes=$(echo "$num * 1024 * 1024" | bc) ;;
                "GB")  size_bytes=$(echo "$num * 1024 * 1024 * 1024" | bc) ;;
            esac
            
            local size_mb=$(echo "scale=2; $size_bytes / 1024 / 1024" | bc)
            
            # Check if layer is large
            if (( $(echo "$size_mb > $THRESHOLD_MB" | bc -l) )); then
                large_layers=$((large_layers + 1))
                size_display="${RED}${size}${NC}"
            fi
        fi
        
        # Truncate long commands
        if [ ${#command} -gt 45 ]; then
            command="${command:0:45}..."
        fi
        
        printf "%-12s %-15b %-50s\n" "$layer_num" "$size_display" "$command"
        layer_num=$((layer_num + 1))
        
    done < <(docker history "$IMAGE_NAME" --human=true --format "{{.Size}}\t{{.CreatedBy}}" --no-trunc | tail -n +2)
    
    echo ""
    
    if [ $large_layers -gt 0 ]; then
        print_color "$RED" "⚠ Warning: Found $large_layers layer(s) larger than ${THRESHOLD_MB}MB"
    else
        print_color "$GREEN" "✓ All layers are within acceptable size limits"
    fi
    
    echo ""
}

# Function to identify optimization opportunities
identify_optimizations() {
    print_header "Optimization Recommendations"
    
    local image_size_bytes=$(get_image_size_bytes)
    local image_size_mb=$(bytes_to_mb $image_size_bytes)
    local layer_count=$(docker history "$IMAGE_NAME" --no-trunc | tail -n +2 | wc -l)
    local recommendations=0
    
    # Check image size
    if (( $(echo "$image_size_mb > 500" | bc -l) )); then
        print_color "$YELLOW" "📦 Image Size Optimization:"
        echo "   → Current size: ${image_size_mb} MB (Large)"
        echo "   → Recommendation: Consider using Alpine or distroless base images"
        echo "   → Impact: Can reduce size by 60-90%"
        echo ""
        recommendations=$((recommendations + 1))
    elif (( $(echo "$image_size_mb > 200" | bc -l) )); then
        print_color "$YELLOW" "📦 Image Size:"
        echo "   → Current size: ${image_size_mb} MB (Medium)"
        echo "   → Consider: Review installed packages and dependencies"
        echo ""
        recommendations=$((recommendations + 1))
    else
        print_color "$GREEN" "✓ Image size is well optimized (${image_size_mb} MB)"
        echo ""
    fi
    
    # Check layer count
    if [ $layer_count -gt 20 ]; then
        print_color "$YELLOW" "🔧 Layer Count Optimization:"
        echo "   → Current layers: $layer_count (High)"
        echo "   → Recommendation: Combine RUN commands to reduce layers"
        echo "   → Example: RUN apt-get update && apt-get install -y pkg1 pkg2 && rm -rf /var/lib/apt/lists/*"
        echo "   → Impact: Fewer layers = faster pulls and less storage"
        echo ""
        recommendations=$((recommendations + 1))
    elif [ $layer_count -gt 15 ]; then
        print_color "$YELLOW" "🔧 Layer Count:"
        echo "   → Current layers: $layer_count (Moderate)"
        echo "   → Consider: Combining related RUN commands"
        echo ""
        recommendations=$((recommendations + 1))
    else
        print_color "$GREEN" "✓ Layer count is optimal ($layer_count layers)"
        echo ""
    fi
    
    # Check for multi-stage build indicators
    local has_builder_stage=$(docker history "$IMAGE_NAME" --no-trunc --format "{{.CreatedBy}}" | grep -i "FROM.*AS builder" || echo "")
    
    if [ -z "$has_builder_stage" ]; then
        print_color "$YELLOW" "🏗️ Multi-Stage Build:"
        echo "   → Not detected in image history"
        echo "   → Recommendation: Use multi-stage builds to separate build and runtime"
        echo "   → Benefits:"
        echo "      • Exclude build tools from final image"
        echo "      • Reduce image size by 70-90%"
        echo "      • Improve security (smaller attack surface)"
        echo ""
        recommendations=$((recommendations + 1))
    else
        print_color "$GREEN" "✓ Multi-stage build detected"
        echo ""
    fi
    
    # Check for common optimization patterns
    print_color "$BLUE" "🔍 Additional Checks:"
    echo ""
    
    # Check for apt-get clean
    local has_apt_clean=$(docker history "$IMAGE_NAME" --no-trunc --format "{{.CreatedBy}}" | grep -i "apt-get.*clean\|rm.*apt/lists" || echo "")
    if [ -z "$has_apt_clean" ]; then
        echo "   ⚠ Package manager cleanup not detected"
        echo "      → Add: && rm -rf /var/lib/apt/lists/* after apt-get install"
        recommendations=$((recommendations + 1))
    else
        echo "   ✓ Package manager cleanup found"
    fi
    
    # Check for --no-cache-dir in pip
    local has_pip_no_cache=$(docker history "$IMAGE_NAME" --no-trunc --format "{{.CreatedBy}}" | grep -i "pip.*--no-cache-dir" || echo "")
    if [ -z "$has_pip_no_cache" ]; then
        echo "   ⚠ pip cache optimization not detected"
        echo "      → Add: pip install --no-cache-dir to prevent cache storage"
        recommendations=$((recommendations + 1))
    else
        echo "   ✓ pip cache optimization found"
    fi
    
    # Check for non-root user
    local has_user=$(docker history "$IMAGE_NAME" --no-trunc --format "{{.CreatedBy}}" | grep -i "USER " || echo "")
    if [ -z "$has_user" ]; then
        echo "   ⚠ Non-root user not detected"
        echo "      → Security: Create and switch to non-root user"
        echo "      → Example: RUN useradd -m appuser && USER appuser"
        recommendations=$((recommendations + 1))
    else
        echo "   ✓ Non-root user configured"
    fi
    
    # Check for health check
    local has_healthcheck=$(docker inspect "$IMAGE_NAME" --format='{{.Config.Healthcheck}}' | grep -v "^<nil>$" || echo "")
    if [ -z "$has_healthcheck" ]; then
        echo "   ⚠ Health check not configured"
        echo "      → Add HEALTHCHECK instruction for container monitoring"
        recommendations=$((recommendations + 1))
    else
        echo "   ✓ Health check configured"
    fi
    
    echo ""
    
    if [ $recommendations -eq 0 ]; then
        print_color "$GREEN" "🎉 Excellent! No major optimization opportunities found."
        print_color "$GREEN" "    Your image is well-optimized!"
    else
        print_color "$YELLOW" "Found $recommendations optimization opportunity/opportunities"
    fi
    
    echo ""
}

# Function to generate optimization score
generate_score() {
    print_header "Optimization Score"
    
    local score=100
    local image_size_bytes=$(get_image_size_bytes)
    local image_size_mb=$(bytes_to_mb $image_size_bytes)
    local layer_count=$(docker history "$IMAGE_NAME" --no-trunc | tail -n +2 | wc -l)
    
    # Size penalties
    if (( $(echo "$image_size_mb > 1000" | bc -l) )); then
        score=$((score - 30))
    elif (( $(echo "$image_size_mb > 500" | bc -l) )); then
        score=$((score - 20))
    elif (( $(echo "$image_size_mb > 200" | bc -l) )); then
        score=$((score - 10))
    fi
    
    # Layer count penalties
    if [ $layer_count -gt 25 ]; then
        score=$((score - 15))
    elif [ $layer_count -gt 20 ]; then
        score=$((score - 10))
    elif [ $layer_count -gt 15 ]; then
        s
