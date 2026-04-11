#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH="notchi/notchi.xcodeproj"
SCHEME="notchi"
DESTINATION="platform=macOS"

BUILD_ROOT="build/test"
DERIVED_DATA_PATH="${BUILD_ROOT}/DerivedData"
RESULT_BUNDLE_PATH="${BUILD_ROOT}/TestResults.xcresult"
LOG_PATH="${BUILD_ROOT}/test.log"
ATTEMPT1_LOG_PATH="${BUILD_ROOT}/test-attempt-1.log"
ATTEMPT2_LOG_PATH="${BUILD_ROOT}/test-attempt-2.log"

usage() {
    cat <<'EOF'
Usage: ./scripts/test.sh [focused|all]

Presets:
  focused   Run the most frequently touched suites (default)
  all       Run the full test suite
EOF
}

preset="${1:-focused}"
case "$preset" in
    focused|all)
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac

mkdir -p "$BUILD_ROOT"

TEST_ARGS=()
if [[ "$preset" == "focused" ]]; then
    TEST_ARGS=(
        "-only-testing:Tests/ClaudeUsageServiceTests"
        "-only-testing:Tests/KeychainManagerTests"
        "-only-testing:Tests/NotchPanelManagerTests"
        "-only-testing:Tests/UsageBarViewTests"
    )
fi

CI_ARGS=()
if [[ -n "${CI:-}" ]]; then
    CI_ARGS=(
        "CODE_SIGNING_ALLOWED=NO"
        "CODE_SIGNING_REQUIRED=NO"
    )
fi

should_retry_for_known_xcode_junk() {
    local log_file="$1"

    grep -qE \
        'code object is not signed at all|LLDB RPC server has crashed|The debug session ended unexpectedly|Failed to initialize logging system due to time out' \
        "$log_file"
}

run_attempt() {
    local attempt="$1"
    local attempt_log="$2"
    local resolve_cmd=(
        xcodebuild
        -resolvePackageDependencies
        -project "$PROJECT_PATH"
        -scheme "$SCHEME"
    )
    local test_cmd=(
        xcodebuild
        test
        -project "$PROJECT_PATH"
        -scheme "$SCHEME"
        -destination "$DESTINATION"
        -derivedDataPath "$DERIVED_DATA_PATH"
        -resultBundlePath "$RESULT_BUNDLE_PATH"
    )

    rm -rf "$RESULT_BUNDLE_PATH"

    if [[ ${#TEST_ARGS[@]} -gt 0 ]]; then
        test_cmd+=("${TEST_ARGS[@]}")
    fi

    if [[ ${#CI_ARGS[@]} -gt 0 ]]; then
        test_cmd+=("${CI_ARGS[@]}")
    fi

    (
        set -euo pipefail
        echo "===> Attempt ${attempt}: resolve packages"
        "${resolve_cmd[@]}"

        echo ""
        echo "===> Attempt ${attempt}: test (${preset})"
        "${test_cmd[@]}"
    ) 2>&1 | tee "$attempt_log"

    local statuses=("${PIPESTATUS[@]}")
    return "${statuses[0]}"
}

rm -f "$LOG_PATH" "$ATTEMPT1_LOG_PATH" "$ATTEMPT2_LOG_PATH"

if run_attempt 1 "$ATTEMPT1_LOG_PATH"; then
    cp "$ATTEMPT1_LOG_PATH" "$LOG_PATH"
    exit 0
fi

cp "$ATTEMPT1_LOG_PATH" "$LOG_PATH"

if ! should_retry_for_known_xcode_junk "$ATTEMPT1_LOG_PATH"; then
    echo ""
    echo "Not retrying: first failure does not match known Xcode/toolchain junk signatures." | tee -a "$LOG_PATH"
    exit 1
fi

echo "" | tee -a "$LOG_PATH"
echo "Known Xcode/toolchain junk detected. Deleting ${DERIVED_DATA_PATH} and retrying once." | tee -a "$LOG_PATH"
rm -rf "$DERIVED_DATA_PATH"

if run_attempt 2 "$ATTEMPT2_LOG_PATH"; then
    {
        cat "$ATTEMPT1_LOG_PATH"
        echo ""
        echo "===== RETRY AFTER DERIVED DATA RESET ====="
        echo ""
        cat "$ATTEMPT2_LOG_PATH"
    } > "$LOG_PATH"
    exit 0
fi

{
    cat "$ATTEMPT1_LOG_PATH"
    echo ""
    echo "===== RETRY AFTER DERIVED DATA RESET ====="
    echo ""
    cat "$ATTEMPT2_LOG_PATH"
} > "$LOG_PATH"

echo ""
echo "Retry failed. See ${LOG_PATH} and ${RESULT_BUNDLE_PATH} for details."
exit 1
