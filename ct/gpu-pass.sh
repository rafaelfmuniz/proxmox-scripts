#!/usr/bin/env bash
# ----------------------------------------------------------------------------------
# Proxmox Host Helper - GPU/iGPU passthrough para LXC
# - Detecta GPU (Intel/AMD/NVIDIA)
# - Descobre GIDs de 'video' e 'render' dentro do CT (sem MOTD)
# - Para o CT corretamente, aplica devices com mode + gid corretos,
#   liga o CT e instala/testa pacotes se necessário.
#
# Uso:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/ct/gpu-pass.sh)"
#
# Variáveis opcionais:
#   CTID=<id>           # pula prompt de CTID
#   MODE=0660|0666      # permissão dos devices (padrão 0660)
#   ADD_KFD=1           # também passar /dev/kfd (ROCm compute) - pode quebrar boot em unprivileged
#   CLEAN_MATCH=1       # remove devX antigos que apontem p/ /dev/dri* ou /dev/kfd antes de adicionar
#   SKIP_INSTALL=1      # não instala pacotes no CT
#   RUN_TESTS=0         # não roda vainfo/docker no CT
# ----------------------------------------------------------------------------------
set -euo pipefail
Y=$'\033[33m'; G=$'\033[1;92m'; R=$'\033[01;31m'; C=$'\033[36m'; N=$'\033[0m'
info(){ echo -e "${Y}>>${N} $*"; }
ok(){   echo -e "${G}✔${N} $*"; }
err(){  echo -e "${R}✖${N} $*" >&2; }

trap 'err "Falha na linha $LINENO"' ERR

command -v pct >/dev/null || { err "Rode no host Proxmox (pct não encontrado)."; exit 1; }
command -v lspci >/dev/null || { err "Instale pciutils (lspci)."; exit 1; }

MODE="${MODE:-0660}"
ADD_KFD="${ADD_KFD:-0}"
CLEAN_MATCH="${CLEAN_MATCH:-0}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
RUN_TESTS="${RUN_TESTS:-1}"

# --- Detectar GPU no host ---
info "Detectando GPU no host..."
DRV="$(lspci -nnk | awk '/VGA|Display/{f=1} f && /Kernel driver in use/{print $5; exit}')"
KIND="UNKNOWN"
case "${DRV:-}" in
  i915)   KIND="INTEL" ;;
  amdgpu) KIND="AMD" ;;
  nvidia) KIND="NVIDIA" ;;
esac
echo -e "  • driver: ${C}${DRV:-n/a}${N}  tipo: ${C}${KIND}${N}"

# --- Escolher CTID ---
if [ -z "${CTID:-}" ]; then
  info "Containers existentes:"
  pct list
  read -rp "Digite o CTID alvo: " CTID
fi
pct config "$CTID" >/dev/null 2>&1 || { err "CTID $CTID não existe."; exit 1; }

# --- Devices do host ---
PASS_DEV=()
if [ -d /dev/dri ]; then
  for d in /dev/dri/card* /dev/dri/renderD*; do [ -e "$d" ] && PASS_DEV+=("$d"); done
fi
if [ "$ADD_KFD" = "1" ] && [ -e /dev/kfd ]; then
  info "ATENÇÃO: /dev/kfd em LXC unprivileged pode impedir boot sem ajustes extras."
  PASS_DEV+=("/dev/kfd")
fi
[ "${#PASS_DEV[@]}" -gt 0 ] || { err "Nenhum /dev/dri encontrado no host."; exit 1; }

# --- Garantir que o CT está rodando para checar grupos ---
WAS_RUNNING=0
if pct status "$CTID" | grep -q running; then
  WAS_RUNNING=1
else
  info "Iniciando CT $CTID temporariamente para verificar grupos..."
  pct start "$CTID" >/dev/null
  sleep 2
fi

# --- Obter/criar GIDs corretos no CT ---
ct_ensure_gid() {
  local grp="$1" gid=""
  if pct exec "$CTID" -- getent group "$grp" >/dev/null 2>&1; then
    gid="$(pct exec "$CTID" -- getent group "$grp" | cut -d: -f3 | tr -d '\r\n')"
  else
    pct exec "$CTID" -- sh -c "groupadd -r $grp || addgroup --system $grp" >/dev/null 2>&1 || true
    gid="$(pct exec "$CTID" -- getent group "$grp" | cut -d: -f3 | tr -d '\r\n')"
  fi
  echo -n "$gid"
}

info "Descobrindo/garantindo GIDs dentro do CT..."
VID_GID="$(ct_ensure_gid video)"
REN_GID="$(ct_ensure_gid render)"
[ -n "$VID_GID" ] || { err "Falha ao obter/criar grupo 'video'."; exit 1; }
[ -n "$REN_GID" ] || { err "Falha ao obter/criar grupo 'render'."; exit 1; }
echo -e "  • video=${C}${VID_GID}${N}  render=${C}${REN_GID}${N}"

# --- Parar CT de forma correta ---
info "Parando CT $CTID para aplicar configurações..."
if ! pct shutdown "$CTID" --timeout 30; then
  err "CT $CTID não respondeu ao shutdown gracioso em 30s. Abortei para evitar corrupção."
  exit 1
fi

# --- Limpeza opcional ---
if [ "$CLEAN_MATCH" = "1" ]; then
  info "Removendo devX antigos relacionados a dri/kfd..."
  while IFS= read -r line; do
    key="${line%%:*}"; val="${line#*: }"
    if [[ "$val" =~ /dev/dri/|/dev/kfd ]]; then
      info "  - removendo $key ($val)"
      pct set "$CTID" -delete "$key" >/dev/null || true
    fi
  done < <(pct config "$CTID" | grep -E '^dev[0-9]+:' || true)
  ok "Limpeza feita."
fi

# --- Descobrir próximo índice devX ---
next_idx() {
  local m=-1 line
  while IFS= read -r line; do
    [[ "$line" =~ ^dev([0-9]+): ]] || continue
    (( ${BASH_REMATCH[1]} > m )) && m="${BASH_REMATCH[1]}"
  done < <(pct config "$CTID" | grep -E '^dev[0-9]+:' || true)
  echo $((m+1))
}

# --- Aplicar devices ---
info "Aplicando passthrough (mode=$MODE) com GIDs (video=$VID_GID / render=$REN_GID)..."
IDX="$(next_idx)"
for DEV in "${PASS_DEV[@]}"; do
  OPTS="mode=${MODE}"
  case "$DEV" in
    /dev/dri/card*)    OPTS+=",gid=${VID_GID}" ;;
    /dev/dri/renderD*) OPTS+=",gid=${REN_GID}" ;;
    /dev/kfd)          OPTS+=",gid=${REN_GID}" ;;
  esac
  info "  - $DEV -> dev${IDX} ($OPTS)"
  pct set "$CTID" -dev${IDX} "${DEV},${OPTS}" >/dev/null
  IDX=$((IDX+1))
done
ok "Devices adicionados."

# --- Ligar CT novamente ---
info "Iniciando CT $CTID..."
pct start "$CTID" >/dev/null
sleep 2

# --- Instalar pacotes no CT ---
if [ "$SKIP_INSTALL" != "1" ]; then
  info "Instalando pacotes dentro do CT..."
  pct exec "$CTID" -- apt-get update
  pct exec "$CTID" -- apt-get -y install curl ca-certificates vainfo >/dev/null || true
  case "$KIND" in
    INTEL) pct exec "$CTID" -- apt-get -y install i965-va-driver intel-gpu-tools >/dev/null || true ;;
    AMD)   pct exec "$CTID" -- apt-get -y install mesa-va-drivers mesa-vulkan-drivers radeontop >/dev/null || true ;;
    NVIDIA)pct exec "$CTID" -- apt-get -y install nvidia-container-toolkit >/dev/null || true ;;
  esac
  ok "Pacotes instalados."
else
  info "SKIP_INSTALL=1 → pulando instalação no CT."
fi

# --- Testes ---
if [ "$RUN_TESTS" = "1" ]; then
  info "Listando /dev/dri no CT:"
  pct exec "$CTID" -- ls -l /dev/dri || true
  info "vainfo (primeiras linhas):"
  pct exec "$CTID" -- sh -c 'vainfo 2>&1 | sed -n "1,40p"' || true
fi

ok "Concluído! Use em containers Docker: --device /dev/dri/renderD128"
