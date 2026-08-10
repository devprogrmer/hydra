#!/usr/bin/env bash
# ============================================================================
#  hydra — Multi-Exit Gaming Tunnel
#  One script for both the Iran server (hub) and the exit server (foreign exit)
#
#  Install: bash <(curl -fsSL https://raw.githubusercontent.com/devprogrmer/hydra/main/install.sh)
#  Run:     hydra
# ============================================================================
set -uo pipefail

VERSION="2.0.0"
DIR="/etc/hydra"
EXITS="$DIR/exits.d"          # hub: one file per exit server
LINKS="$DIR/links.d"          # exit: one file per hub
CLIENTS="$DIR/clients"
CONF="$DIR/hydra.conf"
ROLE_FILE="$DIR/role"
STATE="/run/hydra"
BINDIR="/usr/local/bin"
RT_ID=200; RT_NAME="hydra"
LOG="/var/log/hydra.log"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; M=$'\e[35m'; W=$'\e[97m'; D=$'\e[90m'; N=$'\e[0m'
BLD=$'\e[1m'

# ---------------------------------------------------------------- helpers --
msg()  { echo -e "${B}::${N} $*"; }
ok()   { echo -e "${G}✔${N} $*"; }
warn() { echo -e "${Y}!${N} $*"; }
err()  { echo -e "${R}✘${N} $*" >&2; }
die()  { err "$*"; exit 1; }
logit(){ echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null || true; }

ask() {  # ask "question" "default"  -> value on stdout
  local p="$1" d="${2:-}" v
  printf "${B}?${N} %s%s: " "$p" "${d:+ ${D}[$d]${N}}" >&2
  read -r v </dev/tty
  echo "${v:-$d}"
}
askyn() { # askyn "question" [y|n]  -> 0/1
  local p="$1" d="${2:-y}" v
  printf "${B}?${N} %s ${D}[%s/%s]${N}: " "$p" "$([[ $d == y ]] && echo Y || echo y)" "$([[ $d == n ]] && echo N || echo n)" >&2
  read -r v </dev/tty; v="${v:-$d}"
  [[ "${v,,}" == y* ]]
}
pause() { printf "\n${D}Press Enter to return to the menu…${N}" >&2; read -r </dev/tty; }
hr()    { printf "${D}"; printf '─%.0s' $(seq 1 62); printf "${N}\n"; }

valid_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$1" =~ ^[0-9a-fA-F:]+$ ]]; }

banner() {
cat <<EOF
${M}${BLD}
   ▄▄   ▄▄ ▄▄  ▄▄ ▄▄▄▄  ▄▄▄▄   ▄▄▄
   ██   ██ ██  ██ ██  ██ ██  ██ ██▄▄
   ██▄▄▄██ ▀█▄▄█▀ ██▄▄█▀ ██▄▄█▀ ██▄▄▄
   ██   ██   ██   ██  ██ ██  ██ ██  ██   ${N}${D}v$VERSION${N}
${N}${D}   Multi-exit gaming tunnel · FEC · faketcp · BBR${N}
EOF
}

[[ $EUID -eq 0 ]] || die "Run as root:  sudo hydra"

# ---------------------------------------------------------------- defaults --
CLIENT_NET="10.77.0.0/24"; CLIENT_ADDR="10.77.0.1"; CLIENT_PREFIX="10.77.0"
CLIENT_WG_PORT="51820"; LINK_PREFIX="10.66"
RAW_PORT_BASE="39000"; SPD_LOCAL_BASE="44000"; RAW_LOCAL_BASE="33000"
FEC="10:5"; SWITCH_MARGIN="15"; CHECK_INTERVAL="5"; HYSTERESIS="3"; PUBLIC_IF=""
[[ -f "$CONF" ]] && . "$CONF"

save_conf() {
  mkdir -p "$DIR"
  cat >"$CONF" <<EOF
CLIENT_NET=$CLIENT_NET
CLIENT_ADDR=$CLIENT_ADDR
CLIENT_PREFIX=$CLIENT_PREFIX
CLIENT_WG_PORT=$CLIENT_WG_PORT
LINK_PREFIX=$LINK_PREFIX
RAW_PORT_BASE=$RAW_PORT_BASE
SPD_LOCAL_BASE=$SPD_LOCAL_BASE
RAW_LOCAL_BASE=$RAW_LOCAL_BASE
FEC=$FEC
SWITCH_MARGIN=$SWITCH_MARGIN
CHECK_INTERVAL=$CHECK_INTERVAL
HYSTERESIS=$HYSTERESIS
PUBLIC_IF=$PUBLIC_IF
EOF
  chmod 600 "$CONF"
}

detect_if() { ip -4 route show default 2>/dev/null | awk '/default/{print $5; exit}'; }
pub_ip() {
  curl -s --max-time 6 https://api.ipify.org 2>/dev/null \
    || ip -4 addr show "$(detect_if)" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1
}
role() { cat "$ROLE_FILE" 2>/dev/null || echo ""; }

# ============================================================== base setup ====
install_deps() {
  msg "Installing dependencies…"
  if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq wireguard-tools iproute2 iptables iputils-ping curl tar \
                           qrencode ca-certificates >/dev/null 2>&1
  elif command -v dnf >/dev/null; then
    dnf install -y -q wireguard-tools iproute iptables iputils curl tar qrencode >/dev/null 2>&1
  elif command -v yum >/dev/null; then
    yum install -y -q wireguard-tools iproute iptables iputils curl tar qrencode >/dev/null 2>&1
  else
    die "Only Debian/Ubuntu and RHEL/Rocky/Alma are supported."
  fi
  ok "Dependencies installed."
}

install_binaries() {
  local arch tmp
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64|armv7l|armv6l) arch=arm ;;
    *) die "Architecture $(uname -m) is not supported." ;;
  esac
  tmp="$(mktemp -d)"
  if [[ ! -x "$BINDIR/udp2raw" ]]; then
    msg "Downloading udp2raw…"
    curl -fsSL -o "$tmp/u.tgz" https://github.com/wangyu-/udp2raw/releases/latest/download/udp2raw_binaries.tar.gz \
      && tar -xzf "$tmp/u.tgz" -C "$tmp" && install -m755 "$tmp/udp2raw_$arch" "$BINDIR/udp2raw" \
      || warn "Failed to download udp2raw."
  fi
  if [[ ! -x "$BINDIR/speederv2" ]]; then
    msg "Downloading UDPspeeder…"
    curl -fsSL -o "$tmp/s.tgz" https://github.com/wangyu-/UDPspeeder/releases/latest/download/speederv2_binaries.tar.gz \
      && tar -xzf "$tmp/s.tgz" -C "$tmp" && install -m755 "$tmp/speederv2_$arch" "$BINDIR/speederv2" \
      || warn "Failed to download UDPspeeder."
  fi
  rm -rf "$tmp"
  [[ -x "$BINDIR/udp2raw" && -x "$BINDIR/speederv2" ]] && ok "Binaries are ready."
}

apply_tune() {
  msg "Applying BBR and kernel tuning…"
  modprobe tcp_bbr 2>/dev/null || true
  echo tcp_bbr >/etc/modules-load.d/hydra-bbr.conf
  cat >/etc/sysctl.d/99-hydra.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.netfilter.nf_conntrack_max = 262144
EOF
  sysctl --system >/dev/null 2>&1
  local cc; cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  [[ "$cc" == bbr ]] && ok "BBR enabled." || warn "Current algorithm: $cc (kernel lacks BBR)"
  [[ -n "${PUBLIC_IF:-}" ]] && tc qdisc replace dev "$PUBLIC_IF" root fq 2>/dev/null
  return 0
}

install_units() {
  cat >/etc/systemd/system/hydra-raw@.service <<'EOF'
[Unit]
Description=hydra udp2raw client (%i)
After=network-online.target
[Service]
EnvironmentFile=/etc/hydra/exits.d/%i.conf
ExecStart=/usr/local/bin/udp2raw -c -l 127.0.0.1:${RAW_LOCAL} -r ${EXIT_IP}:${RAW_PORT} -k ${RAW_PASS} --raw-mode faketcp --cipher-mode aes128cbc --auth-mode hmac_sha1 -a
Restart=always
RestartSec=2
Nice=-10
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/hydra-spd@.service <<'EOF'
[Unit]
Description=hydra UDPspeeder FEC client (%i)
After=network-online.target
[Service]
EnvironmentFile=/etc/hydra/exits.d/%i.conf
ExecStart=/usr/local/bin/speederv2 -c -l 127.0.0.1:${SPD_LOCAL} -r ${SPD_REMOTE} -f ${FEC} --mode 0 --timeout 0 --mtu ${SPD_MTU} -k ${SPD_PASS} --report 0
Restart=always
RestartSec=2
Nice=-10
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/hydra-link@.service <<'EOF'
[Unit]
Description=hydra link to exit %i
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/hydra _link-up %i
ExecStop=/usr/local/bin/hydra _link-down %i
[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/hydra-exit-raw@.service <<'EOF'
[Unit]
Description=hydra udp2raw server (%i)
After=network-online.target
[Service]
EnvironmentFile=/etc/hydra/links.d/%i.conf
ExecStart=/usr/local/bin/udp2raw -s -l 0.0.0.0:${RAW_PORT} -r 127.0.0.1:${SPD_LOCAL} -k ${RAW_PASS} --raw-mode faketcp --cipher-mode aes128cbc --auth-mode hmac_sha1 -a
Restart=always
RestartSec=2
Nice=-10
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/hydra-exit-spd@.service <<'EOF'
[Unit]
Description=hydra UDPspeeder FEC server (%i)
After=network-online.target
[Service]
EnvironmentFile=/etc/hydra/links.d/%i.conf
ExecStart=/usr/local/bin/speederv2 -s -l ${SPD_LISTEN} -r 127.0.0.1:${WG_PORT} -f ${FEC} --mode 0 --timeout 0 --mtu ${SPD_MTU} -k ${SPD_PASS} --report 0
Restart=always
RestartSec=2
Nice=-10
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/hydra-exit-link@.service <<'EOF'
[Unit]
Description=hydra exit link %i
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/hydra _elink-up %i
ExecStop=/usr/local/bin/hydra _elink-down %i
[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/hydra-ports.service <<'EOF'
[Unit]
Description=hydra port forwarding rules
After=network-online.target hydra-rule.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/hydra _ports-apply
[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/hydra-watch.service <<'EOF'
[Unit]
Description=hydra health-check and failover
After=network-online.target
[Service]
ExecStart=/usr/local/bin/hydra _watch
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# =============================================================== hub setup ====
setup_hub() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Setting up the Iran server (hub)${N}"; hr; echo
  install_deps; install_binaries
  mkdir -p "$EXITS" "$CLIENTS" "$STATE" /etc/wireguard
  chmod 700 "$DIR" /etc/wireguard
  PUBLIC_IF="$(detect_if)"; save_conf
  echo "hub" >"$ROLE_FILE"
  apply_tune; install_units

  grep -qE "^\s*$RT_ID\s+$RT_NAME\b" /etc/iproute2/rt_tables 2>/dev/null \
    || echo "$RT_ID $RT_NAME" >>/etc/iproute2/rt_tables
  cat >/etc/systemd/system/hydra-rule.service <<EOF
[Unit]
Description=hydra policy routing
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-/sbin/ip rule add from $CLIENT_NET lookup $RT_NAME pref 100
ExecStartPost=-/sbin/iptables -t nat -A POSTROUTING -s $CLIENT_NET -o wg-+ -j MASQUERADE
ExecStartPost=-/sbin/iptables -A FORWARD -i wg0 -j ACCEPT
ExecStartPost=-/sbin/iptables -A FORWARD -o wg0 -j ACCEPT
ExecStop=-/sbin/ip rule del from $CLIENT_NET lookup $RT_NAME pref 100
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now hydra-rule >/dev/null 2>&1

  if [[ ! -f /etc/wireguard/wg0.conf ]]; then
    msg "Creating client interface (wg0)…"
    local priv pub; priv="$(wg genkey)"; pub="$(echo "$priv" | wg pubkey)"
    echo "$pub" >"$DIR/wg0.pub"
    cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $priv
Address    = $CLIENT_ADDR/24
ListenPort = $CLIENT_WG_PORT
MTU        = 1280
EOF
    chmod 600 /etc/wireguard/wg0.conf
    systemctl enable --now "wg-quick@wg0" >/dev/null 2>&1
  fi
  systemctl enable --now hydra-watch >/dev/null 2>&1
  systemctl enable --now hydra-ports >/dev/null 2>&1
  echo; ok "Iran server is ready."
  echo -e "  ${D}Now pick “Create new tunnel” from the menu.${N}"
  pause
}

setup_exit() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Setting up the exit server (foreign exit)${N}"; hr; echo
  install_deps; install_binaries
  mkdir -p "$LINKS" "$STATE" /etc/wireguard
  chmod 700 "$DIR" /etc/wireguard
  PUBLIC_IF="$(detect_if)"; save_conf
  echo "exit" >"$ROLE_FILE"
  apply_tune; install_units
  echo; ok "Exit server is ready."
  echo -e "  ${D}Now enter the token the Iran server gave you using “Connect to hub”.${N}"
  pause
}

# ========================================================= create tunnel (hub) ==
next_idx() {
  local i
  for i in $(seq 1 250); do
    grep -qs "^IDX=$i$" "$EXITS"/*.conf 2>/dev/null || { echo "$i"; return; }
  done
  echo 0
}

create_tunnel() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Create a new tunnel to an exit server${N}"; hr; echo

  local name eip mode
  name="$(ask "A name for this exit server (e.g. de1, nl1)")"
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { err "Name must be English letters, digits, or hyphens only."; pause; return; }
  [[ -f "$EXITS/$name.conf" ]] && { err "A tunnel named “$name” already exists."; pause; return; }

  eip="$(ask "Exit server IP")"
  valid_ip "$eip" || { err "Invalid IP."; pause; return; }

  echo
  echo -e "  ${W}Tunnel mode:${N}"
  echo -e "   ${G}1${N}) ${W}full${N}  ${D}— WireGuard + FEC + faketcp  (recommended, defeats UDP shaping)${N}"
  echo -e "   ${G}2${N}) ${W}fec${N}   ${D}— WireGuard + FEC          (if faketcp doesn't work on that VPS)${N}"
  echo -e "   ${G}3${N}) ${W}plain${N} ${D}— WireGuard only           (clean path, just want multi-exit)${N}"
  echo
  case "$(ask "Choice" "1")" in
    2) mode=fec ;; 3) mode=plain ;; *) mode=full ;;
  esac

  local idx; idx="$(next_idx)"
  [[ "$idx" == 0 ]] && { err "Capacity full."; pause; return; }

  local hub_priv hub_pub exit_priv exit_pub psk raw_pass spd_pass
  hub_priv="$(wg genkey)";  hub_pub="$(echo "$hub_priv" | wg pubkey)"
  exit_priv="$(wg genkey)"; exit_pub="$(echo "$exit_priv" | wg pubkey)"
  psk="$(wg genpsk)"
  raw_pass="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  spd_pass="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"

  local raw_port=$((RAW_PORT_BASE+idx)) raw_local=$((RAW_LOCAL_BASE+idx))
  local spd_local=$((SPD_LOCAL_BASE+idx)) wg_port=$((51900+idx))
  local hub_in="$LINK_PREFIX.$idx.1" exit_in="$LINK_PREFIX.$idx.2"
  local wg_mtu spd_mtu spd_remote wg_endpoint
  case "$mode" in
    full)  wg_mtu=1280; spd_mtu=1200; spd_remote="127.0.0.1:$raw_local"; wg_endpoint="127.0.0.1:$spd_local" ;;
    fec)   wg_mtu=1330; spd_mtu=1250; spd_remote="$eip:$raw_port";       wg_endpoint="127.0.0.1:$spd_local" ;;
    plain) wg_mtu=1420; spd_mtu=1250; spd_remote="-";                    wg_endpoint="$eip:$wg_port" ;;
  esac

  cat >"$EXITS/$name.conf" <<EOF
NAME=$name
IDX=$idx
MODE=$mode
EXIT_IP=$eip
HUB_IN=$hub_in
EXIT_IN=$exit_in
RAW_PORT=$raw_port
RAW_LOCAL=$raw_local
SPD_LOCAL=$spd_local
SPD_REMOTE=$spd_remote
WG_PORT=$wg_port
WG_MTU=$wg_mtu
SPD_MTU=$spd_mtu
FEC=$FEC
RAW_PASS=$raw_pass
SPD_PASS=$spd_pass
ENABLED=1
EOF
  chmod 600 "$EXITS/$name.conf"

  cat >"/etc/wireguard/wg-$name.conf" <<EOF
[Interface]
PrivateKey = $hub_priv
Address    = $hub_in/30
MTU        = $wg_mtu
Table      = off

[Peer]
PublicKey    = $exit_pub
PresharedKey = $psk
Endpoint     = $wg_endpoint
AllowedIPs   = 0.0.0.0/0
PersistentKeepalive = 15
EOF
  chmod 600 "/etc/wireguard/wg-$name.conf"

  systemctl enable --now "hydra-link@$name" >/dev/null 2>&1
  systemctl enable --now hydra-watch >/dev/null 2>&1
  logit "created tunnel $name -> $eip mode=$mode"

  local token
  token="$(printf '%s\n' \
    "NAME=$name" "IDX=$idx" "MODE=$mode" "HUB_IP=$(pub_ip)" \
    "HUB_IN=$hub_in" "EXIT_IN=$exit_in" "RAW_PORT=$raw_port" \
    "SPD_LOCAL=$spd_local" "WG_PORT=$wg_port" "WG_MTU=$wg_mtu" \
    "SPD_MTU=$spd_mtu" "FEC=$FEC" "RAW_PASS=$raw_pass" "SPD_PASS=$spd_pass" \
    "PSK=$psk" "EXIT_PRIV=$exit_priv" "HUB_PUB=$hub_pub" | base64 -w0)"
  echo "$token" >"$DIR/token-$name.txt"; chmod 600 "$DIR/token-$name.txt"

  clear; banner; echo; hr
  ok "Tunnel “$name” created."
  hr; echo
  echo -e "  ${W}${BLD}Now run this one-liner on the exit server ($eip):${N}"; echo
  echo -e "${G}bash <(curl -fsSL $INSTALL_URL) apply $token${N}"
  echo
  hr
  case "$mode" in
    full)  echo -e "  ${Y}Open TCP port $raw_port${N} on the exit server's firewall." ;;
    fec)   echo -e "  ${Y}Open UDP port $raw_port${N} on the exit server's firewall." ;;
    plain) echo -e "  ${Y}Open UDP port $wg_port${N} on the exit server's firewall." ;;
  esac
  echo -e "  ${D}Token saved to $DIR/token-$name.txt (see “Show token”).${N}"
  pause
}

# ============================================================ connect (exit) ==
connect_hub() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Connect to the Iran server${N}"; hr; echo
  echo -e "  ${D}Paste the token the Iran server gave you here:${N}"; echo
  local token; token="$(ask "Token")"
  [[ -n "$token" ]] || { err "Token is empty."; pause; return; }
  apply_token "$token"
  pause
}

apply_token() {
  local token="$1" dec line k v
  dec="$(echo "$token" | tr -d ' \n' | base64 -d 2>/dev/null)" || { err "Invalid token."; return 1; }
  if grep -qvE '^[A-Z_]+=[A-Za-z0-9+/=:._-]*$' <<<"$dec"; then err "Token is corrupted or tampered with."; return 1; fi
  while read -r line; do
    [[ -z "$line" ]] && continue
    k="${line%%=*}"; v="${line#*=}"      # not IFS, or the trailing = of base64 keys gets stripped
    printf -v "$k" '%s' "$v"
  done <<<"$dec"
  [[ -n "${NAME:-}" && -n "${EXIT_PRIV:-}" ]] || { err "Token is incomplete."; return 1; }

  [[ -d "$LINKS" ]] || { msg "Base install first…"; install_deps; install_binaries
                         mkdir -p "$LINKS" "$STATE" /etc/wireguard; chmod 700 "$DIR" /etc/wireguard
                         PUBLIC_IF="$(detect_if)"; save_conf; echo exit >"$ROLE_FILE"
                         apply_tune; install_units; }

  local pif spd_listen; pif="$(detect_if)"
  [[ "$MODE" == "full" ]] && spd_listen="127.0.0.1:$SPD_LOCAL" || spd_listen="0.0.0.0:$RAW_PORT"

  cat >"$LINKS/$NAME.conf" <<EOF
NAME=$NAME
IDX=$IDX
MODE=$MODE
HUB_IP=$HUB_IP
HUB_IN=$HUB_IN
EXIT_IN=$EXIT_IN
RAW_PORT=$RAW_PORT
SPD_LOCAL=$SPD_LOCAL
SPD_LISTEN=$spd_listen
WG_PORT=$WG_PORT
WG_MTU=$WG_MTU
SPD_MTU=$SPD_MTU
FEC=$FEC
RAW_PASS=$RAW_PASS
SPD_PASS=$SPD_PASS
PUBLIC_IF=$pif
EOF
  chmod 600 "$LINKS/$NAME.conf"

  cat >"/etc/wireguard/wg-$NAME.conf" <<EOF
[Interface]
PrivateKey = $EXIT_PRIV
Address    = $EXIT_IN/30
ListenPort = $WG_PORT
MTU        = $WG_MTU
Table      = off
PostUp   = iptables -t nat -A POSTROUTING -s $HUB_IN/32 -o $pif -j MASQUERADE; iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s $HUB_IN/32 -o $pif -j MASQUERADE; iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT

[Peer]
PublicKey    = $HUB_PUB
PresharedKey = $PSK
AllowedIPs   = $HUB_IN/32
PersistentKeepalive = 15
EOF
  chmod 600 "/etc/wireguard/wg-$NAME.conf"

  systemctl enable --now "hydra-exit-link@$NAME" >/dev/null 2>&1
  logit "applied token for hub link $NAME"
  echo; ok "Link “$NAME” activated (mode $MODE)."
  case "$MODE" in
    full)  echo -e "  ${Y}TCP port $RAW_PORT${N} must be open on this server's firewall." ;;
    fec)   echo -e "  ${Y}UDP port $RAW_PORT${N} must be open on this server's firewall." ;;
    plain) echo -e "  ${Y}UDP port $WG_PORT${N} must be open on this server's firewall." ;;
  esac
}

# ================================================================ link ctl ==
_link_up() {
  local n="$1" f="$EXITS/$1.conf"; [[ -f "$f" ]] || exit 1; . "$f"
  case "$MODE" in
    full) systemctl start "hydra-raw@$n"; sleep 1; systemctl start "hydra-spd@$n" ;;
    fec)  systemctl start "hydra-spd@$n" ;;
  esac
  sleep 1; wg-quick up "wg-$n" 2>/dev/null
  [[ -f "$EXITS/$n.ports" ]] && pf_apply_all >/dev/null 2>&1
  if ! ip route show table "$RT_NAME" 2>/dev/null | grep -q default; then
    ip route replace default dev "wg-$n" table "$RT_NAME" 2>/dev/null
    mkdir -p "$STATE"; echo "$n" >"$STATE/active"
  fi
  exit 0
}
_link_down() { wg-quick down "wg-$1" 2>/dev/null; systemctl stop "hydra-spd@$1" 2>/dev/null; systemctl stop "hydra-raw@$1" 2>/dev/null; exit 0; }
_elink_up() {
  local n="$1" f="$LINKS/$1.conf"; [[ -f "$f" ]] || exit 1; . "$f"
  case "$MODE" in
    full) systemctl start "hydra-exit-raw@$n"; sleep 1; systemctl start "hydra-exit-spd@$n" ;;
    fec)  systemctl start "hydra-exit-spd@$n" ;;
  esac
  sleep 1; wg-quick up "wg-$n" 2>/dev/null; exit 0
}
_elink_down() { wg-quick down "wg-$1" 2>/dev/null; systemctl stop "hydra-exit-spd@$1" 2>/dev/null; systemctl stop "hydra-exit-raw@$1" 2>/dev/null; exit 0; }

# ================================================================== probe ===
probe() { # iface peer -> "avg mdev loss"
  local out loss avg mdev
  out="$(ping -I "$1" -c 4 -i 0.2 -W 1 -q "$2" 2>/dev/null)" || { echo "- - 100"; return; }
  loss="$(sed -n 's/.*, \([0-9.]*\)% packet loss.*/\1/p' <<<"$out")"
  avg="$(sed -n 's#.*= [0-9.]*/\([0-9.]*\)/[0-9.]*/\([0-9.]*\) ms.*#\1#p' <<<"$out")"
  mdev="$(sed -n 's#.*= [0-9.]*/\([0-9.]*\)/[0-9.]*/\([0-9.]*\) ms.*#\2#p' <<<"$out")"
  echo "${avg:--} ${mdev:--} ${loss:-100}"
}

show_status_hub() {
  local active pin cc
  active="$(cat "$STATE/active" 2>/dev/null || echo '-')"
  pin="$(cat "$DIR/pin" 2>/dev/null || echo '')"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo -e "  BBR: ${W}$cc${N}   Active exit: ${G}${active}${N}$([[ -n $pin ]] && echo "  ${Y}(manually pinned)${N}")"
  echo
  printf "  ${W}%-10s %-16s %-6s %-9s %-9s %-7s %s${N}\n" "NAME" "IP" "MODE" "PING" "JITTER" "LOSS" "STATUS"
  hr
  local any=0 f
  for f in "$EXITS"/*.conf; do
    [[ -f "$f" ]] || continue; any=1
    ( . "$f"
      read -r avg mdev loss < <(probe "wg-$NAME" "$EXIT_IN")
      local st col
      if [[ "$loss" == "100" ]]; then st="down"; col="$R"
      elif (( $(echo "${loss%.*}" ) > 5 )); then st="weak"; col="$Y"
      else st="healthy"; col="$G"; fi
      [[ "$NAME" == "$active" ]] && st="$st ◀"
      printf "  %-10s %-16s %-6s %-9s %-9s %-7s ${col}%s${N}\n" \
        "$NAME" "$EXIT_IP" "$MODE" "${avg}ms" "${mdev}ms" "${loss}%" "$st" )
  done
  [[ $any == 0 ]] && echo -e "  ${D}No tunnels created yet.${N}"
}

show_status_exit() {
  printf "  ${W}%-12s %-6s %-16s %-16s %s${N}\n" "LINK" "MODE" "HUB" "HANDSHAKE" "SERVICE"
  hr
  local any=0 f
  for f in "$LINKS"/*.conf; do
    [[ -f "$f" ]] || continue; any=1
    ( . "$f"
      local hs col
      hs="$(wg show "wg-$NAME" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)"
      if [[ -n "$hs" && "$hs" != "0" ]]; then hs="$(( $(date +%s) - hs ))s ago"; col="$G"
      else hs="—"; col="$R"; fi
      printf "  %-12s %-6s %-16s ${col}%-16s${N} %s\n" \
        "$NAME" "$MODE" "$HUB_IP" "$hs" "$(systemctl is-active "hydra-exit-link@$NAME" 2>/dev/null)" )
  done
  [[ $any == 0 ]] && echo -e "  ${D}Not connected to any hub yet.${N}"
}

# ================================================================ watchdog ==
_watch() {
  mkdir -p "$STATE"
  local cand="" streak=0 current best best_score cur_score need name sc f
  current="$(cat "$STATE/active" 2>/dev/null || echo '')"
  while :; do
    local pin; pin="$(cat "$DIR/pin" 2>/dev/null || echo '')"
    if [[ -n "$pin" ]]; then
      if [[ "$pin" != "$current" ]] && ip route replace default dev "wg-$pin" table "$RT_NAME" 2>/dev/null; then
        current="$pin"; echo "$current" >"$STATE/active"; logit "pinned -> $pin"
      fi
      sleep "$CHECK_INTERVAL"; continue
    fi
    best=""; best_score=9999999; cur_score=9999999; : >"$STATE/scores.tmp"
    for f in "$EXITS"/*.conf; do
      [[ -f "$f" ]] || continue
      ( . "$f"; [[ "${ENABLED:-1}" == 1 ]] || exit 0
        read -r a m l < <(probe "wg-$NAME" "$EXIT_IN")
        if [[ "$a" == "-" || "$l" == "100" ]]; then echo "$NAME 9999999"
        else awk -v n="$NAME" -v a="$a" -v m="${m:-0}" -v l="$l" \
               'BEGIN{printf "%s %d\n", n, (a+2*m+20*l)*100}'; fi ) >>"$STATE/scores.tmp"
    done
    mv -f "$STATE/scores.tmp" "$STATE/scores" 2>/dev/null
    while read -r name sc; do
      [[ -z "$name" ]] && continue
      [[ "$name" == "$current" ]] && cur_score="$sc"
      (( sc < best_score )) && { best_score="$sc"; best="$name"; }
    done <"$STATE/scores" 2>/dev/null
    if [[ -n "$best" ]] && (( best_score < 9999999 )); then
      if [[ -z "$current" ]]; then
        ip route replace default dev "wg-$best" table "$RT_NAME" 2>/dev/null \
          && { current="$best"; echo "$current" >"$STATE/active"; logit "start -> $best"; }
      else
        need=$(( cur_score * (100 - SWITCH_MARGIN) / 100 ))
        if [[ "$best" != "$current" ]] && { (( cur_score >= 9999999 )) || (( best_score < need )); }; then
          [[ "$best" == "$cand" ]] && streak=$((streak+1)) || { cand="$best"; streak=1; }
          if (( streak >= HYSTERESIS )) || (( cur_score >= 9999999 )); then
            ip route replace default dev "wg-$best" table "$RT_NAME" 2>/dev/null \
              && { logit "switch $current -> $best ($cur_score -> $best_score)"
                   current="$best"; echo "$current" >"$STATE/active"; cand=""; streak=0; }
          fi
        else cand=""; streak=0; fi
      fi
    fi
    sleep "$CHECK_INTERVAL"
  done
}

# ================================================================ clients ===
client_add() {
  clear; banner; echo; hr; echo -e "  ${W}${BLD}New client${N}"; hr; echo
  local n; n="$(ask "Client name")"
  [[ "$n" =~ ^[a-zA-Z0-9_-]+$ ]] || { err "Invalid name."; pause; return; }
  [[ -f "$CLIENTS/$n.conf" ]] && { err "Client already exists."; pause; return; }
  local last=2 ipn priv pub psk f
  for f in "$CLIENTS"/*.ip; do [[ -f "$f" ]] && { local u; u="$(cat "$f")"; (( u > last )) && last=$u; }; done
  ipn=$((last+1)); (( ipn < 255 )) || { err "Out of IPs."; pause; return; }
  priv="$(wg genkey)"; pub="$(echo "$priv" | wg pubkey)"; psk="$(wg genpsk)"
  echo "$ipn" >"$CLIENTS/$n.ip"
  wg set wg0 peer "$pub" preshared-key <(echo "$psk") allowed-ips "$CLIENT_PREFIX.$ipn/32" 2>/dev/null
  wg-quick save wg0 2>/dev/null
  cat >"$CLIENTS/$n.conf" <<EOF
[Interface]
PrivateKey = $priv
Address    = $CLIENT_PREFIX.$ipn/32
DNS        = 1.1.1.1, 8.8.8.8
MTU        = 1280

[Peer]
PublicKey    = $(cat "$DIR/wg0.pub" 2>/dev/null)
PresharedKey = $psk
Endpoint     = $(pub_ip):$CLIENT_WG_PORT
AllowedIPs   = 0.0.0.0/0
PersistentKeepalive = 15
EOF
  chmod 600 "$CLIENTS/$n.conf"
  clear; ok "Client “$n” created → $CLIENT_PREFIX.$ipn"; echo
  command -v qrencode >/dev/null && qrencode -t ansiutf8 <"$CLIENTS/$n.conf"
  echo; hr; cat "$CLIENTS/$n.conf"; hr
  pause
}

client_menu() {
  while :; do
    clear; banner; echo; hr; echo -e "  ${W}${BLD}Manage clients${N}"; hr; echo
    local i=0 f
    printf "  ${W}%-4s %-16s %s${N}\n" "#" "NAME" "IP"
    for f in "$CLIENTS"/*.ip; do [[ -f "$f" ]] || continue; i=$((i+1))
      printf "  %-4s %-16s %s\n" "$i" "$(basename "$f" .ip)" "$CLIENT_PREFIX.$(cat "$f")"; done
    [[ $i == 0 ]] && echo -e "  ${D}No clients.${N}"
    echo; hr
    echo -e "   ${G}1${N}) New client      ${G}2${N}) Show QR       ${G}3${N}) Delete client"
    echo -e "   ${G}0${N}) Back"; echo
    case "$(ask "Choice")" in
      1) client_add ;;
      2) local n; n="$(ask "Client name")"
         [[ -f "$CLIENTS/$n.conf" ]] && { clear; qrencode -t ansiutf8 <"$CLIENTS/$n.conf"; echo; cat "$CLIENTS/$n.conf"; } || err "Not found."
         pause ;;
      3) local n; n="$(ask "Client name to delete")"
         if [[ -f "$CLIENTS/$n.conf" ]]; then
           local pk; pk="$(grep -oP '(?<=^PrivateKey = ).*' "$CLIENTS/$n.conf" | wg pubkey)"
           wg set wg0 peer "$pk" remove 2>/dev/null; wg-quick save wg0 2>/dev/null
           rm -f "$CLIENTS/$n.conf" "$CLIENTS/$n.ip"; ok "Deleted."
         else err "Not found."; fi; pause ;;
      0|"") return ;;
    esac
  done
}

# ============================================================ other options ==
tunnel_menu() {
  while :; do
    clear; banner; echo; hr; echo -e "  ${W}${BLD}Manage tunnels${N}"; hr; echo
    show_status_hub; echo; hr
    echo -e "   ${G}1${N}) Delete tunnel     ${G}2${N}) Show token     ${G}3${N}) Restart all"
    echo -e "   ${G}4${N}) Pin to an exit    ${G}5${N}) Back to automatic"
    echo -e "   ${G}0${N}) Back"; echo
    case "$(ask "Choice")" in
      1) local n; n="$(ask "Tunnel name to delete")"
         if [[ -f "$EXITS/$n.conf" ]]; then
           systemctl disable --now "hydra-link@$n" >/dev/null 2>&1
           rm -f "$EXITS/$n.conf" "$EXITS/$n.ports" "/etc/wireguard/wg-$n.conf" "$DIR/token-$n.txt"
           pf_apply_all >/dev/null 2>&1
           ok "Deleted."
         else err "Not found."; fi; pause ;;
      2) local n; n="$(ask "Tunnel name")"
         if [[ -f "$DIR/token-$n.txt" ]]; then
           clear; echo -e "${W}Run on the exit server:${N}\n"
           echo -e "${G}bash <(curl -fsSL $INSTALL_URL) apply $(cat "$DIR/token-$n.txt")${N}"
         else err "No token."; fi; pause ;;
      3) local f; for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && systemctl restart "hydra-link@$(basename "$f" .conf)"; done
         ok "All restarted."; pause ;;
      4) local n; n="$(ask "Exit name")"
         if [[ -f "$EXITS/$n.conf" ]]; then echo "$n" >"$DIR/pin"
           ip route replace default dev "wg-$n" table "$RT_NAME" 2>/dev/null
           mkdir -p "$STATE"; echo "$n" >"$STATE/active"; ok "Pinned to “$n”."
         else err "Not found."; fi; pause ;;
      5) rm -f "$DIR/pin"; ok "Automatic selection enabled."; pause ;;
      0|"") return ;;
    esac
  done
}

fec_menu() {
  clear; banner; echo; hr; echo -e "  ${W}${BLD}FEC settings${N}  ${D}(current: $FEC)${N}"; hr; echo
  echo -e "  ${D}Format “data:parity” — more parity means more loss tolerance, more overhead.${N}"; echo
  echo -e "   ${G}1${N}) ${W}20:5${N}   ${D}loss under 1%   — 25% overhead${N}"
  echo -e "   ${G}2${N}) ${W}10:5${N}   ${D}loss 1–5%       — 50% overhead  (default)${N}"
  echo -e "   ${G}3${N}) ${W}8:8${N}    ${D}loss 5–15%      — 100% overhead${N}"
  echo -e "   ${G}4${N}) ${W}4:8${N}    ${D}loss above 15%  — 200% overhead${N}"
  echo -e "   ${G}5${N}) Manual       ${G}0${N}) Back"; echo
  local new
  case "$(ask "Choice")" in
    1) new="20:5" ;; 2) new="10:5" ;; 3) new="8:8" ;; 4) new="4:8" ;;
    5) new="$(ask "Value (e.g. 12:6)")" ;;
    *) return ;;
  esac
  [[ "$new" =~ ^[0-9]+:[0-9]+$ ]] || { err "Wrong format."; pause; return; }
  FEC="$new"; save_conf
  local f
  for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && sed -i "s/^FEC=.*/FEC=$new/" "$f"; done
  for f in "$LINKS"/*.conf; do [[ -f "$f" ]] && sed -i "s/^FEC=.*/FEC=$new/" "$f"; done
  systemctl daemon-reload
  for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && systemctl restart "hydra-spd@$(basename "$f" .conf)" 2>/dev/null; done
  for f in "$LINKS"/*.conf; do [[ -f "$f" ]] && systemctl restart "hydra-exit-spd@$(basename "$f" .conf)" 2>/dev/null; done
  ok "FEC set to $new."
  warn "Set the same value on the other side too, or the link won't come up."
  pause
}

# ========================================================== port forwarding ====
#  Stored in $EXITS/<name>.ports — each line:  <proto> <port list>
#  Applied in dedicated chains, so it can always be flushed and cleanly rebuilt.
PF_CHUNK=15          # multiport cap in iptables

pf_norm() {          # "80, 443, 7777-7784" -> "80,443,7777:7784"  (or error)
  local raw="${1// /}" out="" t a b
  [[ -n "$raw" ]] || return 1
  for t in ${raw//,/ }; do
    if [[ "$t" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
      a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
      (( a>=1 && a<=65535 && b>=1 && b<=65535 && a<=b )) || return 1
      out+="$a:$b,"
    elif [[ "$t" =~ ^[0-9]{1,5}$ ]]; then
      (( t>=1 && t<=65535 )) || return 1
      out+="$t,"
    else return 1; fi
  done
  echo "${out%,}"
}

pf_count() {         # number of entries (a range counts as 2)
  local t n=0
  for t in ${1//,/ }; do [[ "$t" == *:* ]] && n=$((n+2)) || n=$((n+1)); done
  echo "$n"
}

pf_chunks() {        # splits a long list into multiport-allowed chunks
  local t c cost=0 cur=""
  for t in ${1//,/ }; do
    [[ "$t" == *:* ]] && c=2 || c=1
    if (( cost + c > PF_CHUNK )); then echo "${cur%,}"; cur=""; cost=0; fi
    cur+="$t,"; cost=$((cost+c))
  done
  [[ -n "$cur" ]] && echo "${cur%,}"
}

pf_reserved() {      # ports that must not be forwarded, or the server itself goes down
  local f sshp
  sshp="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)"
  echo -n "${sshp:-22} $CLIENT_WG_PORT"
  for f in "$EXITS"/*.conf; do
    [[ -f "$f" ]] && echo -n " $(sed -n 's/^RAW_PORT=//p' "$f")"
  done
  echo
}

pf_conflicts() {     # which ports in the list conflict with critical ports
  local list="$1" t p a b conf=""
  local res; res="$(pf_reserved)"
  for t in ${list//,/ }; do
    if [[ "$t" == *:* ]]; then
      a="${t%%:*}"; b="${t##*:}"
      for p in $res; do [[ -n "$p" ]] && (( p>=a && p<=b )) && conf+="$p "; done
    else
      for p in $res; do [[ "$t" == "$p" ]] && conf+="$p "; done
    fi
  done
  echo "$conf"
}

pf_chains_init() {
  iptables -t nat -N HYDRA_PRE  2>/dev/null
  iptables -t nat -N HYDRA_POST 2>/dev/null
  iptables        -N HYDRA_FWD  2>/dev/null
  iptables -t nat -C PREROUTING  -j HYDRA_PRE  2>/dev/null || iptables -t nat -I PREROUTING  1 -j HYDRA_PRE
  iptables -t nat -C POSTROUTING -j HYDRA_POST 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j HYDRA_POST
  iptables        -C FORWARD     -j HYDRA_FWD  2>/dev/null || iptables        -I FORWARD     1 -j HYDRA_FWD
}

pf_apply_all() {     # rebuilds everything from the files (idempotent)
  pf_chains_init
  iptables -t nat -F HYDRA_PRE  2>/dev/null
  iptables -t nat -F HYDRA_POST 2>/dev/null
  iptables        -F HYDRA_FWD  2>/dev/null
  iptables -A HYDRA_FWD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

  local f name proto list pr chunk rules=0
  for f in "$EXITS"/*.ports; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f" .ports)"
    [[ -f "$EXITS/$name.conf" ]] || continue
    local EXIT_IN; EXIT_IN="$(sed -n 's/^EXIT_IN=//p' "$EXITS/$name.conf")"
    [[ -n "$EXIT_IN" ]] || continue
    iptables -t nat -A HYDRA_POST -o "wg-$name" -j MASQUERADE 2>/dev/null
    while read -r proto list; do
      [[ -z "${proto:-}" || -z "${list:-}" ]] && continue
      for pr in $( [[ "$proto" == both ]] && echo "tcp udp" || echo "$proto" ); do
        while read -r chunk; do
          [[ -z "$chunk" ]] && continue
          iptables -t nat -A HYDRA_PRE -i "$PUBLIC_IF" -p "$pr" -m multiport --dports "$chunk" \
                   -j DNAT --to-destination "$EXIT_IN" 2>/dev/null && rules=$((rules+1))
          iptables -A HYDRA_FWD -d "$EXIT_IN" -p "$pr" -m multiport --dports "$chunk" -j ACCEPT 2>/dev/null
        done < <(pf_chunks "$list")
      done
    done <"$f"
  done
  echo "$rules"
}

pf_table() {         # table of current forwards
  printf "  ${W}%-4s %-10s %-6s %s${N}\n" "#" "EXIT" "PROTO" "PORTS"
  hr
  local f name proto list i=0
  for f in "$EXITS"/*.ports; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f" .ports)"
    while read -r proto list; do
      [[ -z "${proto:-}" ]] && continue
      i=$((i+1))
      printf "  %-4s %-10s %-6s %s\n" "$i" "$name" "$proto" "${list//:/-}"
    done <"$f"
  done
  [[ $i == 0 ]] && echo -e "  ${D}No ports forwarded.${N}"
  return 0
}

pf_nth() {           # returns line number n as "name<TAB>proto list"
  local want="$1" f name proto list i=0
  for f in "$EXITS"/*.ports; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f" .ports)"
    while read -r proto list; do
      [[ -z "${proto:-}" ]] && continue
      i=$((i+1))
      [[ "$i" == "$want" ]] && { printf '%s\t%s %s\n' "$name" "$proto" "$list"; return 0; }
    done <"$f"
  done
  return 1
}

pf_add() {
  clear; banner; echo; hr; echo -e "  ${W}${BLD}Add port forward${N}"; hr; echo
  local names n; names="$(for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && basename "$f" .conf; done | tr '\n' ' ')"
  [[ -n "${names// /}" ]] || { err "Create a tunnel first."; pause; return; }
  echo -e "  ${D}Available exits: ${W}$names${N}"; echo
  n="$(ask "Which exit should the ports go to?")"
  [[ -f "$EXITS/$n.conf" ]] || { err "Exit “$n” not found."; pause; return; }

  echo
  echo -e "  ${D}Separate multiple ports with commas, ranges with a hyphen:${N}"
  echo -e "  ${D}Example: ${W}50820,51820,2097,2096,443,80${N}   ${D}or${N}  ${W}27015,7777-7784${N}"
  echo
  local raw list; raw="$(ask "Ports")"
  list="$(pf_norm "$raw")" || { err "Invalid list. Only numbers 1–65535, commas, and hyphens."; pause; return; }

  local conf; conf="$(pf_conflicts "$list")"
  if [[ -n "${conf// /}" ]]; then
    echo
    warn "These ports are already used on this server: ${W}${conf}${N}"
    echo -e "  ${D}Forwarding them means SSH, WireGuard, or the tunnel itself becomes unreachable.${N}"
    echo -e "  ${D}If you're connected remotely, you may lose your connection right here.${N}"; echo
    askyn "Continue anyway?" n || { msg "Cancelled."; pause; return; }
  fi

  echo
  echo -e "   ${G}1${N}) Both (TCP + UDP)   ${G}2${N}) TCP only   ${G}3${N}) UDP only"; echo
  local proto
  case "$(ask "Protocol" "1")" in 2) proto=tcp ;; 3) proto=udp ;; *) proto=both ;; esac

  echo "$proto $list" >>"$EXITS/$n.ports"
  local applied; applied="$(pf_apply_all)"
  logit "port-forward add $n [$proto] $list"
  echo
  ok "$(pf_count "$list") port(s) forwarded to “$n” ($proto)."
  echo -e "  ${D}Condensed into $applied multiport rule(s), not one rule per port.${N}"
  pause
}

pf_del() {
  clear; banner; echo; hr; echo -e "  ${W}${BLD}Remove port forward${N}"; hr; echo
  pf_table; echo; hr
  local sel row name rest
  sel="$(ask "Line number to remove (empty = cancel)")"
  [[ -n "$sel" ]] || return
  row="$(pf_nth "$sel")" || { err "Invalid number."; pause; return; }
  name="${row%%$'\t'*}"; rest="${row#*$'\t'}"
  grep -vxF "$rest" "$EXITS/$name.ports" >"$EXITS/$name.ports.tmp" 2>/dev/null
  mv -f "$EXITS/$name.ports.tmp" "$EXITS/$name.ports"
  [[ -s "$EXITS/$name.ports" ]] || rm -f "$EXITS/$name.ports"
  pf_apply_all >/dev/null
  logit "port-forward del $name [$rest]"
  ok "Deleted."; pause
}

port_menu() {
  while :; do
    clear; banner; echo; hr
    echo -e "  ${W}${BLD}Port forwarding${N}   ${D}Public ports on this server → exit server${N}"
    hr; echo
    pf_table
    echo; hr
    echo -e "   ${G}1${N}) Add port      ${G}2${N}) Remove a row"
    echo -e "   ${G}3${N}) Clear all ports for one exit"
    echo -e "   ${G}4${N}) Reapply rules"
    echo -e "   ${G}5${N}) Show iptables rules"
    echo -e "   ${G}0${N}) Back"; echo
    case "$(ask "Choice")" in
      1) pf_add ;;
      2) pf_del ;;
      3) local n; n="$(ask "Exit name")"
         if [[ -f "$EXITS/$n.ports" ]]; then rm -f "$EXITS/$n.ports"; pf_apply_all >/dev/null
           logit "port-forward clear $n"; ok "All ports for “$n” cleared."
         else err "Nothing registered for “$n”."; fi; pause ;;
      4) local r; r="$(pf_apply_all)"; ok "$r rule(s) applied."; pause ;;
      5) clear; echo -e "${W}nat / HYDRA_PRE${N}"; hr
         iptables -t nat -S HYDRA_PRE 2>/dev/null | sed 's/^/  /' || echo -e "  ${D}empty${N}"
         echo; echo -e "${W}filter / HYDRA_FWD${N}"; hr
         iptables -S HYDRA_FWD 2>/dev/null | sed 's/^/  /' || echo -e "  ${D}empty${N}"
         pause ;;
      0|"") return ;;
    esac
  done
}

logs_menu() {
  clear; echo -e "${W}Last 50 log lines${N}"; hr
  tail -n 50 "$LOG" 2>/dev/null || echo -e "${D}Nothing logged.${N}"
  hr; echo -e "${D}For a live log of a service: journalctl -u hydra-raw@NAME -f${N}"
  pause
}

uninstall_all() {
  clear; banner; echo; hr
  warn "This will delete all tunnels, clients, and configs."
  askyn "Are you sure?" n || return
  local f
  for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && systemctl disable --now "hydra-link@$(basename "$f" .conf)" >/dev/null 2>&1; done
  for f in "$LINKS"/*.conf; do [[ -f "$f" ]] && systemctl disable --now "hydra-exit-link@$(basename "$f" .conf)" >/dev/null 2>&1; done
  systemctl disable --now hydra-watch hydra-rule hydra-ports wg-quick@wg0 >/dev/null 2>&1
  iptables -t nat -D PREROUTING  -j HYDRA_PRE  2>/dev/null
  iptables -t nat -D POSTROUTING -j HYDRA_POST 2>/dev/null
  iptables        -D FORWARD     -j HYDRA_FWD  2>/dev/null
  iptables -t nat -F HYDRA_PRE 2>/dev/null; iptables -t nat -X HYDRA_PRE 2>/dev/null
  iptables -t nat -F HYDRA_POST 2>/dev/null; iptables -t nat -X HYDRA_POST 2>/dev/null
  iptables -F HYDRA_FWD 2>/dev/null; iptables -X HYDRA_FWD 2>/dev/null
  rm -f /etc/systemd/system/hydra-*.service
  rm -f /etc/wireguard/wg-*.conf /etc/wireguard/wg0.conf
  rm -f /etc/sysctl.d/99-hydra.conf /etc/modules-load.d/hydra-bbr.conf
  rm -rf "$DIR" "$STATE"
  systemctl daemon-reload; sysctl --system >/dev/null 2>&1
  ok "Removed. udp2raw and speederv2 binaries were left untouched."
  exit 0
}

# ================================================================== menus ===
menu_hub() {
  while :; do
    clear; banner; echo
    echo -e "  ${D}This server's role:${N} ${W}Iran server (hub)${N}   ${D}$(pub_ip)${N}"
    hr; show_status_hub; hr; echo
    echo -e "   ${G}1${N}) ${W}Create new tunnel${N}       ${D}Add an exit server${N}"
    echo -e "   ${G}2${N}) Manage tunnels        ${D}Delete, pin, restart, token${N}"
    echo -e "   ${G}3${N}) Manage clients        ${D}Create WireGuard config + QR${N}"
    echo -e "   ${G}4${N}) FEC settings          ${D}current: $FEC${N}"
    echo -e "   ${G}5${N}) Port forwarding        ${D}Multiple ports at once, comma-separated${N}"
    echo -e "   ${G}6${N}) Reapply BBR and tuning"
    echo -e "   ${G}7${N}) Events and log"
    echo -e "   ${G}8${N}) ${R}Full uninstall${N}"
    echo -e "   ${G}0${N}) Exit"; echo
    case "$(ask "Choice")" in
      1) create_tunnel ;; 2) tunnel_menu ;; 3) client_menu ;; 4) fec_menu ;;
      5) port_menu ;; 6) apply_tune; pause ;; 7) logs_menu ;; 8) uninstall_all ;;
      0|q|"") clear; exit 0 ;;
    esac
  done
}

menu_exit() {
  while :; do
    clear; banner; echo
    echo -e "  ${D}This server's role:${N} ${W}exit server (foreign exit)${N}   ${D}$(pub_ip)${N}"
    hr; show_status_exit; hr; echo
    echo -e "   ${G}1${N}) ${W}Connect to Iran server${N}   ${D}Paste token${N}"
    echo -e "   ${G}2${N}) Delete a link"
    echo -e "   ${G}3${N}) Restart all links"
    echo -e "   ${G}4${N}) FEC settings          ${D}current: $FEC${N}"
    echo -e "   ${G}5${N}) Reapply BBR and tuning"
    echo -e "   ${G}6${N}) Events and log"
    echo -e "   ${G}7${N}) ${R}Full uninstall${N}"
    echo -e "   ${G}0${N}) Exit"; echo
    case "$(ask "Choice")" in
      1) connect_hub ;;
      2) local n; n="$(ask "Link name")"
         if [[ -f "$LINKS/$n.conf" ]]; then
           systemctl disable --now "hydra-exit-link@$n" >/dev/null 2>&1
           rm -f "$LINKS/$n.conf" "/etc/wireguard/wg-$n.conf"; ok "Deleted."
         else err "Not found."; fi; pause ;;
      3) local f; for f in "$LINKS"/*.conf; do [[ -f "$f" ]] && systemctl restart "hydra-exit-link@$(basename "$f" .conf)"; done
         ok "Restarted."; pause ;;
      4) fec_menu ;; 5) apply_tune; pause ;; 6) logs_menu ;; 7) uninstall_all ;;
      0|q|"") clear; exit 0 ;;
    esac
  done
}

menu_setup() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}What is this server?${N}"; hr; echo
  echo -e "   ${G}1${N}) ${W}Iran server${N}  ${D}— hub. Clients connect to it; it tunnels out to multiple exit servers.${N}"
  echo -e "   ${G}2${N}) ${W}Exit server${N}   ${D}— foreign exit. Connects to the hub using the token the hub gives you.${N}"
  echo -e "   ${G}0${N}) Exit"; echo
  case "$(ask "Choice")" in
    1) setup_hub; menu_hub ;;
    2) setup_exit; menu_exit ;;
    *) clear; exit 0 ;;
  esac
}

[[ -f /etc/hydra/install-url ]] && . /etc/hydra/install-url 2>/dev/null
INSTALL_URL="${HYDRA_INSTALL_URL:-https://raw.githubusercontent.com/devprogrmer/hydra/main/install.sh}"

# =================================================================== entry point ==
case "${1:-}" in
  _link-up)    _link_up "$2" ;;
  _link-down)  _link_down "$2" ;;
  _elink-up)   _elink_up "$2" ;;
  _elink-down) _elink_down "$2" ;;
  _watch)      _watch ;;
  _ports-apply) pf_apply_all >/dev/null; exit 0 ;;
  apply)       shift; apply_token "$1"; exit $? ;;
  status)      [[ "$(role)" == hub ]] && show_status_hub || show_status_exit; exit 0 ;;
  "")
    case "$(role)" in
      hub)  menu_hub ;;
      exit) menu_exit ;;
      *)    menu_setup ;;
    esac ;;
  *) echo "hydra v$VERSION — run with no arguments to open the menu."; exit 1 ;;
esac
