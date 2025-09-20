#!/usr/bin/env bash
# ----------------------------------------------------------------------------------
# Proxmox VE Helper Script
# Criação de LXC Debian 12 com GPU passthrough + Docker Installer (community-style)
# ----------------------------------------------------------------------------------
set -euo pipefail
YW=$'\033[33m'; GN=$'\033[1;92m'; RD=$'\033[01;31m'; CL=$'\033[0m'

# --- Configurações padrão (podem ser sobrescritas via env) ---
CTID="${CTID:-250}"
HN="${HN:-docker-gpu}"
DISK_SIZE="${DISK_SIZE:-20G}"
MEM="${MEM:-4096}"
CPU="${CPU:-4}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local}"   # ajustável, ex.: local, local-lvm, ssd-vms

echo -e "${GN}==> Criando LXC CTID=$CTID hostname=$HN...${CL}"

# --- Template Debian 12 ---
TEMPLATE="$(pveam available -section system | awk '/debian-12-standard/ {print $2}' | sort -V | tail -n1)"
if ! pveam list local | awk '{print $2}' | grep -q "^${TEMPLATE}$"; then
  echo -e "${YW}Baixando template Debian 12...${CL}"
  pveam update
  pveam download local "$TEMPLATE"
fi

# --- Criar container ---
pct create "$CTID" "local:vztmpl/${TEMPLATE}" \
  -arch amd64 \
  -hostname "$HN" \
  -cores "$CPU" \
  -memory "$MEM" \
  -swap 512 \
  -rootfs "${STORAGE}:${DISK_SIZE}" \
  -net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  -features nesting=1,keyctl=1,fuse=1 \
  -unprivileged 1

# --- Detectar GPU ---
GPU_DRIVER="$(lspci -nnk | awk '/VGA|Display/{f=1} f && /Kernel driver in use/{print $5; exit}')"
GPU_KIND="UNKNOWN"
case "$GPU_DRIVER" in
  i915) GPU_KIND="INTEL" ;;
  amdgpu) GPU_KIND="AMD" ;;
  nvidia) GPU_KIND="NVIDIA" ;;
esac
echo -e "${YW}GPU detectada: $GPU_KIND ($GPU_DRIVER)${CL}"

# --- Passar devices ---
DEV_INDEX=0
add_dev() {
  local devpath="$1"
  if [ -e "$devpath" ]; then
    pct set "$CTID" -dev${DEV_INDEX} "${devpath},mode=0666" || true
    DEV_INDEX=$((DEV_INDEX+1))
  fi
}
if [[ "$GPU_KIND" == "INTEL" || "$GPU_KIND" == "AMD" ]]; then
  for d in /dev/dri/card* /dev/dri/renderD* /dev/kfd; do add_dev "$d"; done
elif [[ "$GPU_KIND" == "NVIDIA" ]]; then
  for d in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools; do add_dev "$d"; done
fi

# --- Iniciar container ---
pct start "$CTID"
sleep 5

# --- Instalar curl e rodar o script interno ---
pct exec "$CTID" -- bash -c "apt-get update && apt-get install -y curl"
pct exec "$CTID" -- bash -c "bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/rafaelfmuniz/proxmox-scripts/main/ct/docker-gpu.sh)\""

echo -e "${GN}==> Container criado e script interno iniciado.${CL}"
