#!/usr/bin/env bash
#
# TapVPS server identity cleanup
#
# Strips the hosting provider ASCII art, Ubuntu Pro / ESM nags, legal
# notice and update counters, then installs the TapVPS banner in their
# place.
#
# Usage:
#   sudo bash script.sh                 clean and install the TapVPS banner
#   sudo bash script.sh --no-banner     clean only, leave the login blank
#   sudo bash script.sh --quiet-login   also hide the "Last login" line
#   sudo bash script.sh --purge-pro     also remove the ubuntu-pro client
#   sudo bash script.sh --restore       undo from the last backup
#
# Safe to run more than once.

set -euo pipefail

BACKUP_ROOT="/root/.motd-backups"
LATEST_LINK="${BACKUP_ROOT}/latest"
BANNER_FILE="/etc/update-motd.d/00-tapvps"
SUPPORT_EMAIL="support@tapvps.com"

INSTALL_BANNER=1
QUIET_LOGIN=0
PURGE_PRO=0
RESTORE=0
VERBOSE=0

# ---------------------------------------------------------------- helpers ---

# Silent by default. This runs on customer servers, so it should not
# narrate what it is doing. Pass --verbose when testing.
log()  { [[ ${VERBOSE} -eq 1 ]] && printf '  \033[32m*\033[0m %s\n' "$*"; return 0; }
warn() { [[ ${VERBOSE} -eq 1 ]] && printf '  \033[33m!\033[0m %s\n' "$*"; return 0; }
die()  { [[ ${VERBOSE} -eq 1 ]] && printf '  \033[31mx\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'USAGE'
TapVPS server identity cleanup

Runs silently. Prints nothing unless --verbose is passed.

  sudo bash script.sh                 clean and install the TapVPS banner
  sudo bash script.sh --no-banner     clean only, leave the login blank
  sudo bash script.sh --quiet-login   also hide the "Last login" line
  sudo bash script.sh --purge-pro     also remove the ubuntu-pro client
  sudo bash script.sh --restore       undo from the last backup
  sudo bash script.sh --verbose       show progress and a login preview
USAGE
exit 0
}

# ------------------------------------------------------------ arg parsing ---

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-banner)   INSTALL_BANNER=0; shift ;;
    --quiet-login) QUIET_LOGIN=1; shift ;;
    --purge-pro)   PURGE_PRO=1; shift ;;
    --restore)     RESTORE=1; shift ;;
    --verbose|-v)  VERBOSE=1; shift ;;
    --support)     SUPPORT_EMAIL="${2:-}"; shift 2 ;;
    -h|--help)     usage ;;
    *)             die "Unknown option: $1  (try --help)" ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "Run this as root or with sudo."

# ---------------------------------------------------------------- restore ---

if [[ ${RESTORE} -eq 1 ]]; then
  [[ -L ${LATEST_LINK} ]] || die "No backup found in ${BACKUP_ROOT}."
  BDIR="$(readlink -f "${LATEST_LINK}")"
  log "Restoring from ${BDIR}"

  for f in motd legal issue issue.net; do
    [[ -f "${BDIR}/etc-${f}" ]] && cp -a "${BDIR}/etc-${f}" "/etc/${f}" \
      && log "restored /etc/${f}"
  done

  if [[ -f "${BDIR}/update-motd.d.perms" ]]; then
    while IFS=$'\t' read -r mode path; do
      [[ -e ${path} ]] && chmod "${mode}" "${path}"
    done < "${BDIR}/update-motd.d.perms"
    log "restored /etc/update-motd.d permissions"
  fi

  rm -f "${BANNER_FILE}"
  rm -f /root/.hushlogin /etc/skel/.hushlogin

  if [[ -f /etc/apt/apt.conf.d/20apt-esm-hook.conf.disabled ]]; then
    mv /etc/apt/apt.conf.d/20apt-esm-hook.conf.disabled \
       /etc/apt/apt.conf.d/20apt-esm-hook.conf
    log "restored ESM apt hook"
  fi

  systemctl unmask motd-news.service >/dev/null 2>&1 || true
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

# ------------------------------------------------ disable existing output ---

if [[ -d /etc/update-motd.d ]]; then
  find /etc/update-motd.d -maxdepth 1 -type f -exec chmod -x {} +
  log "Disabled all existing scripts in /etc/update-motd.d"
fi

# Newer Ubuntu also reads drop-in fragments from these directories.
for d in /etc/motd.d /run/motd.d /usr/lib/motd.d; do
  if [[ -d ${d} ]]; then
    find "${d}" -maxdepth 1 -type f -delete 2>/dev/null || true
    find "${d}" -maxdepth 1 -type l -delete 2>/dev/null || true
    log "Cleared ${d}"
  fi
done

for f in /etc/motd /etc/legal /etc/issue /etc/issue.net; do
  [[ -f ${f} ]] && : > "${f}" && log "Cleared ${f}"
done

# Left over from a previous run of the old script. It suppresses the whole
# MOTD, banner included, so it has to go before we install ours.
if [[ -e /root/.hushlogin || -e /etc/skel/.hushlogin ]]; then
  rm -f /root/.hushlogin /etc/skel/.hushlogin
  log "Removed stale .hushlogin (it was blocking the banner)"
fi

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
  log "Disabled the ESM apt hook"
fi

if [[ ${PURGE_PRO} -eq 1 ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y ubuntu-pro-client ubuntu-advantage-tools >/dev/null 2>&1 \
    && log "Purged ubuntu-pro-client" \
    || warn "Purge failed or packages not installed"
fi

# ------------------------------------------------------ install the banner --

if [[ ${INSTALL_BANNER} -eq 1 ]]; then
  mkdir -p /etc/update-motd.d

  cat > "${BANNER_FILE}" <<EOF
#!/bin/sh
cat <<'BANNER'

  ████████╗ █████╗ ██████╗ ██╗   ██╗██████╗ ███████╗
  ╚══██╔══╝██╔══██╗██╔══██╗██║   ██║██╔══██╗██╔════╝
     ██║   ███████║██████╔╝╚██╗ ██╔╝██████╔╝███████╗
     ██║   ██╔══██║██╔═══╝  ╚████╔╝ ██╔═══╝ ╚════██║
     ██║   ██║  ██║██║       ╚██╔╝  ██║     ███████║
     ╚═╝   ╚═╝  ╚═╝╚═╝        ╚═╝   ╚═╝     ╚══════╝

  Managed hosting by TapVPS
  Support: ${SUPPORT_EMAIL}

BANNER
EOF

  chmod +x "${BANNER_FILE}"
  log "Installed banner at ${BANNER_FILE}"

  # Fallback copy. If pam_motd on this image only prints /etc/motd and
  # never runs update-motd.d, this is what gets shown instead.
  if ! grep -q 'motd=/run/motd.dynamic' /etc/pam.d/sshd 2>/dev/null; then
    "${BANNER_FILE}" > /etc/motd
    chmod 644 /etc/motd
    log "pam_motd has no dynamic line, wrote banner to /etc/motd instead"
  fi
fi

# ---------------------------------------------------------- quiet login -----

if [[ ${QUIET_LOGIN} -eq 1 ]]; then
  # Do NOT use .hushlogin here. It hides the banner too.
  sed -i 's/^#\?PrintLastLog.*/PrintLastLog no/' /etc/ssh/sshd_config
  grep -q '^PrintLastLog' /etc/ssh/sshd_config || echo 'PrintLastLog no' >> /etc/ssh/sshd_config
  systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
  log "Hid the last-login line via sshd"
fi

# ------------------------------------------------------------- refresh ------

rm -f /run/motd.dynamic
if command -v run-parts >/dev/null 2>&1 && [[ -d /etc/update-motd.d ]]; then
  run-parts /etc/update-motd.d > /run/motd.dynamic 2>/dev/null || true
fi

# -------------------------------------------------------------- self test ---

if [[ ${VERBOSE} -eq 1 ]]; then
  printf '\n'
  log "This is what the next login will print:"
  printf '\033[36m'
  printf -- '----------------------------------------------------------\n'
  [[ -s /run/motd.dynamic ]] && cat /run/motd.dynamic
  [[ -s /etc/motd ]] && cat /etc/motd
  printf -- '----------------------------------------------------------\n'
  printf '\033[0m\n'

  if [[ ${INSTALL_BANNER} -eq 1 && ! -s /run/motd.dynamic && ! -s /etc/motd ]]; then
    warn "Both sources are empty. Check: grep motd /etc/pam.d/sshd"
  fi

  log "Open a NEW SSH session to confirm before closing this one."
  log "To undo: sudo bash script.sh --restore"
  printf '\n'
fi

exit 0
