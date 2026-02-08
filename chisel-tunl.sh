#!/usr/bin/env bash

set +e
set +u

declare -a LOG_LINES=()
MENU_SELECTED=""
CHISEL_VERSION="1.9.1"
CHISEL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/chisel"
LIMIT_DIR="/etc/chisel-limits"

banner() {
  cat <<'EOF'
╔═════════════════════════════════════════════════════════════════╗
║                                                                 ║
║     ██████╗██╗  ██╗██╗███████╗███████╗██╗                      ║
║    ██╔════╝██║  ██║██║██╔════╝██╔════╝██║                      ║
║    ██║     ███████║██║███████╗█████╗  ██║                      ║
║    ██║     ██╔══██║██║╚════██║██╔══╝  ██║                      ║
║    ╚██████╗██║  ██║██║███████║███████╗███████╗                 ║
║     ╚═════╝╚═╝  ╚═╝╚═╝╚══════╝╚══════╝╚══════╝                 ║
║                                                                 ║
║           CHISEL TUNL - Anti-Filter Tunnel Manager              ║
║                                                                 ║
╚═════════════════════════════════════════════════════════════════╝
EOF
}

add_log() {
  local msg="$1"
  local ts
  ts="$(date +"%H:%M:%S")"
  LOG_LINES+=("[${ts}] ${msg}")
  if (( ${#LOG_LINES[@]} > 10 )); then
    LOG_LINES=("${LOG_LINES[@]:1}")
  fi
}

render() {
  clear
  banner
  echo
  local height=10
  local start_index=0
  if (( ${#LOG_LINES[@]} > height )); then
    start_index=$((${#LOG_LINES[@]} - height))
  fi
  echo "┌───────────────────────────── ACTION LOG ─────────────────────────────┐"
  for (( i=start_index; i<${#LOG_LINES[@]}; i++ )); do
    printf "│ %-68s │\n" "${LOG_LINES[$i]}"
  done
  local remaining=$((height - (${#LOG_LINES[@]} - start_index)))
  for (( j=0; j<remaining; j++ )); do
    printf "│ %-68s │\n" ""
  done
  echo "└──────────────────────────────────────────────────────────────────────┘"
  echo
}

trim() {
  local var="$1"
  var="${var#"${var%%[![:space:]]*}"}"
  var="${var%"${var##*[![:space:]]}"}"
  echo -n "$var"
}

die_soft() {
  add_log "ERROR: $1"
  render
  echo "$1"
  pause_enter
}

pause_enter() {
  echo
  read -r -p "Press ENTER to continue..."
}

valid_ip() {
  local ip="$1"
  local IFS='.'
  read -r -a octets <<< "$ip"
  [[ ${#octets[@]} -ne 4 ]] && return 1
  for o in "${octets[@]}"; do
    [[ ! "$o" =~ ^[0-9]+$ ]] && return 1
    (( o < 0 || o > 255 )) && return 1
  done
  return 0
}

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo)."
    exit 1
  fi
}

# ==================== CHISEL INSTALLATION ====================

install_chisel() {
  add_log "Installing Chisel v${CHISEL_VERSION}..."
  render
  
  local arch=""
  case "$(uname -m)" in
    x86_64) arch="amd64" ;;
    aarch64) arch="arm64" ;;
    armv7l) arch="armv7" ;;
    *) die_soft "Unsupported architecture: $(uname -m)"; return 1 ;;
  esac
  
  local url="https://github.com/jpillora/chisel/releases/download/v${CHISEL_VERSION}/chisel_${CHISEL_VERSION}_linux_${arch}.gz"
  
  add_log "Downloading from GitHub..."
  render
  
  if ! curl -fsSL "$url" -o /tmp/chisel.gz; then
    die_soft "Failed to download Chisel"
    return 1
  fi
  
  gunzip -f /tmp/chisel.gz
  chmod +x /tmp/chisel
  mv /tmp/chisel "${CHISEL_DIR}/chisel"
  
  if [[ -x "${CHISEL_DIR}/chisel" ]]; then
    add_log "Chisel installed successfully!"
    return 0
  else
    die_soft "Chisel installation failed"
    return 1
  fi
}

is_chisel_installed() {
  [[ -x "${CHISEL_DIR}/chisel" ]]
}

# ==================== PORT PARSING ====================

parse_ports() {
  local raw="$1"
  local -a result=()
  raw="${raw// /}"
  
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    valid_port "$raw" && result+=("$raw")
  elif [[ "$raw" =~ ^[0-9]+-[0-9]+$ ]]; then
    local s="${raw%-*}"
    local e="${raw#*-}"
    if valid_port "$s" && valid_port "$e" && ((s<=e)); then
      for ((p=s; p<=e; p++)); do result+=("$p"); done
    fi
  elif [[ "$raw" =~ ^[0-9]+(,[0-9]+)+$ ]]; then
    IFS=',' read -r -a parts <<< "$raw"
    for part in "${parts[@]}"; do
      valid_port "$part" && result+=("$part")
    done
  fi
  
  printf "%s\n" "${result[@]}" | sort -n | uniq
}

# ==================== SERVICE MANAGEMENT ====================

create_server_service() {
  local id="$1"
  local port="$2"
  local auth="$3"
  
  mkdir -p "$CONFIG_DIR"
  
  cat > "/etc/systemd/system/chisel-server-${id}.service" <<EOF
[Unit]
Description=Chisel Server ${id}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStart=${CHISEL_DIR}/chisel server --port ${port} --reverse --auth ${auth}

[Install]
WantedBy=multi-user.target
EOF

  # Save config
  cat > "${CONFIG_DIR}/server-${id}.conf" <<EOF
ID=${id}
PORT=${port}
AUTH=${auth}
TYPE=server
EOF

  systemctl daemon-reload
  systemctl enable "chisel-server-${id}.service" >/dev/null 2>&1
  systemctl start "chisel-server-${id}.service"
  
  add_log "Chisel Server ${id} started on port ${port}"
}

create_client_service() {
  local id="$1"
  local server_ip="$2"
  local server_port="$3"
  local auth="$4"
  shift 4
  local -a ports=("$@")
  
  mkdir -p "$CONFIG_DIR"
  
  # Build remote string
  local remotes=""
  for p in "${ports[@]}"; do
    remotes+="R:0.0.0.0:${p}:localhost:${p} "
  done
  
  cat > "/etc/systemd/system/chisel-client-${id}.service" <<EOF
[Unit]
Description=Chisel Client ${id}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStart=${CHISEL_DIR}/chisel client --auth ${auth} http://${server_ip}:${server_port} ${remotes}

[Install]
WantedBy=multi-user.target
EOF

  # Save config
  cat > "${CONFIG_DIR}/client-${id}.conf" <<EOF
ID=${id}
SERVER_IP=${server_ip}
SERVER_PORT=${server_port}
AUTH=${auth}
PORTS=${ports[*]}
TYPE=client
EOF

  systemctl daemon-reload
  systemctl enable "chisel-client-${id}.service" >/dev/null 2>&1
  systemctl start "chisel-client-${id}.service"
  
  add_log "Chisel Client ${id} connected to ${server_ip}:${server_port}"
}

# ==================== KHAREJ (SERVER) SETUP ====================

kharej_setup() {
  render
  add_log "Selected: KHAREJ (Server) Setup"
  render
  
  # Get Tunnel ID
  local id=""
  while true; do
    read -r -e -p "Tunnel ID (1-99): " id
    id="$(trim "$id")"
    if [[ "$id" =~ ^[0-9]+$ ]] && ((id >= 1 && id <= 99)); then
      break
    fi
    add_log "Invalid ID: $id"
  done
  
  # Get Server Port
  local port=""
  while true; do
    read -r -e -p "Chisel Server Port (default: 8080): " port
    port="$(trim "$port")"
    [[ -z "$port" ]] && port="8080"
    if valid_port "$port"; then
      break
    fi
    add_log "Invalid port: $port"
  done
  
  # Generate Auth
  local auth=""
  read -r -e -p "Auth (user:pass) or ENTER for random: " auth
  auth="$(trim "$auth")"
  if [[ -z "$auth" ]]; then
    auth="chisel$(openssl rand -hex 4):$(openssl rand -hex 8)"
    add_log "Generated Auth: $auth"
  fi
  
  render
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                    KHAREJ SERVER CONFIGURATION                     │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  printf "│ %-67s │\n" "Tunnel ID: ${id}"
  printf "│ %-67s │\n" "Server Port: ${port}"
  printf "│ %-67s │\n" "Auth: ${auth}"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  printf "│ %-67s │\n" "SAVE THIS AUTH! You need it for IRAN setup."
  echo "└─────────────────────────────────────────────────────────────────────┘"
  echo
  
  read -r -e -p "Confirm? (YES/NO): " confirm
  [[ "$confirm" != "YES" ]] && return 0
  
  # Install Chisel
  if ! is_chisel_installed; then
    install_chisel || return 0
  fi
  
  # Create service
  create_server_service "$id" "$port" "$auth"
  
  render
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                    KHAREJ SERVER READY!                            │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  printf "│ %-67s │\n" "Status: $(systemctl is-active chisel-server-${id}.service)"
  printf "│ %-67s │\n" ""
  printf "│ %-67s │\n" "For IRAN setup, use:"
  printf "│ %-67s │\n" "  Server IP: YOUR_KHAREJ_IP"
  printf "│ %-67s │\n" "  Server Port: ${port}"
  printf "│ %-67s │\n" "  Auth: ${auth}"
  echo "└─────────────────────────────────────────────────────────────────────┘"
  
  pause_enter
}

# ==================== IRAN (CLIENT) SETUP ====================

iran_setup() {
  render
  add_log "Selected: IRAN (Client) Setup"
  render
  
  # Get Tunnel ID
  local id=""
  while true; do
    read -r -e -p "Tunnel ID (same as KHAREJ): " id
    id="$(trim "$id")"
    if [[ "$id" =~ ^[0-9]+$ ]] && ((id >= 1 && id <= 99)); then
      break
    fi
    add_log "Invalid ID: $id"
  done
  
  # Get Server IP
  local server_ip=""
  while true; do
    read -r -e -p "KHAREJ Server IP: " server_ip
    server_ip="$(trim "$server_ip")"
    if valid_ip "$server_ip"; then
      break
    fi
    add_log "Invalid IP: $server_ip"
  done
  
  # Get Server Port
  local server_port=""
  while true; do
    read -r -e -p "KHAREJ Server Port (default: 8080): " server_port
    server_port="$(trim "$server_port")"
    [[ -z "$server_port" ]] && server_port="8080"
    if valid_port "$server_port"; then
      break
    fi
    add_log "Invalid port: $server_port"
  done
  
  # Get Auth
  local auth=""
  while true; do
    read -r -e -p "Auth (from KHAREJ setup): " auth
    auth="$(trim "$auth")"
    if [[ -n "$auth" ]] && [[ "$auth" == *":"* ]]; then
      break
    fi
    add_log "Invalid auth format. Use user:pass"
  done
  
  # Get Ports to forward
  local ports_raw=""
  local -a ports=()
  while true; do
    read -r -e -p "Forward Ports (80 | 80,443 | 2050-2060): " ports_raw
    ports_raw="$(trim "$ports_raw")"
    mapfile -t ports < <(parse_ports "$ports_raw")
    if ((${#ports[@]} > 0)); then
      break
    fi
    add_log "Invalid ports: $ports_raw"
  done
  
  render
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                    IRAN CLIENT CONFIGURATION                       │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  printf "│ %-67s │\n" "Tunnel ID: ${id}"
  printf "│ %-67s │\n" "Server: ${server_ip}:${server_port}"
  printf "│ %-67s │\n" "Auth: ${auth}"
  printf "│ %-67s │\n" "Ports: ${ports[*]}"
  echo "└─────────────────────────────────────────────────────────────────────┘"
  echo
  
  read -r -e -p "Confirm? (YES/NO): " confirm
  [[ "$confirm" != "YES" ]] && return 0
  
  # Install Chisel
  if ! is_chisel_installed; then
    install_chisel || return 0
  fi
  
  # Create service
  create_client_service "$id" "$server_ip" "$server_port" "$auth" "${ports[@]}"
  
  sleep 2
  
  render
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                    IRAN CLIENT READY!                              │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  printf "│ %-67s │\n" "Status: $(systemctl is-active chisel-client-${id}.service)"
  printf "│ %-67s │\n" ""
  printf "│ %-67s │\n" "Forwarded Ports: ${ports[*]}"
  printf "│ %-67s │\n" ""
  printf "│ %-67s │\n" "Traffic: IRAN:PORT <---> KHAREJ:PORT"
  echo "└─────────────────────────────────────────────────────────────────────┘"
  
  pause_enter
}

# ==================== ADD PORT ====================

add_port() {
  render
  add_log "Selected: Add Port"
  render
  
  # Find client configs
  local -a configs=()
  for f in "${CONFIG_DIR}"/client-*.conf; do
    [[ -f "$f" ]] && configs+=("$f")
  done
  
  if ((${#configs[@]} == 0)); then
    die_soft "No client tunnels found. Setup IRAN first."
    return 0
  fi
  
  # List tunnels
  echo "Available tunnels:"
  local i=1
  for f in "${configs[@]}"; do
    source "$f"
    echo "  ${i}) Tunnel ${ID} -> ${SERVER_IP}:${SERVER_PORT}"
    ((i++))
  done
  echo
  
  local sel=""
  read -r -e -p "Select tunnel: " sel
  sel="$(trim "$sel")"
  
  if ! [[ "$sel" =~ ^[0-9]+$ ]] || ((sel < 1 || sel > ${#configs[@]})); then
    die_soft "Invalid selection"
    return 0
  fi
  
  source "${configs[$((sel-1))]}"
  
  # Get new ports
  local ports_raw=""
  local -a new_ports=()
  while true; do
    read -r -e -p "New ports to add (80 | 80,443 | 2050-2060): " ports_raw
    ports_raw="$(trim "$ports_raw")"
    mapfile -t new_ports < <(parse_ports "$ports_raw")
    if ((${#new_ports[@]} > 0)); then
      break
    fi
    add_log "Invalid ports"
  done
  
  # Merge ports
  local -a all_ports=($PORTS "${new_ports[@]}")
  mapfile -t all_ports < <(printf "%s\n" "${all_ports[@]}" | sort -n | uniq)
  
  # Update service
  systemctl stop "chisel-client-${ID}.service" >/dev/null 2>&1
  create_client_service "$ID" "$SERVER_IP" "$SERVER_PORT" "$AUTH" "${all_ports[@]}"
  
  add_log "Ports added: ${new_ports[*]}"
  
  render
  echo "Ports added successfully!"
  echo "Current ports: ${all_ports[*]}"
  pause_enter
}

# ==================== REMOVE PORT ====================

remove_port() {
  render
  add_log "Selected: Remove Port"
  render
  
  # Find client configs
  local -a configs=()
  for f in "${CONFIG_DIR}"/client-*.conf; do
    [[ -f "$f" ]] && configs+=("$f")
  done
  
  if ((${#configs[@]} == 0)); then
    die_soft "No client tunnels found."
    return 0
  fi
  
  # List tunnels
  echo "Available tunnels:"
  local i=1
  for f in "${configs[@]}"; do
    source "$f"
    echo "  ${i}) Tunnel ${ID} - Ports: ${PORTS}"
    ((i++))
  done
  echo
  
  local sel=""
  read -r -e -p "Select tunnel: " sel
  sel="$(trim "$sel")"
  
  if ! [[ "$sel" =~ ^[0-9]+$ ]] || ((sel < 1 || sel > ${#configs[@]})); then
    die_soft "Invalid selection"
    return 0
  fi
  
  source "${configs[$((sel-1))]}"
  
  echo "Current ports: ${PORTS}"
  
  # Get ports to remove
  local ports_raw=""
  local -a remove_ports=()
  while true; do
    read -r -e -p "Ports to remove: " ports_raw
    ports_raw="$(trim "$ports_raw")"
    mapfile -t remove_ports < <(parse_ports "$ports_raw")
    if ((${#remove_ports[@]} > 0)); then
      break
    fi
    add_log "Invalid ports"
  done
  
  # Filter ports
  local -a current_ports=($PORTS)
  local -a new_ports=()
  for p in "${current_ports[@]}"; do
    local keep=1
    for rp in "${remove_ports[@]}"; do
      [[ "$p" == "$rp" ]] && keep=0 && break
    done
    ((keep)) && new_ports+=("$p")
  done
  
  if ((${#new_ports[@]} == 0)); then
    die_soft "Cannot remove all ports. Use Uninstall instead."
    return 0
  fi
  
  # Update service
  systemctl stop "chisel-client-${ID}.service" >/dev/null 2>&1
  create_client_service "$ID" "$SERVER_IP" "$SERVER_PORT" "$AUTH" "${new_ports[@]}"
  
  add_log "Ports removed: ${remove_ports[*]}"
  
  render
  echo "Ports removed successfully!"
  echo "Current ports: ${new_ports[*]}"
  pause_enter
}

# ==================== SERVICES MANAGEMENT ====================

services_management() {
  local sel=""
  
  while true; do
    render
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│                    SERVICES MANAGEMENT                             │"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo
    echo "1) View Status"
    echo "2) Start All"
    echo "3) Stop All"
    echo "4) Restart All"
    echo "0) Back"
    echo
    read -r -e -p "Select: " sel
    sel="$(trim "$sel")"
    
    case "$sel" in
      1)
        render
        echo "=== Chisel Services ==="
        systemctl list-units --type=service | grep chisel || echo "No chisel services found"
        pause_enter
        ;;
      2)
        for f in "${CONFIG_DIR}"/*.conf; do
          [[ -f "$f" ]] || continue
          source "$f"
          if [[ "$TYPE" == "server" ]]; then
            systemctl start "chisel-server-${ID}.service" 2>/dev/null
          else
            systemctl start "chisel-client-${ID}.service" 2>/dev/null
          fi
        done
        add_log "All services started"
        ;;
      3)
        systemctl stop 'chisel-*' 2>/dev/null || true
        for f in "${CONFIG_DIR}"/*.conf; do
          [[ -f "$f" ]] || continue
          source "$f"
          if [[ "$TYPE" == "server" ]]; then
            systemctl stop "chisel-server-${ID}.service" 2>/dev/null
          else
            systemctl stop "chisel-client-${ID}.service" 2>/dev/null
          fi
        done
        add_log "All services stopped"
        ;;
      4)
        for f in "${CONFIG_DIR}"/*.conf; do
          [[ -f "$f" ]] || continue
          source "$f"
          if [[ "$TYPE" == "server" ]]; then
            systemctl restart "chisel-server-${ID}.service" 2>/dev/null
          else
            systemctl restart "chisel-client-${ID}.service" 2>/dev/null
          fi
        done
        add_log "All services restarted"
        ;;
      0) return 0 ;;
      *) add_log "Invalid selection" ;;
    esac
  done
}

# ==================== UNINSTALL ====================

uninstall_clean() {
  render
  add_log "Selected: Uninstall & Clean"
  render
  
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                    UNINSTALL & CLEAN                               │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  printf "│ %-67s │\n" "This will remove:"
  printf "│ %-67s │\n" "  - All Chisel services"
  printf "│ %-67s │\n" "  - All configurations"
  printf "│ %-67s │\n" "  - Chisel binary"
  echo "└─────────────────────────────────────────────────────────────────────┘"
  echo
  
  read -r -e -p "Type YES to confirm: " confirm
  [[ "$confirm" != "YES" ]] && return 0
  
  # Stop and remove services
  for f in "${CONFIG_DIR}"/*.conf; do
    [[ -f "$f" ]] || continue
    source "$f"
    if [[ "$TYPE" == "server" ]]; then
      systemctl stop "chisel-server-${ID}.service" 2>/dev/null
      systemctl disable "chisel-server-${ID}.service" 2>/dev/null
      rm -f "/etc/systemd/system/chisel-server-${ID}.service"
    else
      systemctl stop "chisel-client-${ID}.service" 2>/dev/null
      systemctl disable "chisel-client-${ID}.service" 2>/dev/null
      rm -f "/etc/systemd/system/chisel-client-${ID}.service"
    fi
  done
  
  systemctl daemon-reload
  
  # Remove configs
  rm -rf "$CONFIG_DIR"
  rm -rf "$LIMIT_DIR"
  
  # Remove binary
  rm -f "${CHISEL_DIR}/chisel"
  
  add_log "Uninstall complete!"
  
  render
  echo "Chisel has been completely removed."
  pause_enter
}

# ==================== VIEW TUNNEL INFO ====================

view_tunnels() {
  render
  add_log "Viewing tunnel information"
  render
  
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                    TUNNEL INFORMATION                              │"
  echo "└─────────────────────────────────────────────────────────────────────┘"
  echo
  
  local found=0
  
  for f in "${CONFIG_DIR}"/*.conf; do
    [[ -f "$f" ]] || continue
    found=1
    source "$f"
    
    if [[ "$TYPE" == "server" ]]; then
      local status=$(systemctl is-active "chisel-server-${ID}.service" 2>/dev/null || echo "inactive")
      echo "┌─────────────────────────────────────────────────────────────────────┐"
      printf "│ %-67s │\n" "KHAREJ SERVER - Tunnel ${ID}"
      echo "├─────────────────────────────────────────────────────────────────────┤"
      printf "│ %-67s │\n" "Status: ${status}"
      printf "│ %-67s │\n" "Port: ${PORT}"
      printf "│ %-67s │\n" "Auth: ${AUTH}"
      echo "└─────────────────────────────────────────────────────────────────────┘"
    else
      local status=$(systemctl is-active "chisel-client-${ID}.service" 2>/dev/null || echo "inactive")
      echo "┌─────────────────────────────────────────────────────────────────────┐"
      printf "│ %-67s │\n" "IRAN CLIENT - Tunnel ${ID}"
      echo "├─────────────────────────────────────────────────────────────────────┤"
      printf "│ %-67s │\n" "Status: ${status}"
      printf "│ %-67s │\n" "Server: ${SERVER_IP}:${SERVER_PORT}"
      printf "│ %-67s │\n" "Ports: ${PORTS}"
      echo "└─────────────────────────────────────────────────────────────────────┘"
    fi
    echo
  done
  
  if ((found == 0)); then
    echo "No tunnels configured."
  fi
  
  pause_enter
}

# ==================== MAIN MENU ====================

main_menu() {
  local choice=""
  while true; do
    render
    echo "1 > IRAN Setup (Client)"
    echo "2 > KHAREJ Setup (Server)"
    echo "3 > Add Port"
    echo "4 > Remove Port"
    echo "5 > View Tunnels"
    echo "6 > Services Management"
    echo "7 > Uninstall & Clean"
    echo "0 > Exit"
    echo
    read -r -e -p "Select option: " choice
    choice="$(trim "$choice")"

    case "$choice" in
      1) iran_setup ;;
      2) kharej_setup ;;
      3) add_port ;;
      4) remove_port ;;
      5) view_tunnels ;;
      6) services_management ;;
      7) uninstall_clean ;;
      0) add_log "Bye!"; render; exit 0 ;;
      *) add_log "Invalid option: $choice" ;;
    esac
  done
}

ensure_root "$@"
add_log "CHISEL TUNL - Anti-Filter Tunnel Manager"
main_menu
