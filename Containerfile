ARG VJU_T_VERSION=v0-rc0
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

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    tmux \
    zsh \
    bsdextrautils \
    jq \
    ca-certificates \
    curl \
    fonts-dejavu-core \
    python3 \
    python3-pil \
    && curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/$(dpkg --print-architecture)/kubectl" -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && rm -rf /var/lib/apt/lists/* \
    && dpkg --remove --force-depends debconf adduser mailcap perl \
    && dpkg --remove --force-depends libperl5.36 perl-modules-5.36 \
    && rm -rf /usr/share/doc \
              /usr/share/bash-completion \
              /usr/share/common-licenses \
              /usr/share/bug \
              /usr/share/lintian \
              /usr/share/zsh/functions/Completion \
              /usr/share/zsh/vendor-completions \
              /var/cache/debconf

ARG VJU_T_VERSION
RUN ARCH=$(dpkg --print-architecture) \
    && if [ "$VJU_T_VERSION" = "latest" ]; then \
         DOWNLOAD_URL="https://github.com/bbusse/vju-t/releases/latest/download/vju-t-linux-${ARCH}"; \
       else \
         DOWNLOAD_URL="https://github.com/bbusse/vju-t/releases/download/${VJU_T_VERSION}/vju-t-linux-${ARCH}-${VJU_T_VERSION}"; \
       fi \
    && curl -fsSL "$DOWNLOAD_URL" -o /usr/local/bin/vju-t \
    && chmod +x /usr/local/bin/vju-t

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

COPY --from=textimg-builder /go/bin/textimg /usr/local/bin/textimg
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
