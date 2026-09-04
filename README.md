# Paroli RKNN TTS server for RK3566 and CasaOS

This project runs an English Piper/Paroli text-to-speech server on the captured
RK3566 host. The encoder runs on the CPU through ONNX Runtime and the fixed-shape
decoder runs on the Rockchip NPU through `librknnrt`, using the host driver's CMA
allocations.

The target contract is Linux ARM64, RKNPU driver 0.9.8, non-IOMMU operation,
and a 1 GiB CMA reservation.

## Pinned components

- Paroli RK3566 fork commit `1fee2357e34ce2b4240692ec93a40c58bb5624c0`.
- Rockchip RKNN runtime and build header 2.3.0.
- English model revision `5f25612f4bd92ee7308b4c8845b65ac90fda329b`.
- RK3566 decoder compiled with RKNN Toolkit2 2.3.0.
- One serialized RKNN context for the RK3566's single NPU core.

Build and model downloads are pinned by revision and SHA-256. The entrypoint
does not overwrite an existing model with a different checksum.

## Staged deployment

Run these commands in order on the RK3566. Root is required so kernel messages
can be checked as an acceptance gate.

```bash
sudo ./scripts/rollout.sh prepare
sudo ./scripts/rollout.sh start
sudo ./scripts/rollout.sh validate
sudo ./scripts/rollout.sh promote
sudo reboot
sudo ./scripts/rollout.sh post-reboot
```

`prepare` records the container-free baseline, builds natively, and inspects
both final binaries with `ldd`. `start` keeps automatic restart disabled.
`validate` performs the warm-up, 20-request, long-text, CMA recovery, and
container-restart gates. Only `promote` changes the policy to `unless-stopped`.

The old `/DATA/AppData/sherpa-onnx` directory is never changed or deleted. If
the old `sherpa-onnx-rknn` container is running, `prepare` stops it so two
processes cannot compete for the NPU and CMA; the stopped container is retained.

## API

The trusted-LAN service listens on host port `8848` by default.

```bash
curl --fail --show-error \
  --request POST http://DEVICE_IP:8848/api/v1/synthesise \
  --header 'Content-Type: application/json' \
  --data '{"text":"Hello from the RK3566.","audio_format":"opus"}' \
  --output hello.opus
```

Public endpoints:

- `POST /api/v1/synthesise` accepts `{"text":"…","audio_format":"opus"}`.
- `GET /api/v1/speakers` is the health-check endpoint.
- `ws://DEVICE_IP:8848/api/v1/stream` provides streaming synthesis.

Omitting `audio_format` or selecting `opus` returns Ogg/Opus. Selecting `pcm`
returns 22050 Hz, signed 16-bit little-endian PCM.

## Validation policy

The automated rollout enforces all locally measurable gates:

- every synthesis request returns HTTP 200 and begins with `OggS`;
- no new RKNPU timeout, soft reset, wait, submission, or allocation failure;
- at least 256 MiB of `CmaFree` remains after warm-up and after requests;
- the warm-up-to-request-sequence CMA drop is no more than 64 MiB;
- after shutdown, `CmaFree` returns to within 64 MiB of baseline;
- a recreated container and, after promotion, a host reboot restore service.

After `post-reboot`, run one final request from another trusted-LAN machine.
That external-network observation cannot be proven by a script running on the
device.

Records and test audio are written to `/DATA/AppData/paroli/data`. Models are
stored under `/DATA/AppData/paroli/models/en`.

## CasaOS promotion

The normal Compose definition defaults to restart policy `no`. The production
override sets `unless-stopped`:

```bash
docker compose -f docker-compose.yml -f docker-compose.production.yml up -d
```

After validation, `rollout.sh promote` also generates the fully resolved file
`/DATA/AppData/paroli/data/casaos-compose.yml`. Import that generated definition
into CasaOS. It contains the tested `unless-stopped` policy.

The container receives `/dev/dri` and cgroup access to DRM character-device
major 226. It deliberately does not use `privileged: true`, `ipc: host`, an
OpenAI compatibility layer, Wyoming, or authentication. Keep port 8848 on a
trusted LAN; internet exposure needs a separate TLS/authentication deployment.

## Failure isolation

If HTTP inference fails, leave automatic restart disabled and run:

```bash
sudo ./scripts/rollout.sh diagnose
```

This stops the server and invokes the same voice with `paroli-cli`, producing
`/DATA/AppData/paroli/data/paroli-cli-diagnostic.wav`. A CLI failure points at
the RKNN/model/driver path rather than REST or server concurrency.

If runtime 2.3.0 explicitly rejects driver 0.9.8, build a separate matched
decoder, runtime, and header set with Toolkit2 1.6.0. Never run the 2.3.0 model
with a 1.6.0 runtime. If the CLI triggers another six-second NPU timeout, keep
the service stopped, retain the collected logs, and reboot before further NPU
testing.
