#!/usr/bin/env bash
# Author: Rafael Muniz
# License: MIT
# Source: https://github.com/rafaelfmuniz/proxmox-scripts

set -e

CONTAINER_NAME="stremio"
IMAGE_NAME="stremio-gpu"
HTTP_PORT=11470
HTTPS_PORT=12470
DATA_PATH="/opt/stremio-data"

echo "─────────────────────────────────────────────"
echo "   Proxmox Helper Script"
echo "   LXC: Stremio + GPU passthrough"
echo "─────────────────────────────────────────────"

echo ">> Preparando ambiente..."
mkdir -p $DATA_PATH

echo ">> Criando Dockerfile temporário..."
cat > Dockerfile.stremio <<'EOF'
FROM stremio/server:latest

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        mesa-va-drivers \
        vainfo && \
    rm -rf /var/lib/apt/lists/*
EOF

echo ">> Buildando imagem customizada ($IMAGE_NAME)..."
docker build -t $IMAGE_NAME -f Dockerfile.stremio .

echo ">> Removendo container antigo (se existir)..."
docker rm -f $CONTAINER_NAME >/dev/null 2>&1 || true

echo ">> Subindo container com GPU..."
docker run -d \
  --name $CONTAINER_NAME \
  --restart unless-stopped \
  -p ${HTTP_PORT}:11470 \
  -p ${HTTPS_PORT}:12470 \
  -v $DATA_PATH:/root/.stremio-server \
  -v /usr/lib/x86_64-linux-gnu/dri:/usr/lib/x86_64-linux-gnu/dri:ro \
  --device /dev/dri/renderD128:/dev/dri/renderD128 \
  $IMAGE_NAME

echo "✔ Container '$CONTAINER_NAME' iniciado."
echo "   HTTP  -> http://localhost:${HTTP_PORT}"
echo "   HTTPS -> https://localhost:${HTTPS_PORT}"
