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

## Install the RKNPU kernel module on Armbian

The running Armbian system must have Linux headers that match its kernel before
the out-of-tree RKNPU driver can be built. When building the Armbian image,
include the headers with `INSTALL_HEADERS=yes`:

```bash
./compile.sh BOARD=h96-tvbox-3566 BRANCH=edge BUILD_DESKTOP=no BUILD_MINIMAL=no KERNEL_CONFIGURE=yes RELEASE=resolute INSTALL_HEADERS=yes
```

After booting that image on the RK3566, install the build dependencies and the
RKNPU module:

```bash
sudo apt update
sudo apt install -y build-essential dkms git
git clone https://github.com/w568w/rknpu-module.git
cd rknpu-module
sudo dkms install .
```

Verify the installation:

```bash
dkms status
```

Confirm that the output lists `rknpu` with the status `installed` before
continuing.

## Reserve 1 GiB CMA on Armbian

The RK3566 NPU needs a large contiguous-memory reservation. On Armbian systems
that use `/boot/armbianEnv.txt`, add `cma=1G` to the kernel command line before
deploying Paroli. Armbian documents `armbianEnv.txt` as the preferred place for
[boot parameters](https://docs.armbian.com/User-Guide_Advanced-Configuration/).

Check the current reservation and confirm that the boot file exists:

```bash
grep '^CmaTotal:' /proc/meminfo
test -f /boot/armbianEnv.txt
grep '^extraargs=' /boot/armbianEnv.txt || true
```

Back up the boot environment:

```bash
sudo cp --preserve=all /boot/armbianEnv.txt /boot/armbianEnv.txt.pre-paroli
```

Edit it:

```bash
sudo nano /boot/armbianEnv.txt
```

If there is no `extraargs` line, add:

```text
extraargs=cma=1G
```

If `extraargs` already contains other kernel parameters, keep them and append
`cma=1G` on the same line. Do not add a second `extraargs` assignment. For
example:

```text
extraargs=existing_option=value cma=1G
```

Save the file and reboot:

```bash
sudo reboot
```

After the device returns, verify both the active kernel command line and the
reserved memory:

```bash
grep -o 'cma=[^ ]*' /proc/cmdline
grep '^CmaTotal:' /proc/meminfo
```

The expected reservation is:

```text
CmaTotal:        1048576 kB
```

If `cma=1G` is absent from `/proc/cmdline`, the board may boot through
`/boot/extlinux/extlinux.conf` instead of Armbian's boot script. In that case,
restore the backup and add `cma=1G` to the existing `APPEND` line in the active
extlinux entry. Do not create `armbianEnv.txt` on a system that does not already
use it.

To roll back the Armbian change:

```bash
sudo cp /boot/armbianEnv.txt.pre-paroli /boot/armbianEnv.txt
sudo reboot
```

Reserving 1 GiB for CMA removes that memory from normal allocations, so confirm
the device has enough remaining RAM for Armbian, Docker, and other services.


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
