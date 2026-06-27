FROM rust:1-bookworm AS vju-t-builder
WORKDIR /build/vju-t
RUN git clone --branch dev --depth 1 https://github.com/bbusse/vju-t.git /build/vju-t
RUN cargo build --release --locked

FROM golang:1-bookworm AS textimg-builder
RUN go install github.com/jiro4989/textimg/v3@latest

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        tmux \
        zsh \
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

RUN git clone --branch dev https://github.com/bbusse/awsh.git /usr/local/src/awsh
RUN git clone --branch dev https://github.com/bbusse/k8sh.git /usr/local/src/k8sh
RUN git clone --branch dev https://github.com/bbusse/python-datadog.git /usr/local/src/pyqdd

COPY --from=vju-t-builder /build/vju-t/target/release/vju-t /usr/local/bin/vju-t
COPY --from=textimg-builder /go/bin/textimg /usr/local/bin/textimg
COPY klue /usr/local/bin/klue

ENV KLUE_CONFIG="/etc/klue/config.toml"
ENTRYPOINT ["/bin/sh", "-c", "exec /usr/local/bin/klue --config \"$KLUE_CONFIG\" \"$@\"", "--"]
