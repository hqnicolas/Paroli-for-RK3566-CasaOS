# Paroli RKNN TTS server for RK3566 and CasaOS

This project runs a multilingual Piper/Paroli text-to-speech server on the captured
RK3566 host. The encoder runs on the CPU through ONNX Runtime and the fixed-shape
decoder runs on the Rockchip NPU through `librknnrt`, using the host driver's CMA
allocations.

The target contract is Linux ARM64, RKNPU driver 0.9.8, non-IOMMU operation,
and a 1 GiB CMA reservation.

## Components

- Self-contained Paroli TTS engine with built-in OpenAI API support (`/v1/audio/speech`, `/v1/models`, `/v1/audio/voices`).
- Rockchip RKNN runtime and build header 2.3.0.
- English model revision `5f25612f4bd92ee7308b4c8845b65ac90fda329b`.
- RK3566 decoder compiled with RKNN Toolkit2 2.3.0.
- One serialized RKNN context for the RK3566's single NPU core.

Model downloads are pinned by revision and SHA-256. The entrypoint
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
  --data '{"text":"Hello from the RK3566.","language":"en_us","audio_format":"opus"}' \
  --output hello.opus
```

Available model IDs are `de_de`, `en_us`, `fr_fr`, `it_it_riccardo`,
`it_it_serena`, `pt_br`, and `zh_cn`. The startup `LANGUAGE` aliases `it`,
`it_it`, `it-IT`, and `italian` select Serena; API requests use the exact model
IDs. The complete request and response contract is in
[`src/paroli-server/docs/web_api.md`](src/paroli-server/docs/web_api.md).

### Italian model provenance

Both converted archives contain `encoder.onnx`, `decoder-3566.rknn`, and
`config.json` inside a directory matching the model ID.

| Model ID | Upstream voice | Quality | Sample rate | Archive size |
| --- | --- | --- | ---: | ---: |
| `it_it_serena` | [Serena](https://huggingface.co/rhasspy/piper-voices/tree/1162a9173d0ce503555aed757976b7a9912eae4c/it/it_IT/serena/high) | high | 22,050 Hz | 79,007,884 bytes |
| `it_it_riccardo` | [Riccardo](https://huggingface.co/rhasspy/piper-voices/tree/1162a9173d0ce503555aed757976b7a9912eae4c/it/it_IT/riccardo/x_low) | x-low | 16,000 Hz | 16,080,280 bytes |

Pinned source SHA-256 checksums:

```text
743240dae6ecab12cdc3eee9260cbf688a04e066775d0ce28b8007dad12f42d0  it_IT-serena-high.onnx
ce7e3319aee3b687ab6e8be8d49eae350e5ef942eaf95189dec80fb89110d4ee  it_IT-serena-high.onnx.json
1368de15f123275a7ef951c9e5e30be0f58a032daa14a0da44037443c1d1d21b  it_IT-riccardo-x_low.onnx
146ab9c634afe524e9fb7530f2510df7a42fb1db56b52658ca1fb3d98001a62a  it_IT-riccardo-x_low.onnx.json
```

Packaged archive SHA-256 checksums:

```text
5eb11aaa393e54ef1fd0272500dd1c0a96ddc58421bfccda9fde4e111350033c  models/it_it_serena.tar.gz
e1c33fc8dc53fea2e26b2632054ebe2bc9a4fa735925371911ccc8d50d52f747  models/it_it_riccardo.tar.gz
```

The Piper Voices repository is MIT-licensed. Serena's model card attributes its
training data under CC-BY-4.0; Riccardo's model card links to the M-AILABS
dataset for its applicable attribution and license terms.

Public endpoints:

- `GET /api/v1/languages` lists the installed languages and the active model.
- `GET /v1/models` returns every language using the OpenAI model-list shape.
- `GET /v1/audio/voices` returns every language as a selectable voice/model.
- `POST /v1/audio/speech` accepts a returned language ID in `model` or `language`.
- `POST /api/v1/synthesise` accepts `{"text":"…","language":"en_us","audio_format":"opus"}`.
- `GET /api/v1/speakers` is the health-check endpoint.
- `ws://DEVICE_IP:8848/api/v1/stream` provides streaming synthesis.

Omitting `audio_format` or selecting `opus` returns Ogg/Opus. Selecting `pcm`
returns signed 16-bit little-endian PCM at the model's native sample rate: 22,050
Hz for Serena and the existing models, or 16,000 Hz for Riccardo.

## Validation policy

The automated rollout enforces all locally measurable gates:

- every synthesis request returns HTTP 200 and begins with `OggS`;
- explicit Italian requests load and synthesize with both Serena and Riccardo;
- no new RKNPU timeout, soft reset, wait, submission, or allocation failure;
- at least 256 MiB of `CmaFree` remains after warm-up and after requests;
- the warm-up-to-request-sequence CMA drop is no more than 64 MiB;
- after shutdown, `CmaFree` returns to within 64 MiB of baseline;
- a recreated container and, after promotion, a host reboot restore service.

After `post-reboot`, run one final request from another trusted-LAN machine.
That external-network observation cannot be proven by a script running on the
device.

Records and test audio are written to `/DATA/AppData/paroli/data`. Models are
stored in language-specific directories under `/DATA/AppData/paroli/models`; all
bundled language archives are unpacked automatically at container startup and
can be selected from the Web UI.

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
