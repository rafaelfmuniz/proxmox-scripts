#!/usr/bin/env bash
# Author: Rafael Muniz (based on community-scripts)
# License: MIT
# Source: https://www.docker.com/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Instalando pacotes base"
$STD apt-get install -y curl gnupg ca-certificates vainfo
msg_ok "Pacotes base instalados"

# Detectar GPU
GPU_KIND="UNKNOWN"
if ls /dev/dri/renderD128 &>/dev/null; then
  if vainfo 2>/dev/null | grep -qi intel; then GPU_KIND="INTEL"; fi
  if vainfo 2>/dev/null | grep -qi amd; then GPU_KIND="AMD"; fi
fi
if ls /dev/nvidia0 &>/dev/null; then GPU_KIND="NVIDIA"; fi

case "$GPU_KIND" in
  INTEL)
    msg_info "Instalando drivers Intel (VAAPI)"
    $STD apt-get install -y i965-va-driver
    msg_ok "Drivers Intel instalados"
    ;;
  AMD)
    msg_info "Instalando drivers AMD (Mesa)"
    $STD apt-get install -y mesa-va-drivers mesa-vulkan-drivers
    msg_ok "Drivers AMD instalados"
    ;;
  NVIDIA)
    msg_info "Instalando NVIDIA Container Toolkit"
    $STD apt-get install -y nvidia-container-toolkit || true
    msg_ok "Toolkit NVIDIA instalado"
    ;;
  *)
    msg_info "Nenhuma GPU detectada"
    ;;
esac

# Docker
DOCKER_LATEST_VERSION=$(curl -fsSL https://api.github.com/repos/moby/moby/releases/latest | grep '"tag_name":' | cut -d'"' -f4)
msg_info "Instalando Docker $DOCKER_LATEST_VERSION"
$STD sh <(curl -fsSL https://get.docker.com)
msg_ok "Docker $DOCKER_LATEST_VERSION instalado"

# Portainer opcional
read -r -p "${TAB3}Adicionar Portainer (UI)? <y/N> " prompt
if [[ ${prompt,,} =~ ^(y|yes)$ ]]; then
  msg_info "Instalando Portainer"
  docker volume create portainer_data >/dev/null
  $STD docker run -d \
    -p 8000:8000 \
    -p 9443:9443 \
    --name=portainer \
    --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest
  msg_ok "Portainer instalado"
fi

motd_ssh
customize

msg_info "Limpando"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Pronto!"
