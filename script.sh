#!/usr/bin/env bash
#
# clean-motd.sh
# Strips the Contabo ASCII art, Ubuntu Pro / ESM nags, legal notice and
# update counters from an Ubuntu server login. Optionally writes your own
# banner in their place.
#
# Usage:
#   sudo ./clean-motd.sh                    clean everything, no custom banner
#   sudo ./clean-motd.sh --brand "My Host"  clean and write a branded MOTD
#   sudo ./clean-motd.sh --silent           clean and suppress the login line too
#   sudo ./clean-motd.sh --purge-pro        also remove the ubuntu-pro client
#   sudo ./clean-motd.sh --restore          undo everything from the last backup
#
# Safe to run more than once.

set -euo pipefail

BACKUP_ROOT="/root/.motd-backups"
LATEST_LINK="${BACKUP_ROOT}/latest"

BRAND=""
SUPPORT=""
SILENT=0
PURGE_PRO=0
RESTORE=0

# ---------------------------------------------------------------- helpers ---

log()  { printf '  \033[32m*\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[31mx\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    die "Run this as root or with sudo."
  fi
}

usage() {
  sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# ------------------------------------------------------------ arg parsing ---

while [[ $# -gt 0 ]]; do
  case "$1" in
    --brand)     BRAND="${2:-}"; shift 2 ;;
    --support)   SUPPORT="${2:-}"; shift 2 ;;
    --silent)    SILENT=1; shift ;;
    --purge-pro) PURGE_PRO=1; shift ;;
    --restore)   RESTORE=1; shift ;;
    -h|--help)   usage ;;
    *)           die "Unknown option: $1  (try --help)" ;;
  esac
done

require_root

# ---------------------------------------------------------------- restore ---

if [[ ${RESTORE} -eq 1 ]]; then
  [[ -L ${LATEST_LINK} ]] || die "No backup found in ${BACKUP_ROOT}."
  BDIR="$(readlink -f "${LATEST_LINK}")"
  log "Restoring from ${BDIR}"

  for f in motd legal issue issue.net; do
    if [[ -f "${BDIR}/etc-${f}" ]]; then
      cp -a "${BDIR}/etc-${f}" "/etc/${f}"
      log "restored /etc/${f}"
    fi
  done

  if [[ -f "${BDIR}/update-motd.d.perms" ]]; then
    while IFS=$'\t' read -r mode path; do
      [[ -e ${path} ]] && chmod "${mode}" "${path}"
    done < "${BDIR}/update-motd.d.perms"
    log "restored /etc/update-motd.d permissions"
  fi

  if [[ -f /etc/apt/apt.conf.d/20apt-esm-hook.conf.disabled ]]; then
    mv /etc/apt/apt.conf.d/20apt-esm-hook.conf.disabled \
       /etc/apt/apt.conf.d/20apt-esm-hook.conf
    log "restored ESM apt hook"
  fi

  systemctl enable --now motd-news.timer >/dev/null 2>&1 || true
  rm -f /run/motd.dynamic
  log "Done. Open a new SSH session to verify."
  exit 0
fi

# ----------------------------------------------------------------- backup ---

STAMP="$(date +%Y%m%d-%H%M%S)"
BDIR="${BACKUP_ROOT}/${STAMP}"
mkdir -p "${BDIR}"
chmod 700 "${BACKUP_ROOT}"

for f in motd legal issue issue.net; do
  [[ -f "/etc/${f}" ]] && cp -a "/etc/${f}" "${BDIR}/etc-${f}"
done

if [[ -d /etc/update-motd.d ]]; then
  : > "${BDIR}/update-motd.d.perms"
  find /etc/update-motd.d -maxdepth 1 -type f -printf '%m\t%p\n' \
    >> "${BDIR}/update-motd.d.perms"
fi

ln -sfn "${BDIR}" "${LATEST_LINK}"
log "Backed up current state to ${BDIR}"

# ------------------------------------------------ disable dynamic scripts ---

if [[ -d /etc/update-motd.d ]]; then
  find /etc/update-motd.d -maxdepth 1 -type f -exec chmod -x {} +
  log "Disabled all scripts in /etc/update-motd.d"
else
  warn "/etc/update-motd.d not present, skipping"
fi

# ------------------------------------------------- clear the static files ---

for f in /etc/motd /etc/legal /etc/issue /etc/issue.net; do
  if [[ -f ${f} ]]; then
    : > "${f}"
    log "Cleared ${f}"
  fi
done

# ------------------------------------------------------ ubuntu pro / news ---

if command -v pro >/dev/null 2>&1; then
  pro config set apt_news=false >/dev/null 2>&1 && log "Disabled apt news" \
    || warn "Could not set apt_news=false"
fi

systemctl disable --now motd-news.timer >/dev/null 2>&1 \
  && log "Disabled motd-news.timer" || true
systemctl mask motd-news.service >/dev/null 2>&1 || true

if [[ -d /var/lib/ubuntu-advantage/messages ]]; then
  rm -f /var/lib/ubuntu-advantage/messages/* 2>/dev/null || true
  log "Cleared cached Ubuntu Pro messages"
fi

ESM_HOOK="/etc/apt/apt.conf.d/20apt-esm-hook.conf"
if [[ -f ${ESM_HOOK} ]]; then
  mv "${ESM_HOOK}" "${ESM_HOOK}.disabled"
  log "Disabled the ESM apt hook (no more nag during apt update)"
fi

if [[ ${PURGE_PRO} -eq 1 ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y ubuntu-pro-client ubuntu-advantage-tools >/dev/null 2>&1 \
    && log "Purged ubuntu-pro-client" \
    || warn "Purge failed or packages not installed"
fi

# ------------------------------------------------------- custom banner ------

if [[ -n ${BRAND} ]]; then
  {
    printf '\n'
    printf '  %s\n' "${BRAND}"
    [[ -n ${SUPPORT} ]] && printf '  Support: %s\n' "${SUPPORT}"
    printf '\n'
  } > /etc/motd
  chmod 644 /etc/motd
  log "Wrote custom banner to /etc/motd"
fi

# ---------------------------------------------------------- quiet login -----

if [[ ${SILENT} -eq 1 ]]; then
  touch /root/.hushlogin
  chmod 644 /root/.hushlogin
  mkdir -p /etc/skel
  touch /etc/skel/.hushlogin
  log "Suppressed last-login line for root and new users"
fi

# ------------------------------------------------------------- refresh ------

rm -f /run/motd.dynamic
log "Cleared the cached dynamic MOTD"

printf '\n'
log "Finished. Open a NEW SSH session to confirm before closing this one."
log "To undo: sudo $(basename "$0") --restore"
printf '\n'
