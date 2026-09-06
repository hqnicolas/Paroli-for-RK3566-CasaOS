# Paroli RKNN TTS API Reference

The **Paroli RKNN TTS server** exposes both native REST/WebSocket endpoints and an OpenAI-compatible speech synthesis API on host port `8848` by default.

---

## Network & Security Architecture

- **Port**: `8848` (configurable via `PAROLI_PORT`).
- **Network Scope**: Designed for trusted Local Area Networks (LANs), such as local CasaOS instances, Home Assistant hubs, or local microservices.
- **Authentication**: Intentionally unauthenticated and unencrypted for minimal latency and simplicity on low-power embedded hardware.
- **Internet Exposure**: If accessing over the internet or untrusted networks, place the service behind a reverse proxy (e.g. Caddy, Nginx, or Traefik) that provides TLS termination and authentication (such as HTTP Basic Auth, Authelia, or API token inspection).

---

## Available Models and Voices

Paroli bundles multilingual Piper/Paroli models pre-converted for the RK3566 NPU:

| Model ID | Language | Description / Voice Quality | Native Sample Rate |
| :--- | :--- | :--- | :--- |
| `en_us` | English (US) | Standard US English | 22,050 Hz |
| `it_it_serena` | Italian | Serena (High quality) | 22,050 Hz |
| `it_it_riccardo` | Italian | Riccardo (X-Low latency / lightweight) | 16,000 Hz |
| `de_de` | German | Standard German | 22,050 Hz |
| `fr_fr` | French | Standard French | 22,050 Hz |
| `pt_br` | Portuguese | Brazilian Portuguese | 22,050 Hz |
| `zh_cn` | Chinese | Mandarin Chinese | 22,050 Hz |

> [!TIP]
> **Language Aliases & Model Loading**:
> Startup environment variable aliases `it`, `it_it`, `it-IT`, and `italian` automatically select `it_it_serena`.
> In API requests, specify the exact `Model ID`. Models are loaded dynamically upon first request. Subsequent requests with the same voice run immediately from NPU/CPU memory.

---

## Audio Output Formats

Paroli supports two output formats:

1. **`opus` (Default)**:
   - Encapsulated in an Ogg container (magic header: `OggS`).
   - Resampled to **24,000 Hz**.
   - Highly compressed, ideal for web playback and low bandwidth streaming.
2. **`pcm`**:
   - Raw signed 16-bit little-endian PCM (`audio/raw`).
   - Output matches the model's native sample rate (22,050 Hz for standard models and Serena; 16,000 Hz for Riccardo).
   - Useful for low-latency hardware audio pipelines without decoding overhead.

---

## Native REST Endpoints

### 1. `POST /api/v1/synthesise`

Synthesizes speech from input text.

#### Request Headers
- `Content-Type: application/json`

#### Request JSON Parameters

| Parameter | Type | Required | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `text` | string | **Yes** | — | The sentence or text to synthesize into speech. |
| `language` | string | No | active model | Model ID from the available models table. |
| `audio_format` | string | No | `"opus"` | Format of returned audio: `"opus"` or `"pcm"`. |
| `speaker_id` | integer | No | `0` | Speaker ID (for multi-speaker models). |
| `length_scale` | float | No | `1.0` | Speech speed multiplier (higher = slower speech). |
| `noise_scale` | float | No | `0.667` | Phoneme pronunciation variability. |
| `noise_w` | float | No | `0.8` | Phoneme duration variability. |

#### Example: Basic Synthesis (Opus)

```bash
curl --fail --show-error \
  --request POST http://DEVICE_IP:8848/api/v1/synthesise \
  --header 'Content-Type: application/json' \
  --data '{
    "text": "Hello! Welcome to Paroli TTS on the RK3566.",
    "language": "en_us",
    "audio_format": "opus"
  }' \
  --output speech.opus
```

#### Example: Raw PCM Output

```bash
curl --fail --show-error \
  --request POST http://DEVICE_IP:8848/api/v1/synthesise \
  --header 'Content-Type: application/json' \
  --data '{
    "text": "Ciao da Serena.",
    "language": "it_it_serena",
    "audio_format": "pcm"
  }' \
  --output speech.raw
```

To play the raw PCM file with `ffplay` or `aplay`:
```bash
ffplay -f s16le -ar 22050 -ac 1 speech.raw
```

---

### 2. `GET /api/v1/languages`

Lists all installed model packages and returns the currently active model in memory.

#### Example Request
```bash
curl -s http://DEVICE_IP:8848/api/v1/languages
```

#### Example Response
```json
{
  "languages": [
    "de_de",
    "en_us",
    "fr_fr",
    "it_it_riccardo",
    "it_it_serena",
    "pt_br",
    "zh_cn"
  ],
  "active": "en_us"
}
```

---

### 3. `GET /api/v1/speakers`

Returns available speakers for the active model. Also functions as the container's lightweight health check endpoint.

#### Example Request
```bash
curl -s http://DEVICE_IP:8848/api/v1/speakers
```

#### Example Response
```json
{}
```

*(Empty JSON object `{}` indicates the current models are single-speaker models).*

---

## OpenAI-Compatible Endpoints

Paroli provides drop-in compatibility for applications configured to use the OpenAI Audio API (such as Home Assistant, Nextcloud, or OpenAI client libraries).

### 1. `GET /v1/models`

Lists all installed TTS voices formatted as OpenAI model objects.

```bash
curl -s http://DEVICE_IP:8848/v1/models
```

Example response snippet:
```json
{
  "object": "list",
  "data": [
    {"id": "en_us", "object": "model", "owned_by": "paroli", "name": "English (US)"},
    {"id": "it_it_serena", "object": "model", "owned_by": "paroli", "name": "Italian (Serena, High)"},
    {"id": "de_de", "object": "model", "owned_by": "paroli", "name": "German"}
  ]
}
```

### 2. `GET /v1/audio/voices`

Returns installed voices as selectable voice records.

```bash
curl -s http://DEVICE_IP:8848/v1/audio/voices
```

### 3. `POST /v1/audio/speech`

OpenAI-standard speech synthesis endpoint.

#### Request JSON Parameters
- `model`: Model ID (e.g. `"en_us"`, `"fr_fr"`, `"it_it_serena"`).
- `input`: The text to speak.
- `voice`: Optional compatibility field (can be `"0"` or omitted).

#### Example Request
```bash
curl --fail --show-error \
  --request POST http://DEVICE_IP:8848/v1/audio/speech \
  --header 'Content-Type: application/json' \
  --data '{
    "model": "it_it_serena",
    "input": "Buongiorno a tutti gli utenti di CasaOS."
  }' \
  --output speech.opus
```

---

## WebSocket Streaming API

### `ws://DEVICE_IP:8848/api/v1/stream`

Provides low-latency chunk-by-chunk streaming synthesis. As soon as the RKNN decoder finishes synthesizing each audio fragment, it is transmitted over the WebSocket as a binary blob before the full sentence is complete.

#### Streaming Protocol
1. Client connects to `ws://DEVICE_IP:8848/api/v1/stream`.
2. Client sends a JSON request payload identical to `POST /api/v1/synthesise`:
   ```json
   {"text": "Streaming synthesis delivers instant voice feedback.", "language": "en_us", "audio_format": "opus"}
   ```
3. Server streams multiple binary chunks containing Opus/Ogg audio.
4. Server sends a final JSON message signaling completion:
   ```json
   {"status": "ok", "message": "finished"}
   ```

#### Interactive Example with `wscat`

```bash
wscat -c 'ws://DEVICE_IP:8848/api/v1/stream'
```
```text
> {"text":"Testing the streaming engine.","language":"en_us","audio_format":"opus"}
< [Binary Opus chunk]
< [Binary Opus chunk]
< {"status":"ok","message":"finished"}
```

---

## Additional Documentation

For internal C++ structs, model compilation notes, and deep technical specs, refer to [`src/paroli-server/docs/web_api.md`](src/paroli-server/docs/web_api.md). For deployment setup and rollout validation, refer to [`deploy.md`](deploy.md) and [`validation.md`](validation.md).
