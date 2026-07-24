# Containerfile
#
# Minimal distroless-style image: brush + tmux + vju-t + awsh/k8sh/pyqdd + awscli.
# No Debian, no Perl, no package manager in the final layer.
#
# Runtime base: alpine:3  (~5 MB, glibc-free, no Perl)
# All Rust binaries are built as musl-static on rust:alpine.
#
# Build:
#   podman build -f Containerfile -t klue .
#
# brush: bash/POSIX-compatible shell in Rust  https://github.com/reubeno/brush
# vju-t: terminal widget TUI               https://github.com/bbusse/vju-t
# gojq:  pure-Go jq, installed as `jq`     https://github.com/itchyny/gojq

# Clone vju-t using go-git (pure Go git — no system git binary needed).
# Depth 0 = full history (go-git convention for unlimited).
FROM golang:1-alpine AS vju-t-source
RUN apk add --no-cache ca-certificates git curl
WORKDIR /app
RUN printf 'module clone\ngo 1.22\n' > go.mod \
    && printf 'package main\n\nimport (\n\t"log"\n\tgit "github.com/go-git/go-git/v5"\n\t"github.com/go-git/go-git/v5/plumbing"\n)\n\nfunc main() {\n\t_, err := git.PlainClone("/out/vju-t", false, &git.CloneOptions{\n\t\tURL:           "https://github.com/bbusse/vju-t.git",\n\t\tReferenceName: plumbing.NewBranchReferenceName("dev"),\n\t})\n\tif err != nil {\n\t\tlog.Fatal(err)\n\t}\n}\n' > main.go \
    && go get github.com/go-git/go-git/v5 \
    && go mod tidy \
    && go build -o /go-clone . \
    && mkdir -p /out \
    && /go-clone
RUN git clone --branch dev --depth 1 https://github.com/bbusse/awsh.git /out/awsh \
    && git clone --branch dev --depth 1 https://github.com/bbusse/k8sh.git /out/k8sh \
    && git clone --branch dev --depth 1 https://github.com/bbusse/pyqdd.git /out/pyqdd \
    && rm -rf /out/pyqdd/.git /out/pyqdd/Containerfile
RUN go install github.com/jiro4989/textimg/v3@latest
# gojq: pure-Go jq implementation, avoids pulling in C jq + its libs.
RUN go install github.com/itchyny/gojq/cmd/gojq@latest
# kubectl is a static Go binary; GOARCH already matches the release URL scheme.
RUN ARCH=$(go env GOARCH) \
    && curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl" \
         -o /out/kubectl \
    && chmod +x /out/kubectl

# Install awscli and pyqdd's dependency into a --target prefix so there is
# no Python-version dependency on the path (packages land directly in
# /opt/pyqdd/, which is also where the pyqdd scripts' PYTHONPATH points).
FROM python:3-alpine AS pyqdd-exp-builder
RUN pip install --no-cache-dir --target /opt/pyqdd awscli 'datadog-api-client>=2.0.0' \
    && rm -rf /opt/pyqdd/awscli/examples /opt/pyqdd/awscli/topics \
    && find /opt/pyqdd -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null; true

# Build brush and vju-t as musl-static binaries.
# rust:alpine uses the musl toolchain by default.
FROM rust:1-alpine AS brush-builder
RUN apk add --no-cache musl-dev
RUN cargo install --locked --jobs 1 brush-shell \
    && strip /usr/local/cargo/bin/brush
COPY --from=vju-t-source /out/vju-t /build/vju-t
RUN cd /build/vju-t \
    && cargo build --jobs 1 --release \
    && strip target/release/vju-t

# Final image: Alpine + tmux + python3 + Pillow + brush.
FROM alpine:3
RUN apk add --no-cache tmux python3 py3-pillow ttf-dejavu \
    && addgroup -g 10001 klue \
    && adduser -D -h /home/klue -s /usr/local/bin/klue-shell -u 10001 -G klue klue \
    && echo '/usr/local/bin/brush' >> /etc/shells \
    && echo '/usr/local/bin/klue-shell' >> /etc/shells \
    && mkdir -p /home/klue /etc/klue \
    && chown -R klue:klue /home/klue /etc/klue
COPY --from=brush-builder /usr/local/cargo/bin/brush /usr/local/bin/brush
COPY --from=brush-builder /build/vju-t/target/release/vju-t /usr/local/bin/vju-t
COPY --from=vju-t-source /go/bin/textimg /usr/local/bin/textimg
COPY --from=vju-t-source /go/bin/gojq /usr/local/bin/jq
COPY --from=vju-t-source /out/kubectl /usr/local/bin/kubectl
COPY --from=vju-t-source /out/awsh /usr/local/src/awsh
COPY --from=vju-t-source /out/k8sh /usr/local/src/k8sh
COPY --from=vju-t-source /out/pyqdd /usr/local/src/pyqdd
COPY --from=pyqdd-exp-builder /opt/pyqdd /opt/pyqdd
COPY klue /usr/local/bin/klue
RUN ln -s /usr/local/bin/brush /usr/local/bin/bash \
    && printf '#!/usr/bin/env python3\nimport sys\nsys.path.insert(0, "/opt/pyqdd")\nfrom awscli.clidriver import main\nsys.exit(main())\n' > /usr/local/bin/aws \
    && chmod +x /usr/local/bin/aws \
    && printf '#!/bin/sh\n# Unlike bash/zsh, brush only sources ~/.brushrc when passed -i explicitly\n# (being attached to a tty is not enough). tmux execs the login shell\n# directly with no way to inject flags, so this wrapper forces -i for\n# every pane, interactive or not.\nexec /usr/local/bin/brush -i "$@"\n' > /usr/local/bin/klue-shell \
    && chmod +x /usr/local/bin/klue-shell

RUN printf 'export PATH="/usr/local/bin:/usr/local/src/awsh:$PATH"\nexport PYTHONPATH="/opt/pyqdd"\nif [[ -f /usr/local/src/k8sh/k8sh ]]; then\n    source /usr/local/src/k8sh/k8sh\nfi\n' \
        > /home/klue/.brushrc \
    && chown klue:klue /home/klue/.brushrc

ENV SHELL=/usr/local/bin/klue-shell
ENV PYTHONPATH=/opt/pyqdd
ENV STREAM_FONT=/usr/share/fonts/dejavu/DejaVuSansMono.ttf
ENV KLUE_CONFIG="/etc/klue/config.toml"
EXPOSE 6442
USER klue
ENTRYPOINT ["/bin/sh", "-c", "exec /usr/local/bin/klue --config \"$KLUE_CONFIG\" \"$@\"", "--"]
