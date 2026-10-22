# syntax=docker/dockerfile:1

# Built from the local checkout, with the repo root as the context:
#   podman build -f deployment/backend/Dockerfile -t notes-app-backend .

# ==========================================
# Builder: GHC and Cabal
# ==========================================
# Debian's packaged cabal-install is too old for current Hackage mirrors.
# Same GHC as local development, same bookworm glibc as runtime.
FROM docker.io/library/haskell:9.10.3-slim-bookworm AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        pkg-config \
        libsqlite3-dev \
        liblzma-dev \
        zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Cache package index separately from source
RUN cabal update

# Only package metadata at this point.
# Changes to Haskell source won't invalidate
# dependency compilation.
COPY notes-app-backend/notes-app-backend.cabal ./

# Compile external Haskell dependencies
RUN cabal build \
    --only-dependencies \
    pkg:notes-app-backend

# Now add application source
COPY notes-app-backend/ ./

# Compile executable
RUN cabal build exe:notes-app-backend && \
    mkdir -p /output && \
    cp "$(cabal list-bin exe:notes-app-backend)" \
       /output/notes-app-backend


# ==========================================
# Runtime: no compiler or build tools
# ==========================================
FROM debian:bookworm-slim AS runtime

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        libgmp10 \
        libffi8 \
        libsqlite3-0 \
        liblzma5 \
        zlib1g \
        libstdc++6 && \
    rm -rf /var/lib/apt/lists/*

# Fixed non-root account
RUN groupadd --system --gid 10001 app && \
    useradd \
        --system \
        --uid 10001 \
        --gid app \
        --home-dir /app \
        app && \
    mkdir -p /app/data && \
    chown -R app:app /app

COPY --from=builder \
    /output/notes-app-backend \
    /usr/local/bin/notes-app-backend

# SQLite creates notes.db in the working directory
WORKDIR /app/data

USER app

# Containers need to bind on all interfaces
ENV HOST=0.0.0.0
ENV PORT=8081

EXPOSE 8081

CMD ["/usr/local/bin/notes-app-backend"]
