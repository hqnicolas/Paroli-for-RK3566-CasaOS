# Paroli RKNN TTS for RK3566 & CasaOS

A high-performance, multilingual **Piper/Paroli Text-to-Speech (TTS)** server optimized for Rockchip RK3566 devices (TV boxes, single-board computers) running Armbian and CasaOS.

The engine uses a hybrid acceleration architecture:
- **Encoder**: Runs on CPU via ONNX Runtime.
- **Decoder**: Runs on the Rockchip RK3566 NPU (0.8 TOPS) via `librknnrt` 2.3.0 and Contiguous Memory Allocator (CMA) buffers.

---

## Key Features

- **NPU Acceleration**: Offloads neural speech decoding to the RK3566 NPU for low power and high efficiency.
- **Multilingual Support**: Bundles pre-converted voices for English, Italian (Serena & Riccardo), German, French, Brazilian Portuguese, and Mandarin Chinese.
- **Dual API Support**:
  - Native high-performance REST and WebSocket streaming API.
  - Drop-in OpenAI-compatible audio API (`/v1/audio/speech`, `/v1/models`, `/v1/audio/voices`).
- **Production Staged Rollout**: Automated deployment pipeline verifying kernel stability, zero NPU faults, and CMA memory safety before service promotion.
- **CasaOS Ready**: Non-privileged container design granting direct DRM device cgroup access (`c 226:* rmw`) with one-click CasaOS Compose import.

---

## Target Contract

| Parameter | Required Value | Notes |
| :--- | :--- | :--- |
| **Architecture** | `linux/arm64` (`aarch64`) | Rockchip RK3566 quad-core Cortex-A55 |
| **Kernel Driver** | `rknpu` **0.9.8** | Out-of-tree DKMS module |
| **Memory Mode** | Non-IOMMU | Requires physical contiguous memory |
| **CMA Pool** | **1 GiB** (`cma=1G`) | Configured via `/boot/armbianEnv.txt` |
| **RKNN Stack** | Toolkit2 / Runtime **2.3.0** | Matched decoder and runtime |
| **Default Port** | `8848` | Trusted LAN HTTP/REST & WebSocket |

---

## Quick Start

### 1. Host Preparation
Install the RKNPU kernel module and reserve 1 GiB CMA in Armbian:
```bash
# Verify system prerequisites
sudo ./scripts/preflight.sh
```
*See [deploy.md](deploy.md) for DKMS module build and CMA configuration steps.*

### 2. Staged Rollout
Execute the staged rollout sequence on the RK3566:
```bash
sudo ./scripts/rollout.sh prepare      # Baseline, native build, ldd check
sudo ./scripts/rollout.sh start        # Start container (restart policy disabled)
sudo ./scripts/rollout.sh validate     # Multi-voice stress test & CMA recovery check
sudo ./scripts/rollout.sh promote      # Enable restart:unless-stopped & emit CasaOS compose
sudo reboot                            # Reboot host to test auto-start
sudo ./scripts/rollout.sh post-reboot  # Verify clean boot and recovery
```

### 3. Test Synthesis
```bash
curl --fail --show-error \
  --request POST http://DEVICE_IP:8848/api/v1/synthesise \
  --header 'Content-Type: application/json' \
  --data '{"text":"Hello from the RK3566 NPU.","language":"en_us","audio_format":"opus"}' \
  --output hello.opus
```

---

## Documentation Index

Detailed guides are split into dedicated topics:

| Topic | Document | Contents |
| :--- | :--- | :--- |
| **Deployment & Host Setup** | [deploy.md](deploy.md) | Armbian kernel headers, DKMS driver installation, 1 GiB CMA reservation, staged rollout lifecycle, and Docker Compose reference. |
| **API Reference** | [api.md](api.md) | Endpoints, JSON parameters, supported model IDs, audio formats (Opus/PCM), OpenAI compatibility, and WebSocket streaming. |
| **Validation & Diagnostics** | [validation.md](validation.md) | Quality gates, CMA leak checks, CasaOS dashboard promotion, and hardware fault isolation using `paroli-cli`. |
| **Developer API Specs** | [src/paroli-server/docs/web_api.md](src/paroli-server/docs/web_api.md) | Low-level C++ struct signatures and internal schema specifications. |

---

## Repository Structure

```text
Paroli-for-RK3566-CasaOS/
├── deploy.md                    # Host setup, DKMS, CMA, and staged rollout guide
├── api.md                       # Complete REST, OpenAI, and WebSocket API reference
├── validation.md                # Quality gates, CasaOS import, and hardware diagnostics
├── docker-compose.yml           # Base Compose specification (restart: no)
├── docker-compose.production.yml# Production Compose override (restart: unless-stopped)
├── Dockerfile                   # Multi-stage native build for RK3566
├── scripts/
│   ├── preflight.sh             # Validates architecture, DRM node, and driver version
│   ├── rollout.sh               # Staged rollout, promotion, and diagnostic manager
│   └── smoke-test.sh            # Functional synthesis test and CMA leak analyzer
├── src/                         # Paroli C++ server and CLI sources
└── models/                      # Model conversion specifications and download manifests
```

---

## License & Credits

- Powered by [Piper](https://github.com/rhasspy/piper) and [Paroli](https://github.com/rhasspy/piper).
- Hardware acceleration provided by [Rockchip RKNN Toolkit2](https://github.com/airockchip/rknn-toolkit2) and [w568w/rknpu-module](https://github.com/w568w/rknpu-module).
