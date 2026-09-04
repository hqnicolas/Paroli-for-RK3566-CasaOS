FROM ubuntu:24.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive
ARG PIPER_PHONEMIZE_VERSION=2023.11.14-4
ARG PIPER_PHONEMIZE_SHA256=f216660f6225a165155839110cd387947d69618f014f3d1c56729fdedb6557cc
ARG RKNN_VERSION=2.3.0
ARG RKNN_RUNTIME_SHA256=73993ed4b440460825f21611731564503cc1d5a0c123746477da6cd574f34885
ARG RKNN_HEADER_SHA256=340f16c14bc86d41bc5a64251bd1e747dd50899a4438d08707b48d8de384165a

RUN test "$(dpkg --print-architecture)" = "arm64"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        cmake \
        curl \
        g++ \
        libbrotli-dev \
        libdrogon-dev \
        libfmt-dev \
        libhiredis-dev \
        libjsoncpp-dev \
        libmariadb-dev \
        libmariadb-dev-compat \
        libogg-dev \
        libopus-dev \
        libopusenc-dev \
        libpq-dev \
        libsoxr-dev \
        libspdlog-dev \
        libsqlite3-dev \
        libxtensor-dev \
        libyaml-cpp-dev \
        make \
        nlohmann-json3-dev \
        pkg-config \
        uuid-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

COPY src/ /src/paroli/

RUN curl -fL --retry 3 \
        -o /tmp/piper-phonemize.tar.gz \
        "https://github.com/rhasspy/piper-phonemize/releases/download/${PIPER_PHONEMIZE_VERSION}/piper-phonemize_linux_aarch64.tar.gz" \
    && echo "${PIPER_PHONEMIZE_SHA256}  /tmp/piper-phonemize.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/piper-phonemize.tar.gz -C /opt \
    && rm /tmp/piper-phonemize.tar.gz

RUN curl -fL --retry 3 \
        -o /usr/lib/librknnrt.so \
        "https://raw.githubusercontent.com/airockchip/rknn-toolkit2/v${RKNN_VERSION}/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so" \
    && echo "${RKNN_RUNTIME_SHA256}  /usr/lib/librknnrt.so" | sha256sum -c - \
    && curl -fL --retry 3 \
        -o /usr/include/rknn_api.h \
        "https://raw.githubusercontent.com/airockchip/rknn-toolkit2/v${RKNN_VERSION}/rknpu2/runtime/Linux/librknn_api/include/rknn_api.h" \
    && echo "${RKNN_HEADER_SHA256}  /usr/include/rknn_api.h" | sha256sum -c -

RUN cd /src/paroli \
    && cmake -S . -B /src/paroli/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DUSE_RKNN=ON \
        -DORT_ROOT=/opt/piper_phonemize \
        -DPIPER_PHONEMIZE_ROOT=/opt/piper_phonemize \
    && cmake --build /src/paroli/build --parallel 2

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.title="Paroli TTS Server for RK3566" \
      org.opencontainers.image.description="Piper/Paroli TTS with a single RKNN decoder context for non-IOMMU RK3566 hosts" \
      org.opencontainers.image.source="https://github.com/thanhtantran/paroli-on-orangepi" \
      org.opencontainers.image.licenses="MIT"

RUN test "$(dpkg --print-architecture)" = "arm64"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libdrogon1t64 \
        libfmt9 \
        libgomp1 \
        libogg0 \
        libopus0 \
        libopusenc0 \
        libsoxr0 \
        libspdlog1.12 \
        libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/paroli/build/paroli-server /opt/paroli/build/paroli-server
COPY --from=builder /src/paroli/build/paroli-cli /opt/paroli/build/paroli-cli
COPY --from=builder /src/paroli/paroli-server/web-content /opt/paroli/paroli-server/web-content
COPY --from=builder /src/paroli/LICENSE /usr/share/doc/paroli/LICENSE
COPY --from=builder /opt/piper_phonemize/lib/ /usr/local/lib/
COPY --from=builder /opt/piper_phonemize/share/espeak-ng-data/ /opt/paroli/build/espeak-ng-data/
COPY --from=builder /usr/lib/librknnrt.so /usr/lib/librknnrt.so

COPY models/*.tar.gz /opt/paroli/models/
COPY docker/entrypoint.sh /usr/local/bin/paroli-entrypoint

RUN chmod 0755 \
        /opt/paroli/build/paroli-server \
        /opt/paroli/build/paroli-cli \
        /usr/local/bin/paroli-entrypoint \
    && ldconfig

ENV IP_ADDRESS=0.0.0.0 \
    LANGUAGE=pt_br \
    MODEL_DIR=/models \
    PORT=8848

WORKDIR /opt/paroli/build

EXPOSE 8848

ENTRYPOINT ["/usr/local/bin/paroli-entrypoint"]
