#!/bin/bash

###############################################################################
# Docker Image Vulnerability Scanner
# Scans Docker images for security vulnerabilities using Trivy
# Provides detailed reports and actionable security recommendations
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
SEVERITY="CRITICAL,HIGH,MEDIUM,LOW"
OUTPUT_FORMAT="table"
OUTPUT_FILE=""
FAIL_ON_CRITICAL=false
SCAN_TYPE="vuln"  # vuln, config, secret
TRIVY_CACHE_DIR="${HOME}/.cache/trivy"

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

# Function to check if Trivy is installed
check_trivy_installed() {
    if ! command -v trivy &> /dev/null; then
        print_color "$YELLOW" "Trivy not found. Installing..."
        install_trivy
    else
        local version=$(trivy --version | head -n 1)
        print_color "$GREEN" "✓ Trivy is installed: $version"
    fi
}

# Function to install Trivy
install_trivy() {
    print_color "$BLUE" "Installing Trivy..."
    
    # Detect OS
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux installation
        curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS installation
        if command -v brew &> /dev/null; then
            brew install aquasecurity/trivy/trivy
        else
            error_exit "Homebrew not found. Please install Homebrew or manually install Trivy."
        fi
    else
        error_exit "Unsupported OS. Please install Trivy manually from https://github.com/aquasecurity/trivy"
    fi
    
    print_color "$GREEN" "✓ Trivy installed successfully"
}

# Function to update Trivy database
update_trivy_db() {
    print_color "$BLUE" "Updating Trivy vulnerability database..."
    
    if trivy image --download-db-only 2>&1 | grep -q "No such file or directory"; then
        mkdir -p "$TRIVY_CACHE_DIR"
    fi
    
    trivy image --download-db-only 2>&1 | while read line; do
        if [[ "$line" =~ "Downloading" ]] || [[ "$line" =~ "Updating" ]]; then
            echo -ne "\r$line"
        fi
    done
    echo ""
    
    print_color "$GREEN" "✓ Database updated successfully"
}

# Function to perform vulnerability scan
scan_vulnerabilities() {
    print_header "Vulnerability Scan"
    
    print_color "$BLUE" "Scanning image: $IMAGE_NAME"
    print_color "$BLUE" "Severity levels: $SEVERITY"
    print_color "$BLUE" "Scan type: $SCAN_TYPE"
    echo ""
    
    local temp_json="/tmp/trivy-scan-$$.json"
    
    # Perform scan and save to JSON for parsing
    trivy image \
        --severity "$SEVERITY" \
        --format json \
        --output "$temp_json" \
        "$IMAGE_NAME" 2>/dev/null
    
    # Display table format
    if [ "$OUTPUT_FORMAT" == "table" ]; then
        trivy image \
            --severity "$SEVERITY" \
            --format table \
            "$IMAGE_NAME"
    fi
    
    echo "$temp_json"
}

# Function to parse scan results
parse_scan_results() {
    local json_file=$1
    
    if [ ! -f "$json_file" ]; then
        error_exit "Scan results file not found"
    fi
    
    # Count vulnerabilities by severity
    local critical=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "$json_file" 2>/dev/null || echo "0")
    local high=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "$json_file" 2>/dev/null || echo "0")
    local medium=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="MEDIUM")] | length' "$json_file" 2>/dev/null || echo "0")
    local low=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="LOW")] | length' "$json_file" 2>/dev/null || echo "0")
    local unknown=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="UNKNOWN")] | length' "$json_file" 2>/dev/null || echo "0")
    
    local total=$((critical + high + medium + low + unknown))
    
    echo "$critical:$high:$medium:$low:$unknown:$total"
}

# Function to display summary
display_summary() {
    local results=$1
    
    IFS=':' read -r critical high medium low unknown total <<< "$results"
    
    print_header "Vulnerability Summary"
    
    printf "%-20s %s\n" "SEVERITY" "COUNT"
    echo "----------------------------------------"
    
    if [ "$critical" -gt 0 ]; then
        printf "%-20s ${RED}%s${NC}\n" "🔴 Critical" "$critical"
    else
        printf "%-20s ${GREEN}%s${NC}\n" "🔴 Critical" "$critical"
    fi
    
    if [ "$high" -gt 0 ]; then
        printf "%-20s ${YELLOW}%s${NC}\n" "🟠 High" "$high"
    else
        printf "%-20s ${GREEN}%s${NC}\n" "🟠 High" "$high"
    fi
    
    printf "%-20s %s\n" "🟡 Medium" "$medium"
    printf "%-20s %s\n" "🟢 Low" "$low"
    
    if [ "$unknown" -gt 0 ]; then
        printf "%-20s %s\n" "⚪ Unknown" "$unknown"
    fi
    
    echo "----------------------------------------"
    printf "%-20s ${BLUE}%s${NC}\n" "Total" "$total"
    echo ""
    
    # Security status
    if [ "$critical" -eq 0 ] && [ "$high" -eq 0 ]; then
        print_color "$GREEN" "✅ PASSED: No critical or high severity vulnerabilities found"
    elif [ "$critical" -gt 0 ]; then
        print_color "$RED" "❌ FAILED: $critical critical vulnerabilities found"
    else
        print_color "$YELLOW" "⚠️  WARNING: $high high severity vulnerabilities found"
    fi
    
    echo ""
}

# Function to display top vulnerabilities
display_top_vulnerabilities() {
    local json_file=$1
    local count=${2:-5}
    
    print_header "Top $count Critical Vulnerabilities"
    
    local critical_vulns=$(jq -r '.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL") | 
        "\(.VulnerabilityID)|\(.PkgName)|\(.InstalledVersion)|\(.FixedVersion // "N/A")|\(.Title // "No description")"' \
        "$json_file" 2>/dev/null | head -n "$count")
    
    if [ -z "$critical_vulns" ]; then
        print_color "$GREEN" "✓ No critical vulnerabilities found!"
        echo ""
        return
    fi
    
    printf "%-20s %-20s %-15s %-15s\n" "CVE ID" "PACKAGE" "VERSION" "FIXED IN"
    echo "--------------------------------------------------------------------------------"
    
    echo "$critical_vulns" | while IFS='|' read -r cve pkg ver fixed title; do
        printf "%-20s %-20s %-15s %-15s\n" "$cve" "$pkg" "$ver" "$fixed"
        echo "   → $title"
    done
    
    echo ""
}

# Function to scan for misconfigurations
scan_misconfigurations() {
    print_header "Configuration Security Scan"
    
    print_color "$BLUE" "Scanning for security misconfigurations..."
    echo ""
    
    trivy image \
        --scanners config \
        --format table \
        "$IMAGE_NAME" 2>/dev/null || print_color "$YELLOW" "No misconfigurations detected"
    
    echo ""
}

# Function to scan for secrets
scan_secrets() {
    print_header "Secret Detection Scan"
    
    print_color "$BLUE" "Scanning for exposed secrets..."
    echo ""
    
    local temp_secret_json="/tmp/trivy-secret-$$.json"
    
    trivy image \
        --scanners secret \
        --format json \
        --output "$temp_secret_json" \
        "$IMAGE_NAME" 2>/dev/null
    
    local secret_count=$(jq '[.Results[]?.Secrets[]?] | length' "$temp_secret_json" 2>/dev/null || echo "0")
    
    if [ "$secret_count" -gt 0 ]; then
        print_color "$RED" "⚠️  WARNING: $secret_count potential secret(s) detected!"
        echo ""
        trivy image --scanners secret --format table "$IMAGE_NAME" 2>/dev/null
    else
        print_color "$GREEN" "✓ No secrets detected in image"
    fi
    
    rm -f "$temp_secret_json"
    echo ""
}

# Function to generate security score
generate_security_score() {
    local results=$1
    
    IFS=':' read -r critical high medium low unknown total <<< "$results"
    
    local score=100
    
    # Penalty system
    score=$((score - (critical * 10)))  # -10 per critical
    score=$((score - (high * 5)))       # -5 per high
    score=$((score - (medium * 2)))     # -2 per medium
    score=$((score - (low * 1)))        # -1 per low
    
    # Ensure score doesn't go negative
    if [ $score -lt 0 ]; then
        score=0
    fi
    
    print_header "Security Score"
    
    if [ $score -ge 90 ]; then
        print_color "$GREEN" "Score: $score/100 (Excellent)"
        echo "🏆 Your image has excellent security posture!"
    elif [ $score -ge 75 ]; then
        print_color "$GREEN" "Score: $score/100 (Good)"
        echo "✓ Your image has good security with minor vulnerabilities"
    elif [ $score -ge 60 ]; then
        print_color "$YELLOW" "Score: $score/100 (Fair)"
        echo "⚠ Address high severity vulnerabilities"
    elif [ $score -ge 40 ]; then
        print_color "$YELLOW" "Score: $score/100 (Poor)"
        echo "⚠️ Multiple security issues need attention"
    else
        print_color "$RED" "Score: $score/100 (Critical)"
        echo "❌ Immediate action required - critical vulnerabilities present"
    fi
    
    echo ""
}

# Function to provide remediation guidance
provide_remediation_guidance() {
    local results=$1
    
    IFS=':' read -r critical high medium low unknown total <<< "$results"
    
    if [ "$total" -eq 0 ]; then
        return
    fi
    
    print_header "Remediation Guidance"
    
    if [ "$critical" -gt 0 ] || [ "$high" -gt 0 ]; then
        print_color "$YELLOW" "🔧 Recommended Actions:"
        echo ""
        echo "1. Update Base Image:"
        echo "   → Check for latest security patches of your base image"
        echo "   → Consider using Alpine or distroless images"
        echo "   → Example: FROM python:3.11-alpine"
        echo ""
        
        echo "2. Update Dependencies:"
        echo "   → Update package versions in requirements.txt"
        echo "   → Run: pip list --outdated"
        echo "   → Use specific versions instead of ranges"
        echo ""
        
        echo "3. Multi-Stage Builds:"
        echo "   → Use multi-stage builds to exclude unnecessary packages"
        echo "   → Only copy required artifacts to runtime stage"
        echo ""
        
        echo "4. Regular Scans:"
        echo "   → Integrate scanning into CI/CD pipeline"
        echo "   → Scan images before pushing to registry"
        echo "   → Set up automated vulnerability notifications"
        echo ""
    fi
    
    print_color "$BLUE" "📚 Additional Resources:"
    echo "   → Trivy Documentation: https://aquasecurity.github.io/trivy/"
    echo "   → CVE Database: https://cve.mitre.org/"
    echo "   → NIST Vulnerability Database: https://nvd.nist.gov/"
    echo ""
}

# Function to export reports
export_reports() {
    local json_file=$1
    local base_name="${OUTPUT_FILE:-vulnerability-report}"
    
    print_header "Exporting Reports"
    
    # JSON report
    cp "$json_file" "${base_name}.json"
    print_color "$GREEN" "✓ JSON report: ${base_name}.json"
    
    # HTML report
    trivy image \
        --severity "$SEVERITY" \
        --format template \
        --template "@contrib/html.tpl" \
        --output "${base_name}.html" \
        "$IMAGE_NAME" 2>/dev/null
    print_color "$GREEN" "✓ HTML report: ${base_name}.html"
    
    # SARIF report (for GitHub integration)
    trivy image \
        --severity "$SEVERITY" \
        --format sarif \
        --output "${base_name}.sarif" \
        "$IMAGE_NAME" 2>/dev/null
    print_color "$GREEN" "✓ SARIF report: ${base_name}.sarif"
    
    # CSV report
    jq -r '.Results[]?.Vulnerabilities[]? | 
        [.Severity, .VulnerabilityID, .PkgName, .InstalledVersion, .FixedVersion // "N/A", .Title] | 
        @csv' "$json_file" > "${base_name}.csv" 2>/dev/null
    
    # Add CSV header
    echo "Severity,CVE,Package,Installed,Fixed,Description" | cat - "${base_name}.csv" > temp && mv temp "${base_name}.csv"
    print_color "$GREEN" "✓ CSV report: ${base_name}.csv"
    
    echo ""
}

# Function to compare with another image
compare_with_image() {
    local compare_image=$2
    
    print_header "Comparing with: $compare_image"
    
    local temp_compare_json="/tmp/trivy-compare-$$.json"
    
    trivy image \
        --severity "$SEVERITY" \
        --format json \
        --output "$temp_compare_json" \
        "$compare_image" 2>/dev/null
    
    local results1=$(parse_scan_results "/tmp/trivy-scan-$$.json")
    local results2=$(parse_scan_results "$temp_compare_json")
    
    IFS=':' read -r crit1 high1 med1 low1 unk1 tot1 <<< "$results1"
    IFS=':' read -r crit2 high2 med2 low2 unk2 tot2 <<< "$results2"
    
    printf "%-25s %-15s %-15s %-15s\n" "SEVERITY" "$IMAGE_NAME" "$compare_image" "DIFFERENCE"
    echo "--------------------------------------------------------------------------------"
    printf "%-25s %-15s %-15s %-15s\n" "Critical" "$crit1" "$crit2" "$((crit1 - crit2))"
    printf "%-25s %-15s %-15s %-15s\n" "High" "$high1" "$high2" "$((high1 - high2))"
    printf "%-25s %-15s %-15s %-15s\n" "Medium" "$med1" "$med2" "$((med1 - med2))"
    printf "%-25s %-15s %-15s %-15s\n" "Low" "$low1" "$low2" "$((low1 - low2))"
    printf "%-25s %-15s %-15s %-15s\n" "Total" "$tot1" "$tot2" "$((tot1 - tot2))"
    echo ""
    
    if [ "$tot1" -lt "$tot2" ]; then
        print_color "$GREEN" "✓ $IMAGE_NAME has fewer vulnerabilities ($((tot2 - tot1)) less)"
    elif [ "$tot1" -gt "$tot2" ]; then
        print_color "$RED" "⚠ $IMAGE_NAME has more vulnerabilities ($((tot1 - tot2)) more)"
    else
        print_color "$BLUE" "Both images have the same number of vulnerabilities"
    fi
    
    rm -f "$temp_compare_json"
    echo ""
}

# Print usage
usage() {
    cat << EOF
Usage: $0 [IMAGE_NAME] [OPTIONS]

Scan Docker images for security vulnerabilities using Trivy

ARGUMENTS:
    IMAGE_NAME              Docker image to scan (default: multi-stage-app:latest)

OPTIONS:
    -s, --severity LEVELS   Severity levels to scan (default: CRITICAL,HIGH,MEDIUM,LOW)
    -f, --format FORMAT     Output format: table, json, sarif (default: table)
    -o, --output FILE       Export reports with this base filename
    --fail-on-critical      Exit with error if critical vulnerabilities found
    --scan-config           Also scan for misconfigurations
    --scan-secrets          Also scan for exposed secrets
    --compare IMAGE         Compare vulnerabilities with another image
    -h, --help             Show this help message

EXAMPLES:
    # Basic scan
    $0

    # Scan specific image
    $0 myapp:latest

    # Scan only critical and high
    $0 myapp:latest --severity CRITICAL,HIGH

    # Export reports
    $0 --output security-scan

    # Complete security scan
    $0 --scan-config --scan-secrets --output full-scan

    # Compare images
    $0 multi-stage-app:latest --compare single-stage-app:latest

EOF
}

# Parse command line arguments
COMPARE_IMAGE=""
SCAN_CONFIG=false
SCAN_SECRETS_FLAG=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--severity)
            SEVERITY="$2"
            shift 2
            ;;
        -f|--format)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --fail-on-critical)
            FAIL_ON_CRITICAL=true
            shift
            ;;
        --scan-config)
            SCAN_CONFIG=true
            shift
            ;;
        --scan-secrets)
            SCAN_SECRETS_FLAG=true
            shift
            ;;
        --compare)
            COMPARE_IMAGE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            print_color "$RED" "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            IMAGE_NAME="$1"
            shift
            ;;
    esac
done

# Main execution
main() {
    print_color "$CYAN" "╔══════════════════════════════════════════╗"
    print_color "$CYAN" "║  Docker Security Vulnerability Scanner  ║"
    print_color "$CYAN" "╚══════════════════════════════════════════╝"
    
    # Check prerequisites
    check_image_exists "$IMAGE_NAME"
    check_trivy_installed
    update_trivy_db
    
    # Perform vulnerability scan
    local json_file=$(scan_vulnerabilities)
    local results=$(parse_scan_results "$json_file")
    
    # Display results
    display_summary "$results"
    display_top_vulnerabilities "$json_file" 5
    
    # Additional scans
    if [ "$SCAN_CONFIG" = true ]; then
        scan_misconfigurations
    fi
    
    if [ "$SCAN_SECRETS_FLAG" = true ]; then
        scan_secrets
    fi
    
    # Generate security score
    generate_security_score "$results"
    
    # Provide remediation guidance
    provide_remediation_guidance "$results"
    
    # Compare with another image if requested
    if [ -n "$COMPARE_IMAGE" ]; then
        compare_with_image "$IMAGE_NAME" "$COMPARE_IMAGE"
    fi
    
    # Export reports if requested
    if [ -n "$OUTPUT_FILE" ]; then
        export_reports "$json_file"
    fi
    
    # Cleanup
    rm -f "$json_file"
    
    print_header "Scan Complete"
    print_color "$GREEN" "✓ Security scan finished successfully"
    echo ""
    
    # Exit with error if critical vulnerabilities found and flag is set
    IFS=':' read -r critical high medium low unknown total <<< "$results"
    if [ "$FAIL_ON_CRITICAL" = true ] && [ "$critical" -gt 0 ]; then
        print_color "$RED" "Exiting with error due to critical vulnerabilities"
        exit 1
    fi
}

# Run main function
main
