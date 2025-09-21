#!/usr/bin/env bash
# ----------------------------------------------------------------------------------
# Proxmox Host Helper - GPU/iGPU passthrough para LXC + setup dentro do CT
# Autor: você :)
# Uso:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/ct/gpu-pass.sh)"
#
# Variáveis opcionais:
#   CTID=<id>           # pula a pergunta de CTID
#   MODE=0666|0660      # permissões dos devices (padrão 0666)
#   SKIP_INSTALL=1      # não instala pacotes dentro do CT (só passa devices)
#   RUN_TESTS=0|1       # roda testes (vainfo, docker) no CT (padrão 1)
# ----------------------------------------------------------------------------------
set -euo pipefail

# ======== Helpers de saída ========
clr_y="\033[33m"; clr_g="\033[1;92m"; clr_r="\033[01;31m"; clr_c="\033[36m"; clr_n="\033[0m"
info(){ echo -e "${clr_y}>>${clr_n} $*"; }
ok(){   echo -e "${clr_g}✔${clr_n} $*"; }
err(){  echo -e "${clr_r}✖${clr_n} $*" >&2; }

trap 'err "Falha na linha $LINENO"; exit 1' ERR

# ======== Pré-checagens ========
command -v pct >/dev/null || { err "Este script deve rodar no host Proxmox (pct não encontrado)."; exit 1; }
command -v lspci >/dev/null || { err "lspci não encontrado (instale pciutils no host)."; exit 1; }

MODE="${MODE:-0666}"
RUN_TESTS="${RUN_TESTS:-1}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"

# ======== Detectar GPU no host ========
info "Detectando GPU no host..."
GPU_DRIVER="$(lspci -nnk | awk '/VGA|Display/{flag=1} flag && /Kernel driver in use/{print $5; exit}')"
GPU_KIND="UNKNOWN"
case "${GPU_DRIVER:-}" in
  i915)   GPU_KIND="INTEL" ;;
  amdgpu) GPU_KIND="AMD" ;;
  nvidia) GPU_KIND="NVIDIA" ;;
esac
echo -e "  • driver: ${clr_c}${GPU_DRIVER:-n/a}${clr_n}  tipo: ${clr_c}${GPU_KIND}${clr_n}"

# listar devices que existem
DEV_PRESENT=()
if [ -d /dev/dri ]; then
  for d in /dev/dri/card* /dev/dri/renderD*; do [ -e "$d" ] && DEV_PRESENT+=("$d"); done
fi
for d in /dev/kfd /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
  [ -e "$d" ] && DEV_PRESENT+=("$d")
done
echo -e "  • devices visíveis: ${clr_c}${DEV_PRESENT[*]:-(nenhum)}${clr_n}"

# ======== Escolher CTID ========
if [ -z "${CTID:-}" ]; then
  info "Containers existentes:"
  pct list
  read -rp "Digite o CTID do LXC que receberá a GPU: " CTID
fi
pct config "$CTID" >/dev/null 2>&1 || { err "CTID $CTID não existe."; exit 1; }

# ======== Montar lista de devices a passar ========
PASS_DEV=()
case "$GPU_KIND" in
  INTEL|AMD|UNKNOWN)
    # /dev/dri* (VAAPI) e /dev/kfd (AMD ROCm)
    [ -d /dev/dri ] && for d in /dev/dri/card* /dev/dri/renderD*; do [ -e "$d" ] && PASS_DEV+=("$d"); done
    [ -e /dev/kfd ] && PASS_DEV+=("/dev/kfd")
    ;;
  NVIDIA)
    # devices NVIDIA
    for d in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools; do [ -e "$d" ] && PASS_DEV+=("$d"); done
    # se existir /dev/dri também (alguns setups), pode passar junto
    [ -d /dev/dri ] && for d in /dev/dri/card* /dev/dri/renderD*; do [ -e "$d" ] && PASS_DEV+=("$d"); done
    ;;
esac

if [ "${#PASS_DEV[@]}" -eq 0 ]; then
  err "Nenhum device compatível encontrado no host. Verifique drivers e VFIO/uso por VMs."
  exit 1
fi

# ======== Descobrir próximo índice devX livre na config do CT ========
next_dev_index() {
  local max=-1 line key
  while IFS= read -r line; do
    key="${line%%:*}"
    if [[ "$key" =~ ^dev([0-9]+)$ ]]; then
      idx="${BASH_REMATCH[1]}"
      [[ $idx -gt $max ]] && max="$idx"
    fi
  done < <(pct config "$CTID" | grep -E '^dev[0-9]+:' || true)
  echo $((max+1))
}

# ======== Aplicar passthrough ========
info "Aplicando passthrough para CT $CTID (mode=$MODE)..."
idx="$(next_dev_index)"
for dev in "${PASS_DEV[@]}"; do
  info "  - adicionando $dev -> dev$idx"
  pct set "$CTID" -dev${idx} "${dev},mode=${MODE}" >/dev/null
  idx=$((idx+1))
done
ok "Devices adicionados ao CT $CTID."

# ======== Garantir que o CT está rodando ========
if ! pct status "$CTID" | grep -q running; then
  info "Iniciando CT $CTID..."
  pct start "$CTID" >/dev/null
  sleep 3
fi

# ======== (Opcional) instalar pacotes no CT ========
if [ "$SKIP_INSTALL" != "1" ]; then
  info "Instalando pacotes dentro do CT $CTID (isso pode levar alguns minutos)..."
  pct exec "$CTID" -- bash -lc "set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get -y install curl ca-certificates vainfo || true
  "
  case "$GPU_KIND" in
    INTEL)
      pct exec "$CTID" -- bash -lc "apt-get -y install i965-va-driver intel-gpu-tools || true"
      ;;
    AMD)
      pct exec "$CTID" -- bash -lc "apt-get -y install mesa-va-drivers mesa-vulkan-drivers radeontop || true"
      ;;
    NVIDIA)
      # tenta toolkit; se não houver repo, ignora
      pct exec "$CTID" -- bash -lc "apt-get -y install nvidia-container-toolkit || true"
      ;;
  esac
  ok "Pacotes básicos instalados no CT."
else
  info "SKIP_INSTALL=1 → pulando instalação dentro do CT."
fi

# ======== Testes ========
if [ "$RUN_TESTS" = "1" ]; then
  info "Testando /dev/dri dentro do CT:"
  pct exec "$CTID" -- bash -lc "ls -l /dev/dri || true"

  info "Executando 'vainfo' (primeiras linhas):"
  pct exec "$CTID" -- bash -lc "vainfo 2>&1 | sed -n '1,30p' || true"

  # teste docker se existir
  if pct exec "$CTID" -- bash -lc "command -v docker >/dev/null"; then
    case "$GPU_KIND" in
      INTEL|AMD|UNKNOWN)
        info "Testando Docker + VAAPI (ffmpeg -hwaccels):"
        pct exec "$CTID" -- bash -lc "docker run --rm --device /dev/dri/renderD128 jrottenberg/ffmpeg:6.1-vaapi ffmpeg -hwaccels || true"
        ;;
      NVIDIA)
        info "Testando Docker + NVIDIA (nvidia-smi):"
        pct exec "$CTID" -- bash -lc "docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi || true"
        ;;
    esac
  else
    info "Docker não encontrado no CT — pulando teste Docker."
  fi
else
  info "RUN_TESTS=0 → pulando testes."
fi

ok "Pronto! GPU '${GPU_KIND}' passada para CT ${CTID} e validada."
echo -e "${clr_c}Dica:${clr_n} em containers Docker use:
  • Intel/AMD VAAPI:  --device /dev/dri/renderD128
  • NVIDIA:           --gpus all"
