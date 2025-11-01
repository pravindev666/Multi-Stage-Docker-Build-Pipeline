#!/bin/bash

###############################################################################
# Docker Image Test Suite
# Comprehensive testing script for Docker images
# Tests functionality, health, performance, and security
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
CONTAINER_NAME="test-container-$$"
TEST_PORT="${TEST_PORT:-5000}"
HOST_PORT="${HOST_PORT:-5050}"
TIMEOUT=30
HEALTH_CHECK_RETRIES=10

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Test results array
declare -a TEST_RESULTS

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

# Function to print test result
print_test_result() {
    local status=$1
    local test_name=$2
    local message=$3
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    case $status in
        "PASS")
            print_color "$GREEN" "✓ PASS: $test_name"
            TESTS_PASSED=$((TESTS_PASSED + 1))
            TEST_RESULTS+=("PASS: $test_name")
            ;;
        "FAIL")
            print_color "$RED" "✗ FAIL: $test_name"
            if [ -n "$message" ]; then
                print_color "$RED" "   → $message"
            fi
            TESTS_FAILED=$((TESTS_FAILED + 1))
            TEST_RESULTS+=("FAIL: $test_name - $message")
            ;;
        "SKIP")
            print_color "$YELLOW" "⊘ SKIP: $test_name"
            if [ -n "$message" ]; then
                print_color "$YELLOW" "   → $message"
            fi
            TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
            TEST_RESULTS+=("SKIP: $test_name - $message")
            ;;
    esac
}

# Function to cleanup containers
cleanup() {
    if docker ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        print_color "$BLUE" "Cleaning up test container..."
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Function to check if image exists
test_image_exists() {
    print_header "Pre-Test Validation"
    
    if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${IMAGE_NAME}$"; then
        print_test_result "PASS" "Image exists" "$IMAGE_NAME"
        return 0
    else
        print_test_result "FAIL" "Image exists" "Image $IMAGE_NAME not found"
        exit 1
    fi
}

# Function to test image metadata
test_image_metadata() {
    print_header "Image Metadata Tests"
    
    # Test: Image has labels
    local labels=$(docker inspect "$IMAGE_NAME" --format='{{json .Config.Labels}}' 2>/dev/null)
    if [ -n "$labels" ] && [ "$labels" != "null" ]; then
        print_test_result "PASS" "Image has labels"
    else
        print_test_result "SKIP" "Image labels" "No labels found"
    fi
    
    # Test: Image has exposed ports
    local ports=$(docker inspect "$IMAGE_NAME" --format='{{json .Config.ExposedPorts}}' 2>/dev/null)
    if [ -n "$ports" ] && [ "$ports" != "null" ]; then
        print_test_result "PASS" "Image has exposed ports"
    else
        print_test_result "FAIL" "Image exposed ports" "No ports exposed"
    fi
    
    # Test: Image has health check
    local healthcheck=$(docker inspect "$IMAGE_NAME" --format='{{json .Config.Healthcheck}}' 2>/dev/null)
    if [ -n "$healthcheck" ] && [ "$healthcheck" != "null" ]; then
        print_test_result "PASS" "Image has health check"
    else
        print_test_result "SKIP" "Image health check" "No health check defined"
    fi
    
    # Test: Image size is reasonable
    local size_bytes=$(docker inspect "$IMAGE_NAME" --format='{{.Size}}' 2>/dev/null)
    local size_mb=$(echo "scale=2; $size_bytes / 1024 / 1024" | bc)
    
    if (( $(echo "$size_mb < 500" | bc -l) )); then
        print_test_result "PASS" "Image size reasonable" "${size_mb} MB"
    else
        print_test_result "FAIL" "Image size reasonable" "${size_mb} MB is large"
    fi
}

# Function to start container
start_container() {
    print_header "Container Startup Tests"
    
    print_color "$BLUE" "Starting container: $CONTAINER_NAME"
    
    # Test: Container starts successfully
    if docker run -d \
        --name "$CONTAINER_NAME" \
        -p "${HOST_PORT}:${TEST_PORT}" \
        "$IMAGE_NAME" >/dev/null 2>&1; then
        print_test_result "PASS" "Container starts successfully"
    else
        print_test_result "FAIL" "Container starts successfully" "Failed to start container"
        return 1
    fi
    
    # Wait for container to be ready
    sleep 3
    
    # Test: Container is running
    if docker ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        print_test_result "PASS" "Container is running"
    else
        print_test_result "FAIL" "Container is running" "Container exited"
        docker logs "$CONTAINER_NAME" 2>&1 | tail -10
        return 1
    fi
    
    # Test: Container doesn't have restart loops
    local restart_count=$(docker inspect "$CONTAINER_NAME" --format='{{.RestartCount}}' 2>/dev/null)
    if [ "$restart_count" -eq 0 ]; then
        print_test_result "PASS" "No restart loops"
    else
        print_test_result "FAIL" "No restart loops" "Restart count: $restart_count"
    fi
}

# Function to test container health
test_container_health() {
    print_header "Health Check Tests"
    
    print_color "$BLUE" "Waiting for container to be healthy..."
    
    local retries=0
    local healthy=false
    
    while [ $retries -lt $HEALTH_CHECK_RETRIES ]; do
        local health_status=$(docker inspect "$CONTAINER_NAME" --format='{{.State.Health.Status}}' 2>/dev/null || echo "none")
        
        if [ "$health_status" == "healthy" ]; then
            healthy=true
            break
        elif [ "$health_status" == "none" ]; then
            # No health check defined, skip
            print_test_result "SKIP" "Container health check" "No health check defined"
            return 0
        fi
        
        sleep 2
        retries=$((retries + 1))
    done
    
    if [ "$healthy" = true ]; then
        print_test_result "PASS" "Container health check" "Healthy after $((retries * 2)) seconds"
    else
        print_test_result "FAIL" "Container health check" "Not healthy after $((HEALTH_CHECK_RETRIES * 2)) seconds"
    fi
}

# Function to test HTTP endpoints
test_http_endpoints() {
    print_header "HTTP Endpoint Tests"
    
    # Wait a bit for application to be ready
    sleep 5
    
    # Test: Root endpoint responds
    if curl -s -f "http://localhost:${HOST_PORT}/" >/dev/null 2>&1; then
        print_test_result "PASS" "Root endpoint responds"
    else
        print_test_result "FAIL" "Root endpoint responds" "GET / failed"
    fi
    
    # Test: Root endpoint returns JSON
    local response=$(curl -s "http://localhost:${HOST_PORT}/" 2>/dev/null)
    if echo "$response" | jq . >/dev/null 2>&1; then
        print_test_result "PASS" "Root endpoint returns valid JSON"
    else
        print_test_result "FAIL" "Root endpoint returns valid JSON" "Invalid JSON response"
    fi
    
    # Test: Health endpoint responds
    if curl -s -f "http://localhost:${HOST_PORT}/health" >/dev/null 2>&1; then
        print_test_result "PASS" "Health endpoint responds"
    else
        print_test_result "FAIL" "Health endpoint responds" "GET /health failed"
    fi
    
    # Test: Health endpoint returns 200
    local health_status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${HOST_PORT}/health" 2>/dev/null)
    if [ "$health_status" == "200" ]; then
        print_test_result "PASS" "Health endpoint returns 200"
    else
        print_test_result "FAIL" "Health endpoint returns 200" "Got HTTP $health_status"
    fi
    
    # Test: Info endpoint responds
    if curl -s -f "http://localhost:${HOST_PORT}/info" >/dev/null 2>&1; then
        print_test_result "PASS" "Info endpoint responds"
    else
        print_test_result "FAIL" "Info endpoint responds" "GET /info failed"
    fi
    
    # Test: Metrics endpoint responds
    if curl -s -f "http://localhost:${HOST_PORT}/metrics" >/dev/null 2>&1; then
        print_test_result "PASS" "Metrics endpoint responds"
    else
        print_test_result "FAIL" "Metrics endpoint responds" "GET /metrics failed"
    fi
    
    # Test: Response time is acceptable
    local response_time=$(curl -o /dev/null -s -w '%{time_total}' "http://localhost:${HOST_PORT}/" 2>/dev/null)
    local response_ms=$(echo "$response_time * 1000" | bc)
    
    if (( $(echo "$response_ms < 1000" | bc -l) )); then
        print_test_result "PASS" "Response time acceptable" "${response_ms} ms"
    else
        print_test_result "FAIL" "Response time acceptable" "${response_ms} ms (>1000ms)"
    fi
}

# Function to test application functionality
test_application_logic() {
    print_header "Application Logic Tests"
    
    # Test: Application version is set
    local info_response=$(curl -s "http://localhost:${HOST_PORT}/info" 2>/dev/null)
    local app_version=$(echo "$info_response" | jq -r '.application.version' 2>/dev/null)
    
    if [ -n "$app_version" ] && [ "$app_version" != "null" ]; then
        print_test_result "PASS" "Application version is set" "v$app_version"
    else
        print_test_result "SKIP" "Application version" "Version not found in response"
    fi
    
    # Test: System metrics are available
    local metrics_response=$(curl -s "http://localhost:${HOST_PORT}/metrics" 2>/dev/null)
    local cpu_percent=$(echo "$metrics_response" | jq -r '.cpu_percent' 2>/dev/null)
    
    if [ -n "$cpu_percent" ] && [ "$cpu_percent" != "null" ]; then
        print_test_result "PASS" "System metrics available" "CPU: ${cpu_percent}%"
    else
        print_test_result "FAIL" "System metrics available" "Metrics not found"
    fi
    
    # Test: Container user is non-root
    local user=$(docker exec "$CONTAINER_NAME" whoami 2>/dev/null || echo "")
    if [ "$user" != "root" ] && [ -n "$user" ]; then
        print_test_result "PASS" "Running as non-root user" "User: $user"
    else
        print_test_result "FAIL" "Running as non-root user" "Running as root"
    fi
}

# Function to test container performance
test_performance() {
    print_header "Performance Tests"
    
    # Test: Memory usage is reasonable
    local memory_stats=$(docker stats "$CONTAINER_NAME" --no-stream --format "{{.MemUsage}}" 2>/dev/null)
    local memory_mb=$(echo "$memory_stats" | awk '{print $1}' | sed 's/MiB//')
    
    if [ -n "$memory_mb" ] && (( $(echo "$memory_mb < 256" | bc -l) )); then
        print_test_result "PASS" "Memory usage reasonable" "${memory_mb} MB"
    elif [ -n "$memory_mb" ]; then
        print_test_result "FAIL" "Memory usage reasonable" "${memory_mb} MB (>256MB)"
    else
        print_test_result "SKIP" "Memory usage" "Could not retrieve stats"
    fi
    
    # Test: CPU usage is reasonable
    local cpu_percent=$(docker stats "$CONTAINER_NAME" --no-stream --format "{{.CPUPerc}}" 2>/dev/null | sed 's/%//')
    
    if [ -n "$cpu_percent" ] && (( $(echo "$cpu_percent < 50" | bc -l) )); then
        print_test_result "PASS" "CPU usage reasonable" "${cpu_percent}%"
    elif [ -n "$cpu_percent" ]; then
        print_test_result "FAIL" "CPU usage reasonable" "${cpu_percent}% (>50%)"
    else
        print_test_result "SKIP" "CPU usage" "Could not retrieve stats"
    fi
}

# Function to test container logs
test_container_logs() {
    print_header "Logging Tests"
    
    # Test: Container produces logs
    local log_count=$(docker logs "$CONTAINER_NAME" 2>&1 | wc -l)
    if [ "$log_count" -gt 0 ]; then
        print_test_result "PASS" "Container produces logs" "$log_count lines"
    else
        print_test_result "FAIL" "Container produces logs" "No logs found"
    fi
    
    # Test: No error messages in logs
    local error_count=$(docker logs "$CONTAINER_NAME" 2>&1 | grep -i "error\|exception\|failed" | wc -l)
    if [ "$error_count" -eq 0 ]; then
        print_test_result "PASS" "No errors in logs"
    else
        print_test_result "FAIL" "No errors in logs" "$error_count error messages found"
        echo ""
        print_color "$YELLOW" "Recent errors:"
        docker logs "$CONTAINER_NAME" 2>&1 | grep -i "error\|exception\|failed" | tail -5
    fi
}

# Function to test container networking
test_networking() {
    print_header "Network Tests"
    
    # Test: Port is exposed
    local exposed_port=$(docker port "$CONTAINER_NAME" "$TEST_PORT" 2>/dev/null)
    if [ -n "$exposed_port" ]; then
        print_test_result "PASS" "Port is exposed" "$exposed_port"
    else
        print_test_result "FAIL" "Port is exposed" "Port $TEST_PORT not exposed"
    fi
    
    # Test: Can connect to exposed port
    if nc -z localhost "$HOST_PORT" 2>/dev/null; then
        print_test_result "PASS" "Can connect to port"
    else
        print_test_result "FAIL" "Can connect to port" "Cannot connect to localhost:$HOST_PORT"
    fi
}

# Function to test graceful shutdown
test_graceful_shutdown() {
    print_header "Shutdown Tests"
    
    print_color "$BLUE" "Testing graceful shutdown..."
    
    # Send SIGTERM
    docker stop -t 10 "$CONTAINER_NAME" >/dev/null 2>&1
    
    # Check if container stopped cleanly
    local exit_code=$(docker inspect "$CONTAINER_NAME" --format='{{.State.ExitCode}}' 2>/dev/null)
    
    if [ "$exit_code" == "0" ] || [ "$exit_code" == "143" ]; then
        print_test_result "PASS" "Graceful shutdown" "Exit code: $exit_code"
    else
        print_test_result "FAIL" "Graceful shutdown" "Exit code: $exit_code"
    fi
}

# Function to generate test report
generate_test_report() {
    print_header "Test Summary"
    
    local pass_rate=0
    if [ $TESTS_RUN -gt 0 ]; then
        pass_rate=$(echo "scale=2; ($TESTS_PASSED / $TESTS_RUN) * 100" | bc)
    fi
    
    echo "Total Tests:   $TESTS_RUN"
    print_color "$GREEN" "Passed:        $TESTS_PASSED"
    print_color "$RED" "Failed:        $TESTS_FAILED"
    print_color "$YELLOW" "Skipped:       $TESTS_SKIPPED"
    echo "Pass Rate:     ${pass_rate}%"
    echo ""
    
    if [ $TESTS_FAILED -eq 0 ]; then
        print_color "$GREEN" "╔════════════════════════════════════╗"
        print_color "$GREEN" "║   ✓ ALL TESTS PASSED               ║"
        print_color "$GREEN" "╚════════════════════════════════════╝"
        return 0
    else
        print_color "$RED" "╔════════════════════════════════════╗"
        print_color "$RED" "║   ✗ SOME TESTS FAILED              ║"
        print_color "$RED" "╚════════════════════════════════════╝"
        
        echo ""
        print_color "$RED" "Failed Tests:"
        for result in "${TEST_RESULTS[@]}"; do
            if [[ $result == FAIL:* ]]; then
                echo "  - ${result#FAIL: }"
            fi
        done
        
        return 1
    fi
}

# Print usage
usage() {
    cat << EOF
Usage: $0 [IMAGE_NAME] [OPTIONS]

Test Docker image functionality, performance, and security

ARGUMENTS:
    IMAGE_NAME              Docker image to test (default: multi-stage-app:latest)

OPTIONS:
    --port PORT            Container port (default: 5000)
    --host-port PORT       Host port for testing (default: 5050)
    --timeout SECONDS      Timeout for tests (default: 30)
    -h, --help            Show this help message

ENVIRONMENT VARIABLES:
    TEST_PORT              Override container port
    HOST_PORT              Override host port

EXAMPLES:
    # Test default image
    $0

    # Test specific image
    $0 myapp:v1.0

    # Custom ports
    $0 myapp:latest --port 8080 --host-port 8090

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            TEST_PORT="$2"
            shift 2
            ;;
        --host-port)
            HOST_PORT="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
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
    print_color "$CYAN" "║     Docker Image Test Suite             ║"
    print_color "$CYAN" "╚══════════════════════════════════════════╝"
    
    echo ""
    print_color "$BLUE" "Testing image: $IMAGE_NAME"
    print_color "$BLUE" "Host port: $HOST_PORT"
    print_color "$BLUE" "Container port: $TEST_PORT"
    
    # Run test suites
    test_image_exists
    test_image_metadata
    start_container
    test_container_health
    test_http_endpoints
    test_application_logic
    test_performance
    test_container_logs
    test_networking
    test_graceful_shutdown
    
    # Generate summary
    generate_test_report
    
    # Return exit code based on test results
    if [ $TESTS_FAILED -eq 0 ]; then
        exit 0
    else
        exit 1
    fi
}

# Run main function
main
