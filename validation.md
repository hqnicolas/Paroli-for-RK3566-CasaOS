# Validation Policy, CasaOS Promotion, and Diagnostics

This document explains the quality gates enforced by the automated rollout system, how to promote and import Paroli into CasaOS, and step-by-step diagnostic procedures for isolating failures.

---

## 1. Validation Policy & Automated Quality Gates

Running neural network models on embedded Rockchip NPUs requires strict operational validation. Out-of-tree drivers, contiguous memory allocation (CMA), and fixed-shape NPU decoders can fail silently or cause kernel soft-resets under memory pressure.

The staged rollout script ([`scripts/rollout.sh`](scripts/rollout.sh)) and the smoke test runner ([`scripts/smoke-test.sh`](scripts/smoke-test.sh)) enforce the following automated gates:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Automated Rollout Gates                         │
├────────────────────────────────┬───────────────────────────────────────┤
│ 1. Response Integrity         │ HTTP 200 + OggS header signature      │
│ 2. Dynamic Model Loading       │ Seamless switch: Serena & Riccardo    │
│ 3. Kernel Stability            │ Zero new NPU errors in dmesg          │
│ 4. CMA Headroom                │ ≥ 256 MiB CmaFree after warm-up       │
│ 5. CMA Leak Prevention         │ ≤ 64 MiB CmaFree drop over 20 runs    │
│ 6. Post-Shutdown Recovery      │ CmaFree recovers within 64 MiB        │
│ 7. Container Re-creation       │ Service self-heals after cold restart │
│ 8. Post-Reboot Persistence     │ Container auto-starts with zero faults│
└────────────────────────────────┴───────────────────────────────────────┘
```

### Detailed Gate Explanations

1. **Response Integrity**:
   Every synthesis request is inspected at the binary level. The output file must not only return HTTP status 200, but its first four bytes must match the Ogg container magic signature: `OggS`.
2. **Multi-Model Dynamic Loading**:
   Sequential synthesis tests request different voices (`it_it_serena` at 22,050 Hz and `it_it_riccardo` at 16,000 Hz) to verify that loading a new voice into the NPU context succeeds without crashing the runtime or exhausting memory buffers.
3. **Kernel Error Monitoring**:
   Before Paroli starts, `scripts/rollout.sh prepare` counts any existing NPU errors in `dmesg`. During all subsequent stages, the script asserts that **zero new NPU error lines** appear (matching patterns for `timeout`, `soft reset`, `failed to wait`, `failed to submit`, or `allocation fail`).
4. **CMA Headroom & Leak Detection**:
   The RK3566 NPU uses non-IOMMU contiguous memory allocations. The test suite measures `/proc/meminfo` before and after warm-up and across 20 continuous synthesis requests:
   - At least **256 MiB** of `CmaFree` must remain free after initial warm-up.
   - The drop in `CmaFree` across the 20-request test suite must not exceed **64 MiB**.
5. **CMA Recovery on Container Shutdown**:
   When `validate` stops the container, the host kernel must reclaim the CMA buffers. The script asserts that post-shutdown `CmaFree` recovers to within **64 MiB** of the container-free baseline.
6. **Container Restart Resilience**:
   The container is stopped and recreated with `docker compose up -d --force-recreate` to ensure clean recovery from a cold state.
7. **Post-Reboot Verification**:
   After promotion and a full host reboot (`sudo ./scripts/rollout.sh post-reboot`), the script verifies that:
   - Docker automatically brought up the container.
   - The clean boot kernel log contains **zero** NPU faults.
   - End-to-end synthesis succeeds immediately.

### External Network Observation

The final validation gate is external: make one HTTP request to `http://DEVICE_IP:8848/api/v1/synthesise` from another machine on your local network. A script running locally on the device cannot prove external LAN reachability.

---

## 2. CasaOS Promotion and Integration

During initial deployment and validation, the container restart policy is strictly locked to `no` (`PAROLI_RESTART_POLICY=no`). This prevents broken containers from entering rapid crash-restart loops that can hang the NPU hardware.

### How Promotion Works

When you run:
```bash
sudo ./scripts/rollout.sh promote
```

The script:
1. Verifies that the current git commit matches the validated commit record in `/DATA/AppData/paroli/data/rollout-validation.env`.
2. Applies the production override [`docker-compose.production.yml`](docker-compose.production.yml) to set:
   ```yaml
   services:
     paroli-rknn:
       restart: unless-stopped
   ```
3. Recreates the container and verifies that Docker reports restart policy `unless-stopped`.
4. Emits a fully resolved, standalone Compose file for CasaOS:
   ```text
   /DATA/AppData/paroli/data/casaos-compose.yml
   ```
5. Saves promotion metadata to `/DATA/AppData/paroli/data/rollout-promoted.env`.

### Importing into CasaOS

To integrate Paroli into the CasaOS dashboard:

1. Open your CasaOS web interface (`http://DEVICE_IP`).
2. Navigate to **App Store** and click the **Custom Install** button (the `+` icon in the upper right corner).
3. In the top-right corner of the custom install modal, click **Import**.
4. Open or copy the generated file:
   ```bash
   cat /DATA/AppData/paroli/data/casaos-compose.yml
   ```
5. Paste the Compose YAML into the import box and click **Submit**.
6. CasaOS will automatically populate the settings:
   - **App Name**: Paroli TTS
   - **Web UI Port**: `8848`
   - **Volumes**: `/DATA/AppData/paroli/models` and `/DATA/AppData/paroli/data`
   - **Devices**: `/dev/dri`
7. Click **Install**. CasaOS will attach to the existing running container without rebuilding.

### Security and Isolation Details

- **Non-Privileged**: The container deliberately does **not** use `privileged: true` or `ipc: host`.
- **Cgroup Rules**: Hardware access is granted strictly through `device_cgroup_rules: ["c 226:* rmw"]`, limiting access to DRM character devices (major 226).
- **Network Boundary**: The service binds to port 8848 without built-in authentication. Keep it on a trusted private LAN.

---

## 3. Failure Isolation and Diagnostics

If HTTP synthesis fails or the service becomes unresponsive, do **not** restart the service repeatedly. Follow this systematic diagnostic workflow:

### Step 3.1: Run Direct Hardware Diagnostics

Run the built-in diagnostic tool:

```bash
sudo ./scripts/rollout.sh diagnose
```

What this command does:
1. Stops the web server container to prevent concurrent access to the NPU.
2. Invokes the native CLI binary (`paroli-cli`) directly inside the container without any HTTP server or web framework:
   ```bash
   paroli-cli \
     --encoder /models/en/encoder-en.onnx \
     --decoder /models/en/decoder-en-3566.rknn \
     --config /models/en/config-en.json \
     --espeak-data /opt/paroli/build/espeak-ng-data \
     --output-file /data/paroli-cli-diagnostic.wav
   ```
3. Checks if the output file starts with the WAV `RIFF` header.
4. Logs CMA memory consumption before and after the direct CLI run.

### Step 3.2: Interpreting Diagnostic Results

#### Scenario A: Direct CLI Inference Passes (`PASS: direct CLI inference produced ...`)
- **Conclusion**: The NPU hardware, RKNPU kernel driver (0.9.8), RKNN runtime (2.3.0), and model weights are functioning correctly.
- **Problem Area**: The issue is in the HTTP REST server layer, network port conflicts, JSON payload format, or client request timeout.
- **Action**:
  - Inspect server logs:
    ```bash
    docker compose logs --tail=100 paroli-rknn
    ```
  - Check if port 8848 is in use by another process:
    ```bash
    sudo ss -tulpn | grep 8848
    ```

#### Scenario B: Direct CLI Inference Fails (`FAIL: direct CLI inference failed`)
- **Conclusion**: The issue is at the kernel, driver, or hardware NPU level.
- The diagnostic script automatically captures failure information to:
  - `/DATA/AppData/paroli/data/paroli-cli-failure-dmesg.log`
  - `/DATA/AppData/paroli/data/paroli-server-failure.log`

### Common Failure Modes & Solutions

#### 1. NPU Hardware Timeout (6-Second Hang)
- **Symptom**: Kernel log shows `rknpu: timeout` or `soft reset`.
- **Cause**: The RK3566 NPU core entered an unrecoverable state (often due to concurrent model access, interrupted transactions, or CMA exhaustion).
- **Resolution**:
  - Keep the container stopped.
  - **Reboot the host**:
    ```bash
    sudo reboot
    ```
  - Do not attempt further NPU inference until the host is cleanly rebooted.

#### 2. Driver and Runtime Version Incompatibility
- **Symptom**: Logs show `librknnrt version: 2.3.0` but driver fails initialization or returns error `-1`.
- **Cause**: Mismatch between the out-of-tree RKNPU kernel module and `librknnrt`.
- **Resolution**:
  - Confirm the loaded driver is `0.9.8`:
    ```bash
    cat /sys/module/rknpu/version
    ```
  - If using a kernel that requires driver `0.8.x`, you must rebuild the model and runtime with RKNN Toolkit2 1.6.0. **Never mix a 2.3.0 compiled RKNN model with a 1.6.0 runtime.**

#### 3. CMA Out of Memory / Fragmentation
- **Symptom**: `dmesg` reports `cma_alloc failed` or `allocation fail`.
- **Cause**: The 1 GiB CMA reservation was omitted or exhausted by other video/DRM hardware allocations.
- **Resolution**:
  - Check current CMA status:
    ```bash
    grep -E '^Cma(Total|Free):' /proc/meminfo
    ```
  - Ensure `/boot/armbianEnv.txt` has `extraargs=cma=1G` and reboot.

#### 4. Shared Library (`ldd`) Missing Dependencies
- **Symptom**: Container exits immediately on launch with code 127.
- **Resolution**:
  - Review the ldd report generated during `prepare`:
    ```bash
    cat /DATA/AppData/paroli/data/rollout-ldd.log
    ```
  - Any lines reporting `not found` indicate a missing shared library in the Docker build stage.

---

## Diagnostic Artifacts Summary

All operational logs and verification files are stored in `/DATA/AppData/paroli/data/`:

| File | Purpose |
| :--- | :--- |
| `rollout-baseline.env` | Container-free baseline of CMA and kernel error counters |
| `rollout-baseline.log` | Detailed memory, DRM device, and kernel dmesg snapshot |
| `rollout-ldd.log` | Shared library dependency report for `paroli-server` & `paroli-cli` |
| `rollout-validation.env` | Metrics and commit hash recorded during validation |
| `rollout-promoted.env` | Timestamp and commit hash of production promotion |
| `rollout-post-reboot.env` | Final post-reboot certification |
| `casaos-compose.yml` | Resolved Compose specification for CasaOS import |
| `paroli-cli-diagnostic.wav` | Audio generated during standalone hardware diagnostics |
| `paroli-cli-failure-dmesg.log`| Kernel logs captured during diagnostic failure |
