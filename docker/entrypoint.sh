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

# Resolve language names and locale values (for example, en_US.UTF-8) to the
# standardized model folder name.
RAW_LANG="${LANGUAGE:-pt_br}"
RAW_LANG="${RAW_LANG%%.*}"
RAW_LANG="${RAW_LANG%%@*}"
RAW_LANG="$(printf '%s' "$RAW_LANG" | tr '[:upper:]' '[:lower:]')"
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
    it|it_it|it-it|italian|it_it_serena|it-it-serena)
        LANG_FOLDER="it_it_serena"
        ;;
    it_it_riccardo|it-it-riccardo)
        LANG_FOLDER="it_it_riccardo"
        ;;
    *)
        LANG_FOLDER="$RAW_LANG"
        ;;
esac

# Make every bundled language available in the shared model directory.
mkdir -p "$MODEL_DIR"
for MODEL_ARCHIVE in /opt/paroli/models/*.tar.gz; do
    [ -f "$MODEL_ARCHIVE" ] || continue
    ARCHIVE_NAME="${MODEL_ARCHIVE##*/}"
    ARCHIVE_LANG="${ARCHIVE_NAME%.tar.gz}"
    if [ ! -d "${MODEL_DIR}/${ARCHIVE_LANG}" ]; then
        echo "Decompressing model archive '${ARCHIVE_NAME}' into ${MODEL_DIR} ..."
        tar -xzf "$MODEL_ARCHIVE" -C "$MODEL_DIR"
    fi
done

TARGET_LANG_DIR="${MODEL_DIR}/${LANG_FOLDER}"

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
        echo "Available languages: pt_br, en_us, zh_cn, de_de, fr_fr, it_it_serena, it_it_riccardo" >&2
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
