#!/usr/bin/env bash
# Proxmox VE Helper Script (adaptado da comunidade)
# Criação interativa de LXC + chamada do instalador Docker-GPU

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Variáveis básicas (iguais ao original da comunidade)
default_settings() {
  var_os="debian"
  var_version="12"
  var_storage=$(pvesm status -content rootdir | awk 'NR==2 {print $1}')
  var_ctid=$(pvesh get /cluster/nextid)
  var_hostname="docker-gpu"
  var_cores="4"
  var_memory="4096"
  var_disk="20"
  var_bridge="vmbr0"
}

# Aqui é a diferença: em vez de pedir link do script,
# chamamos DIRETO o seu docker-gpu.sh no seu GitHub
run_post_create() {
  msg_info "Rodando instalador Docker-GPU dentro do container"
  pct exec $var_ctid -- bash -c "curl -fsSL https://raw.githubusercontent.com/rafaelfmuniz/proxmox-scripts/main/ct/docker-gpu.sh | bash"
  msg_ok "Instalador Docker-GPU executado"
}

# Chamadas padrão da comunidade
default_settings
start
build_container
basic_settings
network_settings
resources
mounts
dns
confirm_settings
create_container
post_create
