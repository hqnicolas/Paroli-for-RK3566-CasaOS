#!/bin/sh
set -eu

expected_driver="${EXPECTED_RKNPU_DRIVER:-0.9.8}"
failed=0

pass() {
    printf 'PASS: %s\n' "$1"
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failed=1
}

if [ "$(uname -m)" = "aarch64" ]; then
    pass "host architecture is aarch64"
else
    fail "host architecture must be aarch64 (found $(uname -m))"
fi

if command -v docker >/dev/null 2>&1; then
    pass "Docker is installed"
    if docker compose version >/dev/null 2>&1; then
        pass "Docker Compose v2 is available"
    else
        fail "Docker Compose v2 is unavailable"
    fi
else
    fail "Docker is not installed"
fi

if [ -d /dev/dri ]; then
    pass "DRM device directory exists"
else
    fail "/dev/dri does not exist"
fi

render_node=""
for node in /dev/dri/renderD*; do
    [ -e "$node" ] || continue
    if [ "$(stat -c '%t' "$node" 2>/dev/null || true)" = "e2" ]; then
        render_node="$node"
        break
    fi
done

if [ -n "$render_node" ]; then
    pass "DRM render node uses device major 226 ($render_node)"
else
    fail "no /dev/dri/renderD* character device with DRM major 226 was found"
fi

cma_total_kb=$(awk '/^CmaTotal:/ {print $2}' /proc/meminfo)
cma_free_kb=$(awk '/^CmaFree:/ {print $2}' /proc/meminfo)
cma_total_kb=${cma_total_kb:-0}
cma_free_kb=${cma_free_kb:-0}

if [ "$cma_total_kb" -gt 0 ]; then
    pass "CMA is enabled (${cma_total_kb} KiB total, ${cma_free_kb} KiB free)"
else
    fail "no CMA reservation was reported by /proc/meminfo"
fi

if dmesg >/dev/null 2>&1; then
    pass "kernel log is readable"
else
    fail "dmesg is not readable; run this rollout as root so NPU failures cannot be missed"
fi

driver_version=""
driver_source=""
if [ -r /sys/module/rknpu/version ]; then
    driver_version=$(tr -d '[:space:]' < /sys/module/rknpu/version)
    driver_source="/sys/module/rknpu/version"
elif command -v modinfo >/dev/null 2>&1; then
    driver_version=$(modinfo -F version rknpu 2>/dev/null | head -n 1 || true)
    if [ -n "$driver_version" ]; then
        driver_source="modinfo"
    fi
fi

if [ -z "$driver_version" ] && dmesg >/dev/null 2>&1; then
    driver_version=$(dmesg 2>/dev/null \
        | sed -n 's/.*Initialized rknpu \([0-9][0-9.]*\).*/\1/p' \
        | tail -n 1)
    if [ -n "$driver_version" ]; then
        driver_source="dmesg"
    fi
fi

if [ "$driver_version" = "$expected_driver" ]; then
    pass "RKNPU driver is ${expected_driver} (${driver_source})"
elif [ -z "$driver_version" ]; then
    fail "could not determine the loaded RKNPU driver version; expected ${expected_driver}"
else
    fail "RKNPU driver is ${driver_version}; expected ${expected_driver}"
fi

printf '\nDRM nodes:\n'
ls -l /dev/dri 2>/dev/null || true

printf '\nRecent RKNPU messages (baseline information only):\n'
dmesg 2>/dev/null \
    | grep -i -E 'rknpu|npu.*(version|timeout|reset|fail)' \
    | tail -n 20 || true

if [ "$failed" -ne 0 ]; then
    exit 1
fi
