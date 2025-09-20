#!/usr/bin/env bash
# ----------------------------------------------------------------------------------
# Proxmox VE Helper Script
# LXC com Docker + Portainer + GPU passthrough (Intel/AMD/NVIDIA)
# Inspirado em: community-scripts/ProxmoxVE
# ----------------------------------------------------------------------------------
set -euo pipefail

# --- Cores ---
YW=$'\033[33m'; RD=$'\033[01;31m'; BL=$'\033[36m'; GN=$'\033[1;92m'; CL=$'\033[0m'

# --- Banner ---
echo -e "${GN}
─────────────────────────────────────────────
  Proxmox VE Helper Script
  LXC: Docker + Portainer + GPU passthrough
─────────────────────────────────────────────${CL}"

# =========================
# Parâmetros (overrides via env)
# =========================
CTID="${CTID:-250}"
HN="${HN:-docker-gpu}"
DISK_SIZE="${DISK_SIZE:-20G}"
MEM="${MEM:-4096}"
CPU="${CPU:-4}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local-lvm}"

# =========================
# Funções utilitárias
# =========================
die(){ echo -e "${RD}ERRO:${CL} $*" >&2; exit 1; }
info(){ echo -e "${YW}>>${CL} $*"; }
ok(){ echo -e "${GN}✔${CL} $*"; }

trap 'die "Falha na linha $LINENO"' ERR

# =========================
# Checar template Debian 12
# =========================
info "Verificando template Debian 12..."
TEMPLATE="$(pveam available -section system | awk '/debian-12-standard/ {print $2}' | sort -V | tail -n1)"
[ -n "$TEMPLATE" ] || die "Template Debian 12 não encontrado em pveam."

if ! pveam list local | awk '{print $2}' | grep -q "^${TEMPLATE}$"; then
  info "Baixando template ${TEMPLATE}..."
  pveam update
  pveam download local "$TEMPLATE"
fi
ok "Template pronto: $TEMPLATE"

# =========================
# Criar container
# =========================
info "Criando LXC CTID=${CTID} (${HN})..."
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
ok "LXC criado."

# =========================
# Detecção de GPU no host
# =========================
info "Detectando GPU no host..."
GPU_DRIVER="$(lspci -nnk | awk '/VGA|Display/{f=1} f && /Kernel driver in use/{print $5; exit}')"

GPU_KIND="NONE"
case "$GPU_DRIVER" in
  i915) GPU_KIND="INTEL" ;;
  amdgpu) GPU_KIND="AMD" ;;
  nvidia) GPU_KIND="NVIDIA" ;;
  *) GPU_KIND="UNKNOWN" ;;
esac

echo -e "${BL}GPU detectada:${CL} driver=${GPU_DRIVER:-n/a} tipo=${GPU_KIND}"

# =========================
# Adicionar passthrough de devices
# =========================
# Usamos mode=0666 para evitar problemas de idmap/ACL em unprivileged LXC.
# (Depois você pode trocar para 0660 e mapear grupos se quiser endurecer.)
info "Configurando passthrough de dispositivos de GPU..."

DEV_INDEX=0
add_dev() {
  local devpath="$1"
  if [ -e "$devpath" ]; then
    pct set "$CTID" -dev${DEV_INDEX} "${devpath},mode=0666" || true
    echo "  ↳ $devpath"
    DEV_INDEX=$((DEV_INDEX+1))
  fi
}

if [[ "$GPU_KIND" == "INTEL" || "$GPU_KIND" == "AMD" || "$GPU_KIND" == "UNKNOWN" ]]; then
  # Intel/AMD: devices em /dev/dri; AMD compute pode usar /dev/kfd
  if [ -d /dev/dri ]; then
    for d in /dev/dri/card* /dev/dri/renderD*; do
      [ -e "$d" ] && add_dev "$d"
    done
  fi
  add_dev /dev/kfd
elif [[ "$GPU_KIND" == "NVIDIA" ]]; then
  # NVIDIA: requer driver no host e /dev/nvidia* existentes
  for d in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
    [ -e "$d" ] && add_dev "$d"
  done
fi
ok "Devices de GPU adicionados (se existentes)."

# =========================
# Iniciar container
# =========================
info "Iniciando container..."
pct start "$CTID"
sleep 5
ok "Container iniciado."

# =========================
# Instalar Docker + Portainer + drivers de vídeo
# =========================
info "Instalando Docker/Portainer e drivers de vídeo no LXC..."

INSTALL_CMDS='
  set -eux
  export DEBIAN_FRONTEND=noninteractive

  # Base
  apt-get update
  apt-get -y upgrade
  apt-get -y install curl gnupg ca-certificates lsb-release apt-transport-https

  # Docker CE repo (Debian 12 / bookworm)
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get -y install docker-ce docker-ce-cli containerd.io

  # Portainer
  docker run -d -p 9000:9000 --name=portainer --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock portainer/portainer-ce
'

case "$GPU_KIND" in
  INTEL)
    INSTALL_CMDS+='
      apt-get -y install vainfo i965-va-driver
      echo ">>> (INTEL) Instalado i965-va-driver + vainfo"
    '
    ;;
  AMD)
    INSTALL_CMDS+='
      apt-get -y install vainfo mesa-va-drivers mesa-vulkan-drivers
      echo ">>> (AMD) Instalado mesa-va-drivers + mesa-vulkan-drivers + vainfo"
    '
    ;;
  NVIDIA)
    INSTALL_CMDS+='
      apt-get -y install gpg
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
      distribution=$(. /etc/os-release; echo $ID$VERSION_CODENAME)
      curl -fsSL https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list \
        | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" \
        | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
      apt-get update
      apt-get -y install nvidia-container-toolkit
      nvidia-ctk runtime configure --runtime=docker || true
      systemctl restart docker || true
      echo ">>> (NVIDIA) Instalado nvidia-container-toolkit"
    '
    ;;
  *)
    INSTALL_CMDS+='
      echo ">>> GPU desconhecida/não detectada — seguindo sem instalar drivers específicos"
    '
    ;;
esac

pct exec "$CTID" -- bash -lc "$INSTALL_CMDS"
ok "Docker, Portainer e drivers configurados."

# =========================
# Teste básico (opcional)
# =========================
IP=$(pct exec "$CTID" -- bash -lc "hostname -I | awk \"{print \\$1}\"" || true)

info "Teste rápido do VA-API (se aplicável):"
pct exec "$CTID" -- bash -lc "command -v vainfo >/dev/null 2>&1 && vainfo | sed -n '1,30p' || echo 'vainfo não instalado/sem VAAPI' " || true

# =========================
# Mensagem final
# =========================
echo -e "${GN}
─────────────────────────────────────────────
  Concluído!
  • CTID: ${CTID}
  • Hostname: ${HN}
  • Acesse Portainer: ${BL}http://${IP:-<IP-do-container>}:9000${CL}

  Observações:
  • Intel/AMD: dispositivos /dev/dri foram expostos (mode=0666).
    Use VA-API nos containers Docker com: --device=/dev/dri/renderD128
  • NVIDIA: /dev/nvidia* expostos (se presentes) e nvidia-container-toolkit instalado.
    Use nos containers: --gpus all
─────────────────────────────────────────────${CL}
"
