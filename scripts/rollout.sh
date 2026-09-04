#!/bin/sh
set -eu

project_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"

model_dir="${PAROLI_MODEL_HOST_DIR:-/DATA/AppData/paroli/models}"
data_dir="${PAROLI_DATA_HOST_DIR:-/DATA/AppData/paroli/data}"
baseline_file="${data_dir}/rollout-baseline.env"
baseline_log="${data_dir}/rollout-baseline.log"
validation_file="${data_dir}/rollout-validation.env"
promotion_file="${data_dir}/rollout-promoted.env"
final_file="${data_dir}/rollout-post-reboot.env"
container_name="paroli-rknn"
old_container_name="sherpa-onnx-rknn"
maximum_recovery_drop_kb="${MAXIMUM_CMA_RECOVERY_DROP_KB:-65536}"

read_cma_free() {
    awk '/^CmaFree:/ {print $2; exit}' /proc/meminfo
}

count_npu_errors() {
    dmesg 2>/dev/null \
        | grep -i -E '((rknpu|npu).*(timeout|soft reset|failed to wait|failed to submit|allocation.*fail|alloc.*fail))|((timeout|soft reset|failed to wait|failed to submit|allocation.*fail|alloc.*fail).*(rknpu|npu))' \
        | awk 'END {print NR + 0}'
}

current_commit() {
    git rev-parse HEAD 2>/dev/null || printf 'unknown\n'
}

read_record_value() {
    key="$1"
    record="$2"
    awk -F= -v wanted="$key" '$1 == wanted {print $2; exit}' "$record"
}

wait_for_health() {
    attempts=0
    while [ "$attempts" -lt 120 ]; do
        status=$(docker inspect \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
            "$container_name" 2>/dev/null || true)
        case "$status" in
            healthy)
                echo "PASS: ${container_name} is healthy"
                return 0
                ;;
            unhealthy|exited|dead|restarting)
                echo "FAIL: ${container_name} entered state ${status}" >&2
                docker compose logs --no-color paroli-rknn >&2 || true
                docker stop "$container_name" >/dev/null 2>&1 || true
                return 1
                ;;
        esac
        attempts=$((attempts + 1))
        sleep 2
    done

    echo "FAIL: ${container_name} did not become healthy within 240 seconds" >&2
    docker compose logs --no-color paroli-rknn >&2 || true
    return 1
}

require_log_pattern() {
    label="$1"
    pattern="$2"
    logs="$3"
    if printf '%s\n' "$logs" | grep -i -E "$pattern" >/dev/null; then
        printf 'PASS: %s\n' "$label"
    else
        printf 'FAIL: %s was not found in container logs\n' "$label" >&2
        return 1
    fi
}

verify_version_contract() {
    logs=$(docker compose logs --no-color paroli-rknn 2>&1)
    require_log_pattern "RKNN runtime 2.3.0" 'Runtime Information.*librknnrt version: 2\.3\.0' "$logs"
    require_log_pattern "RKNPU driver 0.9.8" 'Driver Information.*version: 0\.9\.8' "$logs"
    require_log_pattern "RKNN compiler/toolkit 2.3.0" 'Model Information.*toolkit version: 2\.3\.0' "$logs"
    require_log_pattern "RK3566 model target" 'target platform: rk3566' "$logs"
}

verify_no_new_npu_errors_since_baseline() {
    baseline_errors=$(read_record_value NPU_ERROR_BASELINE "$baseline_file")
    current_errors=$(count_npu_errors)
    if [ "$current_errors" -gt "$baseline_errors" ]; then
        echo "FAIL: RKNPU errors were added after the container-free baseline" >&2
        dmesg 2>/dev/null \
            | grep -i -E '((rknpu|npu).*(timeout|soft reset|failed to wait|failed to submit|allocation.*fail|alloc.*fail))|((timeout|soft reset|failed to wait|failed to submit|allocation.*fail|alloc.*fail).*(rknpu|npu))' \
            | tail -n 20 >&2 || true
        return 1
    fi
    echo "PASS: no RKNPU failure was added after the container-free baseline"
}

record_baseline() {
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    cma_total_kb=$(awk '/^CmaTotal:/ {print $2; exit}' /proc/meminfo)
    cma_free_kb=$(read_cma_free)
    npu_error_baseline=$(count_npu_errors)
    driver_version="unknown"
    if [ -r /sys/module/rknpu/version ]; then
        driver_version=$(tr -d '[:space:]' < /sys/module/rknpu/version)
    else
        detected=$(dmesg 2>/dev/null \
            | sed -n 's/.*Initialized rknpu \([0-9][0-9.]*\).*/\1/p' \
            | tail -n 1)
        if [ -n "$detected" ]; then
            driver_version="$detected"
        fi
    fi

    {
        printf 'BASELINE_UTC=%s\n' "$timestamp"
        printf 'BASELINE_COMMIT=%s\n' "$(current_commit)"
        printf 'CMA_TOTAL_KB=%s\n' "$cma_total_kb"
        printf 'CMA_BASELINE_KB=%s\n' "$cma_free_kb"
        printf 'NPU_ERROR_BASELINE=%s\n' "$npu_error_baseline"
        printf 'RKNPU_DRIVER_VERSION=%s\n' "$driver_version"
    } > "$baseline_file"

    {
        printf 'Baseline UTC: %s\n' "$timestamp"
        printf 'Repository commit: %s\n' "$(current_commit)"
        printf 'Kernel: '
        uname -a
        printf '\nMemory:\n'
        grep -E '^Cma(Total|Free):' /proc/meminfo
        printf '\nDRM devices:\n'
        ls -l /dev/dri
        printf '\nRKNPU kernel messages before Paroli startup:\n'
        dmesg 2>/dev/null | grep -i -E 'rknpu|npu|cma' | tail -n 200 || true
    } > "$baseline_log"

    printf 'Baseline record: %s\n' "$baseline_file"
    printf 'Baseline log:    %s\n' "$baseline_log"
}

prepare() {
    mkdir -p "$model_dir" "$data_dir"

    if docker ps --format '{{.Names}}' | grep -x "$old_container_name" >/dev/null 2>&1; then
        echo "Stopping the old sherpa container so it cannot compete for RKNPU/CMA."
        docker stop "$old_container_name"
        echo "Its /DATA/AppData/sherpa-onnx data and stopped container are preserved."
    fi

    PAROLI_RESTART_POLICY=no docker compose down
    "$project_dir/scripts/preflight.sh"
    record_baseline

    PAROLI_RESTART_POLICY=no docker compose build

    dependency_report=$(PAROLI_RESTART_POLICY=no docker compose run --rm --no-deps \
        --entrypoint /bin/sh paroli-rknn \
        -c 'ldd /opt/paroli/build/paroli-server; ldd /opt/paroli/build/paroli-cli')
    printf '%s\n' "$dependency_report" | tee "${data_dir}/rollout-ldd.log"

    if printf '%s\n' "$dependency_report" | grep 'not found' >/dev/null; then
        echo "FAIL: ldd reported a missing runtime dependency" >&2
        exit 1
    fi
    echo "PASS: preparation, baseline capture, native build, and ldd inspection completed"
}

start_validation_service() {
    if [ ! -f "$baseline_file" ]; then
        echo "FAIL: missing ${baseline_file}; run '$0 prepare' first" >&2
        exit 1
    fi

    PAROLI_RESTART_POLICY=no docker compose up -d --force-recreate
    wait_for_health
    verify_version_contract
    verify_no_new_npu_errors_since_baseline
    printf 'CmaFree after model load: %s KiB\n' "$(read_cma_free)"
    echo "PASS: service is running with restart policy disabled"
}

validate() {
    if [ ! -f "$baseline_file" ]; then
        echo "FAIL: missing ${baseline_file}; run '$0 prepare' first" >&2
        exit 1
    fi

    wait_for_health
    verify_version_contract
    verify_no_new_npu_errors_since_baseline
    "$project_dir/scripts/smoke-test.sh"

    PAROLI_RESTART_POLICY=no docker compose stop paroli-rknn
    sleep 5

    baseline_cma=$(read_record_value CMA_BASELINE_KB "$baseline_file")
    recovered_cma=$(read_cma_free)
    recovery_drop_kb=$((baseline_cma - recovered_cma))
    if [ "$recovery_drop_kb" -lt 0 ]; then
        recovery_drop_kb=0
    fi
    if [ "$recovery_drop_kb" -gt "$maximum_recovery_drop_kb" ]; then
        echo "FAIL: after shutdown CmaFree remains ${recovery_drop_kb} KiB below baseline; maximum is ${maximum_recovery_drop_kb} KiB" >&2
        exit 1
    fi
    printf 'PASS: shutdown CmaFree is within %s KiB of baseline\n' "$maximum_recovery_drop_kb"

    PAROLI_RESTART_POLICY=no docker compose up -d --force-recreate
    wait_for_health
    verify_version_contract
    verify_no_new_npu_errors_since_baseline
    REQUEST_COUNT=1 RUN_LONG_TEXT=false \
        OUTPUT_FILE="${data_dir}/restart-test.opus" \
        RESULT_FILE="${data_dir}/restart-test.env" \
        "$project_dir/scripts/smoke-test.sh"

    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    {
        printf 'VALIDATED_UTC=%s\n' "$timestamp"
        printf 'VALIDATED_COMMIT=%s\n' "$(current_commit)"
        printf 'CMA_BASELINE_KB=%s\n' "$baseline_cma"
        printf 'CMA_AFTER_STOP_KB=%s\n' "$recovered_cma"
        printf 'CMA_RECOVERY_DROP_KB=%s\n' "$recovery_drop_kb"
    } > "$validation_file"
    printf 'PASS: functional, kernel-log, CMA recovery, and container-restart gates passed\n'
    printf 'Validation record: %s\n' "$validation_file"
    echo "Automatic restart is still disabled. Run '$0 promote' only after reviewing the records."
}

promote() {
    if [ ! -f "$validation_file" ]; then
        echo "FAIL: missing ${validation_file}; run '$0 validate' first" >&2
        exit 1
    fi

    validated_commit=$(read_record_value VALIDATED_COMMIT "$validation_file")
    active_commit=$(current_commit)
    if [ "$validated_commit" != "$active_commit" ]; then
        echo "FAIL: validation was for commit ${validated_commit}, but the checkout is ${active_commit}" >&2
        exit 1
    fi

    docker compose -f docker-compose.yml -f docker-compose.production.yml \
        up -d --force-recreate
    wait_for_health
    verify_version_contract
    verify_no_new_npu_errors_since_baseline

    restart_policy=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$container_name")
    if [ "$restart_policy" != "unless-stopped" ]; then
        echo "FAIL: container restart policy is ${restart_policy}, expected unless-stopped" >&2
        exit 1
    fi

    docker compose -f docker-compose.yml -f docker-compose.production.yml config \
        > "${data_dir}/casaos-compose.yml"

    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    {
        printf 'PROMOTED_UTC=%s\n' "$timestamp"
        printf 'PROMOTED_COMMIT=%s\n' "$active_commit"
        printf 'RESTART_POLICY=unless-stopped\n'
    } > "$promotion_file"

    echo "PASS: production restart policy is unless-stopped"
    printf 'CasaOS import file: %s\n' "${data_dir}/casaos-compose.yml"
    echo "Reboot the host, then run '$0 post-reboot'."
}

post_reboot() {
    if [ ! -f "$promotion_file" ]; then
        echo "FAIL: missing ${promotion_file}; run '$0 promote' before reboot" >&2
        exit 1
    fi

    wait_for_health
    verify_version_contract
    boot_npu_errors=$(count_npu_errors)
    if [ "$boot_npu_errors" -ne 0 ]; then
        echo "FAIL: the current boot already contains ${boot_npu_errors} RKNPU failure message(s)" >&2
        return 1
    fi
    echo "PASS: current boot contains no RKNPU failure messages"
    restart_policy=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$container_name")
    if [ "$restart_policy" != "unless-stopped" ]; then
        echo "FAIL: post-reboot restart policy is ${restart_policy}" >&2
        exit 1
    fi

    REQUEST_COUNT=1 RUN_LONG_TEXT=false \
        OUTPUT_FILE="${data_dir}/post-reboot-test.opus" \
        RESULT_FILE="${data_dir}/post-reboot-test.env" \
        "$project_dir/scripts/smoke-test.sh"

    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    {
        printf 'POST_REBOOT_VERIFIED_UTC=%s\n' "$timestamp"
        printf 'POST_REBOOT_COMMIT=%s\n' "$(current_commit)"
    } > "$final_file"
    echo "PASS: Docker restored a healthy service after host reboot"
    echo "Complete the final trusted-LAN curl test from another machine."
}

diagnose() {
    mkdir -p "$data_dir"
    PAROLI_RESTART_POLICY=no docker compose stop paroli-rknn || true

    before=$(read_cma_free)
    if printf '%s\n' 'Paroli command line diagnostic on the RK3566 NPU.' \
        | PAROLI_RESTART_POLICY=no docker compose run --rm --no-deps \
            --entrypoint /opt/paroli/build/paroli-cli paroli-rknn \
            --encoder /models/en/encoder-en.onnx \
            --decoder /models/en/decoder-en-3566.rknn \
            --config /models/en/config-en.json \
            --espeak-data /opt/paroli/build/espeak-ng-data \
            --output-file /data/paroli-cli-diagnostic.wav; then
        magic=$(dd if="${data_dir}/paroli-cli-diagnostic.wav" bs=4 count=1 2>/dev/null)
        if [ "$magic" != "RIFF" ]; then
            echo "FAIL: paroli-cli did not create a WAV file beginning with RIFF" >&2
            exit 1
        fi
        printf 'PASS: direct CLI inference produced %s\n' "${data_dir}/paroli-cli-diagnostic.wav"
    else
        echo "FAIL: direct CLI inference failed; the server remains stopped" >&2
        dmesg 2>/dev/null | grep -i -E 'rknpu|npu|cma' | tail -n 100 \
            > "${data_dir}/paroli-cli-failure-dmesg.log" || true
        docker compose logs --no-color paroli-rknn \
            > "${data_dir}/paroli-server-failure.log" 2>&1 || true
        echo "If this was another six-second timeout, reboot before any further NPU test." >&2
        exit 1
    fi
    printf 'CmaFree before CLI: %s KiB\n' "$before"
    printf 'CmaFree after CLI:  %s KiB\n' "$(read_cma_free)"
}

status() {
    docker compose ps || true
    printf 'CmaFree: %s KiB\n' "$(read_cma_free)"
    if docker inspect "$container_name" >/dev/null 2>&1; then
        docker inspect \
            --format 'status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restart={{.HostConfig.RestartPolicy.Name}}' \
            "$container_name"
    fi
    dmesg 2>/dev/null | grep -i -E 'rknpu|npu|cma' | tail -n 30 || true
}

usage() {
    cat <<EOF
Usage: $0 prepare|start|validate|promote|post-reboot|diagnose|status

  prepare      stop competing TTS/ASR use, preflight, baseline, build, and ldd
  start        start Paroli with restart policy disabled and verify versions
  validate     run all request/CMA gates, stop/recover, restart, and retest
  promote      recreate with unless-stopped and emit resolved CasaOS Compose
  post-reboot  verify Docker restart, versions, one request, CMA, and dmesg
  diagnose     stop the server and run the same voice directly with paroli-cli
  status       show service, restart policy, CMA, and recent NPU messages
EOF
}

case "${1:-}" in
    prepare) prepare ;;
    start) start_validation_service ;;
    validate) validate ;;
    promote) promote ;;
    post-reboot) post_reboot ;;
    diagnose) diagnose ;;
    status) status ;;
    *) usage; exit 2 ;;
esac
