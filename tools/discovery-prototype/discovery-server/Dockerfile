# SIESTE Discovery Server
#
# OCaml-based REST API for node registration and discovery.
# Simple in-memory storage for demo purposes.

FROM ocaml/opam:alpine-3.19-ocaml-5.1 AS builder

# Install system dependencies
RUN sudo apk add --no-cache \
    m4 \
    openssl-dev \
    linux-headers \
    gmp-dev

# Switch to opam user
USER opam
WORKDIR /home/opam

# Install OCaml dependencies (minimal set)
RUN opam update && opam install -y \
    dune \
    lwt \
    cohttp-lwt-unix \
    yojson

# Copy source code
COPY --chown=opam:opam . /home/opam/discovery-server/
WORKDIR /home/opam/discovery-server

# Build
RUN eval $(opam env) && dune build discovery_server.exe

# Runtime image
FROM alpine:3.19

RUN apk add --no-cache \
    libgcc \
    gmp \
    curl

# Copy binary
COPY --from=builder /home/opam/discovery-server/_build/default/discovery_server.exe /usr/local/bin/discovery-server

# Create non-root user
RUN adduser -D -s /bin/sh sieste
USER sieste

EXPOSE 8877

HEALTHCHECK --interval=10s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8877/health || exit 1

ENTRYPOINT ["/usr/local/bin/discovery-server"]
