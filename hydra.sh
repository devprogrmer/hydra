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

VERSION="3.7.0"
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
SPD_MODE="0"; SPD_TIMEOUT="0"; SPD_QUEUE="200"; RESET_HOURS="6"; TUNNEL_DIR="direct"
WG_KEEPALIVE="15"; SOCK_BUF="1024"; RAW_RETRY="2"
HUB_PUBLIC_IP=""; INGRESS_LOCK="1"
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
HUB_PUBLIC_IP=$HUB_PUBLIC_IP
INGRESS_LOCK=$INGRESS_LOCK
SPD_MODE=$SPD_MODE
SPD_TIMEOUT=$SPD_TIMEOUT
SPD_QUEUE=$SPD_QUEUE
RESET_HOURS=$RESET_HOURS
TUNNEL_DIR=$TUNNEL_DIR
WG_KEEPALIVE=$WG_KEEPALIVE
SOCK_BUF=$SOCK_BUF
RAW_RETRY=$RAW_RETRY
EOF
  chmod 600 "$CONF"
}

detect_if() { ip -4 route show default 2>/dev/null | awk '/default/{print $5; exit}'; }
pub_ip() {                # explicit setting wins - autodetect is only a fallback
  if [[ -n "${HUB_PUBLIC_IP:-}" ]]; then echo "$HUB_PUBLIC_IP"; return; fi
  detect_pub_ip
}

detect_pub_ip() {         # what the outside world sees, which is NOT always the
  local a b               # address you SSH into (NAT, multi-uplink, anycast egress)
  a="$(curl -s --max-time 6 https://api.ipify.org 2>/dev/null)"
  b="$(ip -4 addr show "$(detect_if)" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
  echo "${a:-$b}"
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
  local missing=""
  [[ -x "$BINDIR/udp2raw"   ]] || missing+=" udp2raw"
  [[ -x "$BINDIR/speederv2" ]] || missing+=" speederv2"
  if [[ -n "$missing" ]]; then
    err "Missing binaries:$missing"
    echo -e "  ${D}The download failed. Without these the tunnel cannot come up.${N}"
    echo -e "  ${D}Retry this step, or install them by hand from:${N}"
    echo -e "  ${D}  https://github.com/wangyu-/udp2raw/releases${N}"
    echo -e "  ${D}  https://github.com/wangyu-/UDPspeeder/releases${N}"
    return 1
  fi
  ok "Binaries ready."
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
ExecStart=/usr/local/bin/udp2raw -c -l 127.0.0.1:${RAW_LOCAL} -r ${EXIT_IP}:${RAW_PORT} -k ${RAW_PASS} --raw-mode faketcp --cipher-mode aes128cbc --auth-mode hmac_sha1 -a --fix-gro
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
ExecStart=/usr/local/bin/speederv2 -c -l 127.0.0.1:${SPD_LOCAL} -r ${SPD_REMOTE} -f ${FEC} --mode ${SPD_MODE} --timeout ${SPD_TIMEOUT} --mtu ${SPD_MTU} --queue-len ${SPD_QUEUE} -k ${SPD_PASS}
Restart=always
RestartSec=2
Nice=-10
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/hydra-raw-rev@.service <<'EOF'
[Unit]
Description=hydra udp2raw listener, reverse mode (%i)
After=network-online.target
[Service]
EnvironmentFile=/etc/hydra/exits.d/%i.conf
ExecStart=/usr/local/bin/udp2raw -s -l 0.0.0.0:${RAW_PORT} -r 127.0.0.1:${SPD_LOCAL} -k ${RAW_PASS} --raw-mode faketcp --cipher-mode aes128cbc --auth-mode hmac_sha1 -a --fix-gro
Restart=always
RestartSec=2
Nice=-10
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/hydra-exit-raw-rev@.service <<'EOF'
[Unit]
Description=hydra udp2raw dialler, reverse mode (%i)
After=network-online.target
[Service]
EnvironmentFile=/etc/hydra/links.d/%i.conf
ExecStart=/usr/local/bin/udp2raw -c -l 127.0.0.1:${RAW_LOCAL} -r ${HUB_IP}:${RAW_PORT} -k ${RAW_PASS} --raw-mode faketcp --cipher-mode aes128cbc --auth-mode hmac_sha1 -a --fix-gro
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
ExecStart=/usr/local/bin/udp2raw -s -l 0.0.0.0:${RAW_PORT} -r 127.0.0.1:${SPD_LOCAL} -k ${RAW_PASS} --raw-mode faketcp --cipher-mode aes128cbc --auth-mode hmac_sha1 -a --fix-gro
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
ExecStart=/usr/local/bin/speederv2 -s -l ${SPD_LISTEN} -r 127.0.0.1:${WG_PORT} -f ${FEC} --mode ${SPD_MODE} --timeout ${SPD_TIMEOUT} --mtu ${SPD_MTU} --queue-len ${SPD_QUEUE} -k ${SPD_PASS}
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
  PUBLIC_IF="$(detect_if)"
  echo
  local egress local_ip
  egress="$(detect_pub_ip)"
  local_ip="$(ip -4 addr show "$PUBLIC_IF" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
  echo -e "  ${W}Public address of this hub${N}"
  echo -e "  ${D}The exits will only accept traffic from this address, so it has to be${N}"
  echo -e "  ${D}the address they actually SEE - not necessarily the one you SSH into.${N}"
  echo -e "  ${D}outbound (as seen by the internet): ${W}${egress:-unknown}${N}"
  echo -e "  ${D}on interface $PUBLIC_IF:            ${W}${local_ip:-unknown}${N}"
  if [[ -n "$egress" && -n "$local_ip" && "$egress" != "$local_ip" ]]; then
    warn "These differ. Your outbound traffic leaves through a different address."
    echo -e "  ${D}Pick the one the exits will see. If unsure, the outbound one is usually right.${N}"
  fi
  echo
  HUB_PUBLIC_IP="$(ask "Hub public address" "${egress:-$local_ip}")"
  save_conf
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

# Everything that silently broke a tunnel in practice, checked up front.
preflight() {
  local role_now="$1" fail=0 warnc=0
  echo -e "  ${W}Preflight${N}"

  # binaries
  local b
  for b in udp2raw speederv2 wg; do
    if command -v "$b" >/dev/null; then
      printf "    %-26s ${G}ok${N}\n" "$b"
    else
      printf "    %-26s ${R}MISSING${N}\n" "$b"; fail=1
    fi
  done

  # can the FEC binary actually start? (the --report 0 class of bug)
  if command -v speederv2 >/dev/null; then
    if timeout 3 speederv2 -c -l 127.0.0.1:59998 -r 127.0.0.1:59999 -f 10:5 --mode 0 \
         --timeout 0 --mtu 1200 -k preflight >/dev/null 2>&1 & then
      sleep 1; pkill -f "k preflight" 2>/dev/null
      printf "    %-26s ${G}ok${N}\n" "speederv2 starts"
    fi
  fi

  # kernel bits
  if lsmod 2>/dev/null | grep -q wireguard || modprobe wireguard 2>/dev/null; then
    printf "    %-26s ${G}ok${N}\n" "wireguard module"
  else
    printf "    %-26s ${R}MISSING${N}\n" "wireguard module"; fail=1
  fi

  # forwarding
  if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == 1 ]]; then
    printf "    %-26s ${G}ok${N}\n" "ip_forward"
  else
    printf "    %-26s ${Y}off${N}\n" "ip_forward"; warnc=1
  fi

  # DNS - a real cause of failed downloads on Iranian servers
  if timeout 5 getent hosts github.com >/dev/null 2>&1; then
    printf "    %-26s ${G}ok${N}\n" "DNS resolution"
  else
    printf "    %-26s ${Y}failing${N}\n" "DNS resolution"
    echo -e "      ${D}downloads will fail - try setting a different resolver in /etc/resolv.conf${N}"
    warnc=1
  fi

  # a stable public address matters for plain mode
  if [[ "$role_now" == hub ]]; then
    local a b
    a="$(detect_pub_ip)"; sleep 1; b="$(detect_pub_ip)"
    if [[ -n "$a" && "$a" == "$b" ]]; then
      printf "    %-26s ${G}%s${N}\n" "public address" "$a"
    else
      printf "    %-26s ${Y}changing${N}\n" "public address"
      echo -e "      ${D}saw $a then $b - avoid 'plain' mode, it needs a stable endpoint${N}"
      warnc=1
    fi
  fi

  echo
  (( fail )) && { err "Preflight failed. Fix the missing pieces first."; return 1; }
  (( warnc )) && warn "Preflight passed with warnings."
  return 0
}

create_tunnel() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Create a new tunnel to a foreign server${N}"; hr; echo

  preflight hub || { pause; return; }
  echo; hr; echo

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
    full)  wg_mtu=1240; spd_mtu=1150
           if [[ "${TUNNEL_DIR:-direct}" == reverse ]]; then
             spd_remote="127.0.0.1:$spd_local"; wg_endpoint="127.0.0.1:$spd_local"
           else
             spd_remote="127.0.0.1:$raw_local"; wg_endpoint="127.0.0.1:$spd_local"
           fi ;;
    fec)   wg_mtu=1300; spd_mtu=1220; spd_remote="$eip:$raw_port";       wg_endpoint="127.0.0.1:$spd_local" ;;
    plain) wg_mtu=1420; spd_mtu=1250; spd_remote="-";                    wg_endpoint="$eip:$wg_port" ;;
  esac

  ( umask 077
    cat >"$EXITS/$name.conf" <<EOF
NAME=$name
IDX=$idx
MODE=$mode
DIRECTION=${TUNNEL_DIR:-direct}
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
SPD_MODE=$SPD_MODE
SPD_TIMEOUT=$SPD_TIMEOUT
SPD_QUEUE=$SPD_QUEUE
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
    "SPD_MODE_T=$SPD_MODE" "SPD_TIMEOUT_T=$SPD_TIMEOUT" "SPD_QUEUE_T=$SPD_QUEUE" \
    "DIRECTION=${TUNNEL_DIR:-direct}" \
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
PersistentKeepalive = ${WG_KEEPALIVE:-15}
EOF
  )
  sed -i "s|^EXIT_PUB=.*|EXIT_PUB=$EXIT_PUB|; s|^PAIRED=.*|PAIRED=1|" "$EXITS/$NAME.conf"
  tok_wipe "$DIR/token-$NAME.txt"          # invite is single use - destroy it

  systemctl enable --now "hydra-link@$NAME" >/dev/null 2>&1
  systemctl enable --now hydra-watch >/dev/null 2>&1
  logit "tunnel $NAME paired"
  echo; ok "Tunnel '$NAME' is paired. Waiting for the handshake…"

  # Do not just claim success - wait and verify, then say what to do if it fails.
  local i hs=""
  for i in $(seq 1 12); do
    sleep 2
    hs="$(wg show "wg-$NAME" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)"
    [[ -n "$hs" && "$hs" != 0 ]] && break
    printf "\r  ${D}waiting… %ss${N}  " $((i*2))
  done
  printf "\r%*s\r" 40 ""

  if [[ -n "$hs" && "$hs" != 0 ]]; then
    ok "Handshake complete. The tunnel is up."
  else
    warn "No handshake after 25 seconds."
    echo
    echo -e "  ${W}Most likely causes, in order:${N}"
    local MODE RAW_PORT WG_PORT
    . "$EXITS/$NAME.conf"
    case "$MODE" in
      full)  echo -e "   ${W}1.${N} TCP port ${W}$RAW_PORT${N} is closed in the exit's firewall" ;;
      fec)   echo -e "   ${W}1.${N} UDP port ${W}$RAW_PORT${N} is closed in the exit's firewall" ;;
      plain) echo -e "   ${W}1.${N} UDP port ${W}$WG_PORT${N} is closed in the exit's firewall" ;;
    esac
    echo -e "   ${W}2.${N} FEC settings differ between the two ends (they must match exactly)"
    echo -e "   ${W}3.${N} Your ISP is filtering this path - try mode 'fec', or another exit"
    echo
    echo -e "  ${D}Run 'Diagnose a tunnel' to see which layer is stuck.${N}"
  fi
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
        SPD_PASS="" PSK="" HUB_PUB="" TID="" EXP="" \
        SPD_MODE_T="" SPD_TIMEOUT_T="" SPD_QUEUE_T="" DIRECTION=""
  tok_decode "$1"; rc=$?
  (( rc == 0 )) || { err "Token $(tok_err $rc)."; return 1; }
  [[ -n "$NAME" && -n "$HUB_PUB" && -n "$PSK" ]] || { err "Token is incomplete."; return 1; }
  if [[ -n "$EXP" ]] && (( $(date +%s) > EXP )); then
    err "Token $(tok_err 5)."; return 1
  fi

  preflight exit >/dev/null 2>&1 || true
  [[ -d "$LINKS" ]] || { msg "Running base install first…"
                         install_deps; install_binaries
                         mkdir -p "$LINKS" "$STATE" /etc/wireguard; chmod 700 "$DIR" /etc/wireguard
                         PUBLIC_IF="$(detect_if)"; save_conf; echo exit >"$ROLE_FILE"
                         apply_tune; install_units; }

  # The exit's private key is generated HERE and never leaves this machine.
  local exit_priv exit_pub pif spd_listen
  exit_priv="$(wg genkey)"; exit_pub="$(echo "$exit_priv" | wg pubkey)"
  pif="$(detect_if)"
  if [[ "${DIRECTION:-direct}" == reverse ]]; then
    spd_listen="127.0.0.1:$SPD_LOCAL"
  elif [[ "$MODE" == "full" ]]; then
    spd_listen="127.0.0.1:$SPD_LOCAL"
  else
    spd_listen="0.0.0.0:$RAW_PORT"
  fi

  ( umask 077
    cat >"$LINKS/$NAME.conf" <<EOF
NAME=$NAME
IDX=$IDX
MODE=$MODE
DIRECTION=${DIRECTION:-direct}
HUB_IP=$HUB_IP
HUB_IN=$HUB_IN
EXIT_IN=$EXIT_IN
RAW_PORT=$RAW_PORT
RAW_LOCAL=$(( 33000 + IDX ))
SPD_LOCAL=$SPD_LOCAL
SPD_LISTEN=$spd_listen
WG_PORT=$WG_PORT
WG_MTU=$WG_MTU
SPD_MTU=$SPD_MTU
FEC=$FEC
SPD_MODE=${SPD_MODE_T:-0}
SPD_TIMEOUT=${SPD_TIMEOUT_T:-0}
SPD_QUEUE=${SPD_QUEUE_T:-200}
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
PersistentKeepalive = ${WG_KEEPALIVE:-15}
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

# Restrict the tunnel's listening port to the hub's address. HUB_ALLOW may hold a
# comma-separated list, because a hub can legitimately egress from more than one
# address (multi-uplink, NAT pool, failover link).
exit_lock() {
  local n="$1" f="$LINKS/$1.conf"
  [[ -f "$f" ]] || return 0
  local NAME MODE HUB_IP RAW_PORT WG_PORT HUB_ALLOW
  . "$f"
  iptables -N HYDRA_IN 2>/dev/null
  iptables -C INPUT -j HYDRA_IN 2>/dev/null || iptables -I INPUT 1 -j HYDRA_IN

  local proto port
  case "$MODE" in
    full)  proto=tcp; port="$RAW_PORT" ;;
    fec)   proto=udp; port="$RAW_PORT" ;;
    plain) proto=udp; port="$WG_PORT" ;;
    *) return 0 ;;
  esac

  # clear this port's existing rules so repeated calls never stack up
  while iptables -D HYDRA_IN -p "$proto" --dport "$port" -j DROP 2>/dev/null; do :; done
  iptables -S HYDRA_IN 2>/dev/null | grep -E -- "-p $proto .*--dport $port .*-j ACCEPT" \
    | sed 's/^-A /-D /' | while read -r r; do iptables $r 2>/dev/null; done

  if [[ "${INGRESS_LOCK:-1}" != 1 ]] && [[ "$MODE" != full ]]; then
    logit "ingress lock disabled for $n ($proto/$port open to any source)"
    return 0
  fi

  if [[ "$MODE" == full ]]; then
    # faketcp mode: udp2raw reads from a RAW socket, so it sees the packet no
    # matter what iptables decides. The port must be DROPped for the kernel -
    # otherwise the TCP stack answers the fake SYN with an RST and kills the
    # session. An ACCEPT rule here does exactly that damage, and a source filter
    # cannot restrict udp2raw anyway. So: drop for the kernel, nothing else.
    iptables -A HYDRA_IN -p "$proto" --dport "$port" -j DROP
    logit "faketcp guard: $proto/$port dropped for the kernel stack (raw socket unaffected)"
    return 0
  fi

  local sources="${HUB_ALLOW:-$HUB_IP}" src any=0
  for src in ${sources//,/ }; do
    [[ -n "$src" ]] || continue
    iptables -A HYDRA_IN -p "$proto" --dport "$port" -s "$src" -j ACCEPT && any=1
  done
  if (( any )); then
    iptables -A HYDRA_IN -p "$proto" --dport "$port" -j DROP
    logit "ingress locked: $proto/$port accepts only $sources"
  fi
  return 0
}

# Who is actually knocking on the tunnel port right now.
exit_seen_sources() {
  local n="$1" f="$LINKS/$1.conf"
  [[ -f "$f" ]] || return 0
  local MODE RAW_PORT WG_PORT proto port
  . "$f"
  case "$MODE" in
    full) proto=tcp; port="$RAW_PORT" ;;
    fec)  proto=udp; port="$RAW_PORT" ;;
    *)    proto=udp; port="$WG_PORT" ;;
  esac
  conntrack -L 2>/dev/null | grep -oP "(?<=src=)[0-9.]+(?=.*dport=$port)" | sort -u | head -5
}

exit_lock_all() { local f; for f in "$LINKS"/*.conf; do [[ -f "$f" ]] && exit_lock "$(basename "$f" .conf)"; done; return 0; }

# ================================================================ link ctl ==
_link_up() {
  local n="$1" f="$EXITS/$1.conf"; [[ -f "$f" ]] || exit 1; . "$f"
  local rawunit="hydra-raw@$n"
  [[ "${DIRECTION:-direct}" == reverse ]] && rawunit="hydra-raw-rev@$n"
  case "$MODE" in
    full) systemctl start "$rawunit"; sleep 1; systemctl start "hydra-spd@$n" ;;
    fec)  systemctl start "hydra-spd@$n" ;;
  esac
  sleep 2
  local svc
  for svc in "hydra-raw@$n" "hydra-spd@$n"; do
    systemctl list-unit-files "$svc.service" >/dev/null 2>&1 || continue
    if systemctl is-enabled "$svc" >/dev/null 2>&1 || systemctl is-active "$svc" >/dev/null 2>&1; then :; fi
  done
  case "$MODE" in
    full) systemctl is-active --quiet "hydra-raw@$n" || logit "WARNING: hydra-raw@$n is not running"
          systemctl is-active --quiet "hydra-spd@$n" || logit "WARNING: hydra-spd@$n is not running" ;;
    fec)  systemctl is-active --quiet "hydra-spd@$n" || logit "WARNING: hydra-spd@$n is not running" ;;
  esac
  wg-quick up "wg-$n" 2>/dev/null
  [[ -f "$EXITS/$n.ports" ]] && pf_apply_all >/dev/null 2>&1
  if ! ip route show table "$RT_NAME" 2>/dev/null | grep -q default; then
    ip route replace default dev "wg-$n" table "$RT_NAME" 2>/dev/null
    mkdir -p "$STATE"; echo "$n" >"$STATE/active"
  fi
  exit 0
}
_link_down() {
  wg-quick down "wg-$1" 2>/dev/null
  systemctl stop "hydra-spd@$1" "hydra-raw@$1" "hydra-raw-rev@$1" 2>/dev/null
  exit 0
}
_elink_up() {
  local n="$1" f="$LINKS/$1.conf"; [[ -f "$f" ]] || exit 1; . "$f"
  local rawunit="hydra-exit-raw@$n"
  [[ "${DIRECTION:-direct}" == reverse ]] && rawunit="hydra-exit-raw-rev@$n"
  case "$MODE" in
    full) systemctl start "$rawunit"; sleep 1; systemctl start "hydra-exit-spd@$n" ;;
    fec)  systemctl start "hydra-exit-spd@$n" ;;
  esac
  sleep 1; wg-quick up "wg-$n" 2>/dev/null
  exit_lock "$n"
  exit 0
}
_elink_down() {
  wg-quick down "wg-$1" 2>/dev/null
  systemctl stop "hydra-exit-spd@$1" "hydra-exit-raw@$1" "hydra-exit-raw-rev@$1" 2>/dev/null
  exit 0
}

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
        # a tunnel that never handshook is not a candidate at all
        if ! wg show "wg-$NAME" >/dev/null 2>&1; then echo "$NAME 9999999"; exit 0; fi
        local hs; hs="$(wg show "wg-$NAME" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)"
        if [[ -z "$hs" || "$hs" == 0 ]] || (( $(date +%s) - hs > 300 )); then echo "$NAME 9999999"; exit 0; fi
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
PersistentKeepalive = ${WG_KEEPALIVE:-15}
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
    echo -e "   ${G}7${N}) ${W}Rebuild a tunnel${N}  ${D}clean teardown when it is stuck${N}"
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
      7) rebuild_tunnel ;;
      0|"") return ;;
    esac
  done
}

fec_menu() {
  clear; banner; echo; hr; echo -e "  ${W}${BLD}FEC settings${N}  ${D}(current: $FEC)${N}"; hr; echo
  echo -e "  ${D}Format 'data:parity'. FEC rebuilds lost packets from redundancy instead${N}"
  echo -e "  ${D}of waiting for a retransmit - that is what kills jitter on a lossy link.${N}"
  echo
  echo -e "  ${D}The rule that matters: parity/(data+parity) must EXCEED your loss rate,${N}"
  echo -e "  ${D}with headroom, because loss arrives in bursts rather than evenly.${N}"
  echo
  printf "   ${G}1${N}) ${W}%-7s${N} ${D}%-18s tolerates ~%-6s overhead %s${N}\n" "20:5"  "loss under 2%"   "20%"  "25%"
  printf "   ${G}2${N}) ${W}%-7s${N} ${D}%-18s tolerates ~%-6s overhead %s${N}\n" "2:1"   "loss 2-8%, cheap" "33%"  "50%"
  printf "   ${G}9${N}) ${W}%-7s${N} ${D}%-18s tolerates ~%-6s overhead %s${N}\n" "10:5"  "loss 2-8%"       "33%"  "50%"
  printf "   ${G}3${N}) ${W}%-7s${N} ${D}%-18s tolerates ~%-6s overhead %s${N}\n" "8:8"   "loss 8-20%"      "50%"  "100%"
  printf "   ${G}4${N}) ${W}%-7s${N} ${D}%-18s tolerates ~%-6s overhead %s${N}\n" "6:9"   "loss 20-30%"     "60%"  "150%"
  printf "   ${G}5${N}) ${W}%-7s${N} ${D}%-18s tolerates ~%-6s overhead %s${N}\n" "4:8"   "loss 30-40%"     "66%"  "200%"
  printf "   ${G}6${N}) ${W}%-7s${N} ${D}%-18s tolerates ~%-6s overhead %s${N}\n" "2:6"   "loss above 40%"  "75%"  "300%"
  echo -e "   ${G}7${N}) Custom     ${G}8${N}) ${W}Measure the link and recommend${N}     ${G}0${N}) Back"
  echo
  local new
  case "$(ask "Choice")" in
    1) new="20:5" ;; 2) new="2:1" ;; 9) new="10:5" ;; 3) new="8:8" ;; 4) new="6:9" ;;
    5) new="4:8" ;; 6) new="2:6" ;;
    7) new="$(ask "Value (e.g. 12:6)")" ;;
    8) fec_measure; return ;;
    *) return ;;
  esac
  fec_set "$new"
}

fec_set() {
  local new="$1"
  [[ "$new" =~ ^[0-9]+:[0-9]+$ ]] || { err "Wrong format."; pause; return 1; }
  local d="${new%%:*}" pty="${new##*:}"
  (( d >= 1 && pty >= 1 && d <= 20 && pty <= 20 )) || { err "Each side must be 1-20."; pause; return 1; }
  FEC="$new"; save_conf
  local f
  for f in "$EXITS"/*.conf "$LINKS"/*.conf; do [[ -f "$f" ]] && sed -i "s/^FEC=.*/FEC=$new/" "$f"; done
  systemctl daemon-reload
  for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && systemctl restart "hydra-spd@$(basename "$f" .conf)" 2>/dev/null; done
  for f in "$LINKS"/*.conf; do [[ -f "$f" ]] && systemctl restart "hydra-exit-spd@$(basename "$f" .conf)" 2>/dev/null; done
  ok "FEC set to $new."
  awk -v d="$d" -v p="$pty" 'BEGIN{printf "  tolerates roughly %.0f%% loss, costs %.0f%% extra bandwidth\n", 100*p/(d+p), 100*p/d}'
  warn "Set the SAME value on the other end, or the link will not come up."
  pause
}

fec_measure() {
  clear; banner; echo; hr; echo -e "  ${W}${BLD}Measure the link${N}"; hr; echo
  local names f n
  names="$(for f in "$EXITS"/*.conf "$LINKS"/*.conf; do [[ -f "$f" ]] && basename "$f" .conf; done | sort -u | tr '\n' ' ')"
  [[ -n "${names// /}" ]] || { err "No tunnels."; pause; return; }
  echo -e "  ${D}Available: ${W}$names${N}"; echo
  n="$(ask "Tunnel name")"
  local peer
  if [[ -f "$EXITS/$n.conf" ]]; then peer="$(sed -n 's/^EXIT_IN=//p' "$EXITS/$n.conf")"
  elif [[ -f "$LINKS/$n.conf" ]]; then peer="$(sed -n 's/^HUB_IN=//p' "$LINKS/$n.conf")"
  else err "Not found."; pause; return; fi

  echo
  echo -e "  ${D}Sending 100 packets through the tunnel. This takes about 20 seconds.${N}"
  echo -e "  ${D}Measuring INSIDE the tunnel, so FEC recovery is already applied - the${N}"
  echo -e "  ${D}raw link loss is higher than what you see here.${N}"
  echo
  local out loss avg mdev
  out="$(ping -I "wg-$n" -c 100 -i 0.2 -W 1 -q "$peer" 2>/dev/null)"
  loss="$(sed -n 's/.*, \([0-9.]*\)% packet loss.*/\1/p' <<<"$out")"
  avg="$(sed  -n 's#.*= [0-9.]*/\([0-9.]*\)/[0-9.]*/\([0-9.]*\) ms.*#\1#p' <<<"$out")"
  mdev="$(sed -n 's#.*= [0-9.]*/\([0-9.]*\)/[0-9.]*/\([0-9.]*\) ms.*#\2#p' <<<"$out")"
  [[ -z "$loss" ]] && { err "No reply at all - the tunnel is down, fix that first."; pause; return; }

  hr
  echo -e "  residual loss   ${W}${loss}%${N}   ${D}(after FEC recovery)${N}"
  echo -e "  latency         ${W}${avg:-?}ms${N}"
  echo -e "  jitter          ${W}${mdev:-?}ms${N}"
  hr; echo

  local rec
  # Prefer small FEC blocks: same protection, far less CPU per packet, which
  # matters more than bandwidth on a single-core VPS.
  local cores; cores="$(nproc 2>/dev/null || echo 1)"
  rec="$(awk -v l="${loss%.*}" -v c="$cores" 'BEGIN{
    if (l<1)       print "20:5";
    else if (l<8)  print (c<2 ? "2:1" : "10:5");
    else if (l<15) print (c<2 ? "2:2" : "8:8");
    else if (l<25) print (c<2 ? "2:3" : "6:9");
    else if (l<40) print (c<2 ? "2:4" : "4:8");
    else           print "2:6";
  }')"

  if [[ "${loss%.*}" -gt 0 ]]; then
    echo -e "  ${Y}Packets are still being lost after FEC.${N}"
    echo -e "  ${D}That means the current setting ($FEC) is not strong enough for this link.${N}"
  else
    echo -e "  ${G}FEC is currently absorbing all of the loss.${N}"
  fi
  echo
  echo -e "  Suggested: ${W}$rec${N}"
  echo -e "  ${D}This is a starting point, not a guarantee. Re-measure after applying,${N}"
  echo -e "  ${D}and step up one level if residual loss is still above zero.${N}"
  echo
  if askyn "Apply $rec now?" y; then fec_set "$rec"; else pause; fi
}

# ============================================================ loss analysis ==
#  The number that matters is not "how much loss do I see" but "where does it
#  come from". FEC is the right answer to path loss and the WRONG answer to
#  MTU-induced loss, congestion from your own FEC overhead, or a dead layer.

analyze_loss() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Where is the loss coming from?${N}"; hr; echo
  local n; n="$(ask "Tunnel name")"
  local peer eip
  if [[ -f "$EXITS/$n.conf" ]]; then
    peer="$(sed -n 's/^EXIT_IN=//p' "$EXITS/$n.conf")"
    eip="$(sed -n 's/^EXIT_IP=//p' "$EXITS/$n.conf")"
  elif [[ -f "$LINKS/$n.conf" ]]; then
    peer="$(sed -n 's/^HUB_IN=//p' "$LINKS/$n.conf")"
    eip="$(sed -n 's/^HUB_IP=//p' "$LINKS/$n.conf")"
  else err "Not found."; pause; return; fi

  wg show "wg-$n" >/dev/null 2>&1 || { err "Tunnel is not up. Fix that before measuring."; pause; return; }

  # ---- 1. raw path loss, outside the tunnel ------------------------------
  echo -e "  ${W}1. Raw path loss${N}  ${D}(plain ICMP to $eip, no tunnel involved)${N}"
  local raw_out raw_loss raw_avg
  raw_out="$(ping -c 50 -i 0.2 -W 1 -q "$eip" 2>/dev/null)"
  raw_loss="$(sed -n 's/.*, \([0-9.]*\)% packet loss.*/\1/p' <<<"$raw_out")"
  raw_avg="$(sed -n 's#.*= [0-9.]*/\([0-9.]*\)/.*#\1#p' <<<"$raw_out")"
  if [[ -z "$raw_loss" ]]; then
    echo -e "     ${Y}no ICMP reply - the host may just be blocking ping${N}"
    raw_loss="?"
  else
    echo -e "     loss ${W}${raw_loss}%${N}   latency ${W}${raw_avg:-?}ms${N}"
  fi
  echo

  # ---- 2. loss inside the tunnel, after FEC ------------------------------
  echo -e "  ${W}2. Residual loss inside the tunnel${N}  ${D}(after FEC recovery)${N}"
  local in_out in_loss in_avg in_mdev
  in_out="$(ping -I "wg-$n" -c 50 -i 0.2 -W 1 -q "$peer" 2>/dev/null)"
  in_loss="$(sed -n 's/.*, \([0-9.]*\)% packet loss.*/\1/p' <<<"$in_out")"
  in_avg="$(sed  -n 's#.*= [0-9.]*/\([0-9.]*\)/[0-9.]*/\([0-9.]*\) ms.*#\1#p' <<<"$in_out")"
  in_mdev="$(sed -n 's#.*= [0-9.]*/\([0-9.]*\)/[0-9.]*/\([0-9.]*\) ms.*#\2#p' <<<"$in_out")"
  echo -e "     loss ${W}${in_loss:-100}%${N}   latency ${W}${in_avg:-?}ms${N}   jitter ${W}${in_mdev:-?}ms${N}"
  echo

  # ---- 3. is it MTU? -----------------------------------------------------
  echo -e "  ${W}3. MTU check${N}  ${D}(small packets vs large packets)${N}"
  local small_loss big_loss
  small_loss="$(ping -I "wg-$n" -c 30 -i 0.2 -W 1 -s 64 -q "$peer" 2>/dev/null | sed -n 's/.*, \([0-9.]*\)% packet loss.*/\1/p')"
  big_loss="$(ping   -I "wg-$n" -c 30 -i 0.2 -W 1 -s 1200 -q "$peer" 2>/dev/null | sed -n 's/.*, \([0-9.]*\)% packet loss.*/\1/p')"
  echo -e "     64-byte packets   loss ${W}${small_loss:-100}%${N}"
  echo -e "     1200-byte packets loss ${W}${big_loss:-100}%${N}"
  echo
  hr

  # ---- verdict -----------------------------------------------------------
  echo -e "  ${W}${BLD}Reading${N}"
  local sl="${small_loss%.*}" bl="${big_loss%.*}" il="${in_loss%.*}" rl="${raw_loss%.*}"
  sl="${sl:-100}"; bl="${bl:-100}"; il="${il:-100}"

  if (( bl > sl + 15 )); then
    echo -e "  ${Y}Large packets are lost far more than small ones.${N}"
    echo -e "  ${D}That is an MTU problem, not a lossy path. FEC will NOT fix it and${N}"
    echo -e "  ${D}raising FEC makes it worse by adding header overhead.${N}"
    echo -e "  ${W}Do this instead: menu -> Link tuning -> Find the working MTU${N}"
  elif (( il == 0 )); then
    echo -e "  ${G}FEC is absorbing everything. Nothing to fix.${N}"
    [[ "$rl" != "?" ]] && (( rl > 5 )) && echo -e "  ${D}The raw path loses ${rl}% and you are not feeling any of it.${N}"
  elif [[ "$rl" != "?" ]] && (( rl < 2 )) && (( il > 5 )); then
    echo -e "  ${Y}The raw path is clean but the tunnel is losing packets.${N}"
    echo -e "  ${D}The loss is being created by the tunnel, not the route. Usual causes:${N}"
    echo -e "  ${D}  - FEC overhead saturating a slow uplink (check your bandwidth)${N}"
    echo -e "  ${D}  - queue length too small for this latency${N}"
    echo -e "  ${D}  - CPU saturation on a 1-core VPS during FEC encoding${N}"
    echo -e "  ${W}Try: LOWER the FEC ratio first. More parity is not always better.${N}"
  else
    echo -e "  ${Y}Genuine path loss of roughly ${il}% is getting through FEC.${N}"
    local rec
    rec="$(awk -v l="$il" 'BEGIN{ if(l<5) print "10:5"; else if(l<12) print "8:8"; else if(l<22) print "6:9"; else if(l<35) print "4:8"; else print "2:6" }')"
    echo -e "  ${D}Current setting is $FEC. Suggested: ${W}$rec${N}"
    echo -e "  ${D}If raising it does not help, the route itself is the problem -${N}"
    echo -e "  ${D}another datacentre will beat any FEC setting.${N}"
  fi
  echo
  pause
}

# Find the largest packet that survives the path, then set MTUs from it.
mtu_probe() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Find the working MTU${N}"; hr; echo
  local n; n="$(ask "Tunnel name")"
  local eip
  if   [[ -f "$EXITS/$n.conf" ]]; then eip="$(sed -n 's/^EXIT_IP=//p' "$EXITS/$n.conf")"
  elif [[ -f "$LINKS/$n.conf" ]]; then eip="$(sed -n 's/^HUB_IP=//p'  "$LINKS/$n.conf")"
  else err "Not found."; pause; return; fi

  echo
  echo -e "  ${D}Probing $eip with progressively larger unfragmented packets.${N}"
  echo -e "  ${D}If this finds nothing, the host is blocking ICMP and you will have to${N}"
  echo -e "  ${D}lower the MTU by hand until things work.${N}"
  echo

  local lo=1200 hi=1500 mid best=0
  while (( lo <= hi )); do
    mid=$(( (lo + hi) / 2 ))
    if ping -c 2 -W 2 -M do -s $(( mid - 28 )) "$eip" >/dev/null 2>&1; then
      best=$mid; lo=$(( mid + 1 ))
      printf "\r  testing %s  ${G}ok${N}    " "$mid"
    else
      hi=$(( mid - 1 ))
      printf "\r  testing %s  ${R}too big${N}" "$mid"
    fi
  done
  printf "\r%*s\r" 40 ""

  if (( best == 0 )); then
    err "No size got through - ICMP is filtered, or the link is down."
    echo -e "  ${D}Fall back to setting WG_MTU to 1200 by hand and testing.${N}"
    pause; return
  fi

  echo -e "  Path MTU to $eip: ${W}${best}${N}"
  echo

  # headroom: udp2raw faketcp ~ 44, UDPspeeder ~ 50, WireGuard ~ 60
  local mode; mode="$(sed -n 's/^MODE=//p' "$EXITS/$n.conf" 2>/dev/null || sed -n 's/^MODE=//p' "$LINKS/$n.conf")"
  local spd wg
  case "$mode" in
    full)  spd=$(( best - 44 )); wg=$(( spd - 50 - 60 )) ;;
    fec)   spd=$(( best - 0 ));  wg=$(( spd - 50 - 60 )) ;;
    *)     spd=$best;            wg=$(( best - 60 )) ;;
  esac
  (( wg > 1420 )) && wg=1420
  (( wg < 1000 )) && wg=1000

  echo -e "  Suggested for mode ${W}$mode${N}:"
  echo -e "    SPD_MTU ${W}$spd${N}   ${D}UDPspeeder payload${N}"
  echo -e "    WG_MTU  ${W}$wg${N}   ${D}WireGuard interface${N}"
  echo
  echo -e "  ${D}These leave room for the faketcp, FEC and WireGuard headers. If large${N}"
  echo -e "  ${D}transfers still stall, drop WG_MTU by 40 and retest.${N}"
  echo
  if askyn "Apply these?" y; then
    local f="$EXITS/$n.conf"; [[ -f "$f" ]] || f="$LINKS/$n.conf"
    sed -i "s/^SPD_MTU=.*/SPD_MTU=$spd/; s/^WG_MTU=.*/WG_MTU=$wg/" "$f"
    sed -i "s/^MTU *=.*/MTU        = $wg/" "/etc/wireguard/wg-$n.conf" 2>/dev/null
    systemctl daemon-reload
    if [[ -f "$EXITS/$n.conf" ]]; then systemctl restart "hydra-link@$n"
    else systemctl restart "hydra-exit-link@$n"; fi
    ok "Applied and restarted."
    warn "Set the SAME values on the other end, then re-test."
  fi
  pause
}

# FEC encoding is CPU work. On a 1-core VPS a high parity ratio can saturate the
# core and create the very loss it was meant to absorb.
transport_menu() {
  while :; do
    clear; banner; echo; hr
    echo -e "  ${W}${BLD}Transport tuning${N}"; hr; echo
    echo -e "  WireGuard keepalive   ${W}${WG_KEEPALIVE:-15}s${N}   ${D}lower = faster recovery, more chatter${N}"
    echo -e "  Socket buffer         ${W}${SOCK_BUF:-1024}${N} KB   ${D}raise on high-latency links${N}"
    echo -e "  udp2raw retry delay   ${W}${RAW_RETRY:-2}s${N}    ${D}how fast it redials after a drop${N}"
    echo; hr
    echo -e "  ${D}Defaults suit a normal link. Change these only if the tunnel keeps${N}"
    echo -e "  ${D}dropping or you are on a very high-latency path.${N}"
    echo
    echo -e "   ${G}1${N}) Keepalive interval"
    echo -e "   ${G}2${N}) Socket buffer size"
    echo -e "   ${G}3${N}) Retry delay"
    echo -e "   ${G}4${N}) Restore defaults"
    echo -e "   ${G}0${N}) Back"; echo
    case "$(ask "Choice")" in
      1) local v; v="$(ask "Keepalive seconds (5-60)" "${WG_KEEPALIVE:-15}")"
         if [[ "$v" =~ ^[0-9]+$ ]] && (( v>=5 && v<=60 )); then
           WG_KEEPALIVE="$v"; save_conf
           local f n
           for f in /etc/wireguard/wg-*.conf; do
             [[ -f "$f" ]] && sed -i "s/^PersistentKeepalive.*/PersistentKeepalive = $v/" "$f"
           done
           ok "Keepalive set to ${v}s. Restart the links to apply."
         else err "Enter 5-60."; fi; pause ;;
      2) local v; v="$(ask "Buffer in KB (256-8192)" "${SOCK_BUF:-1024}")"
         if [[ "$v" =~ ^[0-9]+$ ]] && (( v>=256 && v<=8192 )); then
           SOCK_BUF="$v"; save_conf
           local bytes=$(( v * 1024 ))
           sysctl -w net.core.rmem_default="$bytes" >/dev/null 2>&1
           sysctl -w net.core.wmem_default="$bytes" >/dev/null 2>&1
           sed -i "s/^net.core.rmem_default.*/net.core.rmem_default = $bytes/; s/^net.core.wmem_default.*/net.core.wmem_default = $bytes/" /etc/sysctl.d/99-hydra.conf 2>/dev/null
           ok "Buffer set to ${v}KB."
         else err "Enter 256-8192."; fi; pause ;;
      3) local v; v="$(ask "Retry delay seconds (1-30)" "${RAW_RETRY:-2}")"
         if [[ "$v" =~ ^[0-9]+$ ]] && (( v>=1 && v<=30 )); then
           RAW_RETRY="$v"; save_conf
           sed -i "s/^RestartSec=.*/RestartSec=$v/" /etc/systemd/system/hydra-raw*@.service \
                                                    /etc/systemd/system/hydra-exit-raw*@.service 2>/dev/null
           systemctl daemon-reload
           ok "Retry delay set to ${v}s."
         else err "Enter 1-30."; fi; pause ;;
      4) WG_KEEPALIVE=15; SOCK_BUF=1024; RAW_RETRY=2; save_conf; ok "Restored."; pause ;;
      0|"") return ;;
    esac
  done
}

cpu_check() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}CPU headroom${N}"; hr; echo
  local cores load1 pct
  cores="$(nproc 2>/dev/null || echo 1)"
  load1="$(awk '{print $1}' /proc/loadavg)"
  pct="$(awk -v l="$load1" -v c="$cores" 'BEGIN{printf "%.0f", 100*l/c}')"

  echo -e "  cores            ${W}$cores${N}"
  echo -e "  load (1 min)     ${W}$load1${N}   ${D}~${pct}% of capacity${N}"
  echo

  local sp; sp="$(ps -o %cpu= -C speederv2 2>/dev/null | awk '{t+=$1} END{printf "%.1f", t+0}')"
  local ur; ur="$(ps -o %cpu= -C udp2raw   2>/dev/null | awk '{t+=$1} END{printf "%.1f", t+0}')"
  echo -e "  speederv2 CPU    ${W}${sp:-0}%${N}   ${D}FEC encode/decode${N}"
  echo -e "  udp2raw CPU      ${W}${ur:-0}%${N}   ${D}obfuscation + crypto${N}"
  echo
  hr
  local d p
  d="${FEC%%:*}"; p="${FEC##*:}"
  echo -e "  ${W}Reading${N}"
  if (( pct > 85 )); then
    echo -e "  ${R}This machine is saturated.${N}"
    echo -e "  ${D}FEC encoding is CPU-bound. A saturated core drops packets on its own,${N}"
    echo -e "  ${D}which looks exactly like path loss and cannot be fixed by more parity.${N}"
    echo -e "  ${W}Lower the FEC ratio, or move to a VPS with more cores.${N}"
  elif (( pct > 60 )) && awk -v d="$d" -v p="$p" 'BEGIN{exit !(p/d > 1)}'; then
    echo -e "  ${Y}Load is high and your parity ratio is above 1:1 ($FEC).${N}"
    echo -e "  ${D}You are close to the point where FEC costs more than it recovers.${N}"
  else
    echo -e "  ${G}CPU is not the bottleneck.${N}"
  fi
  echo
  echo -e "  ${D}Rule of thumb: with $cores core(s), FEC above ${W}$( (( cores > 1 )) && echo "4:8" || echo "8:8" )${D} on a busy${N}"
  echo -e "  ${D}link is usually counter-productive on hardware this size.${N}"
  pause
}

# Real throughput through the tunnel, which is what FEC overhead actually eats.
bandwidth_test() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Throughput through the tunnel${N}"; hr; echo
  if ! command -v iperf3 >/dev/null; then
    echo -e "  ${D}iperf3 is not installed. It is the only reliable way to measure this.${N}"
    echo
    if askyn "Install it?" y; then
      if command -v apt-get >/dev/null; then apt-get install -y -qq iperf3 >/dev/null 2>&1
      elif command -v dnf >/dev/null; then dnf install -y -q iperf3 >/dev/null 2>&1; fi
      command -v iperf3 >/dev/null || { err "Install failed."; pause; return; }
    else return; fi
  fi
  local n; n="$(ask "Tunnel name")"
  local peer
  if   [[ -f "$EXITS/$n.conf" ]]; then peer="$(sed -n 's/^EXIT_IN=//p' "$EXITS/$n.conf")"
  elif [[ -f "$LINKS/$n.conf" ]]; then peer="$(sed -n 's/^HUB_IN=//p'  "$LINKS/$n.conf")"
  else err "Not found."; pause; return; fi

  echo
  echo -e "  ${W}On the OTHER end, run this first:${N}"
  echo -e "  ${G}iperf3 -s${N}"
  echo
  echo -e "  ${D}Then come back here and continue. Measuring for 10 seconds.${N}"
  echo
  askyn "Is iperf3 -s running on the other side?" n || return
  echo
  echo -e "  ${D}running…${N}"
  iperf3 -c "$peer" -t 10 -f m 2>&1 | tail -6
  echo
  hr
  local d p
  d="${FEC%%:*}"; p="${FEC##*:}"
  awk -v d="$d" -v p="$p" -v f="$FEC" 'BEGIN{
    printf "  At FEC %s you send %.1f bytes for every 1 byte of payload.\n", f, (d+p)/d
    printf "  So the figure above is roughly %.0f%% of your raw link capacity.\n", 100*d/(d+p)
  }'
  echo -e "  ${D}If throughput is far below your line speed, FEC overhead is the reason.${N}"
  pause
}

# ============================================================== self-healing ==
#  Two failure modes that no amount of tuning fixes, both common on Iranian
#  links, both solved by periodic action rather than by configuration:
#
#   1. the hub's public address changes, so the exit's peer entry goes stale
#   2. the udp2raw session dies quietly and never re-establishes
#
#  Azumi's projects ship a reset timer for exactly this. So do we now.

RESET_HOURS_DEFAULT=6

heal_install() {
  cat >/etc/systemd/system/hydra-heal.service <<'EOF'
[Unit]
Description=hydra tunnel self-heal
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/hydra _heal
EOF
  cat >/etc/systemd/system/hydra-heal.timer <<EOF
[Unit]
Description=hydra periodic tunnel reset
[Timer]
OnBootSec=10min
OnUnitActiveSec=${RESET_HOURS:-$RESET_HOURS_DEFAULT}h
Persistent=true
[Install]
WantedBy=timers.target
EOF

  # watchdog: reacts to a dead handshake within minutes, not hours
  cat >/etc/systemd/system/hydra-guard.service <<'EOF'
[Unit]
Description=hydra handshake watchdog
After=network-online.target
[Service]
ExecStart=/usr/local/bin/hydra _guard
Restart=always
RestartSec=30
EOF
  systemctl daemon-reload
}

# Full periodic reset of every tunnel, in the order that actually works.
_heal() {
  local f n restarted=0
  for f in "$EXITS"/*.conf; do
    [[ -f "$f" ]] || continue
    n="$(basename "$f" .conf)"
    [[ "$(sed -n 's/^PAIRED=//p' "$f")" == 1 ]] || continue
    systemctl restart "hydra-link@$n" >/dev/null 2>&1 && restarted=$((restarted+1))
    sleep 2
  done
  for f in "$LINKS"/*.conf; do
    [[ -f "$f" ]] || continue
    n="$(basename "$f" .conf)"
    systemctl restart "hydra-exit-link@$n" >/dev/null 2>&1 && restarted=$((restarted+1))
    sleep 2
  done
  logit "scheduled reset: $restarted link(s) restarted"
  exit 0
}

# Watch handshakes; restart only the link that is actually stuck.
_guard() {
  local grace="${GUARD_GRACE:-240}"     # seconds without a handshake before acting
  local -A strikes=()
  while :; do
    local f n hs now age
    now="$(date +%s)"
    for f in "$EXITS"/*.conf "$LINKS"/*.conf; do
      [[ -f "$f" ]] || continue
      n="$(basename "$f" .conf)"
      wg show "wg-$n" >/dev/null 2>&1 || continue
      hs="$(wg show "wg-$n" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)"
      if [[ -z "$hs" || "$hs" == 0 ]]; then age=99999; else age=$(( now - hs )); fi
      if (( age > grace )); then
        strikes[$n]=$(( ${strikes[$n]:-0} + 1 ))
        if (( ${strikes[$n]} >= 2 )); then
          if [[ -f "$EXITS/$n.conf" ]]; then
            systemctl restart "hydra-link@$n" >/dev/null 2>&1
          else
            systemctl restart "hydra-exit-link@$n" >/dev/null 2>&1
          fi
          logit "guard: $n had no handshake for ${age}s - restarted"
          strikes[$n]=0
          sleep 30
        fi
      else
        strikes[$n]=0
      fi
    done
    sleep 60
  done
}

# Azumi's scripts expose a live status/log view on every tunnel. Ours buried the
# same information across three menus. This puts it on one screen.
# ============================================================= reverse mode ==
#  Normally the hub dials out to each exit. That needs the EXIT to have a stable
#  address - fine - but the exit's ingress filter then needs the HUB's address,
#  and the hub's address is the one that keeps changing on Iranian links.
#
#  In reverse mode the roles flip at the transport layer: the HUB listens and
#  the EXIT dials in. The hub's address can change freely; only the exit needs
#  to be reachable, and it always is.
#
#  The tunnel payload is identical either way - this only changes who connects.

reverse_explain() {
  echo -e "  ${W}Direct${N}   ${D}hub dials the exit${N}"
  echo -e "    ${D}needs: exit reachable, hub address stable enough for the ingress lock${N}"
  echo -e "    ${D}breaks when: the hub's public address changes${N}"
  echo
  echo -e "  ${W}Reverse${N}  ${D}exit dials the hub${N}"
  echo -e "    ${D}needs: hub reachable on one port${N}"
  echo -e "    ${D}breaks when: the hub is behind NAT with no port forward${N}"
  echo
  echo -e "  ${D}If your hub's address moves around, reverse is the answer.${N}"
  echo -e "  ${D}If your hub is behind carrier NAT, direct is the only option.${N}"
}

reverse_menu() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Connection direction${N}"; hr; echo
  reverse_explain
  echo; hr
  echo -e "  ${D}Current default for new tunnels: ${W}${TUNNEL_DIR:-direct}${N}"
  echo
  echo -e "   ${G}1${N}) New tunnels dial out    ${D}direct${N}"
  echo -e "   ${G}2${N}) New tunnels are dialled ${D}reverse${N}"
  echo -e "   ${G}0${N}) Back"; echo
  case "$(ask "Choice")" in
    1) TUNNEL_DIR=direct; save_conf; ok "New tunnels will be direct." ;;
    2) TUNNEL_DIR=reverse; save_conf
       ok "New tunnels will be reverse."
       echo -e "  ${D}Existing tunnels keep their current direction - rebuild them to change it.${N}"
       local p; p="$((RAW_PORT_BASE))"
       warn "Open TCP ${p}xx on THIS server's firewall - the exits will connect in."
       ;;
    *) return ;;
  esac
  pause
}

overview() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Overview${N}"; hr; echo

  local role_now; role_now="$(role)"
  echo -e "  ${W}System${N}"
  echo -e "    role                  ${W}$([[ "$role_now" == hub ]] && echo "hub" || echo "exit")${N}"
  echo -e "    public address        ${W}$(pub_ip)${N}"
  echo -e "    congestion control    ${W}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${N}"
  echo -e "    uptime                ${W}$(uptime -p 2>/dev/null | sed 's/^up //')${N}"
  echo -e "    load                  ${W}$(awk '{print $1", "$2", "$3}' /proc/loadavg)${N}  ${D}$(nproc) core(s)${N}"
  echo
  echo -e "  ${W}Services${N}"
  local u st
  for u in hydra-watch hydra-rule hydra-ports hydra-guard; do
    systemctl list-unit-files "$u.service" >/dev/null 2>&1 || continue
    st="$(systemctl is-active "$u" 2>/dev/null)"
    printf "    %-21s %b\n" "$u" "$([[ "$st" == active ]] && echo "${G}$st${N}" || echo "${D}$st${N}")"
  done
  st="$(systemctl is-enabled hydra-heal.timer 2>/dev/null)"
  printf "    %-21s %b\n" "hydra-heal.timer" "$([[ "$st" == enabled ]] && echo "${G}$st${N}" || echo "${D}${st:-not set up}${N}")"
  echo
  echo -e "  ${W}Tunnels${N}"
  local dir="$EXITS"; [[ "$role_now" != hub ]] && dir="$LINKS"
  local f n hs age any=0
  printf "    ${W}%-12s %-6s %-10s %-12s %s${N}\n" "NAME" "MODE" "FEC" "HANDSHAKE" "TRANSFER"
  for f in "$dir"/*.conf; do
    [[ -f "$f" ]] || continue; any=1
    n="$(basename "$f" .conf)"
    local MODE FEC; MODE="$(sed -n 's/^MODE=//p' "$f")"; FEC="$(sed -n 's/^FEC=//p' "$f")"
    if wg show "wg-$n" >/dev/null 2>&1; then
      hs="$(wg show "wg-$n" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)"
      local tx; tx="$(wg show "wg-$n" transfer 2>/dev/null | awk '{print $2" rx / "$3" tx"}')"
      if [[ -n "$hs" && "$hs" != 0 ]]; then
        age=$(( $(date +%s) - hs ))
        printf "    %-12s %-6s %-10s ${G}%-12s${N} ${D}%s${N}\n" "$n" "$MODE" "$FEC" "${age}s ago" "$(numfmt --to=iec ${tx%% *} 2>/dev/null||echo "$tx")"
      else
        printf "    %-12s %-6s %-10s ${R}%-12s${N}\n" "$n" "$MODE" "$FEC" "never"
      fi
    else
      printf "    %-12s %-6s %-10s ${R}%-12s${N}\n" "$n" "$MODE" "$FEC" "no interface"
    fi
  done
  [[ $any == 0 ]] && echo -e "    ${D}none${N}"
  echo
  echo -e "  ${W}Recent events${N}"
  tail -n 6 "$LOG" 2>/dev/null | sed 's/^/    /' || echo -e "    ${D}none${N}"
  pause
}

heal_menu() {
  while :; do
    clear; banner; echo; hr
    echo -e "  ${W}${BLD}Self-healing${N}   ${D}for links that drop every few hours${N}"; hr; echo
    local tstate gstate nextrun
    tstate="$(systemctl is-enabled hydra-heal.timer 2>/dev/null)"
    gstate="$(systemctl is-active hydra-guard 2>/dev/null)"
    nextrun="$(systemctl list-timers hydra-heal.timer --no-pager 2>/dev/null | awk 'NR==2{print $1, $2, $3}')"

    echo -e "  Scheduled reset      $([[ "$tstate" == enabled ]] && echo "${G}on${N}, every ${RESET_HOURS:-$RESET_HOURS_DEFAULT}h" || echo "${D}off${N}")"
    [[ "$tstate" == enabled && -n "$nextrun" ]] && echo -e "    ${D}next: $nextrun${N}"
    echo -e "  Handshake watchdog   $([[ "$gstate" == active ]] && echo "${G}on${N}" || echo "${D}off${N}")"
    echo
    echo -e "  ${D}The scheduled reset restarts every tunnel on a timer - blunt, but it${N}"
    echo -e "  ${D}clears stale sessions and a hub address that has changed.${N}"
    echo -e "  ${D}The watchdog is targeted: it restarts only a link whose handshake has${N}"
    echo -e "  ${D}gone quiet for more than four minutes.${N}"
    echo
    hr
    echo -e "   ${G}1${N}) Turn the scheduled reset $([[ "$tstate" == enabled ]] && echo off || echo on)"
    echo -e "   ${G}2${N}) Change the reset interval   ${D}current: ${RESET_HOURS:-$RESET_HOURS_DEFAULT}h${N}"
    echo -e "   ${G}3${N}) Turn the watchdog $([[ "$gstate" == active ]] && echo off || echo on)"
    echo -e "   ${G}4${N}) Reset every tunnel now"
    echo -e "   ${G}5${N}) Show recent heal events"
    echo -e "   ${G}0${N}) Back"; echo
    case "$(ask "Choice")" in
      1) heal_install
         if [[ "$tstate" == enabled ]]; then
           systemctl disable --now hydra-heal.timer >/dev/null 2>&1; ok "Scheduled reset off."
         else
           systemctl enable --now hydra-heal.timer >/dev/null 2>&1; ok "Scheduled reset on."
         fi; pause ;;
      2) local h; h="$(ask "Interval in hours" "${RESET_HOURS:-$RESET_HOURS_DEFAULT}")"
         if [[ "$h" =~ ^[0-9]+$ ]] && (( h >= 1 && h <= 168 )); then
           RESET_HOURS="$h"; save_conf; heal_install
           systemctl is-enabled hydra-heal.timer >/dev/null 2>&1 && systemctl restart hydra-heal.timer
           ok "Interval set to ${h}h."
         else err "Enter 1-168."; fi; pause ;;
      3) heal_install
         if [[ "$gstate" == active ]]; then
           systemctl disable --now hydra-guard >/dev/null 2>&1; ok "Watchdog off."
         else
           systemctl enable --now hydra-guard >/dev/null 2>&1; ok "Watchdog on."
         fi; pause ;;
      4) msg "Restarting every tunnel…"; hydra_self_heal_now; ok "Done."; pause ;;
      5) clear; echo -e "${W}Recent heal events${N}"; hr
         grep -E 'guard:|scheduled reset' "$LOG" 2>/dev/null | tail -25 || echo -e "  ${D}none yet${N}"
         pause ;;
      0|"") return ;;
    esac
  done
}

hydra_self_heal_now() {
  local f n
  for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && { n="$(basename "$f" .conf)"; systemctl restart "hydra-link@$n" 2>/dev/null; sleep 2; }; done
  for f in "$LINKS"/*.conf; do [[ -f "$f" ]] && { n="$(basename "$f" .conf)"; systemctl restart "hydra-exit-link@$n" 2>/dev/null; sleep 2; }; done
  logit "manual reset of all links"
  return 0
}

link_tuning_menu() {
  while :; do
    clear; banner; echo; hr; echo -e "  ${W}${BLD}Link tuning${N}  ${D}for lossy or unstable routes${N}"; hr; echo
    echo -e "  FEC                 ${W}$FEC${N}   $(awk -v v="$FEC" 'BEGIN{split(v,a,":"); printf "tolerates ~%.0f%% loss, costs %.0f%% bandwidth", 100*a[2]/(a[1]+a[2]), 100*a[2]/a[1]}')"
    echo -e "  FEC batching mode   ${W}$SPD_MODE${N}   ${D}$([[ "$SPD_MODE" == 0 ]] && echo "0 = fixed block, lowest latency" || echo "1 = adaptive, better on bursty loss")${N}"
    echo -e "  FEC timeout         ${W}${SPD_TIMEOUT}${N}   ${D}$([[ "$SPD_TIMEOUT" == 0 ]] && echo "0 = never wait to fill a block (best for gaming)" || echo "${SPD_TIMEOUT}us of batching delay")${N}"
    echo -e "  Queue length        ${W}$SPD_QUEUE${N}   ${D}packets held for reconstruction${N}"
    echo; hr
    echo -e "   ${G}1${N}) FEC ratio            ${D}the setting that matters most${N}"
    echo -e "   ${G}2${N}) Toggle batching mode ${D}try 1 if loss comes in bursts${N}"
    echo -e "   ${G}3${N}) FEC timeout         ${D}keep at 0 unless bandwidth is tight${N}"
    echo -e "   ${G}4${N}) Queue length        ${D}raise for high loss + high latency${N}"
    echo -e "   ${G}5${N}) ${W}Apply a high-loss preset${N}  ${D}one-shot setup for a bad link${N}"
    echo -e "   ${G}6${N}) ${W}Where is the loss coming from?${N}  ${D}read this before raising FEC${N}"
    echo -e "   ${G}7${N}) Find the working MTU        ${D}fixes loss that FEC cannot${N}"
    echo -e "   ${G}8${N}) CPU headroom                ${D}FEC encoding is CPU work${N}"
    echo -e "   ${G}9${N}) Throughput test             ${D}what the overhead really costs${N}"
    echo -e "   ${G}0${N}) Back"; echo
    case "$(ask "Choice")" in
      1) fec_menu ;;
      2) [[ "$SPD_MODE" == 0 ]] && SPD_MODE=1 || SPD_MODE=0
         save_conf; spd_push; ok "Batching mode is now $SPD_MODE."
         warn "Set the same on the other end."; pause ;;
      3) local t; t="$(ask "Timeout in microseconds (0 = none)" "$SPD_TIMEOUT")"
         if [[ "$t" =~ ^[0-9]+$ ]] && (( t <= 50000 )); then
           SPD_TIMEOUT="$t"; save_conf; spd_push
           ok "Timeout set to $t."
           (( t > 0 )) && warn "This adds up to ${t}us of latency to every packet."
         else err "Enter 0-50000."; fi; pause ;;
      4) local q; q="$(ask "Queue length" "$SPD_QUEUE")"
         if [[ "$q" =~ ^[0-9]+$ ]] && (( q >= 20 && q <= 2000 )); then
           SPD_QUEUE="$q"; save_conf; spd_push; ok "Queue length set to $q."
         else err "Enter 20-2000."; fi; pause ;;
      5) clear; banner; echo; hr
         echo -e "  ${W}${BLD}High-loss preset${N}"; hr; echo
         echo -e "  ${D}For a link losing roughly 20-30% of packets:${N}"
         echo -e "    FEC          ${W}4:8${N}    ${D}tolerates ~67% loss, triples traffic${N}"
         echo -e "    mode         ${W}1${N}      ${D}adaptive, handles bursts better${N}"
         echo -e "    timeout      ${W}0${N}      ${D}no added latency${N}"
         echo -e "    queue        ${W}400${N}    ${D}more room to reconstruct${N}"
         echo
         echo -e "  ${Y}This triples your bandwidth use.${N}"
         echo -e "  ${D}Fine for game traffic, expensive if you also push downloads through.${N}"
         echo
         if askyn "Apply it?" n; then
           SPD_MODE=1; SPD_TIMEOUT=0; SPD_QUEUE=400; save_conf
           fec_set "4:8"
           warn "Apply the SAME preset on the other end before testing."
         fi ;;
      6) analyze_loss ;;
      7) mtu_probe ;;
      8) cpu_check ;;
      9) bandwidth_test ;;
      10) transport_menu ;;
      0|"") return ;;
    esac
  done
}

spd_push() {   # push current tunables into every tunnel conf and restart FEC
  local f
  for f in "$EXITS"/*.conf "$LINKS"/*.conf; do
    [[ -f "$f" ]] || continue
    sed -i "s/^SPD_MODE=.*/SPD_MODE=$SPD_MODE/;    s/^SPD_TIMEOUT=.*/SPD_TIMEOUT=$SPD_TIMEOUT/; s/^SPD_QUEUE=.*/SPD_QUEUE=$SPD_QUEUE/" "$f"
    grep -q '^SPD_MODE='    "$f" || echo "SPD_MODE=$SPD_MODE"       >>"$f"
    grep -q '^SPD_TIMEOUT=' "$f" || echo "SPD_TIMEOUT=$SPD_TIMEOUT" >>"$f"
    grep -q '^SPD_QUEUE='   "$f" || echo "SPD_QUEUE=$SPD_QUEUE"     >>"$f"
  done
  systemctl daemon-reload
  for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && systemctl restart "hydra-spd@$(basename "$f" .conf)" 2>/dev/null; done
  for f in "$LINKS"/*.conf; do [[ -f "$f" ]] && systemctl restart "hydra-exit-spd@$(basename "$f" .conf)" 2>/dev/null; done
  return 0
}

# Azumi's projects all warn: always uninstall before reconfiguring. That advice
# exists because half-removed state causes exactly the symptoms we hit. So make
# it a single action instead of a manual ritual.
rebuild_tunnel() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Rebuild a tunnel from scratch${N}"; hr; echo
  echo -e "  ${D}Tears everything down - services, orphaned processes, interfaces,${N}"
  echo -e "  ${D}iptables rules, keys - then creates a fresh tunnel with the same${N}"
  echo -e "  ${D}settings. Use this when a tunnel is stuck and you have stopped${N}"
  echo -e "  ${D}trusting its current state.${N}"
  echo
  local n; n="$(ask "Tunnel name")"
  [[ -f "$EXITS/$n.conf" ]] || { err "Not found."; pause; return; }
  local MODE EXIT_IP; . "$EXITS/$n.conf"
  echo
  echo -e "  ${Y}The exit side must be cleaned too.${N}"
  echo -e "  ${D}On $EXIT_IP run:  ${W}hydra${D}  ->  Remove a link  ->  $n${N}"
  echo
  askyn "Have you removed it on the exit?" n || { msg "Do that first."; pause; return; }

  msg "Tearing down…"
  systemctl disable --now "hydra-link@$n" "hydra-raw@$n" "hydra-spd@$n" >/dev/null 2>&1
  pkill -f "udp2raw.*:$(sed -n 's/^RAW_PORT=//p' "$EXITS/$n.conf")" 2>/dev/null
  pkill -f "speederv2.*:$(sed -n 's/^SPD_LOCAL=//p' "$EXITS/$n.conf")" 2>/dev/null
  wg-quick down "wg-$n" 2>/dev/null
  ip link delete "wg-$n" 2>/dev/null
  systemctl reset-failed "hydra-link@$n" "hydra-raw@$n" "hydra-spd@$n" >/dev/null 2>&1
  tok_wipe "$DIR/token-$n.txt"
  rm -f "$EXITS/$n.conf" "/etc/wireguard/wg-$n.conf"
  pf_apply_all >/dev/null 2>&1
  ok "Torn down."
  echo
  echo -e "  ${D}Now create it again: menu -> Create new tunnel${N}"
  echo -e "  ${D}Suggested: name ${W}$n${D}, IP ${W}$EXIT_IP${D}, mode ${W}$MODE${N}"
  pause
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
    "SPD_MODE_T=$SPD_MODE" "SPD_TIMEOUT_T=$SPD_TIMEOUT" "SPD_QUEUE_T=$SPD_QUEUE" \
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

fix_hub_ip() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Repair the hub address${N}"; hr; echo
  echo -e "  ${D}The exit only accepts tunnel traffic from the hub address recorded here.${N}"
  echo -e "  ${D}If the hub reaches the internet through a different address than the one${N}"
  echo -e "  ${D}it was told to advertise, the packets get dropped and nothing connects.${N}"
  echo

  local f n
  printf "  ${W}%-12s %-18s %-10s %s${N}\n" "LINK" "RECORDED HUB" "DROPPED" "SEEN KNOCKING"
  hr
  for f in "$LINKS"/*.conf; do
    [[ -f "$f" ]] || continue
    ( . "$f"
      local proto port drops seen
      case "$MODE" in
        full) proto=tcp; port="$RAW_PORT" ;;
        fec)  proto=udp; port="$RAW_PORT" ;;
        *)    proto=udp; port="$WG_PORT" ;;
      esac
      drops="$(iptables -L HYDRA_IN -n -v 2>/dev/null | awk -v p="dpt:$port" '$0 ~ p && /DROP/ {print $1; exit}')"
      seen="$(exit_seen_sources "$NAME" | tr '\n' ' ')"
      printf "  %-12s %-18s %-10s %s\n" "$NAME" "${HUB_ALLOW:-$HUB_IP}" "${drops:-0}" "${seen:-none}" )
  done
  echo; hr
  echo -e "  ${D}A rising DROPPED count with a different address under SEEN KNOCKING${N}"
  echo -e "  ${D}is exactly this problem. Put that address in below.${N}"; echo

  n="$(ask "Link name to repair (blank to cancel)")"
  [[ -n "$n" ]] || return
  [[ -f "$LINKS/$n.conf" ]] || { err "Not found."; pause; return; }

  local cur; cur="$(sed -n 's/^HUB_ALLOW=//p' "$LINKS/$n.conf")"
  [[ -z "$cur" ]] && cur="$(sed -n 's/^HUB_IP=//p' "$LINKS/$n.conf")"
  echo
  echo -e "  ${D}You can enter several addresses separated by commas if the hub has${N}"
  echo -e "  ${D}more than one uplink.${N}"
  local new; new="$(ask "Allowed hub address(es)" "$cur")"
  [[ -n "$new" ]] || return

  if grep -q '^HUB_ALLOW=' "$LINKS/$n.conf"; then
    sed -i "s|^HUB_ALLOW=.*|HUB_ALLOW=$new|" "$LINKS/$n.conf"
  else
    echo "HUB_ALLOW=$new" >>"$LINKS/$n.conf"
  fi
  exit_lock "$n"
  logit "hub address for $n set to $new"
  ok "Updated. The lock now accepts: $new"
  echo -e "  ${D}Check the hub's status table in a few seconds.${N}"
  pause
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
      local locked drops
      locked="$(iptables -S HYDRA_IN 2>/dev/null | grep -c ' -j DROP')"
      drops="$(iptables -L HYDRA_IN -n -v 2>/dev/null | awk '/DROP/{t+=$1} END{print t+0}')"
      local anyfull=0 ff
      for ff in "$LINKS"/*.conf; do [[ -f "$ff" ]] && grep -q '^MODE=full' "$ff" && anyfull=1; done
      if (( anyfull )); then
        echo -e "  Ingress source filter       ${D}n/a in faketcp mode - raw sockets bypass iptables${N}"
      else
        echo -e "  Ingress locked to hub IP    $( [[ "$locked" != 0 ]] && echo "$yes ($locked port(s))" || echo "$no")"
      fi
      echo -e "  Packets dropped by the lock $( [[ "$drops" != 0 ]] && echo "${Y}$drops${N}  <- wrong hub address?" || echo "${G}0${N}")"
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
      echo -e "   ${G}5${N}) Set hub public address   ${D}current: $(pub_ip)${N}"
    else
      echo -e "   ${G}1${N}) Re-apply ingress lock"
      echo -e "   ${G}2${N}) ${W}Repair the hub address${N}   ${D}fixes 'down' with no handshake${N}"
      echo -e "   ${G}3${N}) Re-check binary hashes"
      echo -e "   ${G}4${N}) Turn the ingress lock $([[ "${INGRESS_LOCK:-1}" == 1 ]] && echo off || echo on)"
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
           pause
         else fix_hub_ip; fi ;;
      3) bin_hashes; ok "Checked."; pause ;;
      4) if [[ "$(role)" != hub ]]; then
           [[ "${INGRESS_LOCK:-1}" == 1 ]] && INGRESS_LOCK=0 || INGRESS_LOCK=1
           save_conf; exit_lock_all
           ok "Ingress lock is now $([[ "$INGRESS_LOCK" == 1 ]] && echo on || echo off)."
           [[ "$INGRESS_LOCK" == 0 ]] && warn "The tunnel port is now reachable from any address."
           pause; return
         fi
         if [[ "$(role)" == hub ]]; then
           local m; m="$(ask "Invite lifetime in minutes" "30")"
           [[ "$m" =~ ^[0-9]+$ ]] && (( m >= 1 && m <= 1440 )) \
             && { TOKEN_TTL=$((m*60)); save_conf; ok "Invites now expire after $m minutes."; } \
             || err "Enter a number between 1 and 1440."
         fi; pause ;;
      5) if [[ "$(role)" == hub ]]; then
           echo -e "  ${D}outbound (as seen by the internet): ${W}$(detect_pub_ip)${N}"
           local v; v="$(ask "Hub public address" "$(pub_ip)")"
           if [[ -n "$v" ]]; then
             HUB_PUBLIC_IP="$v"; save_conf
             ok "Hub advertises $v from now on."
             warn "Existing tunnels keep the old address - use 'Re-issue invite' to update them."
           fi
         fi; pause ;;
      0|"") return ;;
    esac
  done
}

# ============================================================== game testing ==
#  Measures what a player would actually feel, WITHOUT anyone needing a config
#  or a game client. The chain is:
#
#     player -> [a] -> Iran hub -> [b] -> exit -> [c] -> game server
#
#  [b] and [c] are measured here. [a] is the player's own ISP latency to the
#  Iran hub and CANNOT be measured from the server - the player has to supply
#  it, or you estimate it from their city. The tool is explicit about this
#  rather than printing a number that pretends to be the final ping.

GAMES_FILE="$DIR/games.conf"

game_defaults() {
  cat <<'EOF'
# game|region|host|note
Dota 2|Europe West|185.25.183.1|Valve Luxembourg
Dota 2|Europe East|155.133.238.1|Valve Vienna
Dota 2|Dubai|185.25.180.1|Valve Dubai
CS2 / CSGO|Europe West|155.133.240.1|Valve Frankfurt
CS2 / CSGO|Europe East|155.133.238.1|Valve Vienna
CS2 / CSGO|Dubai|185.25.180.1|Valve Dubai
Valorant|Europe|104.18.32.1|Riot EU edge
League of Legends|Europe West|162.249.72.1|Riot EUW
PUBG|Europe|52.58.0.1|AWS Frankfurt
PUBG|Middle East|157.241.0.1|AWS Bahrain
Rainbow Six Siege|Europe|185.38.0.1|Ubisoft EU
Call of Duty|Europe|52.58.0.1|Activision EU edge
eFootball|Europe|35.156.0.1|Konami EU
Fortnite|Europe|18.194.0.1|Epic EU
Apex Legends|Europe|162.254.192.1|EA EU
Rocket League|Europe|35.156.0.1|Psyonix EU
Minecraft (Hypixel)|Europe|172.65.230.1|Hypixel EU
GTA Online|Europe|192.81.241.1|Rockstar EU
EOF
}

games_load() {
  [[ -f "$GAMES_FILE" ]] || ( umask 077; game_defaults >"$GAMES_FILE" )
  grep -v '^#' "$GAMES_FILE" | grep -v '^[[:space:]]*$'
}

# Ping a host FROM a given exit, through the tunnel. Returns "avg loss".
ping_via_exit() {
  local exit_name="$1" host="$2" count="${3:-20}"
  local out avg loss
  # source-route through the tunnel interface so the packet really takes the path
  out="$(ping -I "wg-$exit_name" -c "$count" -i 0.2 -W 2 -q "$host" 2>/dev/null)"
  avg="$(sed  -n 's#.*= [0-9.]*/\([0-9.]*\)/.*#\1#p' <<<"$out")"
  loss="$(sed -n 's/.*, \([0-9.]*\)% packet loss.*/\1/p' <<<"$out")"
  echo "${avg:--} ${loss:-100}"
}

# Latency of the tunnel leg itself (hub -> exit), the part you control.
tunnel_leg() {
  local n="$1" peer out avg
  peer="$(sed -n 's/^EXIT_IN=//p' "$EXITS/$n.conf" 2>/dev/null)"
  [[ -n "$peer" ]] || { echo "-"; return; }
  out="$(ping -I "wg-$n" -c 10 -i 0.2 -W 2 -q "$peer" 2>/dev/null)"
  avg="$(sed -n 's#.*= [0-9.]*/\([0-9.]*\)/.*#\1#p' <<<"$out")"
  echo "${avg:--}"
}

rate_ping() {   # colour + verdict for a final estimated ping
  local ms="${1%.*}"
  if   (( ms < 60  )); then echo "${G}excellent${N}"
  elif (( ms < 90  )); then echo "${G}good${N}"
  elif (( ms < 130 )); then echo "${Y}playable${N}"
  elif (( ms < 180 )); then echo "${Y}rough${N}"
  else                      echo "${R}bad${N}"; fi
}

game_test_one() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Test one game${N}"; hr; echo

  local names; names="$(for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && basename "$f" .conf; done | tr '\n' ' ')"
  [[ -n "${names// /}" ]] || { err "No tunnels yet."; pause; return; }

  # pick a game
  local i=0 line
  local -a G_NAME G_REG G_HOST G_NOTE
  while IFS='|' read -r gname greg ghost gnote; do
    [[ -z "$gname" ]] && continue
    i=$((i+1)); G_NAME[i]="$gname"; G_REG[i]="$greg"; G_HOST[i]="$ghost"; G_NOTE[i]="$gnote"
  done < <(games_load)

  local j
  for j in $(seq 1 $i); do
    printf "   ${G}%2s${N}) %-22s ${D}%-14s %s${N}\n" "$j" "${G_NAME[j]}" "${G_REG[j]}" "${G_NOTE[j]}"
  done
  echo
  local sel; sel="$(ask "Game number")"
  [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= i )) || { err "Invalid selection."; pause; return; }

  echo
  echo -e "  ${D}Available exits: ${W}$names${N}"
  local n; n="$(ask "Test through which exit?" "$(cut -d' ' -f1 <<<"$names")")"
  [[ -f "$EXITS/$n.conf" ]] || { err "Exit not found."; pause; return; }
  wg show "wg-$n" >/dev/null 2>&1 || { err "That tunnel is not up."; pause; return; }

  clear; banner; echo; hr
  echo -e "  ${W}${BLD}${G_NAME[$sel]}${N}  ${D}via ${G_REG[$sel]} (${G_HOST[$sel]})${N}"; hr; echo
  echo -e "  ${D}measuring…${N}"

  local leg; leg="$(tunnel_leg "$n")"
  read -r gp gl < <(ping_via_exit "$n" "${G_HOST[$sel]}" 25)

  printf "\r%*s\r" 60 ""
  if [[ "$gp" == "-" ]]; then
    echo -e "  ${Y}No ICMP reply from the game endpoint.${N}"
    echo -e "  ${D}Most game servers filter ping. This does NOT mean the route is broken -${N}"
    echo -e "  ${D}it means this particular endpoint will not answer. Try another region,${N}"
    echo -e "  ${D}or use 'Test a custom host' with an address you know replies.${N}"
    echo
    echo -e "  Tunnel leg (hub to exit): ${W}${leg}ms${N}   ${D}this part is measurable and healthy${N}"
    pause; return
  fi

  echo -e "  ${W}Measured${N}"
  echo -e "    hub -> exit            ${W}${leg}ms${N}"
  echo -e "    exit -> game server    ${W}${gp}ms${N}   ${D}loss ${gl}%${N}"
  echo
  local server_side
  server_side="$(awk -v a="$leg" -v b="$gp" 'BEGIN{printf "%.0f", a+b}')"
  echo -e "    server-side total      ${W}${server_side}ms${N}   ${D}everything you control${N}"
  echo
  hr
  echo -e "  ${W}What the player will see${N}"
  echo -e "  ${D}Add the player's own latency to the Iran hub. Typical values:${N}"
  echo
  local city rtt est
  for city in "Tehran fibre:10" "Tehran ADSL:25" "Mashhad/Isfahan:30" "Mobile 4G:45" "Remote province:60"; do
    rtt="${city##*:}"
    est="$(awk -v s="$server_side" -v r="$rtt" 'BEGIN{printf "%.0f", s+r}')"
    printf "    %-22s +%-5s = ${W}%4sms${N}  %b\n" "${city%%:*}" "${rtt}ms" "$est" "$(rate_ping "$est")"
  done
  echo
  hr
  if [[ "${gl%.*}" -gt 2 ]]; then
    echo -e "  ${Y}${gl}% loss on the exit-to-game leg.${N}"
    echo -e "  ${D}That is beyond your tunnel - it is the exit datacentre's route to the${N}"
    echo -e "  ${D}game server. FEC does not cover this leg. Another exit region may be better.${N}"
  fi
  echo -e "  ${D}If a customer reports worse than the estimate above, the extra latency is${N}"
  echo -e "  ${D}on their side: their ISP, their wifi, or their distance to the hub.${N}"
  pause
}

game_test_all() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Test every game through one exit${N}"; hr; echo
  local names; names="$(for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && basename "$f" .conf; done | tr '\n' ' ')"
  [[ -n "${names// /}" ]] || { err "No tunnels yet."; pause; return; }
  echo -e "  ${D}Available exits: ${W}$names${N}"; echo
  local n; n="$(ask "Exit" "$(cut -d' ' -f1 <<<"$names")")"
  [[ -f "$EXITS/$n.conf" ]] || { err "Not found."; pause; return; }
  wg show "wg-$n" >/dev/null 2>&1 || { err "That tunnel is not up."; pause; return; }

  local leg; leg="$(tunnel_leg "$n")"
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}All games via exit '$n'${N}   ${D}tunnel leg ${leg}ms${N}"; hr; echo
  echo -e "  ${D}Estimates assume a player 25ms from the hub. Adjust for your customer.${N}"
  echo
  printf "  ${W}%-22s %-13s %-8s %-7s %-9s %s${N}\n" "GAME" "REGION" "EXIT>SRV" "LOSS" "EST PING" "RATING"
  hr

  local gname greg ghost gnote gp gl total
  while IFS='|' read -r gname greg ghost gnote; do
    [[ -z "$gname" ]] && continue
    read -r gp gl < <(ping_via_exit "$n" "$ghost" 8)
    if [[ "$gp" == "-" ]]; then
      printf "  %-22s %-13s ${D}%-8s %-7s %-9s %s${N}\n" "$gname" "$greg" "no reply" "-" "-" "filtered"
    else
      total="$(awk -v a="$leg" -v b="$gp" 'BEGIN{printf "%.0f", a+b+25}')"
      printf "  %-22s %-13s %-8s %-7s %-9s %b\n" \
        "$gname" "$greg" "${gp}ms" "${gl}%" "${total}ms" "$(rate_ping "$total")"
    fi
  done < <(games_load)

  echo; hr
  echo -e "  ${D}'filtered' means the endpoint blocks ICMP, not that the route is bad.${N}"
  echo -e "  ${D}EST PING = tunnel leg + exit-to-server + 25ms assumed player latency.${N}"
  pause
}

game_compare_exits() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Which exit is best for one game?${N}"; hr; echo

  local i=0
  local -a G_NAME G_REG G_HOST
  while IFS='|' read -r gname greg ghost gnote; do
    [[ -z "$gname" ]] && continue
    i=$((i+1)); G_NAME[i]="$gname"; G_REG[i]="$greg"; G_HOST[i]="$ghost"
  done < <(games_load)
  local j
  for j in $(seq 1 $i); do
    printf "   ${G}%2s${N}) %-22s ${D}%s${N}\n" "$j" "${G_NAME[j]}" "${G_REG[j]}"
  done
  echo
  local sel; sel="$(ask "Game number")"
  [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= i )) || { err "Invalid."; pause; return; }

  clear; banner; echo; hr
  echo -e "  ${W}${BLD}${G_NAME[$sel]}${N}  ${D}${G_REG[$sel]}${N}"; hr; echo
  printf "  ${W}%-12s %-10s %-10s %-9s %s${N}\n" "EXIT" "TUNNEL" "EXIT>SRV" "TOTAL" "RATING"
  hr
  local f n leg gp gl total best="" bestv=99999
  for f in "$EXITS"/*.conf; do
    [[ -f "$f" ]] || continue
    n="$(basename "$f" .conf)"
    wg show "wg-$n" >/dev/null 2>&1 || { printf "  %-12s ${R}%s${N}\n" "$n" "tunnel down"; continue; }
    leg="$(tunnel_leg "$n")"
    read -r gp gl < <(ping_via_exit "$n" "${G_HOST[$sel]}" 12)
    if [[ "$gp" == "-" ]]; then
      printf "  %-12s %-10s ${D}%-10s %-9s %s${N}\n" "$n" "${leg}ms" "no reply" "-" "filtered"
      continue
    fi
    total="$(awk -v a="$leg" -v b="$gp" 'BEGIN{printf "%.0f", a+b}')"
    printf "  %-12s %-10s %-10s %-9s %b\n" "$n" "${leg}ms" "${gp}ms" "${total}ms" "$(rate_ping "$((total+25))")"
    (( ${total%.*} < bestv )) && { bestv="${total%.*}"; best="$n"; }
  done
  echo; hr
  [[ -n "$best" ]] && echo -e "  Best exit for this game: ${G}$best${N} ${D}(${bestv}ms server-side)${N}"
  echo -e "  ${D}Pin it with: Manage tunnels -> Pin to an exit${N}"
  pause
}

game_custom() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Test a custom host${N}"; hr; echo
  echo -e "  ${D}Use this for a game server you know the address of, or any host that${N}"
  echo -e "  ${D}answers ping. Address or hostname both work.${N}"; echo
  local h; h="$(ask "Host or IP")"
  [[ -n "$h" ]] || return
  local names; names="$(for f in "$EXITS"/*.conf; do [[ -f "$f" ]] && basename "$f" .conf; done | tr '\n' ' ')"
  local n; n="$(ask "Through which exit?" "$(cut -d' ' -f1 <<<"$names")")"
  [[ -f "$EXITS/$n.conf" ]] || { err "Not found."; pause; return; }
  wg show "wg-$n" >/dev/null 2>&1 || { err "That tunnel is not up."; pause; return; }

  echo
  echo -e "  ${D}measuring…${N}"
  local leg; leg="$(tunnel_leg "$n")"
  read -r gp gl < <(ping_via_exit "$n" "$h" 25)
  printf "\r%*s\r" 40 ""
  if [[ "$gp" == "-" ]]; then
    err "No reply from $h (it may filter ICMP)."
    pause; return
  fi
  local server_side; server_side="$(awk -v a="$leg" -v b="$gp" 'BEGIN{printf "%.0f", a+b}')"
  echo -e "  hub -> exit           ${W}${leg}ms${N}"
  echo -e "  exit -> $h  ${W}${gp}ms${N}  ${D}loss ${gl}%${N}"
  echo -e "  server-side total     ${W}${server_side}ms${N}"
  echo
  echo -e "  ${D}Player's final ping = this + their own latency to the hub.${N}"
  pause
}

game_edit_list() {
  clear; banner; echo; hr
  echo -e "  ${W}${BLD}Game server list${N}"; hr; echo
  echo -e "  ${D}Stored in $GAMES_FILE${N}"
  echo -e "  ${D}Format: name|region|host|note - one per line.${N}"
  echo
  echo -e "  ${Y}These are best-effort endpoints for the regions Iranian players usually${N}"
  echo -e "  ${Y}connect to. Publishers change IPs without notice, and many filter ICMP.${N}"
  echo -e "  ${D}For numbers you can rely on, replace them with addresses you have seen${N}"
  echo -e "  ${D}your own traffic actually use.${N}"
  echo
  echo -e "   ${G}1${N}) Edit the list      ${G}2${N}) Restore defaults      ${G}0${N}) Back"
  echo
  case "$(ask "Choice")" in
    1) games_load >/dev/null
       ${EDITOR:-nano} "$GAMES_FILE" ;;
    2) if askyn "Overwrite with defaults?" n; then ( umask 077; game_defaults >"$GAMES_FILE" ); ok "Restored."; fi; pause ;;
    *) return ;;
  esac
}

game_menu() {
  while :; do
    clear; banner; echo; hr
    echo -e "  ${W}${BLD}Game latency test${N}   ${D}no game client or config needed${N}"
    hr; echo
    echo -e "  ${D}Measures the part of the path you control: hub -> exit -> game server.${N}"
    echo -e "  ${D}The player's own latency to the hub is added as an estimate.${N}"
    echo; hr
    echo -e "   ${G}1${N}) Test one game            ${D}detailed, with player estimates${N}"
    echo -e "   ${G}2${N}) Test all games           ${D}one exit, full table${N}"
    echo -e "   ${G}3${N}) Compare exits for a game ${D}which server to pin${N}"
    echo -e "   ${G}4${N}) Test a custom host"
    echo -e "   ${G}5${N}) Edit the game server list"
    echo -e "   ${G}0${N}) Back"; echo
    case "$(ask "Choice")" in
      1) game_test_one ;;
      2) game_test_all ;;
      3) game_compare_exits ;;
      4) game_custom ;;
      5) game_edit_list ;;
      0|"") return ;;
    esac
  done
}

diagnose_menu() {
  clear; banner; echo; hr; echo -e "  ${W}${BLD}Diagnose a tunnel${N}"; hr; echo
  local n; n="$(ask "Tunnel name")"
  local dir="$EXITS" pre="hydra" ; [[ "$(role)" != hub ]] && { dir="$LINKS"; pre="hydra-exit"; }
  [[ -f "$dir/$n.conf" ]] || { err "Not found."; pause; return; }
  local NAME MODE EXIT_IP RAW_PORT SPD_LOCAL PAIRED EXIT_PUB
  . "$dir/$n.conf"
  echo
  local f_ok="${G}ok${N}" f_bad="${R}FAILED${N}"

  echo -e "  ${W}Binaries${N}"
  echo -e "    udp2raw                   $([[ -x $BINDIR/udp2raw ]]   && echo "$f_ok" || echo "$f_bad  not installed")"
  echo -e "    speederv2                 $([[ -x $BINDIR/speederv2 ]] && echo "$f_ok" || echo "$f_bad  not installed")"
  echo
  echo -e "  ${W}Services${N}"
  local svc st
  for svc in raw spd; do
    [[ "$MODE" == plain ]] && break
    [[ "$MODE" == fec && "$svc" == raw ]] && continue
    st="$(systemctl is-active "$pre-$svc@$n" 2>/dev/null)"
    if [[ "$st" == active ]]; then
      echo -e "    $pre-$svc@$n$(printf '%*s' $((24 - ${#pre} - ${#svc} - ${#n} - 2)) '')$f_ok"
    else
      echo -e "    $pre-$svc@$n$(printf '%*s' $((24 - ${#pre} - ${#svc} - ${#n} - 2)) '')${R}$st${N}"
      echo -e "      ${D}journalctl -u $pre-$svc@$n -n 30 --no-pager${N}"
    fi
  done
  echo
  echo -e "  ${W}WireGuard${N}"
  if wg show "wg-$n" >/dev/null 2>&1; then
    local hs; hs="$(wg show "wg-$n" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)"
    if [[ -n "$hs" && "$hs" != 0 ]]; then
      echo -e "    interface wg-$n           $f_ok  handshake $(( $(date +%s) - hs ))s ago"
    else
      echo -e "    interface wg-$n           ${Y}up, no handshake${N}"
      echo -e "      ${D}keys may not match - re-issue the invite and pair again${N}"
    fi
  else
    echo -e "    interface wg-$n           $f_bad  not present"
    echo -e "      ${D}the layer below it is down, fix that first${N}"
  fi
  if [[ "$(role)" == hub ]]; then
    echo
    echo -e "  ${W}Pairing${N}"
    echo -e "    paired                    $([[ "${PAIRED:-0}" == 1 && -n "${EXIT_PUB:-}" ]] && echo "$f_ok" || echo "${Y}not paired${N}")"
  fi
  pause
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
  systemctl disable --now hydra-watch hydra-rule hydra-ports hydra-guard hydra-heal.timer wg-quick@wg0 >/dev/null 2>&1
  iptables -t nat -D PREROUTING  -j HYDRA_PRE  2>/dev/null
  iptables -t nat -D POSTROUTING -j HYDRA_POST 2>/dev/null
  iptables        -D FORWARD     -j HYDRA_FWD  2>/dev/null
  iptables -t nat -F HYDRA_PRE 2>/dev/null; iptables -t nat -X HYDRA_PRE 2>/dev/null
  iptables -t nat -F HYDRA_POST 2>/dev/null; iptables -t nat -X HYDRA_POST 2>/dev/null
  iptables -F HYDRA_FWD 2>/dev/null; iptables -X HYDRA_FWD 2>/dev/null
  iptables -D INPUT -j HYDRA_IN 2>/dev/null
  iptables -F HYDRA_IN 2>/dev/null; iptables -X HYDRA_IN 2>/dev/null
  rm -f /etc/systemd/system/hydra-*.service /etc/systemd/system/hydra-*.timer
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
    echo -e "   ${G}4${N}) Link tuning             ${D}FEC $FEC, for lossy links${N}"
    echo -e "   ${G}5${N}) Port forwarding         ${D}many ports at once, comma-separated${N}"
    echo -e "   ${G}6${N}) Security                ${D}keys, isolation, tokens${N}"
    echo -e "   ${G}7${N}) Re-apply BBR and tuning"
    echo -e "   ${G}8${N}) Events and logs"
    echo -e "   ${G}9${N}) Diagnose a tunnel       ${D}find which layer is broken${N}"
    echo -e "  ${G}10${N}) ${W}Game latency test${N}       ${D}what will the player's ping be${N}"
    echo -e "  ${G}11${N}) ${R}Uninstall${N}"
    echo -e "   ${G}0${N}) Quit"; echo
    case "$(ask "Choice")" in
      1) create_tunnel ;; 2) tunnel_menu ;; 3) client_menu ;; 4) link_tuning_menu ;;
      5) port_menu ;; 6) security_menu ;; 7) apply_tune; pause ;;
      8) logs_menu ;; 9) diagnose_menu ;; 10) game_menu ;;
      11) heal_menu ;; 12) overview ;; 13) reverse_menu ;; 14) uninstall_all ;;
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
    echo -e "   ${G}4${N}) Link tuning             ${D}FEC $FEC, for lossy links${N}"
    echo -e "   ${G}5${N}) Security                ${D}keys, ingress lock${N}"
    echo -e "   ${G}6${N}) Re-apply BBR and tuning"
    echo -e "   ${G}7${N}) Events and logs"
    echo -e "   ${G}8${N}) Diagnose a tunnel       ${D}find which layer is broken${N}"
    echo -e "   ${G}9${N}) Self-healing            ${D}auto-reset for links that drop${N}"
    echo -e "  ${G}10${N}) Overview                ${D}everything on one screen${N}"
    echo -e "  ${G}11${N}) ${R}Uninstall${N}"
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
      4) link_tuning_menu ;; 5) security_menu ;; 6) apply_tune; pause ;;
      7) logs_menu ;; 8) diagnose_menu ;; 9) heal_menu ;;
      10) overview ;; 11) uninstall_all ;;
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
INSTALL_URL="${HYDRA_INSTALL_URL:-https://raw.githubusercontent.com/devprogrmer/hydra/main/install.sh}"

# ================================================================== dispatch ==
case "${1:-}" in
  _link-up)    _link_up "$2" ;;
  _link-down)  _link_down "$2" ;;
  _elink-up)   _elink_up "$2" ;;
  _elink-down) _elink_down "$2" ;;
  _watch)      _watch ;;
  _ports-apply) pf_apply_all >/dev/null; exit 0 ;;
  _heal)       _heal ;;
  _guard)      _guard ;;
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
