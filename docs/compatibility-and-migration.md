# RK3566 TTS server compatibility and migration decision

Research date: 2026-09-04

## Decision

Replace the current sherpa-onnx ASR container with the
[RK3566 fork of Paroli](https://github.com/thanhtantran/paroli-on-orangepi/tree/1fee2357e34ce2b4240692ec93a40c58bb5624c0).
Paroli is a Piper-based TTS server with an HTTP API, WebSocket streaming, an ONNX
encoder, and an RKNN decoder. Its companion model repository contains a decoder
compiled specifically for RK3566.

The first deployment will use:

- Paroli commit `1fee2357e34ce2b4240692ec93a40c58bb5624c0`.
- Rockchip `librknnrt.so` 2.3.0.
- Model revision `5f25612f4bd92ee7308b4c8845b65ac90fda329b`.
- `encoder-en.onnx`, `decoder-en-3566.rknn`, and `config-en.json`.
- One RKNN execution context, patched down from the upstream RK3588-oriented
  default of three.
- Port `8848` and Paroli's native `/api/v1/synthesise` API.

This is a compatibility target, not a claim that it has already passed on-device
testing. The image can be assembled and statically checked away from the box, but
the NPU/CMA smoke test must be run on the RK3566 host.

## Observed hardware contract

The captured host output in [about the hardware notes](../about%20the%20hardware.md)
shows:

| Item | Observed value | Consequence |
| --- | --- | --- |
| SoC target | RK3566 (from the existing configuration) | Use an RK3566-compiled RKNN model, not an RK3588 model. |
| Architecture | `aarch64` | Build and run a Linux ARM64 image. |
| Kernel | `7.2.2-edge-rockchip64` | User-space libraries must use the host's existing RKNPU driver ABI. |
| RKNPU driver | `0.9.8` | Do not replace the kernel module from a container. Pin and test one user-space runtime. |
| IOMMU | Missing from the RKNPU device tree; driver is in non-IOMMU mode | NPU buffers depend on physically contiguous host memory. |
| CMA | `1024 MiB` reserved | There is a useful contiguous pool, but it is global host memory and must be monitored. |
| NPU node | RKNPU registered as DRM minor 1; `/dev/rknpu` is absent | Pass `/dev/dri` into the container. Do not require a fictional `/dev/rknpu` path. |
| Existing failure | NPU jobs time out after about six seconds and the driver soft-resets | Start with one context and one request at a time; treat any new timeout as a failed rollout. |

`CmaTotal` does not make CMA available by itself. The container calls
`librknnrt`, which opens the host DRM/RKNPU device and asks the kernel driver to
allocate NPU buffers. In non-IOMMU mode those driver-side DMA allocations are the
path that can consume the host CMA pool. Docker has no `cma` setting and cannot
create or enlarge this pool.

## Why the current stack does not meet the request

The existing files describe different workloads and versions:

- The Docker build installs sherpa-onnx and downloads a streaming Zipformer
  bilingual ASR model.
- The Compose command invokes `sherpa-onnx` with encoder, decoder, joiner, and a
  test WAV. That is speech-to-text, not a persistent TTS server.
- The README's TTS command uses a Piper `.onnx` voice. It does not provide an
  RK3566 `.rknn` TTS model or demonstrate that TTS is using the NPU.
- The README says runtime 2.2.0 while the lowercase `dockerfile` downloads 2.1.0.
- Compose references `Dockerfile` but the repository currently contains
  lowercase `dockerfile`, which is a case-sensitive build failure on Linux.
- Passing `/dev/dri` and using `--provider=rknn` cannot make an ONNX-only TTS
  graph use the NPU.

## Candidate comparison

| Candidate | RK3566 NPU evidence | Server API | Decision |
| --- | --- | --- | --- |
| [Paroli RK3566 fork](https://github.com/thanhtantran/paroli-on-orangepi) | Declares RK3566 support and publishes `decoder-en-3566.rknn`; implementation calls the RKNN C API | REST, WebSocket, and demo UI | Selected, with one-context patch and pinned artifacts |
| [Rockchip Model Zoo MMS-TTS](https://github.com/airockchip/rknn_model_zoo/tree/main/examples/mms_tts) | Official example lists RK3566 and benchmarks RK3566/RK3568 at RTF 0.311 for 200 tokens | Demo only | Strong fallback if a custom server wrapper is acceptable |
| [RKLLAMA](https://github.com/NotPunchnox/rkllama) | Implements Piper/MMS-TTS through RKNN, but its documented server platforms are RK3588 and RK3576 | OpenAI-compatible `/v1/audio/speech` | Rejected for the first RK3566 deployment |
| Piper or Wyoming-Piper | Works well on ARM64 CPU through ONNX Runtime | CLI or Wyoming protocol | CPU fallback only; does not use RKNPU/CMA |
| Current sherpa-onnx setup | Current model and command are RKNN ASR | ASR server tools | Rejected for this TTS-only service |

Paroli does not move the complete TTS pipeline to the NPU. Its dynamic encoder
runs with ONNX Runtime on the CPU and its fixed-shape waveform decoder runs with
RKNN on the NPU. This is still a real NPU TTS workload, but the split must be kept
clear when measuring CPU and NPU utilization.

## Version and artifact contract

The selected RK3566 decoder embeds this metadata:

```text
target platform: rk3566
toolkit/compiler: 2.3.0
input z:       [1, 192, 55]
input y_mask:  [1, 1, 55]
output audio:  [1, 1, 14080]
```

The container therefore uses the matching Rockchip 2.3.0 runtime instead of
mixing a 2.3.0 model with the old 2.1.0 runtime. Rockchip documents RK3566/RK3568
as an RKNN Toolkit2 platform and Paroli requires `rknnrt >= 1.6.0`. Driver 0.9.8
is not changed by this project. Exact on-device compatibility remains a rollout
gate because Rockchip does not publish a complete driver/runtime/model matrix for
this custom kernel.

Downloaded artifacts are pinned and checksum-verified. A pre-existing file with
the wrong checksum causes startup to stop; it is not silently overwritten.

## CMA and concurrency policy

The selected Paroli fork inherits code that duplicates three RKNN contexts, with
a comment explaining that three was chosen for the three-core RK3588. RK3566 has
one NPU core. The local build patch creates one context and the API serializes
decoder inference through it.

Reasons for starting with one context:

- It avoids scheduling simultaneous work onto a single NPU core.
- It bounds runtime buffer allocations in the global CMA pool.
- It reduces the chance of reproducing the observed six-second timeout/reset
  loop.
- Parallelism can be reconsidered only after repeated, instrumented on-device
  tests.

Do not add `shm_size`, `ipc: host`, or a Docker memory reservation in an attempt
to tune CMA. Those settings control different memory mechanisms.

## Deployment design

The replacement will:

1. Build Paroli from the pinned source revision in an ARM64 multi-stage image.
2. Compile with `USE_RKNN=ON` and the single-context RK3566 patch.
3. Install the pinned 2.3.0 RKNN runtime and matching header.
4. Download the three pinned voice artifacts on first start into
   `/DATA/AppData/paroli/models/en`.
5. Expose `8848`, pass `/dev/dri`, and do not use `privileged: true` or host
   IPC.
6. Keep generated test audio in `/DATA/AppData/paroli/data`.

Default API request:

```bash
curl --fail --show-error \
  --request POST http://DEVICE_IP:8848/api/v1/synthesise \
  --header 'Content-Type: application/json' \
  --data '{"text":"Hello from the RK3566.","audio_format":"opus"}' \
  --output /DATA/AppData/paroli/data/test.opus
```

If `PAROLI_TOKEN` is set, also send `Authorization: Bearer TOKEN`. Paroli disables
neither the UI nor API automatically when the port is published, so authentication
or a trusted LAN boundary is required.

## On-device rollout gates

Run these in order on the RK3566 host:

1. Confirm at least one render node exists under `/dev/dri` and that the RKNPU
   driver still reports 0.9.8.
2. Record `CmaTotal` and `CmaFree` before container startup.
3. Build and start the service. Its startup log must report RKNN runtime 2.3.0,
   driver 0.9.8, model compiler 2.3.0, and target RK3566.
4. Confirm `CmaFree` remains comfortably above zero after the model is loaded.
5. Generate a short phrase, verify a non-empty Ogg/Opus response, and check that
   `dmesg` has no new `RKNPU` timeout, reset, allocation, or submission errors.
6. Repeat at least 20 short requests sequentially. Then test the longest text the
   intended client will send.
7. Stop the service and confirm CMA is returned near its initial value.

Successful HTTP alone is insufficient: the rollout passes only if audio is valid
and the kernel log stays clean.

## Failure and rollback rules

Stop the new container immediately if any request adds an RKNPU timeout or soft
reset to `dmesg`. Do not loop restarts around a wedged NPU. Stop the service,
reboot if the driver does not recover, and collect:

```bash
docker compose logs --no-color
dmesg | grep -i -E 'rknpu|npu|cma'
grep -E 'CmaTotal|CmaFree' /proc/meminfo
ls -l /dev/dri
```

The old sherpa-onnx definition is preserved in Git history, so rollback is a Git
revert rather than keeping two services competing for the same NPU and CMA pool.
If runtime 2.3.0 cannot initialize cleanly with this vendor driver, the next test
should be Paroli plus a decoder compiled by RKNN Toolkit2 1.6.0 and runtime 1.6.0;
do not change the model, runtime, and driver simultaneously.

## Sources

- [Paroli RK3566 fork](https://github.com/thanhtantran/paroli-on-orangepi)
- [Pinned Paroli source](https://github.com/thanhtantran/paroli-on-orangepi/tree/1fee2357e34ce2b4240692ec93a40c58bb5624c0)
- [Pinned RK3566/English model repository](https://huggingface.co/thanhtantran/piper-paroli-rknn-model/tree/5f25612f4bd92ee7308b4c8845b65ac90fda329b)
- [Rockchip RKNN Toolkit2 platform and changelog](https://github.com/airockchip/rknn-toolkit2)
- [Official Rockchip MMS-TTS RKNN example](https://github.com/airockchip/rknn_model_zoo/tree/main/examples/mms_tts)
- [RKLLAMA server and TTS support](https://github.com/NotPunchnox/rkllama)
- [Original Paroli project](https://github.com/marty1885/paroli)
