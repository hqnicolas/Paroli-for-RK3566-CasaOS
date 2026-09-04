#!/bin/sh
set -eu

if [ "$#" -gt 0 ]; then
    exec "$@"
fi

if [ ! -d /dev/dri ]; then
    echo "ERROR: /dev/dri is not available inside the container." >&2
    echo "Pass the host DRM devices so librknnrt can reach the RKNPU driver." >&2
    exit 1
fi

MODEL_REVISION="5f25612f4bd92ee7308b4c8845b65ac90fda329b"
MODEL_BASE_URL="${MODEL_BASE_URL:-https://huggingface.co/thanhtantran/piper-paroli-rknn-model/resolve/${MODEL_REVISION}}"

download_model() {
    filename="$1"
    expected_sha256="$2"
    destination="${MODEL_DIR}/${filename}"

    if [ -f "$destination" ]; then
        if echo "${expected_sha256}  ${destination}" | sha256sum -c - >/dev/null 2>&1; then
            echo "Using verified model file: ${destination}"
            return
        fi

        echo "ERROR: Existing model file has the wrong checksum: ${destination}" >&2
        echo "Move it aside manually if you want the pinned file to be downloaded." >&2
        exit 1
    fi

    temporary="${destination}.part"
    echo "Downloading pinned model file: ${filename}"
    curl -fL --retry 3 -o "$temporary" "${MODEL_BASE_URL}/${filename}"

    if ! echo "${expected_sha256}  ${temporary}" | sha256sum -c - >/dev/null 2>&1; then
        echo "ERROR: Checksum verification failed for ${filename}" >&2
        rm -f "$temporary"
        exit 1
    fi

    mv "$temporary" "$destination"
}

if [ -z "${ENCODER_PATH:-}" ] && [ -z "${DECODER_PATH:-}" ] && [ -z "${CONFIG_PATH:-}" ]; then
    mkdir -p "$MODEL_DIR"
    download_model "encoder-en.onnx" "63f4cc713c35c8c896f00a39edad3374932180863a089724fcfda1a7e2f6f08c"
    download_model "decoder-en-3566.rknn" "e2cc7fe81dc61f35dfd9d00e1707e3f9f5eca53b39f9161cfbb3fc797989face"
    download_model "config-en.json" "f83744ff6aa6138ebade1357b65b3f8456bc00b9edb913ab78674eb323ca32d0"

    ENCODER_PATH="${MODEL_DIR}/encoder-en.onnx"
    DECODER_PATH="${MODEL_DIR}/decoder-en-3566.rknn"
    CONFIG_PATH="${MODEL_DIR}/config-en.json"
elif [ -z "${ENCODER_PATH:-}" ] || [ -z "${DECODER_PATH:-}" ] || [ -z "${CONFIG_PATH:-}" ]; then
    echo "ERROR: Set ENCODER_PATH, DECODER_PATH, and CONFIG_PATH together." >&2
    exit 1
fi

for required_file in "$ENCODER_PATH" "$DECODER_PATH" "$CONFIG_PATH"; do
    if [ ! -r "$required_file" ]; then
        echo "ERROR: Model file is not readable: ${required_file}" >&2
        exit 1
    fi
done

set -- /opt/paroli/build/paroli-server \
    --encoder "$ENCODER_PATH" \
    --decoder "$DECODER_PATH" \
    --config "$CONFIG_PATH" \
    --espeak-data /opt/paroli/build/espeak-ng-data \
    --ip "${IP_ADDRESS}" \
    --port "${PORT}"

if [ "${DISABLE_WEB_UI:-false}" = "true" ]; then
    set -- "$@" --disable-web-ui
fi

if [ -n "${LENGTH_SCALE:-}" ]; then
    set -- "$@" --length-scale "$LENGTH_SCALE"
fi

if [ -n "${NOISE_SCALE:-}" ]; then
    set -- "$@" --noise-scale "$NOISE_SCALE"
fi

if [ -n "${NOISE_W:-}" ]; then
    set -- "$@" --noise-w "$NOISE_W"
fi

exec "$@"
