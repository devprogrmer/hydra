#!/usr/bin/env bash
# ============================================================================
#  hydra — Multi-Exit Gaming Tunnel
#  One script, for both the home server (hub) and the foreign servers (exits)
#
#  Install:  bash <(curl -fsSL https://raw.githubusercontent.com/USER/hydra/main/install.sh)
#  Run:      hydra
# ============================================================================
set -uo pipefail
umask 077                      # every file this script creates is owner-only

VERSION="3.0.0"
DIR="/etc/hydra"
EXITS="$DIR/exits.d"          # hub:  one file per foreign server
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
logit(){ ( umask 077; echo "$(date '+%F %T') $*" >>"$LOG" ) 2>/dev/null || true; chmod 600 "$LOG" 2>/dev/null || true; }

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
CLIENT_ISOLATION="1"; TOKEN_TTL="1800"
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
CLIENT_ISOLATION=$CLIENT_ISOLATION
TOKEN_TTL=$TOKEN_TTL
EOF
  chmod 600 "$CONF"
}

detect_if() { ip -4 route show default 2>/dev/null | awk '/default/{print $5; exit}'; }
pub_ip() {
  curl -s --max-time 6 https://api.ipify.org 2>/dev/null \
    || ip -4 addr show "$(detect_if)" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1
}
role() { cat "$ROLE_FILE" 2>/dev/null || echo ""; }


# ================================================================== tokens ==
#  Tokens carry NO private keys. The exit generates its own WireGuard private
#  key and returns only the public half. Every token is checksummed, carries an
#  expiry, and is bound to a one-time pairing id.

TOKEN_TTL="${TOKEN_TTL:-1800}"       # invite validity, seconds (30 min)

tok_encode() {            # stdin: KEY=VAL lines -> token on stdout
  local body sum
  body="$(cat)"
  sum="$(printf '%s' "$body" | sha256sum | cut -c1-16)"
  printf '%s\nSUM=%s' "$body" "$sum" | base64 -w0
}

tok_decode() {            # $1 = token. Sets the variables. Return codes below.
  local dec sum_given body line k v
  dec="$(echo "$1" | tr -d ' \n\r\t' | base64 -d 2>/dev/null)" || return 2
  grep -qvE '^[A-Z_]+=[A-Za-z0-9+/=:._-]*$' <<<"$dec" && return 3
  sum_given="$(sed -n 's/^SUM=//p' <<<"$dec")"
  body="$(grep -v '^SUM=' <<<"$dec")"
  [[ -n "$sum_given" ]] || return 4
  [[ "$(printf '%s' "$body" | sha256sum | cut -c1-16)" == "$sum_given" ]] || return 4
  while read -r line; do
    [[ -z "$line" ]] && continue
    k="${line%%=*}"; v="${line#*=}"
    printf -v "$k" '%s' "$v"
  done <<<"$body"
  return 0
}

tok_err() {               # human-readable reason for a tok_decode return code
  case "$1" in
    2) echo "not valid base64 - the paste was probably truncated" ;;
    3) echo "contains unexpected characters - do not edit tokens by hand" ;;
    4) echo "checksum mismatch - the paste is incomplete or corrupted" ;;
    5) echo "expired - generate a fresh one on the hub" ;;
    *) echo "invalid" ;;
  esac
}

tok_wipe() {              # remove a stored token beyond casual recovery
  local f="$1"
  [[ -f "$f" ]] || return 0
  command -v shred >/dev/null && shred -u "$f" 2>/dev/null || rm -f "$f"
}

# ============================================================ base install ==
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
  bin_hashes
  [[ -x "$BINDIR/udp2raw" && -x "$BINDIR/speederv2" ]] && ok "Binaries ready."
}

bin_hashes() {          # trust-on-first-use: record hashes, warn if they change
  local f cur old rec="$DIR/binaries.sha256"
  mkdir -p "$DIR"
  for f in "$BINDIR/udp2raw" "$BINDIR/speederv2"; do
    [[ -x "$f" ]] || continue
    cur="$(sha256sum "$f" | cut -d" " -f1)"
    old="$(grep -F " $f" "$rec" 2>/dev/null | cut -d" " -f1)"
    if [[ -z "$old" ]]; then
      ( umask 077; echo "$cur $f" >>"$rec" )
    elif [[ "$old" != "$cur" ]]; then
      warn "$(basename "$f") changed since it was installed."
      echo -e "  ${D}was: $old${N}"
      echo -e "  ${D}now: $cur${N}"
      echo -e "  ${D}If you did not update it yourself, treat this box as compromised.${N}"
    fi
  done
  return 0
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
  [[ "$cc" == bbr ]] && ok "BBR is active." || warn "Current algorithm: $cc (this kernel has no BBR)"
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

# ============================================================= hub install ==
setup_hub() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Setting up the home server (hub)${N}"; hr; echo
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
    msg "Creating the client interface (wg0)…"
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
  echo; ok "Hub is ready."
  echo -e "  ${D}Now pick 'Create new tunnel' from the menu.${N}"
  pause
}

setup_exit() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Setting up the foreign server (exit)${N}"; hr; echo
  install_deps; install_binaries
  mkdir -p "$LINKS" "$STATE" /etc/wireguard
  chmod 700 "$DIR" /etc/wireguard
  PUBLIC_IF="$(detect_if)"; save_conf
  echo "exit" >"$ROLE_FILE"
  apply_tune; install_units
  echo; ok "Exit server is ready."
  echo -e "  ${D}Now paste the hub's token via 'Connect to hub'.${N}"
  pause
}

# =========================================================== create tunnel ==
next_idx() {
  local i
  for i in $(seq 1 250); do
    grep -qs "^IDX=$i$" "$EXITS"/*.conf 2>/dev/null || { echo "$i"; return; }
  done
  echo 0
}

create_tunnel() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Create a new tunnel to a foreign server${N}"; hr; echo

  local name eip mode
  name="$(ask "Name for this foreign server (e.g. de1, nl1)")"
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { err "Name may contain letters, digits and hyphens only."; pause; return; }
  [[ -f "$EXITS/$name.conf" ]] && { err "A tunnel named '$name' already exists."; pause; return; }

  eip="$(ask "Foreign server IP")"
  valid_ip "$eip" || { err "Invalid IP address."; pause; return; }

  echo
  echo -e "  ${W}Tunnel mode:${N}"
  echo -e "   ${G}1${N}) ${W}full${N}  ${D}- WireGuard + FEC + faketcp  (recommended, defeats UDP shaping)${N}"
  echo -e "   ${G}2${N}) ${W}fec${N}   ${D}- WireGuard + FEC            (if faketcp fails on that VPS)${N}"
  echo -e "   ${G}3${N}) ${W}plain${N} ${D}- WireGuard only             (clean route, you just want multi-exit)${N}"
  echo
  case "$(ask "Choice" "1")" in
    2) mode=fec ;; 3) mode=plain ;; *) mode=full ;;
  esac

  local idx; idx="$(next_idx)"
  [[ "$idx" == 0 ]] && { err "No free slots left."; pause; return; }

  # Hub keypair is generated here. The exit's private key is NOT - the exit
  # makes its own and only ever sends back the public half.
  local hub_priv hub_pub psk raw_pass spd_pass tid exp
  hub_priv="$(wg genkey)"; hub_pub="$(echo "$hub_priv" | wg pubkey)"
  psk="$(wg genpsk)"
  raw_pass="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  spd_pass="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  tid="$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12)"
  exp=$(( $(date +%s) + TOKEN_TTL ))

  local raw_port=$((RAW_PORT_BASE+idx)) raw_local=$((RAW_LOCAL_BASE+idx))
  local spd_local=$((SPD_LOCAL_BASE+idx)) wg_port=$((51900+idx))
  local hub_in="$LINK_PREFIX.$idx.1" exit_in="$LINK_PREFIX.$idx.2"
  local wg_mtu spd_mtu spd_remote wg_endpoint
  case "$mode" in
    full)  wg_mtu=1280; spd_mtu=1200; spd_remote="127.0.0.1:$raw_local"; wg_endpoint="127.0.0.1:$spd_local" ;;
    fec)   wg_mtu=1330; spd_mtu=1250; spd_remote="$eip:$raw_port";       wg_endpoint="127.0.0.1:$spd_local" ;;
    plain) wg_mtu=1420; spd_mtu=1250; spd_remote="-";                    wg_endpoint="$eip:$wg_port" ;;
  esac

  ( umask 077
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
PSK=$psk
HUB_PRIV=$hub_priv
HUB_PUB=$hub_pub
EXIT_PUB=
TID=$tid
PAIRED=0
ENABLED=1
EOF
  )

  local token
  token="$(printf '%s\n' \
    "NAME=$name" "IDX=$idx" "MODE=$mode" "HUB_IP=$(pub_ip)" \
    "HUB_IN=$hub_in" "EXIT_IN=$exit_in" "RAW_PORT=$raw_port" \
    "SPD_LOCAL=$spd_local" "WG_PORT=$wg_port" "WG_MTU=$wg_mtu" \
    "SPD_MTU=$spd_mtu" "FEC=$FEC" "RAW_PASS=$raw_pass" "SPD_PASS=$spd_pass" \
    "PSK=$psk" "HUB_PUB=$hub_pub" "TID=$tid" "EXP=$exp" | tok_encode)"
  ( umask 077; echo "$token" >"$DIR/token-$name.txt" )
  logit "tunnel $name created (mode=$mode, exit=$eip, tid=$tid) - awaiting pairing"

  clear; banner; echo; hr
  ok "Tunnel '$name' created - ${Y}waiting to be paired${N}"
  hr; echo
  echo -e "  ${W}${BLD}Step 1${N} - run this on the foreign server ($eip):${N}"; echo
  echo -e "${G}bash <(curl -fsSL $INSTALL_URL) apply $token${N}"
  echo
  hr
  echo -e "  ${W}${BLD}Step 2${N} - it will print a short reply token."
  echo -e "  Bring that back here: ${W}Manage tunnels -> Finish pairing${N}"
  echo
  case "$mode" in
    full)  echo -e "  ${Y}Open TCP port $raw_port${N} in the exit's firewall." ;;
    fec)   echo -e "  ${Y}Open UDP port $raw_port${N} in the exit's firewall." ;;
    plain) echo -e "  ${Y}Open UDP port $wg_port${N} in the exit's firewall." ;;
  esac
  echo -e "  ${D}This invite expires in $((TOKEN_TTL/60)) minutes and can be used once.${N}"
  pause
}

finish_pairing() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Finish pairing${N}"; hr; echo
  echo -e "  ${D}Paste the reply token printed by the foreign server:${N}"; echo
  local reply rc
  reply="$(ask "Reply token")"
  [[ -n "$reply" ]] || return
  local NAME="" TID="" EXIT_PUB=""
  tok_decode "$reply"; rc=$?
  (( rc == 0 )) || { err "Reply token $(tok_err $rc)."; pause; return; }
  [[ -n "$NAME" && -n "$EXIT_PUB" && -n "$TID" ]] || { err "Reply token is incomplete."; pause; return; }
  [[ -f "$EXITS/$NAME.conf" ]] || { err "No pending tunnel named '$NAME'."; pause; return; }

  local want_tid; want_tid="$(sed -n 's/^TID=//p' "$EXITS/$NAME.conf")"
  [[ "$TID" == "$want_tid" ]] || { err "This reply does not match the pending invite for '$NAME'."; pause; return; }

  local HUB_PRIV HUB_IN WG_MTU EXIT_IP MODE WG_PORT SPD_LOCAL PSK
  . "$EXITS/$NAME.conf"
  local wg_endpoint
  case "$MODE" in
    plain) wg_endpoint="$EXIT_IP:$WG_PORT" ;;
    *)     wg_endpoint="127.0.0.1:$SPD_LOCAL" ;;
  esac

  ( umask 077
    cat >"/etc/wireguard/wg-$NAME.conf" <<EOF
[Interface]
PrivateKey = $HUB_PRIV
Address    = $HUB_IN/30
MTU        = $WG_MTU
Table      = off

[Peer]
PublicKey    = $EXIT_PUB
PresharedKey = $PSK
Endpoint     = $wg_endpoint
AllowedIPs   = 0.0.0.0/0
PersistentKeepalive = 15
EOF
  )
  sed -i "s|^EXIT_PUB=.*|EXIT_PUB=$EXIT_PUB|; s|^PAIRED=.*|PAIRED=1|" "$EXITS/$NAME.conf"
  tok_wipe "$DIR/token-$NAME.txt"          # invite is single use - destroy it

  systemctl enable --now "hydra-link@$NAME" >/dev/null 2>&1
  systemctl enable --now hydra-watch >/dev/null 2>&1
  logit "tunnel $NAME paired"
  echo; ok "Tunnel '$NAME' is paired and starting."
  echo -e "  ${D}The invite token has been wiped. Give it a few seconds, then check the status table.${N}"
  pause
}

# ============================================================== exit joins ==
connect_hub() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Connect to the hub${N}"; hr; echo
  echo -e "  ${D}Paste the invite token the hub gave you:${N}"; echo
  local token; token="$(ask "Token")"
  [[ -n "$token" ]] || { err "Token is empty."; pause; return; }
  apply_token "$token"
  pause
}

apply_token() {
  local rc
  local NAME="" IDX="" MODE="" HUB_IP="" HUB_IN="" EXIT_IN="" RAW_PORT="" \
        SPD_LOCAL="" WG_PORT="" WG_MTU="" SPD_MTU="" FEC="" RAW_PASS="" \
        SPD_PASS="" PSK="" HUB_PUB="" TID="" EXP=""
  tok_decode "$1"; rc=$?
  (( rc == 0 )) || { err "Token $(tok_err $rc)."; return 1; }
  [[ -n "$NAME" && -n "$HUB_PUB" && -n "$PSK" ]] || { err "Token is incomplete."; return 1; }
  if [[ -n "$EXP" ]] && (( $(date +%s) > EXP )); then
    err "Token $(tok_err 5)."; return 1
  fi

  [[ -d "$LINKS" ]] || { msg "Running base install first…"
                         install_deps; install_binaries
                         mkdir -p "$LINKS" "$STATE" /etc/wireguard; chmod 700 "$DIR" /etc/wireguard
                         PUBLIC_IF="$(detect_if)"; save_conf; echo exit >"$ROLE_FILE"
                         apply_tune; install_units; }

  # The exit's private key is generated HERE and never leaves this machine.
  local exit_priv exit_pub pif spd_listen
  exit_priv="$(wg genkey)"; exit_pub="$(echo "$exit_priv" | wg pubkey)"
  pif="$(detect_if)"
  [[ "$MODE" == "full" ]] && spd_listen="127.0.0.1:$SPD_LOCAL" || spd_listen="0.0.0.0:$RAW_PORT"

  ( umask 077
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
    cat >"/etc/wireguard/wg-$NAME.conf" <<EOF
[Interface]
PrivateKey = $exit_priv
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
  )
  unset exit_priv

  exit_lock "$NAME"
  systemctl enable --now "hydra-exit-link@$NAME" >/dev/null 2>&1
  logit "link $NAME configured from hub $HUB_IP"

  local reply
  reply="$(printf '%s\n' "NAME=$NAME" "TID=$TID" "EXIT_PUB=$exit_pub" | tok_encode)"

  echo
  ok "Link '$NAME' configured (mode $MODE)."
  case "$MODE" in
    full)  echo -e "  ${Y}TCP port $RAW_PORT${N} must be open in this server's firewall." ;;
    fec)   echo -e "  ${Y}UDP port $RAW_PORT${N} must be open in this server's firewall." ;;
    plain) echo -e "  ${Y}UDP port $WG_PORT${N} must be open in this server's firewall." ;;
  esac
  echo
  hr
  echo -e "  ${W}${BLD}Take this reply token back to the hub${N}"
  echo -e "  ${D}Hub menu -> Manage tunnels -> Finish pairing${N}"; echo
  echo -e "${G}$reply${N}"
  echo
  hr
  echo -e "  ${D}It contains only this server's public key - no secrets.${N}"
  return 0
}

# Restrict the tunnel's listening port to the hub's address only.
exit_lock() {
  local n="$1" f="$LINKS/$1.conf"
  [[ -f "$f" ]] || return 0
  local NAME MODE HUB_IP RAW_PORT WG_PORT
  . "$f"
  [[ -n "${HUB_IP:-}" ]] || return 0
  iptables -N HYDRA_IN 2>/dev/null
  iptables -C INPUT -j HYDRA_IN 2>/dev/null || iptables -I INPUT 1 -j HYDRA_IN
  local proto port
  case "$MODE" in
    full)  proto=tcp; port="$RAW_PORT" ;;
    fec)   proto=udp; port="$RAW_PORT" ;;
    plain) proto=udp; port="$WG_PORT" ;;
    *) return 0 ;;
  esac
  iptables -C HYDRA_IN -p "$proto" --dport "$port" -s "$HUB_IP" -j ACCEPT 2>/dev/null \
    || iptables -A HYDRA_IN -p "$proto" --dport "$port" -s "$HUB_IP" -j ACCEPT
  iptables -C HYDRA_IN -p "$proto" --dport "$port" -j DROP 2>/dev/null \
    || iptables -A HYDRA_IN -p "$proto" --dport "$port" -j DROP
  logit "ingress locked: $proto/$port accepts only $HUB_IP"
}

exit_lock_all() { local f; for f in "$LINKS"/*.conf; do [[ -f "$f" ]] && exit_lock "$(basename "$f" .conf)"; done; return 0; }

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
  sleep 1; wg-quick up "wg-$n" 2>/dev/null
  exit_lock "$n"
  exit 0
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
  printf "  ${W}%-10s %-16s %-6s %-9s %-9s %-7s %s${N}\n" "NAME" "IP" "MODE" "PING" "JITTER" "LOSS" "STATE"
  hr
  local any=0 f
  for f in "$EXITS"/*.conf; do
    [[ -f "$f" ]] || continue; any=1
    ( . "$f"
      read -r avg mdev loss < <(probe "wg-$NAME" "$EXIT_IN")
      local st col
      if [[ "${PAIRED:-1}" != 1 ]]; then st="unpaired"; col="$Y"
      elif [[ "$loss" == "100" ]]; then st="down"; col="$R"
      elif (( $(echo "${loss%.*}" ) > 5 )); then st="poor"; col="$Y"
      else st="ok"; col="$G"; fi
      [[ "$NAME" == "$active" ]] && st="$st ◀"
      printf "  %-10s %-16s %-6s %-9s %-9s %-7s ${col}%s${N}\n" \
        "$NAME" "$EXIT_IP" "$MODE" "${avg}ms" "${mdev}ms" "${loss}%" "$st" )
  done
  [[ $any == 0 ]] && echo -e "  ${D}No tunnels yet.${N}"
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

# ================================================================= clients ==
client_add() {
  clear; banner; echo; hr; echo -e "  ${W}${BLD}New client${N}"; hr; echo
  local n; n="$(ask "Client name")"
  [[ "$n" =~ ^[a-zA-Z0-9_-]+$ ]] || { err "Invalid name."; pause; return; }
  [[ -f "$CLIENTS/$n.conf" ]] && { err "That client already exists."; pause; return; }
  local last=2 ipn priv pub psk f
  for f in "$CLIENTS"/*.ip; do [[ -f "$f" ]] && { local u; u="$(cat "$f")"; (( u > last )) && last=$u; }; done
  ipn=$((last+1)); (( ipn < 255 )) || { err "Ran out of addresses."; pause; return; }
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
  clear; ok "Client '$n' created -> $CLIENT_PREFIX.$ipn"; echo
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
    echo -e "   ${G}1${N}) New client      ${G}2${N}) Show QR      ${G}3${N}) Delete client"
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

# ============================================================= other menus ==
tunnel_menu() {
  while :; do
    clear; banner; echo; hr; echo -e "  ${W}${BLD}Manage tunnels${N}"; hr; echo
    show_status_hub; echo; hr
    echo -e "   ${G}1${N}) ${W}Finish pairing${N}   ${D}paste the exit's reply token${N}"
    echo -e "   ${G}2${N}) Re-issue invite  ${G}3${N}) Delete tunnel   ${G}4${N}) Restart all"
    echo -e "   ${G}5${N}) Pin to an exit   ${G}6${N}) Back to automatic"
    echo -e "   ${G}0${N}) Back"; echo
    case "$(ask "Choice")" in
      1) finish_pairing ;;
      2) reissue_invite ;;
      3) local n; n="$(ask "Tunnel name to delete")"
         if [[ -f "$EXITS/$n.conf" ]]; then
           systemctl disable --now "hydra-link@$n" >/dev/null 2>&1
           tok_wipe "$DIR/token-$n.txt"
           rm -f "$EXITS/$n.conf" "$EXITS/$n.ports" "/etc/wireguard/wg-$n.conf"
           pf_apply_all >/dev/null 2>&1
           ok "Deleted."
         else err "Not found."; fi; pause ;;
      4) local f; for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && systemctl restart "hydra-link@$(basename "$f" .conf)"; done
         ok "All restarted."; pause ;;
      5) local n; n="$(ask "Exit name")"
         if [[ -f "$EXITS/$n.conf" ]]; then echo "$n" >"$DIR/pin"
           ip route replace default dev "wg-$n" table "$RT_NAME" 2>/dev/null
           mkdir -p "$STATE"; echo "$n" >"$STATE/active"; ok "Pinned to '$n'."
         else err "Not found."; fi; pause ;;
      6) rm -f "$DIR/pin"; ok "Automatic selection re-enabled."; pause ;;
      0|"") return ;;
    esac
  done
}

fec_menu() {
  clear; banner; echo; hr; echo -e "  ${W}${BLD}FEC settings${N}  ${D}(current: $FEC)${N}"; hr; echo
  echo -e "  ${D}Format 'data:parity' - more parity means more loss tolerance, more bandwidth.${N}"; echo
  echo -e "   ${G}1${N}) ${W}20:5${N}   ${D}loss under 1%    - 25% overhead${N}"
  echo -e "   ${G}2${N}) ${W}10:5${N}   ${D}loss 1-5%        - 50% overhead  (default)${N}"
  echo -e "   ${G}3${N}) ${W}8:8${N}    ${D}loss 5-15%       - 100% overhead${N}"
  echo -e "   ${G}4${N}) ${W}4:8${N}    ${D}loss above 15%   - 200% overhead${N}"
  echo -e "   ${G}5${N}) Custom   ${G}0${N}) Back"; echo
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
  warn "Set the same value on the other end, or the link will not come up."
  pause
}

# =========================================================== port forwards ==
#  Stored in $EXITS/<name>.ports  - one line per entry:  <proto> <port list>
#  Applied in dedicated chains, so they can always be flushed and rebuilt cleanly.
PF_CHUNK=15          # iptables multiport limit

pf_norm() {          # "80, 443, 7777-7784" -> "80,443,7777:7784"  (or fail)
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

pf_chunks() {        # split a long list into legal multiport chunks
  local t c cost=0 cur=""
  for t in ${1//,/ }; do
    [[ "$t" == *:* ]] && c=2 || c=1
    if (( cost + c > PF_CHUNK )); then echo "${cur%,}"; cur=""; cost=0; fi
    cur+="$t,"; cost=$((cost+c))
  done
  [[ -n "$cur" ]] && echo "${cur%,}"
}

pf_reserved() {      # ports that must not be forwarded or the server goes dark
  local f sshp
  sshp="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)"
  echo -n "${sshp:-22} $CLIENT_WG_PORT"
  for f in "$EXITS"/*.conf; do
    [[ -f "$f" ]] && echo -n " $(sed -n 's/^RAW_PORT=//p' "$f")"
  done
  echo
}

pf_conflicts() {     # which requested ports collide with critical ones
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

pf_apply_all() {     # rebuild everything from the files (idempotent)
  pf_chains_init
  iptables -t nat -F HYDRA_PRE  2>/dev/null
  iptables -t nat -F HYDRA_POST 2>/dev/null
  iptables        -F HYDRA_FWD  2>/dev/null
  iptables -A HYDRA_FWD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
  if [[ "${CLIENT_ISOLATION:-1}" == 1 ]]; then
    # clients may not reach each other, this server's LAN, or any private range
    iptables -A HYDRA_FWD -i wg0 -o wg0 -j DROP 2>/dev/null
    local net
    for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 127.0.0.0/8 100.64.0.0/10; do
      iptables -A HYDRA_FWD -i wg0 -d "$net" -j DROP 2>/dev/null
    done
  fi

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

pf_nth() {           # return row n as "name<TAB>proto list"
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
  clear; banner; echo; hr; echo -e "  ${W}${BLD}Add a port forward${N}"; hr; echo
  local names n; names="$(for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && basename "$f" .conf; done | tr '\n' ' ')"
  [[ -n "${names// /}" ]] || { err "Create a tunnel first."; pause; return; }
  echo -e "  ${D}Available exits: ${W}$names${N}"; echo
  n="$(ask "Forward to which exit?")"
  [[ -f "$EXITS/$n.conf" ]] || { err "Exit '$n' not found."; pause; return; }

  echo
  echo -e "  ${D}Separate ports with commas, ranges with a hyphen:${N}"
  echo -e "  ${D}e.g. ${W}50820,51820,2097,2096,443,80${N}   ${D}or${N}  ${W}27015,7777-7784${N}"
  echo
  local raw list; raw="$(ask "Ports")"
  list="$(pf_norm "$raw")" || { err "Invalid list. Only numbers 1-65535, commas and hyphens."; pause; return; }

  local conf; conf="$(pf_conflicts "$list")"
  if [[ -n "${conf// /}" ]]; then
    echo
    warn "These ports are in use by this server: ${W}${conf}${N}"
    echo -e "  ${D}Forwarding them takes down SSH, WireGuard or the tunnel itself.${N}"
    echo -e "  ${D}If you are connected remotely, this may cut you off right now.${N}"; echo
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
  ok "$(pf_count "$list") port(s) forwarded to '$n' ($proto)."
  echo -e "  ${D}Collapsed into $applied multiport rule(s), not one rule per port.${N}"
  pause
}

pf_del() {
  clear; banner; echo; hr; echo -e "  ${W}${BLD}Remove a port forward${N}"; hr; echo
  pf_table; echo; hr
  local sel row name rest
  sel="$(ask "Row number to remove (blank to cancel)")"
  [[ -n "$sel" ]] || return
  row="$(pf_nth "$sel")" || { err "Invalid row number."; pause; return; }
  name="${row%%$'\t'*}"; rest="${row#*$'\t'}"
  grep -vxF "$rest" "$EXITS/$name.ports" >"$EXITS/$name.ports.tmp" 2>/dev/null
  mv -f "$EXITS/$name.ports.tmp" "$EXITS/$name.ports"
  [[ -s "$EXITS/$name.ports" ]] || rm -f "$EXITS/$name.ports"
  pf_apply_all >/dev/null
  logit "port-forward del $name [$rest]"
  ok "Deleted."; pause
}

reissue_invite() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Re-issue an invite${N}"; hr; echo
  echo -e "  ${D}Use this if the invite expired or the paste was lost.${N}"
  echo -e "  ${D}It rotates the pairing id, so the old invite stops working.${N}"; echo
  local n; n="$(ask "Tunnel name")"
  [[ -f "$EXITS/$n.conf" ]] || { err "Not found."; pause; return; }
  local NAME IDX MODE EXIT_IP HUB_IN EXIT_IN RAW_PORT SPD_LOCAL WG_PORT WG_MTU SPD_MTU FEC RAW_PASS SPD_PASS PSK HUB_PUB
  . "$EXITS/$n.conf"
  local tid exp token
  tid="$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12)"
  exp=$(( $(date +%s) + TOKEN_TTL ))
  sed -i "s|^TID=.*|TID=$tid|; s|^PAIRED=.*|PAIRED=0|" "$EXITS/$n.conf"
  token="$(printf '%s\n' \
    "NAME=$NAME" "IDX=$IDX" "MODE=$MODE" "HUB_IP=$(pub_ip)" \
    "HUB_IN=$HUB_IN" "EXIT_IN=$EXIT_IN" "RAW_PORT=$RAW_PORT" \
    "SPD_LOCAL=$SPD_LOCAL" "WG_PORT=$WG_PORT" "WG_MTU=$WG_MTU" \
    "SPD_MTU=$SPD_MTU" "FEC=$FEC" "RAW_PASS=$RAW_PASS" "SPD_PASS=$SPD_PASS" \
    "PSK=$PSK" "HUB_PUB=$HUB_PUB" "TID=$tid" "EXP=$exp" | tok_encode)"
  ( umask 077; echo "$token" >"$DIR/token-$n.txt" )
  logit "invite re-issued for $n (tid=$tid)"
  clear; echo -e "${W}Run this on the foreign server ($EXIT_IP):${N}"; echo
  echo -e "${G}bash <(curl -fsSL $INSTALL_URL) apply $token${N}"; echo
  echo -e "  ${D}Valid for $((TOKEN_TTL/60)) minutes. The previous invite is now dead.${N}"
  pause
}

port_menu() {
  while :; do
    clear; banner; echo; hr
    echo -e "  ${W}${BLD}Port forwarding${N}   ${D}public ports on this server -> a foreign server${N}"
    hr; echo
    pf_table
    echo; hr
    echo -e "   ${G}1${N}) Add ports            ${G}2${N}) Remove a row"
    echo -e "   ${G}3${N}) Clear all ports of one exit"
    echo -e "   ${G}4${N}) Reapply rules"
    echo -e "   ${G}5${N}) Show iptables rules"
    echo -e "   ${G}0${N}) Back"; echo
    case "$(ask "Choice")" in
      1) pf_add ;;
      2) pf_del ;;
      3) local n; n="$(ask "Exit name")"
         if [[ -f "$EXITS/$n.ports" ]]; then rm -f "$EXITS/$n.ports"; pf_apply_all >/dev/null
           logit "port-forward clear $n"; ok "All ports for '$n' cleared."
         else err "Nothing recorded for '$n'."; fi; pause ;;
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

security_menu() {
  while :; do
    clear; banner; echo; hr; echo -e "  ${W}${BLD}Security${N}"; hr; echo
    local yes="${G}on${N}" no="${R}off${N}"
    local bbr; bbr="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"

    echo -e "  WireGuard encryption        ${G}ChaCha20-Poly1305 + preshared key${N}"
    echo -e "  udp2raw encryption          ${G}AES-128-CBC + HMAC-SHA1${N}"
    echo -e "  Exit private keys           ${G}generated on the exit, never transmitted${N}"
    echo -e "  Invite tokens               ${G}checksummed, single use, $((TOKEN_TTL/60)) min expiry${N}"
    if [[ "$(role)" == hub ]]; then
      echo -e "  Client isolation            $([[ "$CLIENT_ISOLATION" == 1 ]] && echo "$yes" || echo "$no")"
      local pend=0 f
      for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && [[ "$(sed -n 's/^PAIRED=//p' "$f")" != 1 ]] && pend=$((pend+1)); done
      echo -e "  Unpaired tunnels            $( ((pend)) && echo "${Y}$pend${N}" || echo "${G}0${N}")"
      local toks; toks="$(ls "$DIR"/token-*.txt 2>/dev/null | wc -l)"
      echo -e "  Invite tokens on disk       $( [[ "$toks" != 0 ]] && echo "${Y}$toks${N}" || echo "${G}0${N}")"
    else
      local locked; locked="$(iptables -S HYDRA_IN 2>/dev/null | grep -c ' -j DROP')"
      echo -e "  Ingress locked to hub IP    $( [[ "$locked" != 0 ]] && echo "$yes ($locked port(s))" || echo "$no")"
    fi
    echo -e "  Config file permissions     ${G}0600, umask 077${N}"
    echo -e "  Binary integrity            $([[ -f "$DIR/binaries.sha256" ]] && echo "${G}recorded${N}" || echo "${Y}not recorded${N}")"
    echo -e "  Congestion control          $([[ "$bbr" == bbr ]] && echo "${G}bbr${N}" || echo "${Y}$bbr${N}")"
    echo; hr
    if [[ "$(role)" == hub ]]; then
      echo -e "   ${G}1${N}) Toggle client isolation"
      echo -e "   ${G}2${N}) Wipe all stored invite tokens"
      echo -e "   ${G}3${N}) Re-check binary hashes"
      echo -e "   ${G}4${N}) Set invite lifetime      ${D}current: $((TOKEN_TTL/60)) min${N}"
    else
      echo -e "   ${G}1${N}) Re-apply ingress lock"
      echo -e "   ${G}3${N}) Re-check binary hashes"
    fi
    echo -e "   ${G}0${N}) Back"; echo
    case "$(ask "Choice")" in
      1) if [[ "$(role)" == hub ]]; then
           [[ "$CLIENT_ISOLATION" == 1 ]] && CLIENT_ISOLATION=0 || CLIENT_ISOLATION=1
           save_conf; pf_apply_all >/dev/null
           ok "Client isolation is now $([[ "$CLIENT_ISOLATION" == 1 ]] && echo on || echo off)."
           [[ "$CLIENT_ISOLATION" == 0 ]] && warn "Clients can now reach each other and private networks."
         else exit_lock_all; ok "Ingress lock re-applied."; fi; pause ;;
      2) if [[ "$(role)" == hub ]]; then
           local f c=0
           for f in "$DIR"/token-*.txt; do [[ -f "$f" ]] && { tok_wipe "$f"; c=$((c+1)); }; done
           ok "$c token file(s) wiped."
           echo -e "  ${D}Unpaired tunnels will need 'Re-issue invite'.${N}"
         fi; pause ;;
      3) bin_hashes; ok "Checked."; pause ;;
      4) if [[ "$(role)" == hub ]]; then
           local m; m="$(ask "Invite lifetime in minutes" "30")"
           [[ "$m" =~ ^[0-9]+$ ]] && (( m >= 1 && m <= 1440 )) \
             && { TOKEN_TTL=$((m*60)); save_conf; ok "Invites now expire after $m minutes."; } \
             || err "Enter a number between 1 and 1440."
         fi; pause ;;
      0|"") return ;;
    esac
  done
}

logs_menu() {
  clear; echo -e "${W}Last 50 events${N}"; hr
  tail -n 50 "$LOG" 2>/dev/null || echo -e "${D}Nothing logged yet.${N}"
  hr; echo -e "${D}Live log for one service: journalctl -u hydra-raw@NAME -f${N}"
  pause
}

uninstall_all() {
  clear; banner; echo; hr
  warn "This removes every tunnel, client and config file."
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
  iptables -D INPUT -j HYDRA_IN 2>/dev/null
  iptables -F HYDRA_IN 2>/dev/null; iptables -X HYDRA_IN 2>/dev/null
  rm -f /etc/systemd/system/hydra-*.service
  rm -f /etc/wireguard/wg-*.conf /etc/wireguard/wg0.conf
  rm -f /etc/sysctl.d/99-hydra.conf /etc/modules-load.d/hydra-bbr.conf
  rm -rf "$DIR" "$STATE"
  systemctl daemon-reload; sysctl --system >/dev/null 2>&1
  ok "Removed. The udp2raw and speederv2 binaries were left in place."
  exit 0
}

# =================================================================== menus ==
menu_hub() {
  while :; do
    clear; banner; echo
    echo -e "  ${D}Role:${N} ${W}Home server (hub)${N}   ${D}$(pub_ip)${N}"
    hr; show_status_hub; hr; echo
    echo -e "   ${G}1${N}) ${W}Create new tunnel${N}       ${D}add a foreign server${N}"
    echo -e "   ${G}2${N}) Manage tunnels          ${D}delete, pin, restart, token${N}"
    echo -e "   ${G}3${N}) Manage clients          ${D}WireGuard config + QR${N}"
    echo -e "   ${G}4${N}) FEC settings            ${D}current: $FEC${N}"
    echo -e "   ${G}5${N}) Port forwarding         ${D}many ports at once, comma-separated${N}"
    echo -e "   ${G}6${N}) Security                ${D}keys, isolation, tokens${N}"
    echo -e "   ${G}7${N}) Re-apply BBR and tuning"
    echo -e "   ${G}8${N}) Events and logs"
    echo -e "   ${G}9${N}) ${R}Uninstall${N}"
    echo -e "   ${G}0${N}) Quit"; echo
    case "$(ask "Choice")" in
      1) create_tunnel ;; 2) tunnel_menu ;; 3) client_menu ;; 4) fec_menu ;;
      5) port_menu ;; 6) security_menu ;; 7) apply_tune; pause ;;
      8) logs_menu ;; 9) uninstall_all ;;
      0|q|"") clear; exit 0 ;;
    esac
  done
}

menu_exit() {
  while :; do
    clear; banner; echo
    echo -e "  ${D}Role:${N} ${W}Foreign server (exit)${N}   ${D}$(pub_ip)${N}"
    hr; show_status_exit; hr; echo
    echo -e "   ${G}1${N}) ${W}Connect to the hub${N}      ${D}paste the token${N}"
    echo -e "   ${G}2${N}) Remove a link"
    echo -e "   ${G}3${N}) Restart all links"
    echo -e "   ${G}4${N}) FEC settings            ${D}current: $FEC${N}"
    echo -e "   ${G}5${N}) Security                ${D}keys, ingress lock${N}"
    echo -e "   ${G}6${N}) Re-apply BBR and tuning"
    echo -e "   ${G}7${N}) Events and logs"
    echo -e "   ${G}8${N}) ${R}Uninstall${N}"
    echo -e "   ${G}0${N}) Quit"; echo
    case "$(ask "Choice")" in
      1) connect_hub ;;
      2) local n; n="$(ask "Link name")"
         if [[ -f "$LINKS/$n.conf" ]]; then
           systemctl disable --now "hydra-exit-link@$n" >/dev/null 2>&1
           rm -f "$LINKS/$n.conf" "/etc/wireguard/wg-$n.conf"; ok "Deleted."
         else err "Not found."; fi; pause ;;
      3) local f; for f in "$LINKS"/*.conf; do [[ -f "$f" ]] && systemctl restart "hydra-exit-link@$(basename "$f" .conf)"; done
         ok "Restarted."; pause ;;
      4) fec_menu ;; 5) security_menu ;; 6) apply_tune; pause ;;
      7) logs_menu ;; 8) uninstall_all ;;
      0|q|"") clear; exit 0 ;;
    esac
  done
}

menu_setup() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}What is this server?${N}"; hr; echo
  echo -e "   ${G}1${N}) ${W}Home server${N}      ${D}the hub. Clients connect here; it tunnels out to many exits.${N}"
  echo -e "   ${G}2${N}) ${W}Foreign server${N}   ${D}an exit. Joins a hub using the token the hub prints.${N}"
  echo -e "   ${G}0${N}) Quit"; echo
  case "$(ask "Choice")" in
    1) setup_hub; menu_hub ;;
    2) setup_exit; menu_exit ;;
    *) clear; exit 0 ;;
  esac
}

[[ -f /etc/hydra/install-url ]] && . /etc/hydra/install-url 2>/dev/null
INSTALL_URL="${HYDRA_INSTALL_URL:-https://raw.githubusercontent.com/YOUR_USER/hydra/main/install.sh}"

# ================================================================== dispatch ==
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
  *) echo "hydra v$VERSION - run with no arguments to open the menu."; exit 1 ;;
esac
