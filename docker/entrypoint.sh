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

MODEL_DIR="${MODEL_DIR:-/models}"

# Resolve LANGUAGE variable to standardized folder name
RAW_LANG="${LANGUAGE:-pt_br}"
case "$RAW_LANG" in
    pt|pt_br|pt-br|portuguese)
        LANG_FOLDER="pt_br"
        ;;
    en|en_us|en-us|english)
        LANG_FOLDER="en_us"
        ;;
    zh|zh_cn|zh-cn|chinese)
        LANG_FOLDER="zh_cn"
        ;;
    de|de_de|de-de|german)
        LANG_FOLDER="de_de"
        ;;
    fr|fr_fr|fr-fr|french)
        LANG_FOLDER="fr_fr"
        ;;
    *)
        LANG_FOLDER="$RAW_LANG"
        ;;
esac

# Auto-unpack model archive if target language folder is missing
TARGET_LANG_DIR="${MODEL_DIR}/${LANG_FOLDER}"
MODEL_ARCHIVE="/opt/paroli/models/${LANG_FOLDER}.tar.gz"

if [ ! -d "$TARGET_LANG_DIR" ] && [ -f "$MODEL_ARCHIVE" ]; then
    echo "Decompressing model archive '${LANG_FOLDER}.tar.gz' into ${MODEL_DIR} ..."
    mkdir -p "$MODEL_DIR"
    tar -xzf "$MODEL_ARCHIVE" -C "$MODEL_DIR"
    echo "Decompression complete."
fi

if [ -z "${ENCODER_PATH:-}" ] && [ -z "${DECODER_PATH:-}" ] && [ -z "${CONFIG_PATH:-}" ]; then
    ENCODER_PATH="${TARGET_LANG_DIR}/encoder.onnx"
    DECODER_PATH="${TARGET_LANG_DIR}/decoder-3566.rknn"
    CONFIG_PATH="${TARGET_LANG_DIR}/config.json"
elif [ -z "${ENCODER_PATH:-}" ] || [ -z "${DECODER_PATH:-}" ] || [ -z "${CONFIG_PATH:-}" ]; then
    echo "ERROR: Set ENCODER_PATH, DECODER_PATH, and CONFIG_PATH together." >&2
    exit 1
fi

for required_file in "$ENCODER_PATH" "$DECODER_PATH" "$CONFIG_PATH"; do
    if [ ! -r "$required_file" ]; then
        echo "ERROR: Model file is not readable: ${required_file}" >&2
        echo "Available languages: pt_br, en_us, zh_cn, de_de, fr_fr" >&2
        exit 1
    fi
done

echo "Starting Paroli TTS Server with language '${LANG_FOLDER}'..."
echo "  Encoder: ${ENCODER_PATH}"
echo "  Decoder: ${DECODER_PATH}"
echo "  Config:  ${CONFIG_PATH}"

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
