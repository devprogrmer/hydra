#!/usr/bin/env bash
# ============================================================================
#  hydra installer
#
#  Install and open the menu:
#     bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USER/hydra/main/install.sh)
#
#  Install straight onto a foreign server with a token:
#     bash <(curl -fsSL .../install.sh) apply <TOKEN>
# ============================================================================
set -euo pipefail

# ── EDIT THIS ONE LINE: set it to your own GitHub path ─────────────────────
REPO="${HYDRA_REPO:-YOUR_USER/hydra}"
BRANCH="${HYDRA_BRANCH:-main}"
# ───────────────────────────────────────────────────────────────────────────

BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; W=$'\e[97m'; D=$'\e[90m'; N=$'\e[0m'

[[ $EUID -eq 0 ]] || { echo -e "${R}✘${N} Run as root:  sudo bash <(curl -fsSL $BASE/install.sh)"; exit 1; }

echo -e "${W}Installing hydra…${N}"

command -v curl >/dev/null || {
  if   command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq curl
  elif command -v dnf     >/dev/null; then dnf install -y -q curl
  else echo -e "${R}✘${N} curl is not installed."; exit 1; fi
}

tmp="$(mktemp)"
if ! curl -fsSL "$BASE/hydra.sh" -o "$tmp"; then
  echo -e "${R}✘${N} Failed to download $BASE/hydra.sh"
  echo -e "${D}If the repo is private or the path is wrong, set HYDRA_REPO:${N}"
  echo -e "${D}  HYDRA_REPO=user/repo bash <(curl -fsSL .../install.sh)${N}"
  exit 1
fi

head -1 "$tmp" | grep -q '^#!' || { echo -e "${R}✘${N} The downloaded file is not a valid script."; exit 1; }

install -m755 "$tmp" /usr/local/bin/hydra
rm -f "$tmp"

# record the install URL so generated tokens carry the right one-liner
mkdir -p /etc/hydra
echo "HYDRA_INSTALL_URL=$BASE/install.sh" >/etc/hydra/install-url
cat >/etc/profile.d/hydra.sh <<EOF
export HYDRA_INSTALL_URL="$BASE/install.sh"
EOF

echo -e "${G}✔${N} Installed. Run: ${W}hydra${N}"
echo

export HYDRA_INSTALL_URL="$BASE/install.sh"

if [[ "${1:-}" == "apply" && -n "${2:-}" ]]; then
  exec /usr/local/bin/hydra apply "$2"
else
  exec /usr/local/bin/hydra
fi
