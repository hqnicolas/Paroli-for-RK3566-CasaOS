# RK3566 Paroli on-device rollout runbook

Use this runbook directly on the target RK3566 after checking out the committed
migration boundary. Do not run the rollout through emulation: the build, dynamic
link inspection, RKNPU version output, CMA behavior, and inference tests must be
observed on the actual ARM64 host.

## Safety boundary

The rollout does not install or replace a kernel module. It uses the existing
RKNPU 0.9.8 driver and the host's existing 1 GiB CMA pool. It does not delete or
modify `/DATA/AppData/sherpa-onnx`.

Run the stages as root. This is required because unreadable `dmesg` would make
the timeout/reset acceptance gate unreliable.

The normal `docker-compose.yml` defaults to restart policy `no`. Do not use the
production override until `validate` passes.

## 1. Prepare and record the baseline

```bash
cd /path/to/Sherpa-Onnx-Rknn-CasaOs
git status --short
sudo ./scripts/rollout.sh prepare
```

`prepare` performs these actions:

1. Creates `/DATA/AppData/paroli/{models,data}`.
2. Stops, but does not remove, a running `sherpa-onnx-rknn` container.
3. Stops the Paroli Compose project and runs the strict preflight.
4. Requires `aarch64`, Docker Compose v2, a DRM render node on major 226,
   nonzero CMA, readable kernel logs, and RKNPU driver 0.9.8.
5. Records container-free CMA, DRM nodes, kernel messages, kernel version, and
   repository commit.
6. Builds the ARM64 image natively and runs `ldd` over `paroli-server` and
   `paroli-cli`, failing if either reports a missing dependency.

Review these records before startup:

```text
/DATA/AppData/paroli/data/rollout-baseline.env
/DATA/AppData/paroli/data/rollout-baseline.log
/DATA/AppData/paroli/data/rollout-ldd.log
```

Historical RKNPU failures are retained in the baseline; later gates compare
kernel-error counts so only new failures fail this rollout.

## 2. Start without automatic restart

```bash
sudo ./scripts/rollout.sh start
```

The first start downloads the pinned English encoder, RK3566 decoder, and JSON
configuration into `/DATA/AppData/paroli/models/en`, verifies all SHA-256 sums,
and initializes one RKNN context.

The stage does not pass until the container is healthy and its logs contain:

```text
Runtime Information ... librknnrt version: 2.3.0
Driver Information ... version: 0.9.8
Model Information ... toolkit version: 2.3.0
target platform: rk3566
```

At any point, inspect the non-mutating status view:

```bash
sudo ./scripts/rollout.sh status
```

## 3. Run acceptance and recovery gates

```bash
sudo ./scripts/rollout.sh validate
```

The validation sequence is deliberately serial:

1. One warm-up request.
2. Twenty short English requests.
3. One approximately 500-character English request.
4. Stop the container and wait for CMA recovery.
5. Recreate it with automatic restart still disabled.
6. Run one more synthesis request.

Every request must return HTTP 200 and an Ogg stream beginning with `OggS`.
`CmaFree` must be at least 262144 KiB after warm-up and after testing. Its drop
from warm-up through request 20 must be no more than 65536 KiB. After shutdown,
it must return to within 65536 KiB of the container-free baseline. No new RKNPU
timeout, soft-reset, failed-wait, failed-submission, or allocation-failure line
may appear.

Successful results are stored under `/DATA/AppData/paroli/data`, including
`smoke-test-last.env`, `rollout-validation.env`, and the generated audio.

If this stage fails, do not promote the restart policy.

## 4. Isolate an inference failure

If a server request fails, run the direct CLI test:

```bash
sudo ./scripts/rollout.sh diagnose
```

This leaves the HTTP server stopped and feeds a sentence to `paroli-cli` using
the exact same encoder, RK3566 decoder, configuration, runtime, DRM device, and
CMA path. Success produces `paroli-cli-diagnostic.wav` beginning with `RIFF`.

Interpretation:

- CLI success suggests an HTTP lifecycle or concurrency issue.
- CLI failure without an RKNPU timeout suggests a model/runtime initialization
  issue; retain the command output and kernel log.
- A six-second CLI timeout or soft reset is a driver/NPU failure. Keep the
  service stopped, collect the logs, and reboot before any further test.

If runtime 2.3.0 explicitly rejects driver 0.9.8, the fallback is a separately
produced RK3566 decoder plus matching runtime and header built with Toolkit2
1.6.0. Do not reuse the 2.3.0 model with that runtime, and do not alter the host
kernel module as part of this rollout.

## 5. Promote and test host reboot

Only after validation succeeds:

```bash
sudo ./scripts/rollout.sh promote
sudo reboot
```

`promote` recreates the tested service with `restart: unless-stopped`, verifies
the effective Docker policy, and writes a resolved CasaOS definition to:

```text
/DATA/AppData/paroli/data/casaos-compose.yml
```

After the device returns:

```bash
cd /path/to/Sherpa-Onnx-Rknn-CasaOs
sudo ./scripts/rollout.sh post-reboot
```

This requires Docker to have restored the service without an explicit `up`,
checks the same version contract, and performs one more Ogg/CMA/kernel-log test.

## 6. Redeploy in CasaOS and test from the LAN

Import the generated `casaos-compose.yml` as the CasaOS custom app. Confirm the
effective restart policy remains `unless-stopped`; do not enable privileged
mode or host IPC.

From a different machine on the trusted LAN:

```bash
curl --fail --show-error \
  --request POST http://DEVICE_IP:8848/api/v1/synthesise \
  --header 'Content-Type: application/json' \
  --data '{"text":"Final network acceptance test.","audio_format":"opus"}' \
  --output paroli-final.opus
```

Verify it is HTTP 200 and starts with `OggS`:

```bash
head -c 4 paroli-final.opus
```

The output must be `OggS`. This first release has no authentication and must not
be exposed to the internet.

## Rollback

Stop Paroli before returning to the old service so both never share the NPU:

```bash
docker compose -f docker-compose.yml -f docker-compose.production.yml down
docker start sherpa-onnx-rknn
```

Then revert to the recorded Git boundary if the old Compose definition is
needed. The old application data remains under `/DATA/AppData/sherpa-onnx`.
