# Deployment and Host Setup Guide

This guide details the complete host preparation and staged deployment process for running the **Paroli RKNN TTS server** on a Rockchip RK3566 board (such as TV boxes or single-board computers) running Armbian and CasaOS.

---

## Hardware and Target Contract

The service operates under the following hardware contract:
- **Architecture**: Linux `aarch64` (ARM64).
- **SoC**: Rockchip RK3566 (single-core NPU, 0.8 TOPS).
- **RKNPU Driver**: Version `0.9.8`.
- **Memory Addressing**: Non-IOMMU operation requiring contiguous physical memory.
- **CMA Reservation**: `1 GiB` (1,048,576 KiB) via kernel boot arguments.
- **Device Access**: Direct DRM character-device node `/dev/dri/renderD*` with major `226`.

---

## Prerequisites

Before starting deployment, ensure the host system meets these prerequisites:

1. **Docker Engine & Docker Compose v2**:
   ```bash
   docker --version
   docker compose version
   ```
2. **Root privileges**: Root access is required for kernel log checking (`dmesg`), boot configuration edits, and DKMS module compilation.
3. **Sufficient System RAM**: Reserving 1 GiB for CMA removes that block from general OS memory. Ensure your device (typically 2 GB, 4 GB, or 8 GB RAM) has sufficient remaining memory for Armbian, Docker, and any existing CasaOS applications.
4. **Preflight verification**:
   You can verify these basic system capabilities by running:
   ```bash
   sudo ./scripts/preflight.sh
   ```

---

## 1. Install the RKNPU Kernel Module on Armbian

The Rockchip RKNN runtime communicates with the NPU through the `/dev/dri` render node provided by the out-of-tree `rknpu` kernel module.

### Step 1.1: Ensure Kernel Headers Match

Armbian must have the Linux headers corresponding exactly to the active kernel before building out-of-tree modules.

If building an Armbian image from source, ensure kernel headers are included using `INSTALL_HEADERS=yes`:

```bash
./compile.sh BOARD=h96-tvbox-3566 BRANCH=edge BUILD_DESKTOP=no BUILD_MINIMAL=no KERNEL_CONFIGURE=yes RELEASE=resolute INSTALL_HEADERS=yes
```

On an already-installed Armbian system, install the corresponding header package:
```bash
sudo apt update
sudo apt install -y linux-headers-$(uname -r)
```

### Step 1.2: Build and Install with DKMS

Install the build dependencies and clone the `rknpu-module` repository:

```bash
sudo apt update
sudo apt install -y build-essential dkms git
git clone https://github.com/w568w/rknpu-module.git
cd rknpu-module
sudo dkms install .
```

### Step 1.3: Verify Driver Installation

Check the DKMS status:

```bash
dkms status
```

Confirm that the output reports `rknpu` with status `installed`:
```text
rknpu/0.9.8, 6.x.x-edge-rockchip64, aarch64: installed
```

Confirm the module is loaded and reports version `0.9.8`:
```bash
cat /sys/module/rknpu/version || dmesg | grep -i "Initialized rknpu"
```

---

## 2. Reserve 1 GiB CMA on Armbian

The RK3566 NPU lacks a dedicated hardware IOMMU and requires physically contiguous memory (Contiguous Memory Allocator - CMA) for model weights and intermediate inference buffers. Standard dynamic allocations will fail without an adequate CMA pool.

### Step 2.1: Check Current CMA Status

Check whether CMA is currently configured and if `/boot/armbianEnv.txt` exists:

```bash
grep '^CmaTotal:' /proc/meminfo
test -f /boot/armbianEnv.txt && echo "armbianEnv.txt found"
grep '^extraargs=' /boot/armbianEnv.txt || true
```

### Step 2.2: Backup and Edit `/boot/armbianEnv.txt`

Armbian designates `/boot/armbianEnv.txt` as the preferred configuration for [kernel boot parameters](https://docs.armbian.com/User-Guide_Advanced-Configuration/).

1. Create a backup copy:
   ```bash
   sudo cp --preserve=all /boot/armbianEnv.txt /boot/armbianEnv.txt.pre-paroli
   ```

2. Open the file for editing:
   ```bash
   sudo nano /boot/armbianEnv.txt
   ```

3. Configure `cma=1G`:
   - If there is no existing `extraargs` line, add:
     ```text
     extraargs=cma=1G
     ```
   - If `extraargs` already exists, append `cma=1G` to the existing line (do **not** add a second `extraargs` line):
     ```text
     extraargs=existing_option=value cma=1G
     ```

4. Save the file and reboot the board:
   ```bash
   sudo reboot
   ```

### Step 2.3: Verify CMA Allocation After Reboot

After the device boots, verify both the kernel command line and the reserved CMA memory:

```bash
grep -o 'cma=[^ ]*' /proc/cmdline
grep '^CmaTotal:' /proc/meminfo
```

The expected output in `/proc/meminfo` is:
```text
CmaTotal:        1048576 kB
```

> [!NOTE]
> **Systems using Extlinux Boot**:
> If `cma=1G` is absent from `/proc/cmdline` after rebooting, your board may boot via `/boot/extlinux/extlinux.conf` rather than Armbian's boot script. In that case, restore `/boot/armbianEnv.txt` and append `cma=1G` to the `APPEND` line of the active entry in `/boot/extlinux/extlinux.conf`. Do not create `armbianEnv.txt` if your system does not already use it.

### Step 2.4: Rollback Procedure

If you ever need to revert the CMA reservation:
```bash
sudo cp /boot/armbianEnv.txt.pre-paroli /boot/armbianEnv.txt
sudo reboot
```

---

## 3. Staged Deployment

The deployment script [`scripts/rollout.sh`](scripts/rollout.sh) executes a strict progression of validation gates. Root is required so kernel logs (`dmesg`) can be monitored for NPU reset or timeout events during deployment.

```
 prepare ──► start ──► validate ──► promote ──► reboot ──► post-reboot
(baseline)   (no-restart) (stress & CMA) (unless-stopped) (persistence test)
```

Run these commands in sequence on the RK3566:

### Step 3.1: Prepare

```bash
sudo ./scripts/rollout.sh prepare
```

What this does:
- Creates required directories: `/DATA/AppData/paroli/models` and `/DATA/AppData/paroli/data`.
- Safely stops any competing TTS/ASR containers (such as legacy `sherpa-onnx-rknn`) so they do not contend for NPU or CMA resources. The existing `/DATA/AppData/sherpa-onnx` directory and container are retained and never modified.
- Runs [`scripts/preflight.sh`](scripts/preflight.sh) to verify driver, architecture, and DRM node.
- Captures a container-free baseline of memory, CMA, and kernel error counters to `/DATA/AppData/paroli/data/rollout-baseline.env`.
- Builds the native container image (`paroli-rknn:rk3566`).
- Inspects binary dependencies using `ldd` inside the image to ensure all runtime shared libraries are resolved.

### Step 3.2: Start

```bash
sudo ./scripts/rollout.sh start
```

What this does:
- Starts the container with `restart: no` (preventing infinite restart loops if a driver fault occurs).
- Waits for health status on `http://127.0.0.1:8848/api/v1/speakers`.
- Verifies the version contract in container logs:
  - RKNN runtime `2.3.0`
  - RKNPU driver `0.9.8`
  - RKNN compiler/toolkit `2.3.0`
  - RK3566 target platform
- Checks that no new NPU errors occurred in `dmesg`.

### Step 3.3: Validate

```bash
sudo ./scripts/rollout.sh validate
```

What this does:
- Runs warm-up and 20 sequential synthesis requests.
- Tests multi-voice switching (e.g. Italian Serena and Riccardo).
- Tests long-text synthesis.
- Measures CMA headroom (verifying at least 256 MiB remains free).
- Stops the container and verifies that CMA memory recovers to within 64 MiB of the baseline (confirming no kernel memory leaks).
- Restarts the container and runs a re-verification synthesis test.
- Writes validation proof to `/DATA/AppData/paroli/data/rollout-validation.env`.

### Step 3.4: Promote

```bash
sudo ./scripts/rollout.sh promote
```

What this does:
- Recreates the container with the production restart policy (`restart: unless-stopped`).
- Generates a standalone, fully resolved Compose file at:
  `/DATA/AppData/paroli/data/casaos-compose.yml`
- Emits promotion records to `/DATA/AppData/paroli/data/rollout-promoted.env`.

### Step 3.5: Host Reboot & Post-Reboot Verification

```bash
sudo reboot
```

After the device comes back online:
```bash
sudo ./scripts/rollout.sh post-reboot
```

What this does:
- Verifies that Docker automatically restarted `paroli-rknn` on boot.
- Confirms zero NPU error messages exist in the clean boot log.
- Executes an end-to-end synthesis test.
- Writes final certification to `/DATA/AppData/paroli/data/rollout-post-reboot.env`.

---

## 4. Operational Monitoring and Status

You can check the current health, container status, free CMA memory, and recent NPU kernel events at any time with:

```bash
sudo ./scripts/rollout.sh status
```

Example status output:
```text
NAME          IMAGE                COMMAND                  SERVICE       CREATED         STATUS                   PORTS
paroli-rknn   paroli-rknn:rk3566   "/opt/paroli/build/p…"   paroli-rknn   3 minutes ago   Up 3 minutes (healthy)   0.0.0.0:8848->8848/tcp
CmaFree: 786432 KiB
status=running health=healthy restart=unless-stopped
```

---

## 5. Container Configuration Reference

The service is defined in [`docker-compose.yml`](docker-compose.yml):

- **Exposed Port**: `${PAROLI_PORT:-8848}:8848` (default: 8848).
- **Environment**:
  - `IP_ADDRESS=0.0.0.0`
  - `PORT=8848`
  - `MODEL_DIR=/models`
- **Volume Mounts**:
  - `/dev/dri:/dev/dri`: Grants access to the GPU/NPU DRM render nodes.
  - `/DATA/AppData/paroli/models:/models`: Storage for downloaded and extracted voice models.
  - `/DATA/AppData/paroli/data:/data`: Storage for diagnostic logs, recordings, and generated configurations.
- **Device Cgroup Rules**:
  - `c 226:* rmw`: Grants character-device permissions for DRM major 226 without requiring `privileged: true`.
- **Healthcheck**: Queries `GET /api/v1/speakers` every 30 seconds.

For CasaOS integration, promotion details, and diagnostic workflows, see [validation.md](validation.md). For HTTP and WebSocket usage, see [api.md](api.md).
