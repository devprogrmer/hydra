#!/usr/bin/env bash
# ============================================================================
#  hydra installer
#
#  Install and open the menu:
#     bash <(curl -fsSL https://raw.githubusercontent.com/devprogrmer/hydra/main/install.sh)
#
#  Install straight onto a foreign server with an invite token:
#     bash <(curl -fsSL .../install.sh) apply PASTE_THE_REAL_TOKEN_HERE
#
#  Override the source repo without editing this file:
#     HYDRA_REPO=user/repo bash <(curl -fsSL .../install.sh)
# ============================================================================
set -euo pipefail

# ── Source repository. Override at runtime with HYDRA_REPO=user/repo ────────
REPO="${HYDRA_REPO:-devprogrmer/hydra}"
BRANCH="${HYDRA_BRANCH:-}"
# ───────────────────────────────────────────────────────────────────────────

G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; W=$'\e[97m'; D=$'\e[90m'; N=$'\e[0m'
ok(){   echo -e "${G}✔${N} $*"; }
warn(){ echo -e "${Y}!${N} $*"; }
err(){  echo -e "${R}✘${N} $*" >&2; }

[[ $EUID -eq 0 ]] || {
  err "Run as root."
  echo -e "  ${W}sudo bash <(curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh)${N}"
  exit 1
}

# Refuse to run with the placeholder still in place - this is the mistake that
# produces a confusing 404 halfway through the install.
if [[ "$REPO" == *YOUR_USER* || "$REPO" == *your_user* ]]; then
  err "The REPO line in this installer was never filled in."
  echo -e "  Edit it to your GitHub path, or run it once like this:"
  echo -e "  ${W}HYDRA_REPO=youruser/hydra bash <(curl -fsSL <url>/install.sh)${N}"
  exit 1
fi

echo -e "${W}Installing hydra…${N}"
echo -e "${D}source: $REPO${N}"

command -v curl >/dev/null || {
  if   command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq curl
  elif command -v dnf     >/dev/null; then dnf install -y -q curl
  elif command -v yum     >/dev/null; then yum install -y -q curl
  else err "curl is not installed and no known package manager was found."; exit 1; fi
}

fetch() {  # fetch <branch> <outfile> -> 0 on success
  curl -fsSL --max-time 30 "https://raw.githubusercontent.com/$REPO/$1/hydra.sh" -o "$2"
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

got=""
if [[ -n "$BRANCH" ]]; then
  fetch "$BRANCH" "$tmp" && got="$BRANCH"
else
  for b in main master; do
    if fetch "$b" "$tmp"; then got="$b"; break; fi
  done
fi

if [[ -z "$got" ]]; then
  err "Could not download hydra.sh from $REPO"
  echo
  echo -e "${W}What to check, in order:${N}"
  echo -e "  ${W}1.${N} Is hydra.sh actually in the repository root?"
  echo -e "     ${D}curl -sI https://raw.githubusercontent.com/$REPO/main/hydra.sh | head -1${N}"
  echo -e "     ${D}A 200 means yes. A 404 means the file was never pushed.${N}"
  echo -e "  ${W}2.${N} Is the repo public? Private repos are not reachable this way."
  echo -e "  ${W}3.${N} Is the branch called something other than main or master?"
  echo -e "     ${D}HYDRA_BRANCH=yourbranch HYDRA_REPO=$REPO bash <(curl -fsSL .../install.sh)${N}"
  echo -e "  ${W}4.${N} Is the repo path right? It should look like ${W}user/repo${N}, not a full URL."
  exit 1
fi

# Sanity-check what came back. A truncated download is worse than no download,
# and some misconfigurations serve an HTML error page with a 200 status.
head -1 "$tmp" | grep -q '^#!' || {
  err "The downloaded file is not a shell script."
  echo -e "  ${D}First line was: $(head -c 120 "$tmp")${N}"
  exit 1
}
grep -q 'hydra' "$tmp" || { err "The downloaded file does not look like hydra.sh."; exit 1; }
bash -n "$tmp" 2>/dev/null || { err "The downloaded hydra.sh has syntax errors - the file is likely corrupted."; exit 1; }

install -m755 "$tmp" /usr/local/bin/hydra

BASE="https://raw.githubusercontent.com/$REPO/$got"
mkdir -p /etc/hydra
( umask 077; echo "HYDRA_INSTALL_URL=$BASE/install.sh" >/etc/hydra/install-url )
cat >/etc/profile.d/hydra.sh <<EOF
export HYDRA_INSTALL_URL="$BASE/install.sh"
EOF

ok "Installed from $REPO ($got). Command: ${W}hydra${N}"
echo

export HYDRA_INSTALL_URL="$BASE/install.sh"

if [[ "${1:-}" == "apply" ]]; then
  if [[ -z "${2:-}" ]]; then
    err "No token given."
    echo -e "  Paste the ${W}actual${N} invite token from the hub, with no angle brackets:"
    echo -e "  ${D}bash <(curl -fsSL $BASE/install.sh) apply eyJOQU1FPWRl…${N}"
    exit 1
  fi
  exec /usr/local/bin/hydra apply "$2"
else
  exec /usr/local/bin/hydra
fi
