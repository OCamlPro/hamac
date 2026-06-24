# SIESTE Static Build Environment
# Based on Alpine with musl for fully static executables
#
# Usage:
#   docker build -t sieste-static-builder tools/static-build/
#   docker run --rm -v $(pwd):/src sieste-static-builder /src/tools/static-build/build.sh

FROM ocaml/opam:alpine-3.19-ocaml-5.1

# Install static libraries and build dependencies
USER root
RUN apk add --no-cache \
    openssl-libs-static \
    openssl-dev \
    zlib-static \
    zlib-dev \
    gmp-dev \
    libev-dev \
    linux-headers \
    musl-dev \
    gcc \
    g++ \
    make \
    m4 \
    git \
    curl

USER opam

# Update opam and install dependencies
RUN opam update && opam upgrade -y

# Install common SIESTE dependencies with static linking support
RUN opam install -y \
    dune \
    cohttp-lwt-unix \
    lwt \
    yojson \
    caqti \
    caqti-lwt \
    caqti-driver-sqlite3 \
    cmdliner \
    logs \
    fmt \
    fpath \
    bos

WORKDIR /src

# Default command
CMD ["bash"]
