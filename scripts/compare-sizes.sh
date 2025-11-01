#!/bin/bash

###############################################################################
# Docker Image Size Comparison Script
# Compares multi-stage vs single-stage Docker images
# Provides detailed layer-by-layer analysis and size breakdown
###############################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default image names
MULTI_STAGE_IMAGE="${MULTI_STAGE_IMAGE:-multi-stage-app:latest}"
SINGLE_STAGE_IMAGE="${SINGLE_STAGE_IMAGE:-single-stage-app:latest}"

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
    local image=$1
    docker inspect --format='{{.Size}}' "$image" 2>/dev/null || echo "0"
}

# Function to get image size in human-readable format
get_image_size_human() {
    local image=$1
    docker images "$image" --format "{{.Size}}" 2>/dev/null || echo "N/A"
}

# Function to convert bytes to human-readable format
bytes_to_human() {
    local bytes=$1
    local units=("B" "KB" "MB" "GB" "TB")
    local unit=0
    local size=$bytes
    
    while (( $(echo "$size >= 1024" | bc -l) )) && (( unit < 4 )); do
        size=$(echo "scale=2; $size / 1024" | bc)
        ((unit++))
    done
    
    echo "$size ${units[$unit]}"
}

# Function to get layer count
get_layer_count() {
    local image=$1
    docker history "$image" --no-trunc 2>/dev/null | tail -n +2 | wc -l
}

# Function to get creation date
get_creation_date() {
    local image=$1
    docker inspect --format='{{.Created}}' "$image" 2>/dev/null | cut -d'T' -f1
}

# Function to analyze layers
analyze_layers() {
    local image=$1
    local image_name=$2
    
    print_color "$YELLOW" "Analyzing layers for: $image_name"
    echo ""
    
    printf "%-15s %-50s\n" "SIZE" "LAYER"
    echo "-------------------------------------------------------------------"
    
    docker history "$image" --human=true --format "table {{.Size}}\t{{.CreatedBy}}" --no-trunc 2>/dev/null | \
        tail -n +2 | \
        head -n 10 | \
        while IFS=\t' read -r size command; do
            # Truncate long commands
            if [ ${#command} -gt 45 ]; then
                command="${command:0:45}..."
            fi
            printf "%-15s %-50s\n" "$size" "$command"
        done
    
    local total_layers=$(get_layer_count "$image")
    if [ "$total_layers" -gt 10 ]; then
        echo "... ($((total_layers - 10)) more layers)"
    fi
    echo ""
}

# Function to calculate percentage
calculate_percentage() {
    local part=$1
    local whole=$2
    echo "scale=2; ($part / $whole) * 100" | bc
}

# Function to calculate reduction
calculate_reduction() {
    local old=$1
    local new=$2
    local diff=$((old - new))
    local percent=$(calculate_percentage "$diff" "$old")
    echo "$diff bytes (${percent}%)"
}

# Main comparison function
compare_images() {
    print_header "Docker Image Size Comparison"
    
    # Check if images exist
    print_color "$BLUE" "Checking for images..."
    check_image_exists "$MULTI_STAGE_IMAGE"
    check_image_exists "$SINGLE_STAGE_IMAGE"
    print_color "$GREEN" "✓ Both images found"
    
    # Get image sizes
    print_color "$BLUE" "Gathering image information..."
    
    MULTI_SIZE_BYTES=$(get_image_size_bytes "$MULTI_STAGE_IMAGE")
    SINGLE_SIZE_BYTES=$(get_image_size_bytes "$SINGLE_STAGE_IMAGE")
    
    MULTI_SIZE_HUMAN=$(get_image_size_human "$MULTI_STAGE_IMAGE")
    SINGLE_SIZE_HUMAN=$(get_image_size_human "$SINGLE_STAGE_IMAGE")
    
    MULTI_LAYERS=$(get_layer_count "$MULTI_STAGE_IMAGE")
    SINGLE_LAYERS=$(get_layer_count "$SINGLE_STAGE_IMAGE")
    
    MULTI_DATE=$(get_creation_date "$MULTI_STAGE_IMAGE")
    SINGLE_DATE=$(get_creation_date "$SINGLE_STAGE_IMAGE")
    
    # Calculate differences
    SIZE_DIFF=$((SINGLE_SIZE_BYTES - MULTI_SIZE_BYTES))
    SIZE_REDUCTION=$(calculate_percentage "$SIZE_DIFF" "$SINGLE_SIZE_BYTES")
    
    LAYER_DIFF=$((SINGLE_LAYERS - MULTI_LAYERS))
    
    # Print comparison table
    print_header "Size Comparison Summary"
    
    printf "%-25s %-20s %-20s\n" "METRIC" "MULTI-STAGE" "SINGLE-STAGE"
    echo "-------------------------------------------------------------------"
    printf "%-25s %-20s %-20s\n" "Image Name" "$MULTI_STAGE_IMAGE" "$SINGLE_STAGE_IMAGE"
    printf "%-25s %-20s %-20s\n" "Size (Human)" "$MULTI_SIZE_HUMAN" "$SINGLE_SIZE_HUMAN"
    printf "%-25s %-20s %-20s\n" "Size (Bytes)" "$MULTI_SIZE_BYTES" "$SINGLE_SIZE_BYTES"
    printf "%-25s %-20s %-20s\n" "Layer Count" "$MULTI_LAYERS" "$SINGLE_LAYERS"
    printf "%-25s %-20s %-20s\n" "Created" "$MULTI_DATE" "$SINGLE_DATE"
    echo ""
    
    # Print reduction summary
    print_header "Optimization Results"
    
    print_color "$GREEN" "Size Reduction:"
    print_color "$GREEN" "  Absolute: $(bytes_to_human $SIZE_DIFF)"
    print_color "$GREEN" "  Percentage: ${SIZE_REDUCTION}%"
    echo ""
    
    print_color "$BLUE" "Layer Optimization:"
    if [ "$LAYER_DIFF" -gt 0 ]; then
        print_color "$GREEN" "  Reduced by: $LAYER_DIFF layers"
    elif [ "$LAYER_DIFF" -lt 0 ]; then
        print_color "$YELLOW" "  Increased by: ${LAYER_DIFF#-} layers"
    else
        print_color "$BLUE" "  Same number of layers"
    fi
    echo ""
    
    # Visual comparison
    print_header "Visual Size Comparison"
    
    local multi_percent=$(calculate_percentage "$MULTI_SIZE_BYTES" "$SINGLE_SIZE_BYTES")
    local multi_bars=$(echo "($multi_percent / 2)" | bc)
    local single_bars=50
    
    echo "Multi-Stage:  $(printf '█%.0s' $(seq 1 $multi_bars)) $MULTI_SIZE_HUMAN"
    echo "Single-Stage: $(printf '█%.0s' $(seq 1 $single_bars)) $SINGLE_SIZE_HUMAN"
    echo ""
    
    # Savings calculation
    print_header "Storage & Transfer Savings"
    
    # Calculate savings for different scenarios
    local deployments_per_month=100
    local bandwidth_cost_per_gb=0.09  # AWS data transfer cost
    
    local monthly_data_single=$(echo "scale=2; ($SINGLE_SIZE_BYTES * $deployments_per_month) / 1024 / 1024 / 1024" | bc)
    local monthly_data_multi=$(echo "scale=2; ($MULTI_SIZE_BYTES * $deployments_per_month) / 1024 / 1024 / 1024" | bc)
    local data_saved=$(echo "scale=2; $monthly_data_single - $monthly_data_multi" | bc)
    
    local cost_single=$(echo "scale=2; $monthly_data_single * $bandwidth_cost_per_gb" | bc)
    local cost_multi=$(echo "scale=2; $monthly_data_multi * $bandwidth_cost_per_gb" | bc)
    local cost_saved=$(echo "scale=2; $cost_single - $cost_multi" | bc)
    
    echo "Assuming $deployments_per_month deployments/month:"
    echo ""
    printf "%-30s %-15s %-15s\n" "METRIC" "SINGLE-STAGE" "MULTI-STAGE"
    echo "-------------------------------------------------------------------"
    printf "%-30s %-15s %-15s\n" "Data Transferred" "${monthly_data_single} GB" "${monthly_data_multi} GB"
    printf "%-30s %-15s %-15s\n" "Transfer Cost (AWS)" "\${cost_single}" "\${cost_multi}"
    echo ""
    print_color "$GREEN" "Monthly Savings: ${data_saved} GB (\${cost_saved})"
    print_color "$GREEN" "Annual Savings: $(echo "scale=2; $data_saved * 12" | bc) GB (\$(echo "scale=2; $cost_saved * 12" | bc))"
    echo ""
}

# Layer-by-layer comparison
compare_layers() {
    print_header "Layer-by-Layer Analysis"
    
    echo ""
    analyze_layers "$MULTI_STAGE_IMAGE" "MULTI-STAGE"
    echo ""
    analyze_layers "$SINGLE_STAGE_IMAGE" "SINGLE-STAGE"
}

# Generate detailed report
generate_report() {
    local output_file="${1:-size-comparison-report.txt}"
    
    print_color "$BLUE" "Generating detailed report: $output_file"
    
    {
        echo "Docker Image Size Comparison Report"
        echo "Generated: $(date)"
        echo "======================================"
        echo ""
        
        echo "Multi-Stage Image: $MULTI_STAGE_IMAGE"
        echo "Single-Stage Image: $SINGLE_STAGE_IMAGE"
        echo ""
        
        echo "Size Comparison:"
        echo "  Multi-Stage:  $MULTI_SIZE_HUMAN ($MULTI_SIZE_BYTES bytes)"
        echo "  Single-Stage: $SINGLE_SIZE_HUMAN ($SINGLE_SIZE_BYTES bytes)"
        echo "  Reduction:    $SIZE_REDUCTION%"
        echo ""
        
        echo "Layer Count:"
        echo "  Multi-Stage:  $MULTI_LAYERS layers"
        echo "  Single-Stage: $SINGLE_LAYERS layers"
        echo ""
        
        echo "Multi-Stage Layers:"
        docker history "$MULTI_STAGE_IMAGE" --human=true --no-trunc
        echo ""
        
        echo "Single-Stage Layers:"
        docker history "$SINGLE_STAGE_IMAGE" --human=true --no-trunc
        echo ""
        
    } > "$output_file"
    
    print_color "$GREEN" "✓ Report saved to: $output_file"
}

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Compare Docker image sizes between multi-stage and single-stage builds

OPTIONS:
    -m, --multi-stage IMAGE     Multi-stage image name (default: multi-stage-app:latest)
    -s, --single-stage IMAGE    Single-stage image name (default: single-stage-app:latest)
    -l, --layers                Show detailed layer analysis
    -r, --report FILE           Generate detailed report to file
    -h, --help                  Show this help message

EXAMPLES:
    # Basic comparison
    $0

    # Custom image names
    $0 -m myapp:optimized -s myapp:standard

    # With layer analysis
    $0 --layers

    # Generate report
    $0 --report comparison.txt

ENVIRONMENT VARIABLES:
    MULTI_STAGE_IMAGE           Override default multi-stage image
    SINGLE_STAGE_IMAGE          Override default single-stage image

EOF
}

# Parse command line arguments
SHOW_LAYERS=false
GENERATE_REPORT=false
REPORT_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--multi-stage)
            MULTI_STAGE_IMAGE="$2"
            shift 2
            ;;
        -s|--single-stage)
            SINGLE_STAGE_IMAGE="$2"
            shift 2
            ;;
        -l|--layers)
            SHOW_LAYERS=true
            shift
            ;;
        -r|--report)
            GENERATE_REPORT=true
            REPORT_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_color "$RED" "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Main execution
main() {
    print_color "$CYAN" "╔══════════════════════════════════════════╗"
    print_color "$CYAN" "║  Docker Image Size Comparison Tool      ║"
    print_color "$CYAN" "╚══════════════════════════════════════════╝"
    
    # Run comparison
    compare_images
    
    # Show layer analysis if requested
    if [ "$SHOW_LAYERS" = true ]; then
        compare_layers
    fi
    
    # Generate report if requested
    if [ "$GENERATE_REPORT" = true ]; then
        generate_report "$REPORT_FILE"
    fi
    
    print_header "Comparison Complete"
    print_color "$GREEN" "✓ Analysis finished successfully"
    echo ""
    print_color "$YELLOW" "Tip: Use --layers to see detailed layer breakdown"
    print_color "$YELLOW" "Tip: Use --report FILE to save detailed report"
    echo ""
}

# Run main function
main
