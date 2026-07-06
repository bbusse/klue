ARG VJU_T_VERSION=latest

FROM golang:1-bookworm AS textimg-builder
RUN go install github.com/jiro4989/textimg/v3@latest \
    && git clone --branch dev --depth 1 https://github.com/bbusse/awsh.git /usr/local/src/awsh \
    && git clone --branch dev --depth 1 https://github.com/bbusse/k8sh.git /usr/local/src/k8sh \
    && git clone --branch dev --depth 1 https://github.com/bbusse/pyqdd.git /usr/local/src/pyqdd

FROM python:3.11 AS pyqdd-deps-builder
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --branch dev --depth 1 https://github.com/bbusse/python-datadog.git /build/pyqdd \
    && pip install --no-cache-dir --prefix /opt/pyqdd -r /build/pyqdd/requirements.txt \
    && pip install --no-cache-dir --prefix /opt/pyqdd awscli \
    && rm -rf /opt/pyqdd/lib/python*/site-packages/awscli/examples \
              /opt/pyqdd/lib/python*/site-packages/awscli/topics \
    && find /opt/pyqdd -type d -name '*.dist-info' -exec rm -rf {} + 2>/dev/null; \
       find /opt/pyqdd -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null; true

# Downloads and UPX-compresses kubectl, vju-t, and textimg in one stage so
# upx never lands in the runtime image.
FROM debian:bookworm-slim AS binary-compressor
ARG VJU_T_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/upx/upx/releases/download/v4.2.4/upx-4.2.4-${ARCH}_linux.tar.xz" \
         -o /tmp/upx.tar.xz \
    && tar -xJf /tmp/upx.tar.xz -C /tmp \
    && mv /tmp/upx-4.2.4-${ARCH}_linux/upx /usr/local/bin/upx \
    && rm -rf /tmp/upx.tar.xz /tmp/upx-4.2.4-* \
    && curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl" \
         -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && if [ "$VJU_T_VERSION" = "latest" ]; then \
         DOWNLOAD_URL="https://github.com/bbusse/vju-t/releases/latest/download/vju-t-linux-${ARCH}"; \
       else \
         DOWNLOAD_URL="https://github.com/bbusse/vju-t/releases/download/${VJU_T_VERSION}/vju-t-linux-${ARCH}-${VJU_T_VERSION}"; \
       fi \
    && curl -fsSL "$DOWNLOAD_URL" -o /usr/local/bin/vju-t \
    && chmod +x /usr/local/bin/vju-t
COPY --from=textimg-builder /go/bin/textimg /usr/local/bin/textimg
RUN upx --best /usr/local/bin/kubectl /usr/local/bin/textimg /usr/local/bin/vju-t

FROM debian:bookworm-slim
# Prevent dpkg from writing docs, completions, and other cruft during install.
RUN printf 'path-exclude=/usr/share/doc/*\n\
path-exclude=/usr/share/bash-completion/*\n\
path-exclude=/usr/share/common-licenses/*\n\
path-exclude=/usr/share/bug/*\n\
path-exclude=/usr/share/lintian/*\n\
path-exclude=/usr/share/zsh/functions/Completion/*\n\
path-exclude=/usr/share/zsh/vendor-completions/*\n' \
    > /etc/dpkg/dpkg.cfg.d/00-docker
RUN apt-get update && apt-get install -y --no-install-recommends \
    tmux \
    zsh \
    bsdextrautils \
    jq \
    ca-certificates \
    fonts-dejavu-core \
    python3 \
    python3-pil \
    && rm -rf /var/lib/apt/lists/* \
    && dpkg --remove --force-depends debconf adduser mailcap perl \
    && dpkg --remove --force-depends libperl5.36 perl-modules-5.36 \
    && rm -rf /var/cache/debconf

COPY --from=binary-compressor /usr/local/bin/kubectl /usr/local/bin/kubectl
COPY --from=binary-compressor /usr/local/bin/vju-t /usr/local/bin/vju-t

COPY --from=textimg-builder /usr/local/src/awsh /usr/local/src/awsh
COPY --from=textimg-builder /usr/local/src/k8sh /usr/local/src/k8sh
COPY --from=textimg-builder /usr/local/src/pyqdd /usr/local/src/pyqdd
RUN useradd --create-home --home-dir /home/klue --shell /bin/zsh --uid 10001 klue \
    && mkdir -p /etc/klue \
    && chown -R klue:klue /home/klue /etc/klue

RUN cat > /home/klue/.zshrc <<'EOF' \
    && chown klue:klue /home/klue/.zshrc
#!/usr/bin/env zsh
export PATH="/usr/local/bin:/usr/local/src/awsh:$PATH"
if [[ -f /usr/local/src/k8sh/k8sh ]]; then
    source /usr/local/src/k8sh/k8sh
fi
EOF

COPY --from=binary-compressor /usr/local/bin/textimg /usr/local/bin/textimg
COPY --from=pyqdd-deps-builder /opt/pyqdd /opt/pyqdd
ENV PYTHONPATH="/opt/pyqdd/lib/python3.11/site-packages"
RUN sed -i '1s|.*|#!/usr/bin/python3|' /opt/pyqdd/bin/aws \
    && ln -s /opt/pyqdd/bin/aws /usr/local/bin/aws
COPY klue /usr/local/bin/klue

ENV KLUE_CONFIG="/etc/klue/config.toml"
ENV LANG="C.UTF-8"
ENV LC_ALL="C.UTF-8"
USER klue
ENTRYPOINT ["/bin/sh", "-c", "exec /usr/local/bin/klue --config \"$KLUE_CONFIG\" \"$@\"", "--"]
