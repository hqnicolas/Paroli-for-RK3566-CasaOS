#!/bin/sh
set -eu

server_url="${PAROLI_URL:-http://127.0.0.1:8848}"
request_count="${REQUEST_COUNT:-20}"
output_file="${OUTPUT_FILE:-/DATA/AppData/paroli/data/smoke-test.opus}"
result_file="${RESULT_FILE:-/DATA/AppData/paroli/data/smoke-test-last.env}"
test_text="${TEST_TEXT:-Hello from the RK3566 text to speech server.}"
test_language="${TEST_LANGUAGE:-}"
run_long_text="${RUN_LONG_TEXT:-true}"
minimum_cma_kb="${MINIMUM_CMA_KB:-262144}"
maximum_cma_drop_kb="${MAXIMUM_CMA_DROP_KB:-65536}"

case "$request_count" in
    ''|*[!0-9]*)
        echo "FAIL: REQUEST_COUNT must be a positive integer" >&2
        exit 1
        ;;
    0)
        echo "FAIL: REQUEST_COUNT must be greater than zero" >&2
        exit 1
        ;;
esac

mkdir -p "$(dirname "$output_file")" "$(dirname "$result_file")"

if ! dmesg >/dev/null 2>&1; then
    echo "FAIL: dmesg is not readable; run as root so kernel failures are part of the test" >&2
    exit 1
fi

read_cma_free() {
    awk '/^CmaFree:/ {print $2; exit}' /proc/meminfo
}

count_npu_errors() {
    dmesg 2>/dev/null \
        | grep -i -E '((rknpu|npu).*(timeout|soft reset|failed to wait|failed to submit|allocation.*fail|alloc.*fail))|((timeout|soft reset|failed to wait|failed to submit|allocation.*fail|alloc.*fail).*(rknpu|npu))' \
        | awk 'END {print NR + 0}'
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

synthesise() {
    label="$1"
    request_text="$2"
    request_output="$3"
    escaped_text=$(json_escape "$request_text")
    if [ -n "$test_language" ]; then
        escaped_language=$(json_escape "$test_language")
        payload="{\"text\":\"${escaped_text}\",\"language\":\"${escaped_language}\",\"audio_format\":\"opus\"}"
    else
        payload="{\"text\":\"${escaped_text}\",\"audio_format\":\"opus\"}"
    fi

    if [ -n "${PAROLI_TOKEN:-}" ]; then
        http_status=$(curl --fail --silent --show-error \
            --request POST "${server_url}/api/v1/synthesise" \
            --header 'Content-Type: application/json' \
            --header "Authorization: Bearer ${PAROLI_TOKEN}" \
            --data "$payload" \
            --output "$request_output" \
            --write-out '%{http_code}')
    else
        http_status=$(curl --fail --silent --show-error \
            --request POST "${server_url}/api/v1/synthesise" \
            --header 'Content-Type: application/json' \
            --data "$payload" \
            --output "$request_output" \
            --write-out '%{http_code}')
    fi

    if [ "$http_status" != "200" ]; then
        echo "FAIL: ${label} returned HTTP ${http_status}" >&2
        exit 1
    fi

    magic=$(dd if="$request_output" bs=4 count=1 2>/dev/null)
    if [ "$magic" != "OggS" ]; then
        echo "FAIL: ${label} did not return an Ogg stream beginning with OggS" >&2
        exit 1
    fi

    printf 'PASS: %s returned HTTP 200 and OggS\n' "$label"
}

errors_before=$(count_npu_errors)
cma_before=$(read_cma_free)

synthesise "warm-up request" "$test_text" "$output_file"
cma_after_warmup=$(read_cma_free)

if [ "$cma_after_warmup" -lt "$minimum_cma_kb" ]; then
    echo "FAIL: CmaFree after warm-up is ${cma_after_warmup} KiB; require at least ${minimum_cma_kb} KiB" >&2
    exit 1
fi
printf 'PASS: CmaFree after warm-up is %s KiB\n' "$cma_after_warmup"

request_number=1
while [ "$request_number" -le "$request_count" ]; do
    synthesise "sequential request ${request_number}/${request_count}" "$test_text" "$output_file"
    request_number=$((request_number + 1))
done

cma_after_sequence=$(read_cma_free)
cma_drop_kb=$((cma_after_warmup - cma_after_sequence))
if [ "$cma_drop_kb" -lt 0 ]; then
    cma_drop_kb=0
fi

if [ "$cma_after_sequence" -lt "$minimum_cma_kb" ]; then
    echo "FAIL: CmaFree after the request sequence is ${cma_after_sequence} KiB; require at least ${minimum_cma_kb} KiB" >&2
    exit 1
fi

if [ "$cma_drop_kb" -gt "$maximum_cma_drop_kb" ]; then
    echo "FAIL: CmaFree fell ${cma_drop_kb} KiB after warm-up; maximum allowed is ${maximum_cma_drop_kb} KiB" >&2
    exit 1
fi
printf 'PASS: post-warm-up CmaFree drop is %s KiB\n' "$cma_drop_kb"

if [ "$run_long_text" = "true" ]; then
    long_text="This is the long-form acceptance request for the RK3566 Paroli text to speech service. It exercises the complete English synthesis path after the warm-up and sequential request tests. The decoder must continue using one serialized RKNN context, the kernel log must remain free of new timeout, reset, submission, wait, and allocation failures, and the contiguous memory pool must remain stable. This paragraph is intentionally close to five hundred characters so the rollout tests a realistic message instead of only short phrases on the trusted local network."
    synthesise "long English request (${#long_text} characters)" "$long_text" "$output_file"
fi

cma_final=$(read_cma_free)
errors_after=$(count_npu_errors)

if [ "$cma_final" -lt "$minimum_cma_kb" ]; then
    echo "FAIL: final CmaFree is ${cma_final} KiB; require at least ${minimum_cma_kb} KiB" >&2
    exit 1
fi

if [ "$errors_after" -gt "$errors_before" ]; then
    echo "FAIL: the kernel logged a new RKNPU timeout, reset, wait, submission, or allocation failure" >&2
    dmesg 2>/dev/null \
        | grep -i -E '((rknpu|npu).*(timeout|soft reset|failed to wait|failed to submit|allocation.*fail|alloc.*fail))|((timeout|soft reset|failed to wait|failed to submit|allocation.*fail|alloc.*fail).*(rknpu|npu))' \
        | tail -n 20 >&2 || true
    exit 1
fi

timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
{
    printf 'SMOKE_TEST_UTC=%s\n' "$timestamp"
    printf 'REQUEST_COUNT=%s\n' "$request_count"
    printf 'TEST_LANGUAGE=%s\n' "$test_language"
    printf 'CMA_BEFORE_KB=%s\n' "$cma_before"
    printf 'CMA_AFTER_WARMUP_KB=%s\n' "$cma_after_warmup"
    printf 'CMA_AFTER_SEQUENCE_KB=%s\n' "$cma_after_sequence"
    printf 'CMA_FINAL_KB=%s\n' "$cma_final"
    printf 'CMA_POST_WARMUP_DROP_KB=%s\n' "$cma_drop_kb"
    printf 'NPU_ERRORS_BEFORE=%s\n' "$errors_before"
    printf 'NPU_ERRORS_AFTER=%s\n' "$errors_after"
} > "$result_file"

printf 'CmaFree before:         %s KiB\n' "$cma_before"
printf 'CmaFree after warm-up:  %s KiB\n' "$cma_after_warmup"
printf 'CmaFree after sequence: %s KiB\n' "$cma_after_sequence"
printf 'CmaFree final:          %s KiB\n' "$cma_final"
printf 'Audio output:           %s\n' "$output_file"
printf 'Result record:          %s\n' "$result_file"
echo "PASS: synthesis, Ogg framing, CMA stability, and kernel-log gates passed"
