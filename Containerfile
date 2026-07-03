FROM rust:1-bookworm AS vju-t-builder
WORKDIR /build/vju-t
RUN git clone --branch dev --depth 1 https://github.com/bbusse/vju-t.git /build/vju-t \
    && cargo build --release --locked

FROM golang:1-bookworm AS textimg-builder
RUN go install github.com/jiro4989/textimg/v3@latest

FROM python:3.11-slim AS pyqdd-deps-builder
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --branch dev --depth 1 https://github.com/bbusse/python-datadog.git /build/pyqdd \
    && python -m venv /opt/pyqdd-venv \
    && /opt/pyqdd-venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/pyqdd-venv/bin/pip install --no-cache-dir -r /build/pyqdd/requirements.txt

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    tmux \
    zsh \
    bsdextrautils \
    jq \
    ca-certificates \
    curl \
    git \
    fonts-dejavu-core \
    python3 \
    python3-pil \
    awscli \
    && curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/$(dpkg --print-architecture)/kubectl" -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --branch dev https://github.com/bbusse/awsh.git /usr/local/src/awsh \
    && git clone --branch dev https://github.com/bbusse/k8sh.git /usr/local/src/k8sh \
    && git clone --branch dev https://github.com/bbusse/python-datadog.git /usr/local/src/pyqdd \
    && find /usr/local/src/pyqdd -maxdepth 1 -type f -name "*.py" -exec \
        sed -i '/^from __future__ import annotations$/a import sys\nsys.path.insert(0, "/opt/pyqdd-venv/lib/python3.11/site-packages")' {} + \
    && useradd --create-home --home-dir /home/klue --shell /bin/zsh --uid 10001 klue \
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

COPY --from=vju-t-builder /build/vju-t/target/release/vju-t /usr/local/bin/vju-t
COPY --from=textimg-builder /go/bin/textimg /usr/local/bin/textimg
COPY --from=pyqdd-deps-builder /opt/pyqdd-venv /opt/pyqdd-venv
COPY klue /usr/local/bin/klue

ENV KLUE_CONFIG="/etc/klue/config.toml"
ENV LANG="C.UTF-8"
ENV LC_ALL="C.UTF-8"
USER klue
ENTRYPOINT ["/bin/sh", "-c", "exec /usr/local/bin/klue --config \"$KLUE_CONFIG\" \"$@\"", "--"]
