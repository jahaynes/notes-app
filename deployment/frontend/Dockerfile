# syntax=docker/dockerfile:1

# ==========================================
# Source: sparse checkout from GitHub
# ==========================================
FROM debian:bookworm-slim AS source

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

ARG SOURCE_CACHEBUST=0

RUN echo "Source refresh: ${SOURCE_CACHEBUST}" && \
    git clone \
        --depth 1 \
        --filter=blob:none \
        --sparse \
        --branch master \
        https://github.com/jahaynes/notes-app.git \
        /tmp/repo && \
    cd /tmp/repo && \
    git sparse-checkout set notes-app && \
    mkdir -p /src && \
    cp -a notes-app/. /src/ && \
    rm -rf /tmp/repo


# ==========================================
# Builder: Flutter SDK
# ==========================================
FROM debian:bookworm-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        curl \
        unzip \
        xz-utils \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Flutter objects to running as root, and as root
# its tar extractions try to keep foreign owners.
RUN useradd --create-home builder && \
    mkdir -p /opt/flutter /build /output && \
    chown builder:builder /opt/flutter /build /output

USER builder

# Same Flutter as local development.
# Prebuilt Flutter images lag behind stable.
ARG FLUTTER_VERSION=3.47.7

RUN git clone \
        --depth 1 \
        --branch "${FLUTTER_VERSION}" \
        https://github.com/flutter/flutter.git \
        /opt/flutter

ENV PATH="/opt/flutter/bin:${PATH}"

# Fetch the Dart SDK and web engine once,
# ahead of anything project-specific.
RUN flutter config --no-analytics && \
    flutter precache --web

WORKDIR /build

# Only package metadata at this point.
# Changes to Dart source won't invalidate
# dependency resolution.
COPY --from=source --chown=builder:builder \
    /src/pubspec.* \
    ./

RUN flutter pub get

# Now add application source
COPY --from=source --chown=builder:builder /src/ ./

# The backend address is entered at the login
# screen, so nothing about it is baked in here.
RUN flutter build web --release && \
    cp -a build/web/. /output/


# ==========================================
# Runtime: static files behind nginx
# ==========================================
# Runs as a non-root user and listens on 8080.
FROM docker.io/nginxinc/nginx-unprivileged:1.29-alpine AS runtime

USER root

# Unknown paths fall back to the app, so its routes
# survive a reload or a direct link.
RUN printf '%s\n' \
    'server {' \
    '    listen 8080;' \
    '    root /usr/share/nginx/html;' \
    '' \
    '    location / {' \
    '        try_files $uri $uri/ /index.html;' \
    '    }' \
    '' \
    '    # Filenames are not content-hashed, so make' \
    '    # browsers revalidate rather than serve stale.' \
    '    add_header Cache-Control "no-cache";' \
    '}' \
    > /etc/nginx/conf.d/default.conf

COPY --from=builder \
    /output/ \
    /usr/share/nginx/html/

USER nginx

EXPOSE 8080
