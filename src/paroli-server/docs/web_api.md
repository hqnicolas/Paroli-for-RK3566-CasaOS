# paroli-server API

## Available model IDs

| Model ID | Language | Request value |
| --- | --- | --- |
| `de_de` | German | `"model":"de_de"` or `"language":"de_de"` |
| `en_us` | English (United States) | `"model":"en_us"` or `"language":"en_us"` |
| `fr_fr` | French (France) | `"model":"fr_fr"` or `"language":"fr_fr"` |
| `it_it_riccardo` | Italian (Riccardo, X-Low) | `"model":"it_it_riccardo"` or `"language":"it_it_riccardo"` |
| `it_it_serena` | Italian (Serena, High) | `"model":"it_it_serena"` or `"language":"it_it_serena"` |
| `pt_br` | Portuguese (Brazil) | `"model":"pt_br"` or `"language":"pt_br"` |
| `zh_cn` | Chinese (Mandarin) | `"model":"zh_cn"` or `"language":"zh_cn"` |

Use `language` with the native REST and WebSocket APIs. Use `model` with the
OpenAI-compatible speech API. That endpoint also accepts `language` as an alias.
Model IDs are lowercase and must match this table exactly. An unknown ID returns
HTTP 400 for REST requests or a JSON error message over WebSocket. The first
request after changing IDs may take longer while the selected model is loaded.

All bundled models currently contain one speaker. Language selection chooses the
model; `/api/v1/speakers` only chooses among speakers inside a multi-speaker model.

## REST APIs

### /api/v1/languages

* Method: GET
* Parameters: None

Returns the installed model languages and the currently active language.

```json
{"languages":["de_de","en_us","fr_fr","it_it_riccardo","it_it_serena","pt_br","zh_cn"],"active":"pt_br"}
```

### /api/v1/speakers

* Method: GET
* Parameters: None

Returns a mapping from speaker name to speaker ID. The bundled models are
single-speaker models, so the current response is:

```json
{}
```

### /api/v1/synthesise

* Method: POST
* Parameters: A JSON object denoting the text, language, and optional speaker
* Response: `audio/ogg; codecs=opus` or `audio/raw`

Example request body:
```json
{
    "text": "How can I help you? Is there anything wrong?",
    "language": "en_us",
    "audio_format": "opus"
}
```

The fields are as follows:

* `text` - Text for the TTS engine to synthesize.
* `language` - One of the model IDs in the table above. If omitted, the active model is used.
* `speaker_id` - Optional speaker ID for a multi-speaker model.
* `audio_format` - Format of the resulting audio. Valid options are:

   * `pcm` - 16-bit little-endian PCM audio of the model's native sample rate
   * `opus` - OGG stream with OPUS encoded audio. Always at 24000 Hz

The following is the full structure of the request JSON (in C++).

```c++
struct ApiData
{
    std::string text;
    std::optional<std::string> language;
    std::optional<uint64_t> speaker_id;
    std::optional<float> length_scale;
    std::optional<float> noise_scale;
    std::optional<float> noise_w;
    // The returned audio format. Valid values are "pcm" and "opus".
    std::optional<std::string> audio_format;
};

```

Example response:

```
<Some OGG/OPUS audio>
```

### /v1/models

* Method: GET

Returns all installed languages in an OpenAI-compatible model list. Each `id`
is valid as the `model` value for `POST /v1/audio/speech`.

```json
{
  "object": "list",
  "data": [
    {"id":"de_de","object":"model","owned_by":"paroli","name":"German"},
    {"id":"en_us","object":"model","owned_by":"paroli","name":"English (US)"},
    {"id":"fr_fr","object":"model","owned_by":"paroli","name":"French"},
    {"id":"it_it_riccardo","object":"model","owned_by":"paroli","name":"Italian (Riccardo, X-Low)"},
    {"id":"it_it_serena","object":"model","owned_by":"paroli","name":"Italian (Serena, High)"},
    {"id":"pt_br","object":"model","owned_by":"paroli","name":"Portuguese (Brazil)"},
    {"id":"zh_cn","object":"model","owned_by":"paroli","name":"Chinese (Mandarin)"}
  ]
}
```

### /v1/audio/voices

* Method: GET

Returns all installed languages as voice records. Every record uses the same model ID
in its `id`, `language`, and `model` fields.

### /v1/audio/speech

* Method: POST
* Content-Type: `application/json`
* Response: `audio/ogg; codecs=opus`

Use one of the documented model IDs in `model`:

```json
{
  "model": "fr_fr",
  "input": "Bonjour tout le monde",
  "voice": "0"
}
```

The bundled models are single-speaker, so `voice` does not select the language.
For compatibility, it can be omitted or set to `"0"`. PCM output uses each
model's native sample rate: 22,050 Hz for Serena and 16,000 Hz for Riccardo.
Opus output is resampled to 24,000 Hz as documented above.

## WebSocket API

### /api/v1/stream

* Method: GET
* Parameters: None

This endpoint works exactly like the synthesise API above. But audio is streamed in chunks as soon as they are available - reducing latency, as binary blobs. Message format is the same as the synthesise API body. A text message is sent once an error is encountered or synthesis of current text is finished.

For example, the following message causes OPUS audio to be streamed back as binary messages.

```bash
wscat -c 'ws://example.com:8848/api/v1/stream' 
> {"text":"Hello! How can I help you?","language":"en_us","audio_format":"opus"}
< [OPUS audio blob]
< [OPUS audio blob]
< {"status":"ok", "message":"finished"}
```

The server will reply error as text

```bash
wscat -c 'ws://example.com:8848/api/v1/stream' 
> {"hello": "blablabla"}
< {"status":"failed", "message":"Missing 'text' field"}
```
