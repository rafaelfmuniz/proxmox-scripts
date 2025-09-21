#!/usr/bin/env bash
# ----------------------------------------------------------------------------------
# Proxmox Host Helper - GPU/iGPU passthrough p/ LXC com detecção DINÂMICA de GIDs
# Autor: Rafael (adaptado)
# Uso (no host Proxmox):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/ct/gpu-pass.sh)"
#
# Variáveis opcionais:
#   CTID=<id>           # pula a pergunta do CTID
#   MODE=0660|0666      # permissão dos devices (padrão 0660)
#   ADD_KFD=1           # também passa /dev/kfd (p/ ROCm compute; pode quebrar boot em unprivileged)
#   SKIP_INSTALL=1      # não instala pacotes no CT
#   RUN_TESTS=0         # pula testes (vainfo/docker)
#   CLEAN_MATCH=1       # remove devX existentes que apontem para /dev/dri* ou /dev/kfd antes de adicionar
# ----------------------------------------------------------------------------------
set -euo pipefail
y=$'\033[33m'; g=$'\033[1;92m'; r=$'\033[01;31m'; c=$'\033[36m'; n=$'\033[0m'
info(){ echo -e "${y}>>${n} $*"; }
ok(){ echo -e "${g}✔${n} $*"; }
err(){ echo -e "${r}✖${n} $*" >&2; }

trap 'err "Falha na linha $LINENO"' ERR

command -v pct >/dev/null || { err "Rode no host Proxmox (pct não encontrado)."; exit 1; }
command -v lspci >/dev/null || { err "Instale pciutils (lspci)."; exit 1; }

MODE="${MODE:-0660}"
ADD_KFD="${ADD_KFD:-0}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
RUN_TESTS="${RUN_TESTS:-1}"
CLEAN_MATCH="${CLEAN_MATCH:-0}"

# --- Detectar GPU no host ---
info "Detectando GPU no host..."
DRV="$(lspci -nnk | awk '/VGA|Display/{f=1} f && /Kernel driver in use/{print $5; exit}')"
KIND="UNKNOWN"
case "${DRV:-}" in
  i915)   KIND="INTEL" ;;
  amdgpu) KIND="AMD" ;;
  nvidia) KIND="NVIDIA" ;;
esac
echo -e "  • driver: ${c}${DRV:-n/a}${n}  tipo: ${c}${KIND}${n}"

# --- Escolher CTID ---
if [ -z "${CTID:-}" ]; then
  info "Containers existentes:"
  pct list
  read -rp "Digite o CTID do LXC alvo: " CTID
fi
pct config "$CTID" >/dev/null 2>&1 || { err "CTID $CTID não existe."; exit 1; }

# --- Construir lista de devices do host a passar ---
PASS_DEV=()
if [ -d /dev/dri ]; then
  for d in /dev/dri/card* /dev/dri/renderD*; do [ -e "$d" ] && PASS_DEV+=("$d"); done
fi
if [ "$ADD_KFD" = "1" ] && [ -e /dev/kfd ]; then
  info "ATENÇÃO: /dev/kfd em LXC unprivileged pode impedir o boot sem ajustes cgroup."
  PASS_DEV+=("/dev/kfd")
fi
[ "${#PASS_DEV[@]}" -gt 0 ] || { err "Nenhum device /dev/dri encontrado no host."; exit 1; }

# --- Se pedido, limpar devX antigos que apontem p/ dri/kfd ---
if [ "$CLEAN_MATCH" = "1" ]; then
  info "Limpando devX antigos relacionados a /dev/dri ou /dev/kfd no CT $CTID..."
  while IFS= read -r line; do
    key="${line%%:*}"
    val="${line#*: }"
    if [[ "$val" =~ /dev/dri/|/dev/kfd ]]; then
      idx="${key#dev}"
      info "  - removendo $key ($val)"
      pct set "$CTID" -delete "$key" >/dev/null || true
    fi
  done < <(pct config "$CTID" | grep -E '^dev[0-9]+:' || true)
  ok "Limpeza feita."
fi

# --- Garantir que o CT está rodando (para consultar grupos internos) ---
WAS_RUNNING=0
if pct status "$CTID" | grep -q running; then
  WAS_RUNNING=1
else
  info "Iniciando CT $CTID para detectar GIDs internos..."
  pct start "$CTID" >/dev/null
  sleep 2
fi

# --- Obter (ou criar) GIDs corretos DENTRO do CT ---
ct_get_gid() {
  local grp="$1"
  pct exec "$CTID" -- bash -lc "
    set -e
    if ! getent group '$grp' >/dev/null 2>&1; then
      if command -v addgroup >/dev/null 2>&1; then addgroup --system '$grp' >/dev/null 2>&1 || true;
      elif command -v groupadd >/dev/null 2>&1; then groupadd -r '$grp' >/dev/null 2>&1 || true;
      fi
    fi
    getent group '$grp' | awk -F: '{print \$3}'
  " | tr -d '\r\n'
}

info "Descobrindo GIDs internos do CT..."
VID_GID="$(ct_get_gid video || true)"
REN_GID="$(ct_get_gid render || true)"
[ -n "$VID_GID" ] || { err "Não foi possível obter/criar grupo 'video' no CT."; exit 1; }
[ -n "$REN_GID" ] || { err "Não foi possível obter/criar grupo 'render' no CT."; exit 1; }
echo -e "  • video=${c}${VID_GID}${n}  render=${c}${REN_GID}${n}"

# --- Descobrir próximo índice devX ---
next_idx() {
  local m=-1 line
  while IFS= read -r line; do
    [[ "$line" =~ ^dev([0-9]+): ]] || continue
    (( ${BASH_REMATCH[1]} > m )) && m="${BASH_REMATCH[1]}"
  done < <(pct config "$CTID" | grep -E '^dev[0-9]+:' || true)
  echo $((m+1))
}

# --- Aplicar devices com GIDs do CT ---
info "Aplicando passthrough (mode=$MODE) com GIDs internos (video=$VID_GID / render=$REN_GID)..."
IDX="$(next_idx)"
for DEV in "${PASS_DEV[@]}"; do
  OPTS="mode=${MODE}"
  case "$DEV" in
    /dev/dri/card*)     OPTS+=",gid=${VID_GID}"  ;;
    /dev/dri/renderD*)  OPTS+=",gid=${REN_GID}"  ;;
    /dev/kfd)           OPTS+=",gid=${REN_GID}"  ;; # em geral 'render'; pode variar
  esac
  info "  - $DEV -> dev${IDX} ($OPTS)"
  pct set "$CTID" -dev${IDX} "${DEV},${OPTS}" >/dev/null
  IDX=$((IDX+1))
done
ok "Devices adicionados."

# --- Instalar pacotes dentro do CT (opcional) ---
if [ "$SKIP_INSTALL" != "1" ]; then
  info "Instalando pacotes dentro do CT..."
  pct exec "$CTID" -- bash -lc "set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get -y install curl ca-certificates vainfo || true
  "
  case "$KIND" in
    INTEL) pct exec "$CTID" -- bash -lc "apt-get -y install i965-va-driver intel-gpu-tools || true" ;;
    AMD)   pct exec "$CTID" -- bash -lc "apt-get -y install mesa-va-drivers mesa-vulkan-drivers radeontop || true" ;;
    NVIDIA)pct exec "$CTID" -- bash -lc "apt-get -y install nvidia-container-toolkit || true" ;;
  esac
  ok "Pacotes instalados."
else
  info "SKIP_INSTALL=1 → pulando instalação."
fi

# --- Testes (opcional) ---
if [ "$RUN_TESTS" = "1" ]; then
  info "Listando /dev/dri no CT:"
  pct exec "$CTID" -- bash -lc "ls -l /dev/dri || true"
  info "vainfo (primeiras linhas):"
  pct exec "$CTID" -- bash -lc "vainfo 2>&1 | sed -n '1,40p' || true"
  if pct exec "$CTID" -- bash -lc "command -v docker >/dev/null"; then
    case "$KIND" in
      INTEL|AMD|UNKNOWN)
        info "Teste Docker + VAAPI (ffmpeg -hwaccels):"
        pct exec "$CTID" -- bash -lc "docker run --rm --device /dev/dri/renderD128 jrottenberg/ffmpeg:6.1-vaapi ffmpeg -hwaccels || true"
        ;;
      NVIDIA)
        info "Teste Docker + NVIDIA (nvidia-smi):"
        pct exec "$CTID" -- bash -lc "docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi || true"
        ;;
    esac
  fi
fi

# --- Se estava parado antes, opcionalmente pare (mantemos rodando por padrão) ---
if [ "$WAS_RUNNING" -eq 0 ]; then
  info "CT estava parado antes; mantendo em execução (para você testar)."
fi

ok "Concluído! Use em containers Docker: --device /dev/dri/renderD128"
