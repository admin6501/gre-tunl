#!/usr/bin/env bash

set +e
set +u
export LC_ALL=C
LOG_LINES=()
LOG_MIN=3
LOG_MAX=10

banner() {
  cat <<'EOF'
╔═════════════════════════════════════════════════════╗
║                                                     ║
║    ██████╗ ██████╗ ███████╗    ████████╗██╗   ██╗   ║
║   ██╔════╝ ██╔══██╗██╔════╝    ╚══██╔══╝██║   ██║   ║
║   ██║  ███╗██████╔╝█████╗         ██║   ██║   ██║   ║
║   ██║   ██║██╔══██╗██╔══╝         ██║   ██║   ██║   ║
║   ╚██████╔╝██║  ██║███████╗       ██║   ╚██████╔╝   ║
║    ╚═════╝ ╚═╝  ╚═╝╚══════╝       ╚═╝    ╚═════╝    ║
║                                                     ║
║              GRE TUNL - Tunnel Manager              ║
║                                                     ║
╚═════════════════════════════════════════════════════╝
EOF
}

add_log() {
  local msg="$1"
  local ts
  ts="$(date +"%H:%M:%S")"
  LOG_LINES+=("[$ts] $msg")
  if ((${#LOG_LINES[@]} > LOG_MAX)); then
    LOG_LINES=("${LOG_LINES[@]: -$LOG_MAX}")
  fi
}

render() {
  clear
  banner
  echo
  local shown_count="${#LOG_LINES[@]}"
  local height=$shown_count
  ((height < LOG_MIN)) && height=$LOG_MIN
  ((height > LOG_MAX)) && height=$LOG_MAX

  echo "┌───────────────────────────── ACTION LOG ─────────────────────────────┐"
  local start_index=0
  if ((${#LOG_LINES[@]} > height)); then
    start_index=$((${#LOG_LINES[@]} - height))
  fi

  local i line
  for ((i=start_index; i<${#LOG_LINES[@]}; i++)); do
    line="${LOG_LINES[$i]}"
    printf "│ %-68s │\n" "$line"
  done

  local missing=$((height - (${#LOG_LINES[@]} - start_index)))
  for ((i=0; i<missing; i++)); do
    printf "│ %-68s │\n" ""
  done

  echo "└──────────────────────────────────────────────────────────────────────┘"
  echo
}

pause_enter() {
  echo
  read -r -p "Press ENTER to return to menu..." _
}

die_soft() {
  add_log "ERROR: $1"
  render
  pause_enter
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Re-running with sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

trim() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$1"; }
is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

valid_octet() {
  local o="$1"
  [[ "$o" =~ ^[0-9]+$ ]] && ((o>=0 && o<=255))
}

valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  valid_octet "$a" && valid_octet "$b" && valid_octet "$c" && valid_octet "$d"
}

valid_port() {
  local p="$1"
  is_int "$p" || return 1
  ((p>=1 && p<=65535))
}

valid_gre_base() {
  local ip="$1"
  valid_ipv4 "$ip" || return 1
  [[ "$ip" =~ \.0$ ]] || return 1
  return 0
}

ipv4_set_last_octet() {
  local ip="$1" last="$2"
  IFS='.' read -r a b c d <<<"$ip"
  echo "${a}.${b}.${c}.${last}"
}

ask_until_valid() {
  local prompt="$1" validator="$2" __var="$3"
  local ans=""
  while true; do
    render
    read -r -e -p "$prompt " ans
    ans="$(trim "$ans")"
    if [[ -z "$ans" ]]; then
      add_log "Empty input. Please try again."
      continue
    fi
    if "$validator" "$ans"; then
      printf -v "$__var" '%s' "$ans"
      add_log "OK: $prompt $ans"
      return 0
    else
      add_log "Invalid: $prompt $ans"
      add_log "Please enter a valid value."
    fi
  done
}

ask_ports() {
  local prompt="Forward PORT (80 | 80,2053 | 2050-2060):"
  local raw=""
  while true; do
    render
    read -r -e -p "$prompt " raw
    raw="$(trim "$raw")"
    raw="${raw// /}"

    if [[ -z "$raw" ]]; then
      add_log "Empty ports. Please try again."
      continue
    fi

    local -a ports=()
    local ok=1

    if [[ "$raw" =~ ^[0-9]+$ ]]; then
      valid_port "$raw" && ports+=("$raw") || ok=0

    elif [[ "$raw" =~ ^[0-9]+-[0-9]+$ ]]; then
      local s="${raw%-*}"
      local e="${raw#*-}"
      if valid_port "$s" && valid_port "$e" && ((s<=e)); then
        local p
        for ((p=s; p<=e; p++)); do ports+=("$p"); done
      else
        ok=0
      fi

    elif [[ "$raw" =~ ^[0-9]+(,[0-9]+)+$ ]]; then
      IFS=',' read -r -a parts <<<"$raw"
      local part
      for part in "${parts[@]}"; do
        valid_port "$part" && ports+=("$part") || { ok=0; break; }
      done
    else
      ok=0
    fi

    if ((ok==0)); then
      add_log "Invalid ports: $raw"
      add_log "Examples: 80 | 80,2053 | 2050-2060"
      continue
    fi

    mapfile -t PORT_LIST < <(printf "%s\n" "${ports[@]}" | awk '!seen[$0]++' | sort -n)
    add_log "Ports accepted: ${PORT_LIST[*]}"
    return 0
  done
}

ensure_iproute_only() {
  add_log "Checking required package: iproute2"
  render

  if command -v ip >/dev/null 2>&1; then
    add_log "iproute2 is already installed."
    return 0
  fi

  add_log "Installing missing package: iproute2"
  render
  apt-get update -y >/dev/null 2>&1
  apt-get install -y iproute2 >/dev/null 2>&1 && add_log "iproute2 installed successfully." || return 1
  return 0
}

ensure_packages() {
  add_log "Checking required packages: iproute2, haproxy"
  render
  local missing=()
  command -v ip >/dev/null 2>&1 || missing+=("iproute2")
  command -v haproxy >/dev/null 2>&1 || missing+=("haproxy")

  if ((${#missing[@]}==0)); then
    add_log "All required packages are installed."
    return 0
  fi

  add_log "Installing missing packages: ${missing[*]}"
  render
  apt-get update -y >/dev/null 2>&1
  apt-get install -y "${missing[@]}" >/dev/null 2>&1 && add_log "Packages installed successfully." || return 1
  return 0
}

systemd_reload() { systemctl daemon-reload >/dev/null 2>&1; }
unit_exists() { [[ -f "/etc/systemd/system/$1" ]]; }
enable_now() { systemctl enable --now "$1" >/dev/null 2>&1; }

show_unit_status_brief() {
  systemctl --no-pager --full status "$1" 2>&1 | sed -n '1,12p'
}

make_gre_service() {
  local id="$1" local_ip="$2" remote_ip="$3" local_gre_ip="$4" key="$5" remote_gre_ip="$6"
  local unit="gre${id}.service"
  local path="/etc/systemd/system/${unit}"
  local script_path="/usr/local/bin/gre${id}-tunnel.sh"
  local watchdog_path="/usr/local/bin/gre${id}-watchdog.sh"

  if unit_exists "$unit"; then
    add_log "Service already exists: $unit"
    return 2
  fi

  add_log "Creating GRE tunnel scripts..."
  render

  # Create tunnel management script
  cat >"$script_path" <<EOF
#!/bin/bash
# GRE${id} Tunnel Management Script

GRE_ID="${id}"
LOCAL_IP="${local_ip}"
REMOTE_IP="${remote_ip}"
LOCAL_GRE_IP="${local_gre_ip}"
REMOTE_GRE_IP="${remote_gre_ip}"
KEY="${key}"
IFACE="gre\${GRE_ID}"

cleanup() {
    ip link set \$IFACE down 2>/dev/null
    ip tunnel del \$IFACE 2>/dev/null
}

setup_tunnel() {
    cleanup
    
    ip tunnel add \$IFACE mode gre local \$LOCAL_IP remote \$REMOTE_IP ttl 255 key \$KEY
    if [[ \$? -ne 0 ]]; then
        echo "Failed to create tunnel"
        return 1
    fi
    
    ip addr add \${LOCAL_GRE_IP}/30 dev \$IFACE
    ip link set \$IFACE mtu 1400
    ip link set \$IFACE up
    
    echo "Tunnel \$IFACE is UP"
    return 0
}

trap cleanup EXIT

setup_tunnel || exit 1

# Keep running and monitor
while true; do
    sleep 10
    
    # Check if interface exists
    if ! ip link show \$IFACE >/dev/null 2>&1; then
        echo "Interface \$IFACE disappeared, recreating..."
        setup_tunnel || exit 1
    fi
done
EOF

  chmod +x "$script_path"

  # Create watchdog script
  cat >"$watchdog_path" <<EOF
#!/bin/bash
# GRE${id} Watchdog Script

IFACE="gre${id}"
REMOTE_GRE_IP="${remote_gre_ip}"
FAIL_COUNT=0
MAX_FAILS=3

while true; do
    sleep 30
    
    # Check if interface is up
    if ! ip link show \$IFACE up 2>/dev/null | grep -q "UP"; then
        echo "[\$(date)] Interface \$IFACE is DOWN"
        systemctl restart gre${id}.service
        sleep 10
        continue
    fi
    
    # Ping test
    if ping -c 2 -W 5 \$REMOTE_GRE_IP >/dev/null 2>&1; then
        FAIL_COUNT=0
    else
        ((FAIL_COUNT++))
        echo "[\$(date)] Ping failed (\$FAIL_COUNT/\$MAX_FAILS)"
        
        if ((FAIL_COUNT >= MAX_FAILS)); then
            echo "[\$(date)] Max failures reached, restarting tunnel..."
            systemctl restart gre${id}.service
            FAIL_COUNT=0
            sleep 10
        fi
    fi
done
EOF

  chmod +x "$watchdog_path"

  # Create main service
  add_log "Creating: $path"
  render

  cat >"$path" <<EOF
[Unit]
Description=GRE Tunnel ${id} to ${remote_ip}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=3
ExecStart=${script_path}
ExecStopPost=-/sbin/ip link set gre${id} down
ExecStopPost=-/sbin/ip tunnel del gre${id}
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF

  # Create watchdog service
  cat >"/etc/systemd/system/gre${id}-watchdog.service" <<EOF
[Unit]
Description=GRE Tunnel ${id} Watchdog
After=gre${id}.service
Requires=gre${id}.service

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStart=${watchdog_path}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload >/dev/null 2>&1
  
  [[ $? -eq 0 ]] && add_log "GRE service created: $unit" || return 1
  
  return 0
}

haproxy_unit_exists() {
  systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -qx 'haproxy.service'
}

haproxy_write_main_cfg() {
  add_log "Rebuilding /etc/haproxy/haproxy.cfg (no include)"
  render

  rm -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1 || true

  cat >/etc/haproxy/haproxy.cfg <<'EOF'
#HAPROXY-FOR-GRE
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon
    maxconn 200000

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client  1m
    timeout server  1m

EOF
}

haproxy_write_gre_cfg() {
  local id="$1" target_ip="$2"
  shift 2
  local -a ports=("$@")

  mkdir -p /etc/haproxy/conf.d >/dev/null 2>&1 || true
  local cfg="/etc/haproxy/conf.d/haproxy-gre${id}.cfg"

  if [[ -f "$cfg" ]]; then
    add_log "ERROR: haproxy-gre${id}.cfg already exists."
    return 2
  fi

  add_log "Creating HAProxy config: $cfg"
  render

  : >"$cfg" || return 1

  local p
  for p in "${ports[@]}"; do
    cat >>"$cfg" <<EOF
frontend gre${id}_fe_${p}
    bind 0.0.0.0:${p}
    default_backend gre${id}_be_${p}

backend gre${id}_be_${p}
    server gre${id}_b_${p} ${target_ip}:${p}

EOF
  done

  return 0
}

haproxy_patch_systemd() {
  local dir="/etc/systemd/system/haproxy.service.d"
  local override="${dir}/override.conf"

  if ! haproxy_unit_exists; then
    add_log "ERROR: not found haproxy service"
    return 1
  fi

  add_log "Patching systemd for haproxy to load /etc/haproxy/conf.d/ (drop-in override)"
  render

  mkdir -p "$dir" >/dev/null 2>&1 || return 1

  cat >"$override" <<'EOF'
[Service]
Environment="CONFIG=/etc/haproxy/haproxy.cfg"
Environment="PIDFILE=/run/haproxy.pid"
Environment="EXTRAOPTS=-S /run/haproxy-master.sock"
ExecStart=
ExecStart=/usr/sbin/haproxy -Ws -f $CONFIG -f /etc/haproxy/conf.d/ -p $PIDFILE $EXTRAOPTS
ExecReload=
ExecReload=/usr/sbin/haproxy -Ws -f $CONFIG -f /etc/haproxy/conf.d/ -c -q $EXTRAOPTS
EOF

  systemctl daemon-reload >/dev/null 2>&1 || true
  return 0
}

haproxy_apply_and_show() {
  haproxy_patch_systemd || return 1

  add_log "Enabling HAProxy..."
  render
  systemctl enable --now haproxy >/dev/null 2>&1 || true

  add_log "Restarting HAProxy..."
  render
  systemctl restart haproxy >/dev/null 2>&1 || true

  render
  echo "---- STATUS (haproxy.service) ----"
  systemctl status haproxy --no-pager 2>&1 | sed -n '1,18p'
  echo "---------------------------------"
}

iran_setup() {
  local ID IRANIP KHAREJIP GREBASE
  local -a PORT_LIST=()

  ask_until_valid "GRE Number :" is_int ID
  ask_until_valid "IRAN IP :" valid_ipv4 IRANIP
  ask_until_valid "KHAREJ IP :" valid_ipv4 KHAREJIP
  ask_until_valid "GRE IP RANG (Example : 10.80.70.0):" valid_gre_base GREBASE
  ask_ports

  local key=$((ID*100))
  local local_gre_ip peer_gre_ip
  local_gre_ip="$(ipv4_set_last_octet "$GREBASE" 1)"
  peer_gre_ip="$(ipv4_set_last_octet "$GREBASE" 2)"
  add_log "KEY=${key} | IRAN=${local_gre_ip} | KHAREJ=${peer_gre_ip}"

  ensure_packages || { die_soft "Package installation failed."; return 0; }

  make_gre_service "$ID" "$IRANIP" "$KHAREJIP" "$local_gre_ip" "$key" "$peer_gre_ip"
  local rc=$?
  [[ $rc -eq 2 ]] && return 0
  [[ $rc -ne 0 ]] && { die_soft "Failed creating GRE service."; return 0; }

  add_log "Reloading systemd..."
  systemd_reload

  add_log "Starting gre${ID}..."
  enable_now "gre${ID}.service"
  
  add_log "Starting watchdog..."
  enable_now "gre${ID}-watchdog.service"

  add_log "Writing HAProxy configs for GRE${ID}..."
  haproxy_write_gre_cfg "$ID" "$peer_gre_ip" "${PORT_LIST[@]}"
  local hrc=$?
  if [[ $hrc -eq 2 ]]; then
    die_soft "haproxy-gre${ID}.cfg already exists."
    return 0
  elif [[ $hrc -ne 0 ]]; then
    die_soft "Failed writing haproxy-gre${ID}.cfg"
    return 0
  fi

  haproxy_write_main_cfg

  if command -v haproxy >/dev/null 2>&1; then
    haproxy -c -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d/ >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
      die_soft "HAProxy config validation failed (haproxy -c)."
      return 0
    fi
  fi

  haproxy_apply_and_show || { die_soft "Failed applying HAProxy systemd override."; return 0; }

  render
  echo "GRE IPs:"
  echo "  IRAN  : ${local_gre_ip}"
  echo "  KHAREJ: ${peer_gre_ip}"
  echo
  echo "Status:"
  show_unit_status_brief "gre${ID}.service"
  pause_enter
}

kharej_setup() {
  local ID KHAREJIP IRANIP GREBASE

  ask_until_valid "GRE Number(Like IRAN PLEASE) :" is_int ID
  ask_until_valid "KHAREJ IP :" valid_ipv4 KHAREJIP
  ask_until_valid "IRAN IP :" valid_ipv4 IRANIP
  ask_until_valid "GRE IP RANG (Example : 10.80.70.0) Like IRAN PLEASE:" valid_gre_base GREBASE

  local key=$((ID*100))
  local local_gre_ip peer_gre_ip
  local_gre_ip="$(ipv4_set_last_octet "$GREBASE" 2)"
  peer_gre_ip="$(ipv4_set_last_octet "$GREBASE" 1)"
  add_log "KEY=${key} | KHAREJ=${local_gre_ip} | IRAN=${peer_gre_ip}"

  ensure_iproute_only || { die_soft "Package installation failed (iproute2)."; return 0; }

  make_gre_service "$ID" "$KHAREJIP" "$IRANIP" "$local_gre_ip" "$key" "$peer_gre_ip"
  local rc=$?
  [[ $rc -eq 2 ]] && return 0
  [[ $rc -ne 0 ]] && { die_soft "Failed creating GRE service."; return 0; }

  add_log "Reloading systemd..."
  systemd_reload

  add_log "Starting gre${ID}..."
  enable_now "gre${ID}.service"
  
  add_log "Starting watchdog..."
  enable_now "gre${ID}-watchdog.service"

  render
  echo "GRE IPs:"
  echo "  KHAREJ: ${local_gre_ip}"
  echo "  IRAN  : ${peer_gre_ip}"
  echo
  show_unit_status_brief "gre${ID}.service"
  pause_enter
}

get_gre_ids() {
  local ids=()

  while IFS= read -r u; do
    [[ "$u" =~ ^gre([0-9]+)\.service$ ]] && ids+=("${BASH_REMATCH[1]}")
  done < <(systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^gre[0-9]+\.service$' || true)

  while IFS= read -r f; do
    f="$(basename "$f")"
    [[ "$f" =~ ^gre([0-9]+)\.service$ ]] && ids+=("${BASH_REMATCH[1]}")
  done < <(find /etc/systemd/system -maxdepth 1 -type f -name 'gre*.service' 2>/dev/null || true)

  printf "%s\n" "${ids[@]}" | awk 'NF{a[$0]=1} END{for(k in a) print k}' | sort -n
}

MENU_SELECTED=-1

menu_select_index() {
  local title="$1"
  local prompt="$2"
  shift 2
  local -a items=("$@")
  local choice=""

  while true; do
    render
    echo "$title"
    echo

    if ((${#items[@]} == 0)); then
      echo "No service found."
      echo
      read -r -p "Press ENTER to go back..." _
      MENU_SELECTED=-1
      return 1
    fi

    local i
    for ((i=0; i<${#items[@]}; i++)); do
      printf "%d) %s\n" $((i+1)) "${items[$i]}"
    done
    echo "0) Back"
    echo

    read -r -e -p "$prompt " choice
    choice="$(trim "$choice")"

    if [[ "$choice" == "0" ]]; then
      MENU_SELECTED=-1
      return 1
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice>=1 && choice<=${#items[@]})); then
      MENU_SELECTED=$((choice-1))
      return 0
    fi

    add_log "Invalid selection: $choice"
  done
}

service_action_menu() {
  local unit="$1"
  local action=""

  while true; do
    render
    echo "Selected: $unit"
    echo
    echo "1) Enable & Start"
    echo "2) Restart"
    echo "3) Stop & Disable"
    echo "4) Status"
    echo "0) Back"
    echo

    read -r -e -p "Select action: " action
    action="$(trim "$action")"

    case "$action" in
      1)
        add_log "Enable & Start: $unit"
        systemctl enable "$unit" >/dev/null 2>&1 && add_log "Enabled: $unit" || add_log "Enable failed: $unit"
        systemctl start "$unit"  >/dev/null 2>&1 && add_log "Started: $unit" || add_log "Start failed: $unit"
        ;;
      2)
        add_log "Restart: $unit"
        systemctl restart "$unit" >/dev/null 2>&1 && add_log "Restarted: $unit" || add_log "Restart failed: $unit"
        ;;
      3)
        add_log "Stop & Disable: $unit"
        systemctl stop "$unit"    >/dev/null 2>&1 && add_log "Stopped: $unit" || add_log "Stop failed: $unit"
        systemctl disable "$unit" >/dev/null 2>&1 && add_log "Disabled: $unit" || add_log "Disable failed: $unit"
        ;;
      4)
        render
        echo "---- STATUS ($unit) ----"
        systemctl --no-pager --full status "$unit" 2>&1 | sed -n '1,16p'
        echo "------------------------"
        pause_enter
        ;;
      0) return 0 ;;
      *) add_log "Invalid action: $action" ;;
    esac
  done
}

services_management() {
  local sel=""

  while true; do
    render
    echo "Services Management"
    echo
    echo "1) GRE"
    echo "2) HAPROXY"
    echo "0) Back"
    echo
    read -r -e -p "Select: " sel
    sel="$(trim "$sel")"

    case "$sel" in
      1)
        mapfile -t GRE_IDS < <(get_gre_ids)
        local -a GRE_LABELS=()
        local id
        for id in "${GRE_IDS[@]}"; do
          GRE_LABELS+=("GRE${id}")
        done

        if menu_select_index "GRE Services" "Select GRE:" "${GRE_LABELS[@]}"; then
          local idx="$MENU_SELECTED"
          id="${GRE_IDS[$idx]}"
          add_log "GRE selected: GRE${id}"
          service_action_menu "gre${id}.service"
        fi
        ;;

      2)
        if ! haproxy_unit_exists; then
          add_log "ERROR: not found haproxy service"
          render
          pause_enter
          continue
        fi
        add_log "HAProxy selected"
        service_action_menu "haproxy.service"
        ;;

      0) return 0 ;;
      *) add_log "Invalid selection: $sel" ;;
    esac
  done
}

uninstall_clean() {
  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  local id
  for id in "${GRE_IDS[@]}"; do
    GRE_LABELS+=("GRE${id}")
  done

  if ! menu_select_index "Uninstall & Clean" "Select GRE to uninstall:" "${GRE_LABELS[@]}"; then
    return 0
  fi

  local idx="$MENU_SELECTED"
  id="${GRE_IDS[$idx]}"

  while true; do
    render
    echo "Uninstall & Clean"
    echo
    echo "Target: GRE${id}"
    echo "This will remove:"
    echo "  - gre${id}.service"
    echo "  - /etc/haproxy/conf.d/haproxy-gre${id}.cfg"
    echo
    echo "Type: YES (confirm)  or  NO (cancel)"
    echo
    local confirm=""
    read -r -e -p "Confirm: " confirm
    confirm="$(trim "$confirm")"

    if [[ "$confirm" == "NO" || "$confirm" == "no" ]]; then
      add_log "Uninstall cancelled for GRE${id}"
      return 0
    fi
    if [[ "$confirm" == "YES" ]]; then
      break
    fi
    add_log "Please type YES or NO."
  done

  add_log "Stopping gre${id}.service"
  systemctl stop "gre${id}.service" >/dev/null 2>&1 || true
  add_log "Disabling gre${id}.service"
  systemctl disable "gre${id}.service" >/dev/null 2>&1 || true

  add_log "Removing unit file..."
  rm -f "/etc/systemd/system/gre${id}.service" >/dev/null 2>&1 || true

  add_log "Removing HAProxy GRE config..."
  rm -f "/etc/haproxy/conf.d/haproxy-gre${id}.cfg" >/dev/null 2>&1 || true

  add_log "Reloading systemd..."
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed  >/dev/null 2>&1 || true

  if haproxy_unit_exists; then
    add_log "Restarting haproxy (no disable)..."
    systemctl restart haproxy >/dev/null 2>&1 || true
  else
    add_log "haproxy service not found; skip restart."
  fi

  add_log "Uninstall completed for GRE${id}"
  render
  pause_enter
}

get_gre_local_ip_cidr() {
  local id="$1"
  ip -4 -o addr show dev "gre${id}" 2>/dev/null | awk '{print $4}' | head -n1
}

get_peer_ip_from_local_cidr() {
  local cidr="$1"
  local ip="${cidr%/*}"
  local mask="${cidr#*/}"

  IFS='.' read -r a b c d <<<"$ip"

  local peer_d
  if [[ "$d" == "1" ]]; then
    peer_d="2"
  elif [[ "$d" == "2" ]]; then
    peer_d="1"
  else
    peer_d="2"
  fi

  echo "${a}.${b}.${c}.${peer_d}"
}

haproxy_add_ports_to_gre_cfg() {
  local id="$1" target_ip="$2"
  shift 2
  local -a ports=("$@")
  local cfg="/etc/haproxy/conf.d/haproxy-gre${id}.cfg"

  if [[ ! -f "$cfg" ]]; then
    add_log "ERROR: Not found: $cfg"
    return 1
  fi

  add_log "Editing HAProxy config: $cfg"
  render

  local p added=0 skipped=0
  for p in "${ports[@]}"; do
    if grep -qE "^frontend[[:space:]]+gre${id}_fe_${p}\b" "$cfg" 2>/dev/null; then
      add_log "Skip (exists): GRE${id} port ${p}"
      ((skipped++))
      continue
    fi

    cat >>"$cfg" <<EOF

frontend gre${id}_fe_${p}
    bind 0.0.0.0:${p}
    default_backend gre${id}_be_${p}

backend gre${id}_be_${p}
    server gre${id}_b_${p} ${target_ip}:${p}
EOF

    add_log "Added: GRE${id} port ${p} -> ${target_ip}:${p}"
    ((added++))
  done

  add_log "Done. Added=${added}, Skipped=${skipped}"
  return 0
}

add_tunnel_port() {
  render
  add_log "Selected: add tunnel port"
  render

  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  local id
  for id in "${GRE_IDS[@]}"; do
    GRE_LABELS+=("GRE${id}")
  done

  if ! menu_select_index "Add Tunnel Port" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi

  local idx="$MENU_SELECTED"
  id="${GRE_IDS[$idx]}"
  add_log "GRE selected: GRE${id}"
  render

  local cidr
  cidr="$(get_gre_local_ip_cidr "$id")"
  if [[ -z "$cidr" ]]; then
    die_soft "Could not detect IP on gre${id}. Is it up and has an IP?"
    return 0
  fi

  local peer_ip
  peer_ip="$(get_peer_ip_from_local_cidr "$cidr")"
  add_log "Detected: gre${id} local=${cidr} | peer=${peer_ip}"
  render

  PORT_LIST=()
  ask_ports

  haproxy_add_ports_to_gre_cfg "$id" "$peer_ip" "${PORT_LIST[@]}" || { die_soft "Failed editing haproxy-gre${id}.cfg"; return 0; }

  if command -v haproxy >/dev/null 2>&1; then
    haproxy -c -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d/ >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
      die_soft "HAProxy config validation failed (haproxy -c)."
      return 0
    fi
  fi

  if haproxy_unit_exists; then
    add_log "Restarting HAProxy..."
    render
    systemctl restart haproxy >/dev/null 2>&1 || true
    add_log "HAProxy restarted."
  else
    add_log "WARNING: haproxy.service not found; skipped restart."
  fi

  render
  echo "GRE${id} updated."
  echo "Local CIDR : ${cidr}"
  echo "Peer IP    : ${peer_ip}"
  echo "Ports added: ${PORT_LIST[*]}"
  echo
  echo "---- STATUS (haproxy.service) ----"
  systemctl status haproxy --no-pager 2>&1 | sed -n '1,16p'
  echo "---------------------------------"
  pause_enter
}


get_gre_ports() {
  local id="$1"
  local cfg="/etc/haproxy/conf.d/haproxy-gre${id}.cfg"
  
  if [[ ! -f "$cfg" ]]; then
    return 1
  fi
  
  grep -oP "^frontend gre${id}_fe_\K[0-9]+" "$cfg" 2>/dev/null | sort -n | uniq
}

haproxy_remove_ports_from_gre_cfg() {
  local id="$1"
  shift
  local -a ports=("$@")
  local cfg="/etc/haproxy/conf.d/haproxy-gre${id}.cfg"

  if [[ ! -f "$cfg" ]]; then
    add_log "ERROR: Not found: $cfg"
    return 1
  fi

  add_log "Removing ports from HAProxy config: $cfg"
  render

  local p removed=0 notfound=0
  local tmpfile
  tmpfile="$(mktemp)"

  for p in "${ports[@]}"; do
    if ! grep -qE "^frontend[[:space:]]+gre${id}_fe_${p}\b" "$cfg" 2>/dev/null; then
      add_log "Skip (not found): GRE${id} port ${p}"
      ((notfound++))
      continue
    fi

    # Remove frontend block
    awk -v fe="frontend gre${id}_fe_${p}" '
      BEGIN { skip=0 }
      $0 ~ "^"fe"$" { skip=1; next }
      /^frontend / || /^backend / { if(skip) skip=0 }
      !skip { print }
    ' "$cfg" > "$tmpfile"
    cp "$tmpfile" "$cfg"

    # Remove backend block
    awk -v be="backend gre${id}_be_${p}" '
      BEGIN { skip=0 }
      $0 ~ "^"be"$" { skip=1; next }
      /^frontend / || /^backend / { if(skip) skip=0 }
      !skip { print }
    ' "$cfg" > "$tmpfile"
    cp "$tmpfile" "$cfg"

    add_log "Removed: GRE${id} port ${p}"
    ((removed++))
  done

  rm -f "$tmpfile" 2>/dev/null || true

  # Clean up empty lines at end of file
  sed -i '/^$/N;/^\n$/d' "$cfg" 2>/dev/null || true

  add_log "Done. Removed=${removed}, NotFound=${notfound}"
  return 0
}

remove_tunnel_port() {
  render
  add_log "Selected: remove tunnel port"
  render

  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  local id
  for id in "${GRE_IDS[@]}"; do
    GRE_LABELS+=("GRE${id}")
  done

  if ! menu_select_index "Remove Tunnel Port" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi

  local idx="$MENU_SELECTED"
  id="${GRE_IDS[$idx]}"
  add_log "GRE selected: GRE${id}"
  render

  # Get existing ports
  local -a existing_ports
  mapfile -t existing_ports < <(get_gre_ports "$id")

  if ((${#existing_ports[@]} == 0)); then
    die_soft "No ports found for GRE${id}. Config file may not exist or is empty."
    return 0
  fi

  render
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                    Existing Ports for GRE${id}                        │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  printf "│ %-67s │\n" "Ports: ${existing_ports[*]}"
  echo "└─────────────────────────────────────────────────────────────────────┘"
  echo

  # Ask for ports to remove
  local raw=""
  local -a REMOVE_PORT_LIST=()
  
  while true; do
    echo "Enter ports to REMOVE (80 | 80,2053 | 2050-2060):"
    read -r -e -p "> " raw
    raw="$(trim "$raw")"
    raw="${raw// /}"

    if [[ -z "$raw" ]]; then
      add_log "Empty ports. Please try again."
      continue
    fi

    local -a ports=()
    local ok=1

    if [[ "$raw" =~ ^[0-9]+$ ]]; then
      valid_port "$raw" && ports+=("$raw") || ok=0

    elif [[ "$raw" =~ ^[0-9]+-[0-9]+$ ]]; then
      local s="${raw%-*}"
      local e="${raw#*-}"
      if valid_port "$s" && valid_port "$e" && ((s<=e)); then
        local p
        for ((p=s; p<=e; p++)); do ports+=("$p"); done
      else
        ok=0
      fi

    elif [[ "$raw" =~ ^[0-9]+(,[0-9]+)+$ ]]; then
      IFS=',' read -r -a parts <<<"$raw"
      local part
      for part in "${parts[@]}"; do
        valid_port "$part" && ports+=("$part") || { ok=0; break; }
      done
    else
      ok=0
    fi

    if ((ok==0)); then
      add_log "Invalid ports: $raw"
      continue
    fi

    mapfile -t REMOVE_PORT_LIST < <(printf "%s\n" "${ports[@]}" | awk '!seen[$0]++' | sort -n)
    add_log "Ports to remove: ${REMOVE_PORT_LIST[*]}"
    break
  done

  # Confirmation
  while true; do
    render
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│                      CONFIRM PORT REMOVAL                          │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    printf "│ %-67s │\n" "GRE Tunnel: GRE${id}"
    printf "│ %-67s │\n" "Ports to remove: ${REMOVE_PORT_LIST[*]}"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo
    echo "Type: YES (confirm)  or  NO (cancel)"
    echo
    local confirm=""
    read -r -e -p "Confirm: " confirm
    confirm="$(trim "$confirm")"

    if [[ "$confirm" == "NO" || "$confirm" == "no" ]]; then
      add_log "Port removal cancelled for GRE${id}"
      return 0
    fi
    if [[ "$confirm" == "YES" ]]; then
      break
    fi
    add_log "Please type YES or NO."
  done

  # Remove ports
  haproxy_remove_ports_from_gre_cfg "$id" "${REMOVE_PORT_LIST[@]}" || { die_soft "Failed removing ports from haproxy-gre${id}.cfg"; return 0; }

  # Validate HAProxy config
  if command -v haproxy >/dev/null 2>&1; then
    haproxy -c -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d/ >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
      die_soft "HAProxy config validation failed (haproxy -c)."
      return 0
    fi
  fi

  # Restart HAProxy
  if haproxy_unit_exists; then
    add_log "Restarting HAProxy..."
    render
    systemctl restart haproxy >/dev/null 2>&1 || true
    add_log "HAProxy restarted."
  else
    add_log "WARNING: haproxy.service not found; skipped restart."
  fi

  # Show remaining ports
  local -a remaining_ports
  mapfile -t remaining_ports < <(get_gre_ports "$id")

  render
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                    PORT REMOVAL COMPLETED                          │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  printf "│ %-67s │\n" "GRE Tunnel: GRE${id}"
  printf "│ %-67s │\n" "Removed ports: ${REMOVE_PORT_LIST[*]}"
  if ((${#remaining_ports[@]} > 0)); then
    printf "│ %-67s │\n" "Remaining ports: ${remaining_ports[*]}"
  else
    printf "│ %-67s │\n" "Remaining ports: (none)"
  fi
  echo "└─────────────────────────────────────────────────────────────────────┘"
  echo
  echo "---- STATUS (haproxy.service) ----"
  systemctl status haproxy --no-pager 2>&1 | sed -n '1,16p'
  echo "---------------------------------"
  pause_enter
}

# ==================== TRAFFIC LIMIT SYSTEM ====================

LIMIT_DIR="/etc/gre-limits"
LIMIT_CHECK_SCRIPT="/usr/local/bin/gre-limit-checker.sh"
LIMIT_SERVICE="/etc/systemd/system/gre-limit-checker.service"
LIMIT_TIMER="/etc/systemd/system/gre-limit-checker.timer"

bytes_to_human() {
  local bytes="$1"
  if ((bytes >= 1073741824)); then
    echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}") GB"
  elif ((bytes >= 1048576)); then
    echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}") MB"
  elif ((bytes >= 1024)); then
    echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1024}") KB"
  else
    echo "${bytes} B"
  fi
}

gb_to_bytes() {
  local gb="$1"
  awk "BEGIN {printf \"%.0f\", $gb * 1073741824}"
}

get_tunnel_traffic() {
  local id="$1"
  local iface="gre${id}"
  
  if [[ ! -d "/sys/class/net/${iface}" ]]; then
    echo "0 0"
    return 1
  fi
  
  local rx tx
  rx=$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null || echo 0)
  tx=$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null || echo 0)
  echo "$rx $tx"
}

get_limit_config() {
  local id="$1"
  local cfg="${LIMIT_DIR}/gre${id}.conf"
  
  if [[ -f "$cfg" ]]; then
    cat "$cfg"
  fi
}

save_limit_config() {
  local id="$1"
  local limit_bytes="$2"
  local base_rx="$3"
  local base_tx="$4"
  local enabled="$5"
  local calc_mode="${6:-both}"  # rx, tx, both
  
  mkdir -p "$LIMIT_DIR" 2>/dev/null || true
  
  cat > "${LIMIT_DIR}/gre${id}.conf" <<EOF
LIMIT_BYTES=${limit_bytes}
BASE_RX=${base_rx}
BASE_TX=${base_tx}
ENABLED=${enabled}
CALC_MODE=${calc_mode}
CREATED="$(date +"%Y-%m-%d_%H:%M:%S")"
EOF
}

calc_mode_to_text() {
  local mode="$1"
  case "$mode" in
    rx) echo "Download Only (RX)" ;;
    tx) echo "Upload Only (TX)" ;;
    both) echo "Download + Upload (RX+TX)" ;;
    *) echo "Download + Upload (RX+TX)" ;;
  esac
}

# ==================== PORT-SPECIFIC TRAFFIC FUNCTIONS ====================

get_port_traffic() {
  local id="$1"
  local port="$2"
  local chain="GRE${id}_P${port}"
  
  # Check if chain exists
  if ! iptables -L "$chain" -n >/dev/null 2>&1; then
    echo "0 0"
    return 1
  fi
  
  # Get bytes from iptables (INPUT = RX, OUTPUT = TX)
  local rx tx
  rx=$(iptables -L "$chain" -v -n -x 2>/dev/null | awk 'NR==3 {print $2}' || echo 0)
  tx=$(iptables -L "${chain}_OUT" -v -n -x 2>/dev/null | awk 'NR==3 {print $2}' || echo 0)
  [[ -z "$rx" ]] && rx=0
  [[ -z "$tx" ]] && tx=0
  echo "$rx $tx"
}

setup_port_counter() {
  local id="$1"
  local port="$2"
  local chain="GRE${id}_P${port}"
  local chain_out="${chain}_OUT"
  
  # Remove if exists
  iptables -D INPUT -p tcp --dport "$port" -j "$chain" 2>/dev/null || true
  iptables -D OUTPUT -p tcp --sport "$port" -j "$chain_out" 2>/dev/null || true
  iptables -F "$chain" 2>/dev/null || true
  iptables -X "$chain" 2>/dev/null || true
  iptables -F "$chain_out" 2>/dev/null || true
  iptables -X "$chain_out" 2>/dev/null || true
  
  # Create new chains
  iptables -N "$chain" 2>/dev/null || true
  iptables -A "$chain" -j RETURN
  iptables -I INPUT -p tcp --dport "$port" -j "$chain"
  
  iptables -N "$chain_out" 2>/dev/null || true
  iptables -A "$chain_out" -j RETURN
  iptables -I OUTPUT -p tcp --sport "$port" -j "$chain_out"
  
  return 0
}

remove_port_counter() {
  local id="$1"
  local port="$2"
  local chain="GRE${id}_P${port}"
  local chain_out="${chain}_OUT"
  
  iptables -D INPUT -p tcp --dport "$port" -j "$chain" 2>/dev/null || true
  iptables -D OUTPUT -p tcp --sport "$port" -j "$chain_out" 2>/dev/null || true
  iptables -F "$chain" 2>/dev/null || true
  iptables -X "$chain" 2>/dev/null || true
  iptables -F "$chain_out" 2>/dev/null || true
  iptables -X "$chain_out" 2>/dev/null || true
}

save_port_limit_config() {
  local id="$1"
  local port="$2"
  local limit_bytes="$3"
  local base_rx="$4"
  local base_tx="$5"
  local enabled="$6"
  local calc_mode="${7:-both}"
  
  mkdir -p "$LIMIT_DIR" 2>/dev/null || true
  
  cat > "${LIMIT_DIR}/gre${id}_port${port}.conf" <<EOF
LIMIT_TYPE=port
GRE_ID=${id}
PORT=${port}
LIMIT_BYTES=${limit_bytes}
BASE_RX=${base_rx}
BASE_TX=${base_tx}
ENABLED=${enabled}
CALC_MODE=${calc_mode}
CREATED="$(date +"%Y-%m-%d_%H:%M:%S")"
EOF
}

block_port() {
  local port="$1"
  # Block port using iptables
  iptables -I INPUT -p tcp --dport "$port" -j DROP 2>/dev/null || true
}

unblock_port() {
  local port="$1"
  # Remove block
  iptables -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null || true
}

install_limit_checker() {
  add_log "Installing traffic limit checker service..."
  render
  
  mkdir -p "$LIMIT_DIR" 2>/dev/null || true
  
  # Create checker script
  cat > "$LIMIT_CHECK_SCRIPT" <<'CHECKER_EOF'
#!/usr/bin/env bash
LIMIT_DIR="/etc/gre-limits"

# Function to get port traffic from iptables
get_port_traffic_checker() {
  local id="$1"
  local port="$2"
  local chain="GRE${id}_P${port}"
  
  local rx tx
  rx=$(iptables -L "$chain" -v -n -x 2>/dev/null | awk 'NR==3 {print $2}' || echo 0)
  tx=$(iptables -L "${chain}_OUT" -v -n -x 2>/dev/null | awk 'NR==3 {print $2}' || echo 0)
  [[ -z "$rx" ]] && rx=0
  [[ -z "$tx" ]] && tx=0
  echo "$rx $tx"
}

# Check tunnel limits
for cfg in "${LIMIT_DIR}"/gre[0-9]*.conf; do
  [[ -f "$cfg" ]] || continue
  [[ "$cfg" =~ _port ]] && continue  # Skip port configs
  
  id=$(basename "$cfg" | sed 's/gre\([0-9]*\)\.conf/\1/')
  iface="gre${id}"
  
  [[ -d "/sys/class/net/${iface}" ]] || continue
  
  source "$cfg"
  
  [[ "$ENABLED" != "1" ]] && continue
  
  rx=$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null || echo 0)
  tx=$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null || echo 0)
  
  used_rx=$((rx - BASE_RX))
  used_tx=$((tx - BASE_TX))
  ((used_rx < 0)) && used_rx=0
  ((used_tx < 0)) && used_tx=0
  
  case "${CALC_MODE:-both}" in
    rx) total_used=$used_rx ;;
    tx) total_used=$used_tx ;;
    both|*) total_used=$((used_rx + used_tx)) ;;
  esac
  
  if ((total_used >= LIMIT_BYTES)); then
    systemctl stop "gre${id}.service" 2>/dev/null || true
    sed -i 's/^ENABLED=1/ENABLED=0/' "$cfg"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] GRE${id} TUNNEL stopped - Limit reached (Used: $((total_used/1073741824))GB)" >> "${LIMIT_DIR}/limit.log"
  fi
done

# Check port-specific limits
for cfg in "${LIMIT_DIR}"/gre*_port*.conf; do
  [[ -f "$cfg" ]] || continue
  
  source "$cfg"
  
  [[ "$ENABLED" != "1" ]] && continue
  [[ "$LIMIT_TYPE" != "port" ]] && continue
  
  read -r rx tx <<< "$(get_port_traffic_checker "$GRE_ID" "$PORT")"
  
  used_rx=$((rx - BASE_RX))
  used_tx=$((tx - BASE_TX))
  ((used_rx < 0)) && used_rx=0
  ((used_tx < 0)) && used_tx=0
  
  case "${CALC_MODE:-both}" in
    rx) total_used=$used_rx ;;
    tx) total_used=$used_tx ;;
    both|*) total_used=$((used_rx + used_tx)) ;;
  esac
  
  if ((total_used >= LIMIT_BYTES)); then
    # Block the port
    iptables -C INPUT -p tcp --dport "$PORT" -j DROP 2>/dev/null || \
      iptables -I INPUT -p tcp --dport "$PORT" -j DROP
    
    sed -i 's/^ENABLED=1/ENABLED=0/' "$cfg"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] GRE${GRE_ID} PORT ${PORT} blocked - Limit reached (Used: $((total_used/1073741824))GB)" >> "${LIMIT_DIR}/limit.log"
  fi
done
CHECKER_EOF

  chmod +x "$LIMIT_CHECK_SCRIPT"
  
  # Create systemd service
  cat > "$LIMIT_SERVICE" <<EOF
[Unit]
Description=GRE Tunnel Traffic Limit Checker
After=network.target

[Service]
Type=oneshot
ExecStart=${LIMIT_CHECK_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF

  # Create systemd timer (runs every minute)
  cat > "$LIMIT_TIMER" <<EOF
[Unit]
Description=GRE Tunnel Traffic Limit Checker Timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable --now gre-limit-checker.timer >/dev/null 2>&1
  
  add_log "Traffic limit checker installed and started."
}

is_limit_checker_installed() {
  [[ -f "$LIMIT_CHECK_SCRIPT" ]] && [[ -f "$LIMIT_TIMER" ]]
}

set_traffic_limit() {
  render
  add_log "Selected: Set Traffic Limit"
  render
  
  # Ensure checker is installed
  if ! is_limit_checker_installed; then
    install_limit_checker
  fi
  
  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  local id
  for id in "${GRE_IDS[@]}"; do
    GRE_LABELS+=("GRE${id}")
  done

  if ! menu_select_index "Set Traffic Limit" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi

  local idx="$MENU_SELECTED"
  id="${GRE_IDS[$idx]}"
  add_log "GRE selected: GRE${id}"
  render
  
  # Ask: Entire tunnel or specific port?
  local limit_type=""
  while true; do
    render
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│                    LIMIT TYPE - GRE${id}                              │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    printf "│ %-67s │\n" "Apply limit to:"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo
    echo "1) Entire Tunnel (all traffic)"
    echo "2) Specific Port"
    echo "0) Back"
    echo
    read -r -e -p "Select: " limit_type
    limit_type="$(trim "$limit_type")"
    
    case "$limit_type" in
      1) limit_type="tunnel"; break ;;
      2) limit_type="port"; break ;;
      0) return 0 ;;
      *) add_log "Invalid selection" ;;
    esac
  done
  
  if [[ "$limit_type" == "tunnel" ]]; then
    set_tunnel_limit "$id"
  else
    set_port_limit "$id"
  fi
}

set_tunnel_limit() {
  local id="$1"
  
  # Check if tunnel is up
  if [[ ! -d "/sys/class/net/gre${id}" ]]; then
    die_soft "GRE${id} interface not found. Is the tunnel running?"
    return 0
  fi
  
  # Get current traffic
  local traffic_info
  traffic_info=$(get_tunnel_traffic "$id")
  local current_rx current_tx
  read -r current_rx current_tx <<< "$traffic_info"
  
  # Ask for limit
  local limit_gb=""
  while true; do
    render
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│                SET TUNNEL LIMIT - GRE${id}                            │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    printf "│ %-67s │\n" "Current RX (Download): $(bytes_to_human $current_rx)"
    printf "│ %-67s │\n" "Current TX (Upload): $(bytes_to_human $current_tx)"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo
    read -r -e -p "Enter traffic limit in GB (e.g., 10 or 5.5): " limit_gb
    limit_gb="$(trim "$limit_gb")"
    
    if [[ -z "$limit_gb" ]]; then
      add_log "Empty input. Please try again."
      continue
    fi
    
    if [[ "$limit_gb" =~ ^[0-9]+\.?[0-9]*$ ]] && awk "BEGIN {exit !($limit_gb > 0)}"; then
      break
    else
      add_log "Invalid input: $limit_gb"
    fi
  done
  
  # Ask for calculation mode
  local calc_mode=""
  while true; do
    render
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│                    CALCULATION MODE - GRE${id}                        │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    printf "│ %-67s │\n" "How should traffic be calculated?"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo
    echo "1) Download Only (RX)"
    echo "2) Upload Only (TX)"
    echo "3) Download + Upload (RX+TX)"
    echo
    read -r -e -p "Select (1-3): " calc_mode
    calc_mode="$(trim "$calc_mode")"
    
    case "$calc_mode" in
      1) calc_mode="rx"; break ;;
      2) calc_mode="tx"; break ;;
      3) calc_mode="both"; break ;;
      *) add_log "Invalid selection: $calc_mode" ;;
    esac
  done
  
  local limit_bytes
  limit_bytes=$(gb_to_bytes "$limit_gb")
  
  # Save config
  save_limit_config "$id" "$limit_bytes" "$current_rx" "$current_tx" "1" "$calc_mode"
  
  add_log "Tunnel limit set: ${limit_gb} GB"
  
  render
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                    TUNNEL LIMIT CONFIGURED                         │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  printf "│ %-67s │\n" "Tunnel: GRE${id}"
  printf "│ %-67s │\n" "Type: Entire Tunnel"
  printf "│ %-67s │\n" "Limit: ${limit_gb} GB"
  printf "│ %-67s │\n" "Mode: $(calc_mode_to_text $calc_mode)"
  printf "│ %-67s │\n" "Status: ENABLED"
  echo "└─────────────────────────────────────────────────────────────────────┘"
  echo
  echo "The tunnel will automatically STOP when limit is reached."
  pause_enter
}

set_port_limit() {
  local id="$1"
  
  # Get ports for this GRE
  local -a existing_ports
  mapfile -t existing_ports < <(get_gre_ports "$id")
  
  if ((${#existing_ports[@]} == 0)); then
    die_soft "No ports found for GRE${id}."
    return 0
  fi
  
  # Show available ports
  render
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                  AVAILABLE PORTS - GRE${id}                           │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  printf "│ %-67s │\n" "Ports: ${existing_ports[*]}"
  echo "└─────────────────────────────────────────────────────────────────────┘"
  echo
  
  # Ask for port
  local port=""
  while true; do
    read -r -e -p "Enter port number to limit: " port
    port="$(trim "$port")"
    
    if [[ -z "$port" ]]; then
      add_log "Empty input."
      continue
    fi
    
    if ! valid_port "$port"; then
      add_log "Invalid port: $port"
      continue
    fi
    
    # Check if port exists in haproxy config
    local found=0
    for p in "${existing_ports[@]}"; do
      [[ "$p" == "$port" ]] && found=1 && break
    done
    
    if ((found == 0)); then
      add_log "Port $port not found in GRE${id} config."
      continue
    fi
    
    break
  done
  
  # Setup iptables counter for this port
  add_log "Setting up traffic counter for port $port..."
  setup_port_counter "$id" "$port"
  
  # Get current traffic (will be 0 for new counter)
  local traffic_info
  traffic_info=$(get_port_traffic "$id" "$port")
  local current_rx current_tx
  read -r current_rx current_tx <<< "$traffic_info"
  
  # Ask for limit
  local limit_gb=""
  while true; do
    render
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│              SET PORT LIMIT - GRE${id} PORT ${port}                     │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    printf "│ %-67s │\n" "Current RX: $(bytes_to_human $current_rx)"
    printf "│ %-67s │\n" "Current TX: $(bytes_to_human $current_tx)"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo
    read -r -e -p "Enter traffic limit in GB (e.g., 10 or 5.5): " limit_gb
    limit_gb="$(trim "$limit_gb")"
    
    if [[ -z "$limit_gb" ]]; then
      add_log "Empty input."
      continue
    fi
    
    if [[ "$limit_gb" =~ ^[0-9]+\.?[0-9]*$ ]] && awk "BEGIN {exit !($limit_gb > 0)}"; then
      break
    else
      add_log "Invalid input: $limit_gb"
    fi
  done
  
  # Ask for calculation mode
  local calc_mode=""
  while true; do
    render
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│                    CALCULATION MODE                                │"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo
    echo "1) Download Only (RX)"
    echo "2) Upload Only (TX)"
    echo "3) Download + Upload (RX+TX)"
    echo
    read -r -e -p "Select (1-3): " calc_mode
    calc_mode="$(trim "$calc_mode")"
    
    case "$calc_mode" in
      1) calc_mode="rx"; break ;;
      2) calc_mode="tx"; break ;;
      3) calc_mode="both"; break ;;
      *) add_log "Invalid selection" ;;
    esac
  done
  
  local limit_bytes
  limit_bytes=$(gb_to_bytes "$limit_gb")
  
  # Save port config
  save_port_limit_config "$id" "$port" "$limit_bytes" "$current_rx" "$current_tx" "1" "$calc_mode"
  
  add_log "Port limit set: ${limit_gb} GB for port $port"
  
  render
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                    PORT LIMIT CONFIGURED                           │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  printf "│ %-67s │\n" "Tunnel: GRE${id}"
  printf "│ %-67s │\n" "Port: ${port}"
  printf "│ %-67s │\n" "Limit: ${limit_gb} GB"
  printf "│ %-67s │\n" "Mode: $(calc_mode_to_text $calc_mode)"
  printf "│ %-67s │\n" "Status: ENABLED"
  echo "└─────────────────────────────────────────────────────────────────────┘"
  echo
  echo "The port will be BLOCKED when limit is reached."
  pause_enter
}

view_traffic_usage() {
  render
  add_log "Selected: View Traffic Usage"
  render
  
  mapfile -t GRE_IDS < <(get_gre_ids)
  
  if ((${#GRE_IDS[@]} == 0)); then
    die_soft "No GRE tunnels found."
    return 0
  fi
  
  render
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                       TRAFFIC USAGE REPORT                         │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  
  local id
  for id in "${GRE_IDS[@]}"; do
    local iface="gre${id}"
    local status="DOWN"
    local rx=0 tx=0 used=0 limit_bytes=0 limit_str="No Limit" percent="-"
    local base_rx=0 base_tx=0 enabled="N/A"
    
    if [[ -d "/sys/class/net/${iface}" ]]; then
      status="UP"
      local traffic_info
      traffic_info=$(get_tunnel_traffic "$id")
      read -r rx tx <<< "$traffic_info"
    fi
    
    # Check if limit is set
    local cfg="${LIMIT_DIR}/gre${id}.conf"
    if [[ -f "$cfg" ]]; then
      source "$cfg"
      limit_bytes="${LIMIT_BYTES:-0}"
      base_rx="${BASE_RX:-0}"
      base_tx="${BASE_TX:-0}"
      enabled="${ENABLED:-0}"
      
      local used_rx=$((rx - base_rx))
      local used_tx=$((tx - base_tx))
      ((used_rx < 0)) && used_rx=0
      ((used_tx < 0)) && used_tx=0
      used=$((used_rx + used_tx))
      
      if ((limit_bytes > 0)); then
        limit_str="$(bytes_to_human $limit_bytes)"
        percent=$(awk "BEGIN {printf \"%.1f\", ($used/$limit_bytes)*100}")
        [[ "$enabled" == "1" ]] && enabled="ON" || enabled="OFF"
      fi
    fi
    
    local total=$((rx + tx))
    
    printf "│ %-67s │\n" "─────────────────────────────────────────────────────────────────"
    printf "│ %-67s │\n" "GRE${id} [${status}]  Limit: ${enabled}"
    printf "│ %-67s │\n" "  Total RX (Download): $(bytes_to_human $rx)"
    printf "│ %-67s │\n" "  Total TX (Upload): $(bytes_to_human $tx)"
    if [[ -f "$cfg" ]] && ((limit_bytes > 0)); then
      local calc_mode="${CALC_MODE:-both}"
      local used_rx=$((rx - base_rx))
      local used_tx=$((tx - base_tx))
      ((used_rx < 0)) && used_rx=0
      ((used_tx < 0)) && used_tx=0
      
      # Calculate based on mode
      case "$calc_mode" in
        rx) used=$used_rx ;;
        tx) used=$used_tx ;;
        both|*) used=$((used_rx + used_tx)) ;;
      esac
      
      percent=$(awk "BEGIN {printf \"%.1f\", ($used/$limit_bytes)*100}")
      
      printf "│ %-67s │\n" "  Mode: $(calc_mode_to_text $calc_mode)"
      printf "│ %-67s │\n" "  Used: $(bytes_to_human $used) / ${limit_str} (${percent}%)"
      
      # Progress bar
      local bar_len=40
      local filled=$(awk "BEGIN {printf \"%.0f\", ($percent/100)*$bar_len}")
      ((filled > bar_len)) && filled=$bar_len
      local empty=$((bar_len - filled))
      local bar=""
      for ((i=0; i<filled; i++)); do bar+="█"; done
      for ((i=0; i<empty; i++)); do bar+="░"; done
      printf "│ %-67s │\n" "  [${bar}]"
    fi
    
    # Show port-specific limits for this GRE
    for port_cfg in "${LIMIT_DIR}"/gre${id}_port*.conf; do
      [[ -f "$port_cfg" ]] || continue
      
      source "$port_cfg"
      [[ "$LIMIT_TYPE" != "port" ]] && continue
      
      local p_rx p_tx p_used p_percent p_enabled
      read -r p_rx p_tx <<< "$(get_port_traffic "$id" "$PORT")"
      
      local p_used_rx=$((p_rx - BASE_RX))
      local p_used_tx=$((p_tx - BASE_TX))
      ((p_used_rx < 0)) && p_used_rx=0
      ((p_used_tx < 0)) && p_used_tx=0
      
      case "${CALC_MODE:-both}" in
        rx) p_used=$p_used_rx ;;
        tx) p_used=$p_used_tx ;;
        both|*) p_used=$((p_used_rx + p_used_tx)) ;;
      esac
      
      p_percent=$(awk "BEGIN {printf \"%.1f\", ($p_used/$LIMIT_BYTES)*100}")
      [[ "$ENABLED" == "1" ]] && p_enabled="ON" || p_enabled="OFF"
      
      printf "│ %-67s │\n" "  ├─ Port ${PORT}: Limit ${p_enabled}"
      printf "│ %-67s │\n" "  │  Used: $(bytes_to_human $p_used) / $(bytes_to_human $LIMIT_BYTES) (${p_percent}%)"
      
      # Mini progress bar
      local p_bar_len=30
      local p_filled=$(awk "BEGIN {printf \"%.0f\", ($p_percent/100)*$p_bar_len}")
      ((p_filled > p_bar_len)) && p_filled=$p_bar_len
      local p_empty=$((p_bar_len - p_filled))
      local p_bar=""
      for ((i=0; i<p_filled; i++)); do p_bar+="█"; done
      for ((i=0; i<p_empty; i++)); do p_bar+="░"; done
      printf "│ %-67s │\n" "  │  [${p_bar}]"
    done
  done
  
  echo "└─────────────────────────────────────────────────────────────────────┘"
  pause_enter
}

# Get list of port limits for a GRE
get_port_limits() {
  local id="$1"
  local -a ports=()
  for cfg in "${LIMIT_DIR}"/gre${id}_port*.conf; do
    [[ -f "$cfg" ]] || continue
    local port=$(basename "$cfg" | sed "s/gre${id}_port\([0-9]*\)\.conf/\1/")
    ports+=("$port")
  done
  printf "%s\n" "${ports[@]}" | sort -n
}

reset_traffic_counter() {
  render
  add_log "Selected: Reset Traffic Counter"
  render
  
  mapfile -t GRE_IDS < <(get_gre_ids)
  
  if ((${#GRE_IDS[@]} == 0)); then
    die_soft "No GRE tunnels found."
    return 0
  fi
  
  # Build list of all limits (tunnel + port)
  local -a LIMIT_LABELS=()
  local -a LIMIT_TYPES=()
  local -a LIMIT_IDS=()
  local -a LIMIT_PORTS=()
  
  local id
  for id in "${GRE_IDS[@]}"; do
    # Check tunnel limit
    local cfg="${LIMIT_DIR}/gre${id}.conf"
    if [[ -f "$cfg" ]]; then
      LIMIT_LABELS+=("GRE${id} - Entire Tunnel")
      LIMIT_TYPES+=("tunnel")
      LIMIT_IDS+=("$id")
      LIMIT_PORTS+=("")
    fi
    
    # Check port limits
    for port_cfg in "${LIMIT_DIR}"/gre${id}_port*.conf; do
      [[ -f "$port_cfg" ]] || continue
      source "$port_cfg"
      LIMIT_LABELS+=("GRE${id} - Port ${PORT}")
      LIMIT_TYPES+=("port")
      LIMIT_IDS+=("$id")
      LIMIT_PORTS+=("$PORT")
    done
  done
  
  if ((${#LIMIT_LABELS[@]} == 0)); then
    die_soft "No traffic limits configured."
    return 0
  fi
  
  if ! menu_select_index "Reset Traffic Counter" "Select limit to reset:" "${LIMIT_LABELS[@]}"; then
    return 0
  fi
  
  local idx="$MENU_SELECTED"
  local limit_type="${LIMIT_TYPES[$idx]}"
  id="${LIMIT_IDS[$idx]}"
  local port="${LIMIT_PORTS[$idx]}"
  
  if [[ "$limit_type" == "tunnel" ]]; then
    reset_tunnel_counter "$id"
  else
    reset_port_counter "$id" "$port"
  fi
}

reset_tunnel_counter() {
  local id="$1"
  local cfg="${LIMIT_DIR}/gre${id}.conf"
  
  # Get current traffic values
  local traffic_info rx tx
  traffic_info=$(get_tunnel_traffic "$id")
  read -r rx tx <<< "$traffic_info"
  
  # Read current limit
  source "$cfg"
  local limit_bytes="${LIMIT_BYTES:-0}"
  local calc_mode="${CALC_MODE:-both}"
  
  # Confirmation
  while true; do
    render
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│                    RESET TUNNEL COUNTER                            │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    printf "│ %-67s │\n" "Tunnel: GRE${id}"
    printf "│ %-67s │\n" "This will reset the usage counter to ZERO"
    printf "│ %-67s │\n" "and RE-ENABLE the limit if it was disabled."
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo
    echo "Type: YES (confirm)  or  NO (cancel)"
    local confirm=""
    read -r -e -p "Confirm: " confirm
    confirm="$(trim "$confirm")"
    
    if [[ "$confirm" == "NO" || "$confirm" == "no" ]]; then
      add_log "Reset cancelled for GRE${id}"
      return 0
    fi
    if [[ "$confirm" == "YES" ]]; then
      break
    fi
    add_log "Please type YES or NO."
  done
  
  # Save new config with current values as base (reset counter)
  save_limit_config "$id" "$limit_bytes" "$rx" "$tx" "1" "$calc_mode"
  
  # Restart tunnel if it was stopped
  if [[ ! -d "/sys/class/net/gre${id}" ]]; then
    add_log "Starting GRE${id} tunnel..."
    systemctl start "gre${id}.service" >/dev/null 2>&1 || true
  fi
  
  add_log "Traffic counter reset for GRE${id}"
  
  render
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                    COUNTER RESET COMPLETED                         │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  printf "│ %-67s │\n" "Tunnel: GRE${id}"
  printf "│ %-67s │\n" "Limit: $(bytes_to_human $limit_bytes)"
  printf "│ %-67s │\n" "Mode: $(calc_mode_to_text $calc_mode)"
  printf "│ %-67s │\n" "Used: 0 B (reset)"
  printf "│ %-67s │\n" "Status: ENABLED"
  echo "└─────────────────────────────────────────────────────────────────────┘"
  pause_enter
}

reset_port_counter() {
  local id="$1"
  local port="$2"
  local cfg="${LIMIT_DIR}/gre${id}_port${port}.conf"
  
  # Read current limit
  source "$cfg"
  local limit_bytes="${LIMIT_BYTES:-0}"
  local calc_mode="${CALC_MODE:-both}"
  
  # Get current traffic from iptables
  local traffic_info rx tx
  traffic_info=$(get_port_traffic "$id" "$port")
  read -r rx tx <<< "$traffic_info"
  
  # Confirmation
  while true; do
    render
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│                    RESET PORT COUNTER                              │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    printf "│ %-67s │\n" "Tunnel: GRE${id} - Port ${port}"
    printf "│ %-67s │\n" "This will reset the usage counter to ZERO"
    printf "│ %-67s │\n" "and UNBLOCK the port if it was blocked."
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo
    echo "Type: YES (confirm)  or  NO (cancel)"
    local confirm=""
    read -r -e -p "Confirm: " confirm
    confirm="$(trim "$confirm")"
    
    if [[ "$confirm" == "NO" || "$confirm" == "no" ]]; then
      add_log "Reset cancelled for GRE${id} port ${port}"
      return 0
    fi
    if [[ "$confirm" == "YES" ]]; then
      break
    fi
    add_log "Please type YES or NO."
  done
  
  # Unblock port if blocked
  unblock_port "$port"
  add_log "Port ${port} unblocked"
  
  # Reset iptables counter by recreating chain
  setup_port_counter "$id" "$port"
  
  # Get new base values (should be 0 or close to it)
  traffic_info=$(get_port_traffic "$id" "$port")
  read -r rx tx <<< "$traffic_info"
  
  # Save new config
  save_port_limit_config "$id" "$port" "$limit_bytes" "$rx" "$tx" "1" "$calc_mode"
  
  add_log "Traffic counter reset for GRE${id} port ${port}"
  
  render
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                    PORT COUNTER RESET COMPLETED                    │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  printf "│ %-67s │\n" "Tunnel: GRE${id} - Port ${port}"
  printf "│ %-67s │\n" "Limit: $(bytes_to_human $limit_bytes)"
  printf "│ %-67s │\n" "Mode: $(calc_mode_to_text $calc_mode)"
  printf "│ %-67s │\n" "Used: 0 B (reset)"
  printf "│ %-67s │\n" "Status: ENABLED (port unblocked)"
  echo "└─────────────────────────────────────────────────────────────────────┘"
  pause_enter
}

remove_traffic_limit() {
  render
  add_log "Selected: Remove Traffic Limit"
  render
  
  mapfile -t GRE_IDS < <(get_gre_ids)
  
  if ((${#GRE_IDS[@]} == 0)); then
    die_soft "No GRE tunnels found."
    return 0
  fi
  
  # Build list of all limits (tunnel + port)
  local -a LIMIT_LABELS=()
  local -a LIMIT_TYPES=()
  local -a LIMIT_IDS=()
  local -a LIMIT_PORTS=()
  
  local id
  for id in "${GRE_IDS[@]}"; do
    # Check tunnel limit
    local cfg="${LIMIT_DIR}/gre${id}.conf"
    if [[ -f "$cfg" ]]; then
      LIMIT_LABELS+=("GRE${id} - Entire Tunnel")
      LIMIT_TYPES+=("tunnel")
      LIMIT_IDS+=("$id")
      LIMIT_PORTS+=("")
    fi
    
    # Check port limits
    for port_cfg in "${LIMIT_DIR}"/gre${id}_port*.conf; do
      [[ -f "$port_cfg" ]] || continue
      source "$port_cfg"
      LIMIT_LABELS+=("GRE${id} - Port ${PORT}")
      LIMIT_TYPES+=("port")
      LIMIT_IDS+=("$id")
      LIMIT_PORTS+=("$PORT")
    done
  done
  
  if ((${#LIMIT_LABELS[@]} == 0)); then
    die_soft "No traffic limits configured."
    return 0
  fi
  
  if ! menu_select_index "Remove Traffic Limit" "Select limit to remove:" "${LIMIT_LABELS[@]}"; then
    return 0
  fi
  
  local idx="$MENU_SELECTED"
  local limit_type="${LIMIT_TYPES[$idx]}"
  id="${LIMIT_IDS[$idx]}"
  local port="${LIMIT_PORTS[$idx]}"
  
  if [[ "$limit_type" == "tunnel" ]]; then
    remove_tunnel_limit "$id"
  else
    remove_port_limit "$id" "$port"
  fi
}

remove_tunnel_limit() {
  local id="$1"
  local cfg="${LIMIT_DIR}/gre${id}.conf"
  
  # Confirmation
  while true; do
    render
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│                    REMOVE TUNNEL LIMIT                             │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    printf "│ %-67s │\n" "Tunnel: GRE${id}"
    printf "│ %-67s │\n" "This will REMOVE the traffic limit completely."
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo
    echo "Type: YES (confirm)  or  NO (cancel)"
    local confirm=""
    read -r -e -p "Confirm: " confirm
    confirm="$(trim "$confirm")"
    
    if [[ "$confirm" == "NO" || "$confirm" == "no" ]]; then
      add_log "Remove limit cancelled for GRE${id}"
      return 0
    fi
    if [[ "$confirm" == "YES" ]]; then
      break
    fi
    add_log "Please type YES or NO."
  done
  
  # Remove config file
  rm -f "$cfg" 2>/dev/null || true
  add_log "Traffic limit removed for GRE${id}"
  
  # Start tunnel if it was stopped
  if [[ ! -d "/sys/class/net/gre${id}" ]]; then
    add_log "Starting GRE${id} tunnel..."
    systemctl start "gre${id}.service" >/dev/null 2>&1 || true
    sleep 1
    if [[ -d "/sys/class/net/gre${id}" ]]; then
      add_log "GRE${id} tunnel started successfully."
    else
      add_log "WARNING: Failed to start GRE${id} tunnel."
    fi
  fi
  
  render
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                    TUNNEL LIMIT REMOVED                            │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  printf "│ %-67s │\n" "Tunnel: GRE${id}"
  printf "│ %-67s │\n" "Limit config removed"
  if [[ -d "/sys/class/net/gre${id}" ]]; then
    printf "│ %-67s │\n" "Tunnel status: RUNNING"
  else
    printf "│ %-67s │\n" "Tunnel status: STOPPED (start manually)"
  fi
  echo "└─────────────────────────────────────────────────────────────────────┘"
  pause_enter
}

remove_port_limit() {
  local id="$1"
  local port="$2"
  local cfg="${LIMIT_DIR}/gre${id}_port${port}.conf"
  
  # Confirmation
  while true; do
    render
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│                    REMOVE PORT LIMIT                               │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    printf "│ %-67s │\n" "Tunnel: GRE${id} - Port ${port}"
    printf "│ %-67s │\n" "This will REMOVE the port limit and UNBLOCK the port."
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo
    echo "Type: YES (confirm)  or  NO (cancel)"
    local confirm=""
    read -r -e -p "Confirm: " confirm
    confirm="$(trim "$confirm")"
    
    if [[ "$confirm" == "NO" || "$confirm" == "no" ]]; then
      add_log "Remove limit cancelled for GRE${id} port ${port}"
      return 0
    fi
    if [[ "$confirm" == "YES" ]]; then
      break
    fi
    add_log "Please type YES or NO."
  done
  
  # Remove config file
  rm -f "$cfg" 2>/dev/null || true
  
  # Unblock port
  unblock_port "$port"
  
  # Remove iptables counter chains
  remove_port_counter "$id" "$port"
  
  add_log "Port limit removed for GRE${id} port ${port}"
  
  render
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                    PORT LIMIT REMOVED                              │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  printf "│ %-67s │\n" "Tunnel: GRE${id} - Port ${port}"
  printf "│ %-67s │\n" "Limit config removed"
  printf "│ %-67s │\n" "Port status: UNBLOCKED"
  echo "└─────────────────────────────────────────────────────────────────────┘"
  pause_enter
}

edit_traffic_limit() {
  render
  add_log "Selected: Edit Traffic Limit"
  render
  
  mapfile -t GRE_IDS < <(get_gre_ids)
  
  if ((${#GRE_IDS[@]} == 0)); then
    die_soft "No GRE tunnels found."
    return 0
  fi
  
  # Build list of all limits (tunnel + port)
  local -a LIMIT_LABELS=()
  local -a LIMIT_TYPES=()
  local -a LIMIT_IDS=()
  local -a LIMIT_PORTS=()
  
  local id
  for id in "${GRE_IDS[@]}"; do
    # Check tunnel limit
    local cfg="${LIMIT_DIR}/gre${id}.conf"
    if [[ -f "$cfg" ]]; then
      source "$cfg"
      LIMIT_LABELS+=("GRE${id} - Tunnel ($(bytes_to_human ${LIMIT_BYTES:-0}))")
      LIMIT_TYPES+=("tunnel")
      LIMIT_IDS+=("$id")
      LIMIT_PORTS+=("")
    fi
    
    # Check port limits
    for port_cfg in "${LIMIT_DIR}"/gre${id}_port*.conf; do
      [[ -f "$port_cfg" ]] || continue
      source "$port_cfg"
      LIMIT_LABELS+=("GRE${id} - Port ${PORT} ($(bytes_to_human ${LIMIT_BYTES:-0}))")
      LIMIT_TYPES+=("port")
      LIMIT_IDS+=("$id")
      LIMIT_PORTS+=("$PORT")
    done
  done
  
  if ((${#LIMIT_LABELS[@]} == 0)); then
    die_soft "No traffic limits configured."
    return 0
  fi
  
  if ! menu_select_index "Edit Traffic Limit" "Select limit to edit:" "${LIMIT_LABELS[@]}"; then
    return 0
  fi
  
  local idx="$MENU_SELECTED"
  local limit_type="${LIMIT_TYPES[$idx]}"
  id="${LIMIT_IDS[$idx]}"
  local port="${LIMIT_PORTS[$idx]}"
  
  if [[ "$limit_type" == "tunnel" ]]; then
    edit_tunnel_limit "$id"
  else
    edit_port_limit "$id" "$port"
  fi
}

edit_tunnel_limit() {
  local id="$1"
  local cfg="${LIMIT_DIR}/gre${id}.conf"
  source "$cfg"
  
  local old_limit_bytes="${LIMIT_BYTES:-0}"
  local base_rx="${BASE_RX:-0}"
  local base_tx="${BASE_TX:-0}"
  local enabled="${ENABLED:-1}"
  local calc_mode="${CALC_MODE:-both}"
  
  # Get current usage
  local traffic_info rx tx used_rx used_tx used
  traffic_info=$(get_tunnel_traffic "$id")
  read -r rx tx <<< "$traffic_info"
  used_rx=$((rx - base_rx))
  used_tx=$((tx - base_tx))
  ((used_rx < 0)) && used_rx=0
  ((used_tx < 0)) && used_tx=0
  
  case "$calc_mode" in
    rx) used=$used_rx ;;
    tx) used=$used_tx ;;
    both|*) used=$((used_rx + used_tx)) ;;
  esac
  
  local new_limit_gb=""
  while true; do
    render
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│                    EDIT TUNNEL LIMIT - GRE${id}                       │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    printf "│ %-67s │\n" "Current Limit: $(bytes_to_human $old_limit_bytes)"
    printf "│ %-67s │\n" "Current Mode: $(calc_mode_to_text $calc_mode)"
    printf "│ %-67s │\n" "Used So Far: $(bytes_to_human $used)"
    printf "│ %-67s │\n" "Status: $( [[ "$enabled" == "1" ]] && echo "ENABLED" || echo "DISABLED" )"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo
    read -r -e -p "Enter NEW limit in GB (e.g., 20 or 15.5): " new_limit_gb
    new_limit_gb="$(trim "$new_limit_gb")"
    
    if [[ -z "$new_limit_gb" ]]; then
      add_log "Empty input."
      continue
    fi
    
    if [[ "$new_limit_gb" =~ ^[0-9]+\.?[0-9]*$ ]] && awk "BEGIN {exit !($new_limit_gb > 0)}"; then
      break
    else
      add_log "Invalid input: $new_limit_gb"
    fi
  done
  
  # Ask if user wants to change calculation mode
  render
  echo "Change calculation mode? Current: $(calc_mode_to_text $calc_mode)"
  echo
  echo "1) Keep current mode"
  echo "2) Download Only (RX)"
  echo "3) Upload Only (TX)"
  echo "4) Download + Upload (RX+TX)"
  echo
  local change_mode=""
  read -r -e -p "Select (1-4): " change_mode
  
  case "$change_mode" in
    2) calc_mode="rx" ;;
    3) calc_mode="tx" ;;
    4) calc_mode="both" ;;
  esac
  
  local new_limit_bytes
  new_limit_bytes=$(gb_to_bytes "$new_limit_gb")
  
  save_limit_config "$id" "$new_limit_bytes" "$base_rx" "$base_tx" "$enabled" "$calc_mode"
  
  add_log "Tunnel limit changed: $(bytes_to_human $old_limit_bytes) -> ${new_limit_gb} GB"
  
  render
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                    TUNNEL LIMIT UPDATED                            │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  printf "│ %-67s │\n" "Tunnel: GRE${id}"
  printf "│ %-67s │\n" "New Limit: ${new_limit_gb} GB"
  printf "│ %-67s │\n" "Mode: $(calc_mode_to_text $calc_mode)"
  echo "└─────────────────────────────────────────────────────────────────────┘"
  pause_enter
}

edit_port_limit() {
  local id="$1"
  local port="$2"
  local cfg="${LIMIT_DIR}/gre${id}_port${port}.conf"
  source "$cfg"
  
  local old_limit_bytes="${LIMIT_BYTES:-0}"
  local base_rx="${BASE_RX:-0}"
  local base_tx="${BASE_TX:-0}"
  local enabled="${ENABLED:-1}"
  local calc_mode="${CALC_MODE:-both}"
  
  # Get current usage
  local traffic_info rx tx used_rx used_tx used
  traffic_info=$(get_port_traffic "$id" "$port")
  read -r rx tx <<< "$traffic_info"
  used_rx=$((rx - base_rx))
  used_tx=$((tx - base_tx))
  ((used_rx < 0)) && used_rx=0
  ((used_tx < 0)) && used_tx=0
  
  case "$calc_mode" in
    rx) used=$used_rx ;;
    tx) used=$used_tx ;;
    both|*) used=$((used_rx + used_tx)) ;;
  esac
  
  local new_limit_gb=""
  while true; do
    render
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│              EDIT PORT LIMIT - GRE${id} PORT ${port}                    │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    printf "│ %-67s │\n" "Current Limit: $(bytes_to_human $old_limit_bytes)"
    printf "│ %-67s │\n" "Current Mode: $(calc_mode_to_text $calc_mode)"
    printf "│ %-67s │\n" "Used So Far: $(bytes_to_human $used)"
    printf "│ %-67s │\n" "Status: $( [[ "$enabled" == "1" ]] && echo "ENABLED" || echo "BLOCKED" )"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo
    read -r -e -p "Enter NEW limit in GB (e.g., 20 or 15.5): " new_limit_gb
    new_limit_gb="$(trim "$new_limit_gb")"
    
    if [[ -z "$new_limit_gb" ]]; then
      add_log "Empty input."
      continue
    fi
    
    if [[ "$new_limit_gb" =~ ^[0-9]+\.?[0-9]*$ ]] && awk "BEGIN {exit !($new_limit_gb > 0)}"; then
      break
    else
      add_log "Invalid input: $new_limit_gb"
    fi
  done
  
  # Ask if user wants to change calculation mode
  render
  echo "Change calculation mode? Current: $(calc_mode_to_text $calc_mode)"
  echo
  echo "1) Keep current mode"
  echo "2) Download Only (RX)"
  echo "3) Upload Only (TX)"
  echo "4) Download + Upload (RX+TX)"
  echo
  local change_mode=""
  read -r -e -p "Select (1-4): " change_mode
  
  case "$change_mode" in
    2) calc_mode="rx" ;;
    3) calc_mode="tx" ;;
    4) calc_mode="both" ;;
  esac
  
  local new_limit_bytes
  new_limit_bytes=$(gb_to_bytes "$new_limit_gb")
  
  save_port_limit_config "$id" "$port" "$new_limit_bytes" "$base_rx" "$base_tx" "$enabled" "$calc_mode"
  
  add_log "Port limit changed: $(bytes_to_human $old_limit_bytes) -> ${new_limit_gb} GB"
  
  render
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                    PORT LIMIT UPDATED                              │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  printf "│ %-67s │\n" "Tunnel: GRE${id} - Port ${port}"
  printf "│ %-67s │\n" "New Limit: ${new_limit_gb} GB"
  printf "│ %-67s │\n" "Mode: $(calc_mode_to_text $calc_mode)"
  echo "└─────────────────────────────────────────────────────────────────────┘"
  pause_enter
}

set_unlimited() {
  render
  add_log "Selected: Set Unlimited"
  render
  
  mapfile -t GRE_IDS < <(get_gre_ids)
  
  if ((${#GRE_IDS[@]} == 0)); then
    die_soft "No GRE tunnels found."
    return 0
  fi
  
  # Build list of enabled limits
  local -a LIMIT_LABELS=()
  local -a LIMIT_TYPES=()
  local -a LIMIT_IDS=()
  local -a LIMIT_PORTS=()
  
  local id
  for id in "${GRE_IDS[@]}"; do
    local cfg="${LIMIT_DIR}/gre${id}.conf"
    if [[ -f "$cfg" ]]; then
      source "$cfg"
      if [[ "$ENABLED" == "1" ]]; then
        LIMIT_LABELS+=("GRE${id} - Tunnel")
        LIMIT_TYPES+=("tunnel")
        LIMIT_IDS+=("$id")
        LIMIT_PORTS+=("")
      fi
    fi
    
    for port_cfg in "${LIMIT_DIR}"/gre${id}_port*.conf; do
      [[ -f "$port_cfg" ]] || continue
      source "$port_cfg"
      if [[ "$ENABLED" == "1" ]]; then
        LIMIT_LABELS+=("GRE${id} - Port ${PORT}")
        LIMIT_TYPES+=("port")
        LIMIT_IDS+=("$id")
        LIMIT_PORTS+=("$PORT")
      fi
    done
  done
  
  if ((${#LIMIT_LABELS[@]} == 0)); then
    die_soft "No enabled limits found."
    return 0
  fi
  
  if ! menu_select_index "Set Unlimited" "Select limit to disable:" "${LIMIT_LABELS[@]}"; then
    return 0
  fi
  
  local idx="$MENU_SELECTED"
  local limit_type="${LIMIT_TYPES[$idx]}"
  id="${LIMIT_IDS[$idx]}"
  local port="${LIMIT_PORTS[$idx]}"
  
  local cfg
  if [[ "$limit_type" == "tunnel" ]]; then
    cfg="${LIMIT_DIR}/gre${id}.conf"
  else
    cfg="${LIMIT_DIR}/gre${id}_port${port}.conf"
  fi
  
  # Disable limit
  sed -i 's/^ENABLED=1/ENABLED=0/' "$cfg"
  
  # Unblock port if it's a port limit
  if [[ "$limit_type" == "port" ]]; then
    unblock_port "$port"
  fi
  
  add_log "Limit disabled (unlimited mode)"
  
  render
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                    UNLIMITED MODE ENABLED                          │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  if [[ "$limit_type" == "tunnel" ]]; then
    printf "│ %-67s │\n" "Tunnel: GRE${id}"
  else
    printf "│ %-67s │\n" "Tunnel: GRE${id} - Port ${port}"
    printf "│ %-67s │\n" "Port: UNBLOCKED"
  fi
  printf "│ %-67s │\n" "Status: UNLIMITED (limit disabled)"
  echo "└─────────────────────────────────────────────────────────────────────┘"
  pause_enter
}

enable_limit() {
  render
  add_log "Selected: Enable Limit"
  render
  
  mapfile -t GRE_IDS < <(get_gre_ids)
  
  if ((${#GRE_IDS[@]} == 0)); then
    die_soft "No GRE tunnels found."
    return 0
  fi
  
  # Build list of disabled limits
  local -a LIMIT_LABELS=()
  local -a LIMIT_TYPES=()
  local -a LIMIT_IDS=()
  local -a LIMIT_PORTS=()
  
  local id
  for id in "${GRE_IDS[@]}"; do
    local cfg="${LIMIT_DIR}/gre${id}.conf"
    if [[ -f "$cfg" ]]; then
      source "$cfg"
      if [[ "$ENABLED" != "1" ]]; then
        LIMIT_LABELS+=("GRE${id} - Tunnel ($(bytes_to_human ${LIMIT_BYTES:-0}))")
        LIMIT_TYPES+=("tunnel")
        LIMIT_IDS+=("$id")
        LIMIT_PORTS+=("")
      fi
    fi
    
    for port_cfg in "${LIMIT_DIR}"/gre${id}_port*.conf; do
      [[ -f "$port_cfg" ]] || continue
      source "$port_cfg"
      if [[ "$ENABLED" != "1" ]]; then
        LIMIT_LABELS+=("GRE${id} - Port ${PORT} ($(bytes_to_human ${LIMIT_BYTES:-0}))")
        LIMIT_TYPES+=("port")
        LIMIT_IDS+=("$id")
        LIMIT_PORTS+=("$PORT")
      fi
    done
  done
  
  if ((${#LIMIT_LABELS[@]} == 0)); then
    die_soft "No disabled limits found."
    return 0
  fi
  
  if ! menu_select_index "Enable Limit" "Select limit to enable:" "${LIMIT_LABELS[@]}"; then
    return 0
  fi
  
  local idx="$MENU_SELECTED"
  local limit_type="${LIMIT_TYPES[$idx]}"
  id="${LIMIT_IDS[$idx]}"
  local port="${LIMIT_PORTS[$idx]}"
  
  local cfg
  if [[ "$limit_type" == "tunnel" ]]; then
    cfg="${LIMIT_DIR}/gre${id}.conf"
  else
    cfg="${LIMIT_DIR}/gre${id}_port${port}.conf"
  fi
  
  # Enable limit
  sed -i 's/^ENABLED=0/ENABLED=1/' "$cfg"
  
  add_log "Limit enabled"
  
  render
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│                    LIMIT RE-ENABLED                                │"
  echo "├─────────────────────────────────────────────────────────────────────┤"
  if [[ "$limit_type" == "tunnel" ]]; then
    printf "│ %-67s │\n" "Tunnel: GRE${id}"
  else
    printf "│ %-67s │\n" "Tunnel: GRE${id} - Port ${port}"
  fi
  printf "│ %-67s │\n" "Status: ENABLED"
  echo "└─────────────────────────────────────────────────────────────────────┘"
  pause_enter
}

traffic_limit_menu() {
  local sel=""
  
  while true; do
    render
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│                    TRAFFIC LIMIT MANAGEMENT                        │"
    echo "├─────────────────────────────────────────────────────────────────────┤"
    printf "│ %-67s │\n" "NOTE: Use this feature on IRAN server only"
    printf "│ %-67s │\n" "      (both sides have same traffic)"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo
    echo "1) Set Traffic Limit"
    echo "2) Edit Traffic Limit"
    echo "3) View Traffic Usage"
    echo "4) Reset Traffic Counter"
    echo "5) Set Unlimited"
    echo "6) Enable Limit"
    echo "7) Remove Limit Config"
    echo "0) Back"
    echo
    read -r -e -p "Select: " sel
    sel="$(trim "$sel")"
    
    case "$sel" in
      1) set_traffic_limit ;;
      2) edit_traffic_limit ;;
      3) view_traffic_usage ;;
      4) reset_traffic_counter ;;
      5) set_unlimited ;;
      6) enable_limit ;;
      7) remove_traffic_limit ;;
      0) return 0 ;;
      *) add_log "Invalid selection: $sel" ;;
    esac
  done
}

# ==================== MAIN MENU ====================

main_menu() {
  local choice=""
  while true; do
    render
    echo "1 > IRAN Setup"
    echo "2 > KHAREJ Setup"
    echo "3 > Services Management"
    echo "4 > Uninstall & Clean"
    echo "5 > Add Tunnel Port"
    echo "6 > Remove Tunnel Port"
    echo "7 > Traffic Limit"
    echo "0 > Exit"
    echo
    read -r -e -p "Select option: " choice
    choice="$(trim "$choice")"

    case "$choice" in
      1) add_log "Selected: IRAN Setup"; iran_setup ;;
      2) add_log "Selected: KHAREJ Setup"; kharej_setup ;;
      3) add_log "Selected: Services Management"; services_management ;;
      4) add_log "Selected: Uninstall & Clean"; uninstall_clean ;;
      5) add_log "Selected: Add Tunnel Port"; add_tunnel_port ;;
      6) add_log "Selected: Remove Tunnel Port"; remove_tunnel_port ;;
      7) add_log "Selected: Traffic Limit"; traffic_limit_menu ;;
      0) add_log "Bye!"; render; exit 0 ;;
      *) add_log "Invalid option: $choice" ;;
    esac
  done
}

ensure_root "$@"
add_log "GRE TUNL - Tunnel Manager"
main_menu
