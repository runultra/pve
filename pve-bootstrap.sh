#!/usr/bin/env bash
# =============================================================================
# pve-bootstrap.sh : post-install setup for Proxmox VE lab hosts
#
#   1. APT repos       disable enterprise, enable no-subscription (PVE + Ceph)
#   2. Sub nag         remove the "No valid subscription" popup (survives updates)
#   3. Packages        dist-upgrade + tools (ethtool, iperf3, lldpd, nfs-common...)
#   4. Network         vmbr0 (mgmt) + vmbr1 (high-speed) on a bond at MTU 9000,
#                      auto-detected NICs, dead-man rollback. Bond mode is
#                      recommended from LLDP: 802.3ad only when the switch
#                      ports advertise LAG membership, else active-backup.
#                      LACP is verified after apply (partner + aggregator).
#   3b. vastnfs        optional VAST NFS client: DKMS build, kernel guard (never
#                      boots a kernel without it), boot-time sync of per-node
#                      mount options into /etc/nfsmount.conf. Reboot required.
#   5. Cluster         join an existing cluster or create one; corosync
#                      link0 = vmbr0, link1 = vmbr1, with full preflight checks.
#                      The choice is asked FIRST: for a join, the script logs in
#                      to the peer up front, runs every check that doesn't need
#                      this node's network, and builds vmbr1 on the cluster's
#                      own high-speed subnet/MTU. The join itself runs last.
#   6. HA services     optionally disable on standalone hosts
#   7. Storage         optionally add NFS storage. "vast" layout: N image
#                      datastores + iso + dump, each on its own VAST DNS
#                      prefix (<id>.<vip-pool-fqdn>) so mounts spread across
#                      VIPs; nconnect sized from the vmbr1 link speed.
#
# Usage:
#   bash -c "$(curl -fsSL <raw-url>/pve-bootstrap.sh)"
#   ./pve-bootstrap.sh [--dry-run] [--network-only] [--cluster-only] [--vastnfs]
#                      [--skip-repos] [--skip-upgrade] [--skip-network]
#                      [--skip-cluster] [--skip-storage] [--skip-vastnfs] [-y]
#
#   --dry-run       Show the planned network diff and run every cluster-join
#                   check against the peer. Changes nothing.
#   --network-only  Run only the network stage.
#   --cluster-only  Run only the cluster stage.
#   --vastnfs       Retrofit an existing node: install vastnfs, re-check the
#                   storage network (HS_MODE=split to use both NICs), then reboot (or remount if it is
#                   already loaded). Skips repos, upgrade, cluster, storage.
#                   Migrate VMs off first; it warns if any are running.
#   -y              Accept defaults for every prompt (non-interactive).
#
# Environment overrides (handy for -y / Ansible):
#   HS_NICS="nic5 nic6"   high-speed NICs for vmbr1 (default: auto-detect)
#   HS_BOND=bond0         bond name
#   HS_MODE=auto          vmbr1 mode (auto | active-backup | 802.3ad | split);
#                         auto = 802.3ad if LLDP shows the switch ports are
#                         LAG members, else active-backup. split is opt-in
#                         only: vmbr1 gets one NIC (no failover for VM
#                         traffic on vmbr1), the 2nd NIC is host-only storage
#                         via vastnfs localports. Use it only when no VMs
#                         attach to vmbr1.
#   HS_NIC2_ADDR=         split mode: address/CIDR for the 2nd storage NIC
#                         (default: vmbr1 address with 3rd octet + 1)
#   VASTNFS=yes|no        install the VAST NFS client (default: ask)
#   VAST_VIP_RANGE=172.200.201.145-172.200.201.150   VIP pool range (remoteports)
#   HS_MTU=9000           MTU for NICs, bond, vmbr1
#   HS_NET_PREFIX=172.200.5  vmbr1 default = <prefix>.<vmbr0 last octet>
#   HS_CIDR=16
#   VMBR1_ADDR=172.200.5.175/16   explicit vmbr1 address
#   VMBR0_ADDR / VMBR0_GW          change mgmt IP (console only!)
#   HS_TEST_IP=172.200.209.1       jumbo-ping target ("" to skip)
#   ROLLBACK_SECS=180              dead-man window after applying network
#   CLUSTER_ACTION=skip|join|create
#   CLUSTER_PEER=10.144.12.121     existing node to join through
#   CLUSTER_PASSWORD=...           root@pam password of the peer (else prompted)
#   CLUSTER_NAME=poc-var           name when creating
#   CLUSTER_LINK0 / CLUSTER_LINK1  corosync addresses (default vmbr0 / vmbr1 IPs)
#   STORAGE_LAYOUT=vast|single|skip
#   VAST_POOL_FQDN=proxmox.selab-var201.selab.vastdata.com   VIP pool FQDN
#   VAST_EXPORT_BASE=/proxmox/datastores/<cluster>           parent of the views
#   VAST_DS_COUNT=4       image datastores (views <base>/ds1..dsN must exist)
#   VAST_ID_PREFIX=vast   storage IDs: vast-ds1.., vast-iso, vast-dump
#   NFS_NCONNECT=         override nconnect (default: 12 at >=100G, else 4;
#                         12 divides evenly over 6 VIPs x 1 or 2 NICs)
# =============================================================================
set -Eeuo pipefail
trap 'printf "\n[xx] unexpected failure at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

VERSION="1.7.1"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/pve-bootstrap-backup/${TS}"
IFACES="/etc/network/interfaces"
ROLLBACK_UNIT="pveb-net-rollback"

HS_NICS="${HS_NICS:-}"
HS_BOND="${HS_BOND:-bond0}"
HS_MODE="${HS_MODE:-auto}"
HS_MTU="${HS_MTU:-9000}"
HS_NET_PREFIX="${HS_NET_PREFIX:-172.200.5}"
HS_CIDR="${HS_CIDR:-16}"
HS_MIN_SPEED="${HS_MIN_SPEED:-10000}"
HS_TEST_IP="${HS_TEST_IP-172.200.209.1}"
VMBR1_ADDR="${VMBR1_ADDR:-}"
VMBR0_ADDR="${VMBR0_ADDR:-}"
VMBR0_GW="${VMBR0_GW:-}"
ROLLBACK_SECS="${ROLLBACK_SECS:-180}"
CLUSTER_ACTION="${CLUSTER_ACTION:-}"
CLUSTER_PEER="${CLUSTER_PEER:-}"
CLUSTER_PASSWORD="${CLUSTER_PASSWORD:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"
CLUSTER_LINK0="${CLUSTER_LINK0:-}"
CLUSTER_LINK1="${CLUSTER_LINK1:-}"
STORAGE_LAYOUT="${STORAGE_LAYOUT:-}"
VAST_POOL_FQDN="${VAST_POOL_FQDN:-}"
VAST_EXPORT_BASE="${VAST_EXPORT_BASE:-}"
VAST_DS_COUNT="${VAST_DS_COUNT:-4}"
VAST_ID_PREFIX="${VAST_ID_PREFIX:-vast}"
NFS_NCONNECT="${NFS_NCONNECT:-}"
HS_NIC2_ADDR="${HS_NIC2_ADDR:-}"
VASTNFS="${VASTNFS:-}"
VAST_VIP_RANGE="${VAST_VIP_RANGE:-}"
WANT_VASTNFS=""      # 1/0 once decided (preflight detects an existing install)
NEED_REBOOT=0
VASTNFS_HELPER="/usr/local/sbin/vastnfs-pve.sh"
VAST_CLUSTER_CONF="/etc/pve/vast-multipath.conf"
SPLIT_SYSCTL="/etc/sysctl.d/90-vast-multihome.conf"

ASSUME_YES=0
DRY_RUN=0
RETROFIT=0
DO_REPOS=1 DO_NAG=1 DO_UPGRADE=1 DO_HA=1 DO_NETWORK=1 DO_CLUSTER=1 DO_STORAGE=1 DO_VASTNFS=1

# -----------------------------------------------------------------------------
# UI: colors, symbols, stage headers, spinner, summary
#   Fancy output only on a UTF-8 terminal; plain ASCII when piped/logged.
# -----------------------------------------------------------------------------
IS_TTY=0; [[ -t 1 ]] && IS_TTY=1
UTF=0; [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" =~ [Uu][Tt][Ff]-?8 ]] && UTF=1
if (( IS_TTY )); then
  C_R=$'\e[38;5;203m' C_G=$'\e[38;5;114m' C_Y=$'\e[38;5;221m' C_B=$'\e[38;5;81m'
  C_M=$'\e[38;5;208m' C_D=$'\e[38;5;245m' C_W=$'\e[1;97m' C_0=$'\e[0m' C_BOLD=$'\e[1m'
else
  C_R='' C_G='' C_Y='' C_B='' C_M='' C_D='' C_W='' C_0='' C_BOLD=''
fi
if (( UTF && IS_TTY )); then
  S_OK='✔' S_WARN='▲' S_ERR='✖' S_INFO='›' S_Q='?' S_SKIP='–' S_RULE='━' S_BAR='┃' S_TOP='┏' S_BOT='┗'
  SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
else
  S_OK='ok' S_WARN='!!' S_ERR='xx' S_INFO='..' S_Q='?' S_SKIP='--' S_RULE='=' S_BAR='|' S_TOP='+' S_BOT='+'
  SPIN=('-' '\' '|' '/')
fi
COLS="$(tput cols 2>/dev/null || echo 80)"; [[ $COLS =~ ^[0-9]+$ ]] || COLS=80; (( COLS > 100 )) && COLS=100

info()  { printf '  %s%s%s %s\n' "$C_B" "$S_INFO" "$C_0" "$*"; }
ok()    { printf '  %s%s%s %s\n' "$C_G" "$S_OK" "$C_0" "$*"; }
warn()  { printf '  %s%s%s %s\n' "$C_Y" "$S_WARN" "$C_0" "$*" >&2; }
err()   { printf '  %s%s%s %s\n' "$C_R" "$S_ERR" "$C_0" "$*" >&2; }
die()   { err "$*"; exit 1; }
hdr()   { printf '\n  %s%s%s %s%s%s\n' "$C_M" "$S_INFO$S_INFO" "$C_0" "$C_BOLD" "$*" "$C_0"; }
rule()  { local n="$1" out=""; while (( n-- > 0 )); do out+="$S_RULE"; done; printf '%s' "$out"; }

STAGE_N=0 STAGE_TOTAL=0
stage() { # numbered, full-width stage header
  STAGE_N=$((STAGE_N + 1))
  local label=" [${STAGE_N}/${STAGE_TOTAL}] $* "
  local fill=$(( COLS - ${#label} - 6 )); (( fill < 3 )) && fill=3
  printf '\n%s%s%s%s%s%s%s\n' "$C_M" "$(rule 3)" "$C_W" "$label" "$C_M" "$(rule "$fill")" "$C_0"
}

LOG="/root/pve-bootstrap.log"
spin() { # spin "label" cmd args...  : run quietly with a spinner + timer, log output
  local label="$1"; shift
  local t0=$SECONDS rc=0
  printf '\n===== %s: %s\n' "$(date '+%F %T')" "$label" >>"$LOG"
  if (( ! IS_TTY )); then
    info "$label"
    "$@" >>"$LOG" 2>&1 || rc=$?
  else
    "$@" >>"$LOG" 2>&1 &
    local pid=$! i=0
    printf '\e[?25l'
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s%s%s %s %s%ds%s ' "$C_B" "${SPIN[i++ % ${#SPIN[@]}]}" "$C_0" "$label" "$C_D" $((SECONDS - t0)) "$C_0"
      sleep 0.12
    done
    wait "$pid" || rc=$?
    printf '\e[?25h'
    printf '\r\e[K'
  fi
  if (( rc == 0 )); then
    ok "$label ${C_D}($(dur $((SECONDS - t0))))${C_0}"
  else
    err "$label failed (exit $rc). Last lines of $LOG:"
    tail -n 12 "$LOG" | sed 's/^/      /' >&2
  fi
  return $rc
}

dur() { local s="$1"; (( s >= 60 )) && printf '%dm%02ds' $((s / 60)) $((s % 60)) || printf '%ds' "$s"; }

SUMMARY=()
summ() { # summ ok|warn|skip|err "Stage" "detail"
  local sym col
  case "$1" in
    ok)   sym="$S_OK"   col="$C_G" ;;
    warn) sym="$S_WARN" col="$C_Y" ;;
    err)  sym="$S_ERR"  col="$C_R" ;;
    *)    sym="$S_SKIP" col="$C_D" ;;
  esac
  SUMMARY+=("$(printf '%s%s%s %s%-9s%s %s' "$col" "$sym" "$C_0" "$C_BOLD" "$2" "$C_0" "$3")")
}

print_summary() {
  local line title=" Summary "
  printf '\n  %s%s%s%s%s%s%s\n' "$C_M" "$S_TOP$(rule 2)" "$C_W" "$title" "$C_M" "$(rule $((COLS - ${#title} - 8)))" "$C_0"
  for line in "${SUMMARY[@]}"; do printf '  %s%s%s %s\n' "$C_M" "$S_BAR" "$C_0" "$line"; done
  printf '  %s%s%s %s%s%s\n' "$C_M" "$S_BOT$(rule 2)" "$C_0" "$C_D" "$1" "$C_0"
}

banner() {
  local mode="interactive"
  (( ASSUME_YES )) && mode="unattended (-y)"
  (( DRY_RUN )) && mode="${C_Y}DRY RUN${C_0}${C_D}: nothing will be changed"
  local -a side=(
    "${C_W}bootstrap${C_0} ${C_D}v${VERSION}${C_0}"
    "${C_D}host   ${C_0} $(hostname)"
    "${C_D}pve    ${C_0} $(pveversion 2>/dev/null | grep -oE 'pve-manager/[0-9.]+' | cut -d/ -f2 || echo '?')"
    "${C_D}kernel ${C_0} $(uname -r)"
    "${C_D}mode   ${C_0} ${mode}"
    "${C_D}log    ${C_0} ${LOG}"
  )
  echo
  if (( UTF && IS_TTY )); then
    local -a art=(
      '██████╗ ██╗   ██╗███████╗'
      '██╔══██╗██║   ██║██╔════╝'
      '██████╔╝██║   ██║█████╗  '
      '██╔═══╝ ╚██╗ ██╔╝██╔══╝  '
      '██║      ╚████╔╝ ███████╗'
      '╚═╝       ╚═══╝  ╚══════╝'
    )
    local -a grad=(202 202 208 208 214 214) i
    for i in 0 1 2 3 4 5; do
      printf '  \e[38;5;%sm%s%s    %s\n' "${grad[i]}" "${art[i]}" "$C_0" "${side[i]}"
    done
  else
    printf '  %spve-bootstrap %s%s\n' "$C_BOLD" "$VERSION" "$C_0"
    for i in "${side[@]:1}"; do printf '  %s\n' "$i"; done
  fi
}

colordiff() { # colorize unified diff on stdin
  local l
  while IFS= read -r l; do
    case "$l" in
      ---*|+++*) printf '    %s%s%s\n' "$C_D" "$l" "$C_0" ;;
      @@*)       printf '    %s%s%s\n' "$C_B" "$l" "$C_0" ;;
      +*)        printf '    %s%s%s\n' "$C_G" "$l" "$C_0" ;;
      -*)        printf '    %s%s%s\n' "$C_R" "$l" "$C_0" ;;
      *)         printf '    %s%s%s\n' "$C_D" "$l" "$C_0" ;;
    esac
  done
}

# All prompts read from /dev/tty so this works under `bash -c "$(curl ...)"`.
# drop keystrokes typed ahead (e.g. while a check was running) so they can't
# leak into the next answer
flush_tty() { local _junk; while read -r -s -t 0.05 -n 256 _junk </dev/tty 2>/dev/null; do :; done; return 0; }
ask() { # ask "Prompt" "default" -> echoes answer
  local prompt="$1" def="${2-}" ans
  if (( ASSUME_YES )); then printf '%s\n' "$def"; return; fi
  flush_tty
  read -r -p "  ${C_B}${S_Q}${C_0} ${prompt} ${C_D}[${def}]${C_0} " ans </dev/tty || true
  printf '%s\n' "${ans:-$def}"
}
confirm() { # confirm "Prompt" y|n
  local prompt="$1" def="${2:-n}" ans hint
  [[ $def == y ]] && hint="Y/n" || hint="y/N"
  if (( ASSUME_YES )); then [[ $def == y ]]; return; fi
  flush_tty
  read -r -p "  ${C_B}${S_Q}${C_0} ${prompt} ${C_D}(${hint})${C_0} " ans </dev/tty || true
  ans="${ans:-$def}"
  [[ ${ans,,} == y || ${ans,,} == yes ]]
}

backup() { # backup <file> : copy into BACKUP_DIR preserving path
  local f="$1"
  [[ -e $f ]] || return 0
  mkdir -p "${BACKUP_DIR}$(dirname "$f")"
  cp -a "$f" "${BACKUP_DIR}${f}"
}

valid_cidr() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; }
valid_ip()   { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# -----------------------------------------------------------------------------
# preflight
# -----------------------------------------------------------------------------
PVE_MAJOR=0 PVE_MINOR=0 CODENAME="" CLUSTERED=0
preflight() {
  [[ $EUID -eq 0 ]] || die "Run as root."
  command -v pveversion >/dev/null || die "This is not a Proxmox VE host."
  local v
  v="$(pveversion | grep -oE 'pve-manager/[0-9]+\.[0-9]+' | cut -d/ -f2)"
  PVE_MAJOR="${v%%.*}" PVE_MINOR="${v##*.}"
  # shellcheck disable=SC1091
  CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  [[ -f /etc/pve/corosync.conf ]] && CLUSTERED=1
  if dkms status -m vastnfs 2>/dev/null | gq ': installed'; then WANT_VASTNFS=1; fi
  (( PVE_MAJOR >= 8 )) || die "PVE ${v} not supported (need 8.x or 9.x)."
  (( CLUSTERED )) && info "Debian ${CODENAME}, already in a cluster" || info "Debian ${CODENAME}, standalone"
  if [[ -n ${SSH_CONNECTION:-} && -z ${TMUX:-}${STY:-} ]]; then
    warn "Running over SSH without tmux/screen. The network stage has an auto-rollback,"
    warn "but tmux is safer: apt install tmux && tmux new -s bootstrap"
  fi
}

# -----------------------------------------------------------------------------
# 1. repositories
# -----------------------------------------------------------------------------
disable_enterprise_repos() {
  local f
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*.sources; do
    grep -q 'enterprise.proxmox.com' "$f" || continue
    backup "$f"
    if grep -q '^Enabled:' "$f"; then
      sed -i 's/^Enabled:.*/Enabled: false/' "$f"
    else
      sed -i '0,/^Types:/s//Enabled: false\nTypes:/' "$f"
    fi
    ok "Disabled enterprise repo: $(basename "$f")"
  done
  for f in /etc/apt/sources.list.d/*.list; do
    grep -qE '^[^#]*enterprise.proxmox.com' "$f" || continue
    backup "$f"
    sed -i -E 's|^([^#]*enterprise\.proxmox\.com)|# \1|' "$f"
    ok "Disabled enterprise repo: $(basename "$f")"
  done
  shopt -u nullglob
}

has_repo_component() { # has_repo_component <component> : enabled anywhere?
  local comp="$1" f
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*.sources; do
    # skip stanzas explicitly disabled; good enough for single-stanza files
    grep -q '^Enabled: *false' "$f" && continue
    grep -qE "^Components:.*\b${comp}\b" "$f" && { shopt -u nullglob; return 0; }
  done
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f $f ]] && grep -qE "^[^#]*\b${comp}\b" "$f" && { shopt -u nullglob; return 0; }
  done
  shopt -u nullglob
  return 1
}

ceph_release() { # derive ceph-<name> from existing repo files, else from PVE minor
  local r
  r="$(grep -rhoE 'debian/ceph-[a-z]+' /etc/apt/sources.list.d/ 2>/dev/null | head -1 | cut -d/ -f2 || true)"
  if [[ -z $r ]]; then
    if (( PVE_MAJOR >= 9 )); then
      (( PVE_MINOR >= 2 )) && r="ceph-tentacle" || r="ceph-squid"
    else
      r="ceph-reef"
    fi
  fi
  printf '%s\n' "$r"
}

setup_repos() {
  stage "APT repositories"
  disable_enterprise_repos

  if has_repo_component pve-no-subscription; then
    ok "pve-no-subscription already enabled"
  elif (( PVE_MAJOR >= 9 )); then
    backup /etc/apt/sources.list.d/proxmox.sources
    cat >/etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${CODENAME}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    ok "Added pve-no-subscription (deb822)"
  else
    echo "deb http://download.proxmox.com/debian/pve ${CODENAME} pve-no-subscription" \
      >/etc/apt/sources.list.d/pve-no-subscription.list
    ok "Added pve-no-subscription"
  fi

  local cr; cr="$(ceph_release)"
  if grep -rqE "download.proxmox.com/debian/ceph-[a-z]+" /etc/apt/sources.list.d/ 2>/dev/null \
     && has_repo_component no-subscription; then
    ok "Ceph no-subscription already enabled"
  elif (( PVE_MAJOR >= 9 )); then
    backup /etc/apt/sources.list.d/ceph.sources
    cat >/etc/apt/sources.list.d/ceph.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/${cr}
Suites: ${CODENAME}
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    ok "Ceph repo set to ${cr} no-subscription (deb822)"
  else
    backup /etc/apt/sources.list.d/ceph.list
    echo "deb http://download.proxmox.com/debian/${cr} ${CODENAME} no-subscription" \
      >/etc/apt/sources.list.d/ceph.list
    ok "Ceph repo set to ${cr} no-subscription"
  fi
  summ ok "Repos" "enterprise off, pve + ${cr} no-subscription on"
}

# -----------------------------------------------------------------------------
# 2. subscription nag
# -----------------------------------------------------------------------------
remove_nag() {
  stage "Subscription nag"
  cat >/usr/local/bin/pve-remove-nag.sh <<'EOF'
#!/bin/sh
# Installed by pve-bootstrap.sh; re-applied after every dpkg run.
WEB_JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
if [ -s "$WEB_JS" ] && ! grep -q NoMoreNagging "$WEB_JS"; then
  sed -i -e "/data\.status/ s/!//" -e "/data\.status/ s/active/NoMoreNagging/" "$WEB_JS"
fi
EOF
  chmod 755 /usr/local/bin/pve-remove-nag.sh
  echo 'DPkg::Post-Invoke { "/usr/local/bin/pve-remove-nag.sh"; };' >/etc/apt/apt.conf.d/no-nag-script
  /usr/local/bin/pve-remove-nag.sh
  ok "Nag removed (hard-refresh the browser). Hook re-applies it after updates."
  summ ok "Nag" "subscription popup removed"
}

# -----------------------------------------------------------------------------
# 3. packages
# -----------------------------------------------------------------------------
# Other things grab the dpkg lock too: pve-daily-update at boot, or tools that
# SSH in right after a cluster join to install their own packages.
APT_WAIT="-o DPkg::Lock::Timeout=600"

apt_busy() { pgrep -a -x 'apt|apt-get|dpkg|unattended-upgr' 2>/dev/null | head -1 || true; }

wait_for_apt() { # wait up to $1 seconds for any apt/dpkg to finish
  local max="${1:-600}" t0=$SECONDS who i=0
  who="$(apt_busy)"
  [[ -z $who ]] && return 0
  warn "Another package job is running: ${who#* }"
  while [[ -n "$(apt_busy)" ]] && (( SECONDS - t0 < max )); do
    if (( IS_TTY )); then
      printf '\r  %s%s%s waiting for it to finish %s%ds%s ' "$C_B" "${SPIN[i++ % ${#SPIN[@]}]}" "$C_0" "$C_D" $((SECONDS - t0)) "$C_0"
    fi
    sleep 1
  done
  (( IS_TTY )) && printf '\r\e[K'
  if [[ -n "$(apt_busy)" ]]; then warn "Still running after $(dur $max)."; return 1; fi
  ok "Package job finished ($(dur $((SECONDS - t0))))"
}

safe_reboot() {
  wait_for_apt 900 || { warn "Not rebooting while packages are being installed. Reboot by hand when it finishes."; return 0; }
  info "Rebooting"
  systemctl reboot || warn "systemd refused the reboot (see 'systemd-inhibit --list'); reboot by hand when clear."
}

TOOLS=(ethtool iperf3 lldpd nfs-common jq htop tmux curl vim-nox)
KERNEL_BEFORE=""
upgrade_and_tools() {
  stage "Packages"
  KERNEL_BEFORE="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 || true)"
  spin "Refreshing package lists" apt-get $APT_WAIT update -q || die "apt-get update failed (check repos above)."
  local upgr; upgr="$(apt-get -s dist-upgrade 2>/dev/null | grep -c '^Inst ' || true)"
  info "${upgr} package(s) can be upgraded"
  if (( upgr > 0 )) && confirm "Run dist-upgrade now?" y; then
    spin "Upgrading ${upgr} packages" env DEBIAN_FRONTEND=noninteractive apt-get $APT_WAIT -y -q \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade \
      || die "dist-upgrade failed."
    summ ok "Packages" "upgraded ${upgr} packages, now PVE $(pveversion | grep -oE 'pve-manager/[0-9.]+' | cut -d/ -f2)"
  else
    summ skip "Packages" "no upgrade run"
  fi
  spin "Installing tools (${TOOLS[*]})" env DEBIAN_FRONTEND=noninteractive apt-get $APT_WAIT -y -q install "${TOOLS[@]}" \
    || warn "Some tools failed to install."
  systemctl enable -q --now lldpd 2>/dev/null || true
  info "lldpd is on: 'lldpctl' shows which switch port each NIC is plugged into"
}

kernel_changed() {
  [[ -n $KERNEL_BEFORE && "$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)" != "$KERNEL_BEFORE" ]]
}

# -----------------------------------------------------------------------------
# 3b. VAST NFS client (vastnfs)
# -----------------------------------------------------------------------------
# The helper below is also published standalone as vastnfs-pve.sh; it is
# embedded so this script stays a single file you can curl.
write_vastnfs_helper() {
  cat >"$VASTNFS_HELPER" <<'VASTNFS_PVE_EOF'
#!/usr/bin/env bash
# =============================================================================
# vastnfs-pve.sh : the VAST NFS client (vastnfs) on Proxmox VE, safely.
#
#   install   deps (incl. dh-dkms, lsb-release, proxmox-default-headers so every
#             future kernel gets headers), download + DKMS build, initramfs,
#             guard hooks, boot-time sync unit. Reboot afterwards.
#   hooks     (re)install the guard hooks and the sync unit
#   sync      write/refresh the managed block in /etc/nfsmount.conf
#             [--remount] also remount idle VAST storages to pick it up
#   guard     (hook) run by kernel/header post-install and every dpkg run
#   status    versions, DKMS per kernel, pin state, managed mounts
#   remove    purge vastnfs + hooks + managed block, unpin. Reboot afterwards.
#
# Design
#   storage.cfg (cluster-wide) keeps only standard options (vers=3,nconnect=12),
#   so any node, with or without vastnfs, can mount every storage.
#   Each node adds the vastnfs-only options locally through nfsmount.conf, one
#   [ MountPoint "/mnt/pve/<id>" ] section per VAST storage:
#     remoteports=<VIP range>  spread_reads  spread_writes  [localports=vmbr1~<nic2>]
#   The sync unit runs at every boot before PVE activates storage: if vastnfs is
#   loaded it writes the sections; if not (e.g. booted an old/odd kernel) it
#   removes them, so mounts fall back to the stock client instead of failing.
#
#   Cluster settings, set once:  /etc/pve/vast-multipath.conf
#     POOL_FQDN=proxmox.selab-var201.selab.vastdata.com
#     VIP_RANGE=172.200.201.145-172.200.201.150
#     SHARE_TRANSPORT=yes   (default) all VAST storages on a node share one set
#                           of nconnect connections; "no" gives each storage its
#                           own set (more connections, more small-block IOPS)
#   localports is per node and automatic: vmbr1 plus the NIC whose stanza in
#   /etc/network/interfaces carries the "#highspeed2" marker (pve-bootstrap's
#   split mode), when that NIC has an IPv4 address.
#
# Guard: DKMS rebuilds vastnfs for each new kernel. If a new PVE kernel is
# outside the range vastnfs supports, the build fails. The guard then pins boot
# to a kernel that has vastnfs and says so in the motd; once a later kernel
# builds, it releases the pin itself.
# =============================================================================
set -Eeuo pipefail

VASTNFS_VERSION="${VASTNFS_VERSION:-}"      # empty = latest from download.sh
WORK="/root/vastnfs-build"
SELF="/usr/local/sbin/vastnfs-pve.sh"
GUARD_STATE="/var/lib/vastnfs-guard"
GUARD_NAME="zzz-vastnfs-guard"
GUARD_BIN="/usr/local/sbin/vastnfs-guard"
APT_HOOK="/etc/apt/apt.conf.d/99vastnfs-guard"
SYNC_UNIT="/etc/systemd/system/vastnfs-sync.service"
CLUSTER_CONF="${VAST_CLUSTER_CONF:-/etc/pve/vast-multipath.conf}"
STORAGE_CFG="${VAST_STORAGE_CFG:-/etc/pve/storage.cfg}"
IFACES="${VAST_IFACES:-/etc/network/interfaces}"
NFSCONF="${VAST_NFSCONF:-/etc/nfsmount.conf}"
MARK_BEGIN="# >>> vastnfs-pve managed block: do not edit, run 'vastnfs-pve.sh sync' >>>"
MARK_END="# <<< vastnfs-pve managed block <<<"

say()  { printf '  > %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf '  x %s\n' "$*" >&2; exit 1; }
# gq [grep opts] PATTERN : "grep -q" for pipelines. Reads ALL input first, so the
# writer never takes SIGPIPE when grep -q exits on the first match; with
# pipefail that SIGPIPE would turn a successful match into a failure.
gq() { local in; in="$(cat)"; grep -q "$@" <<<"$in"; }

built_for() { # built_for <kver> : vastnfs DKMS module installed for that kernel?
  dkms status -m vastnfs -k "$1" 2>/dev/null | gq ': installed'
}

vastnfs_loaded() { # the running NFS stack is vastnfs (not just installed)
  command -v vastnfs-ctl >/dev/null || return 1
  local out; out="$(vastnfs-ctl status 2>/dev/null || true)"   # no pipe: grep -q + pipefail = SIGPIPE
  grep -q '^version: .*vastdata' <<<"$out"
}

# ---------------------------------------------------------------------------
# guard
# ---------------------------------------------------------------------------
installed_kernels() { # versions with an image in /boot, oldest -> newest
  local f
  # VASTNFS_GUARD_TEST_KERNEL: pretend this kernel is installed (tests only)
  { for f in /boot/vmlinuz-*; do [[ -e $f ]] && printf '%s\n' "${f#/boot/vmlinuz-}"; done
    [[ -n ${VASTNFS_GUARD_TEST_KERNEL:-} ]] && printf '%s\n' "$VASTNFS_GUARD_TEST_KERNEL"
  } | sort -V
}

guard() {
  set +e
  local run k newest fallback="" kernels
  run="$(uname -r)"
  logm() { logger -t vastnfs-guard "$*"; printf 'vastnfs-guard: %s\n' "$*" >&2; }
  mkdir -p "$GUARD_STATE"
  kernels="$(installed_kernels)"
  [[ -n $kernels ]] || exit 0

  for k in $kernels; do   # build for any kernel that has headers but no module yet
    if ! built_for "$k" && [[ -d /lib/modules/$k/build ]]; then
      if dkms autoinstall -k "$k" >/dev/null 2>&1 && built_for "$k"; then
        logm "built vastnfs for ${k}"
      else
        logm "WARNING: vastnfs FAILED to build for ${k}"
      fi
    fi
  done

  newest="$(tail -1 <<<"$kernels")"   # what PVE boots by default
  if built_for "$newest"; then
    if [[ -f $GUARD_STATE/pinned ]]; then
      proxmox-boot-tool kernel unpin >/dev/null 2>&1
      rm -f "$GUARD_STATE/pinned" /etc/motd.d/vastnfs-guard
      logm "vastnfs present for default kernel ${newest}; released guard boot pin"
    fi
    exit 0
  fi

  if built_for "$run"; then fallback="$run"
  else
    for k in $(tac <<<"$kernels"); do built_for "$k" && { fallback="$k"; break; }; done
  fi
  [[ -n $fallback ]] || { logm "no installed kernel has vastnfs; not pinning"; exit 0; }
  if [[ "$(cat "$GUARD_STATE/pinned" 2>/dev/null)" != "${newest}>${fallback}" ]]; then
    proxmox-boot-tool kernel pin "$fallback" >/dev/null 2>&1
    echo "${newest}>${fallback}" >"$GUARD_STATE/pinned"
    local why="no headers yet"; [[ -d /lib/modules/$newest/build ]] && why="build failed"
    logm "default kernel ${newest} has no vastnfs (${why}); boot pinned to ${fallback}"
    cat >/etc/motd.d/vastnfs-guard 2>/dev/null <<EOF || true

  !! vastnfs missing for kernel ${newest} (${why}); boot is pinned to ${fallback}.
  !! Check: vastnfs-pve.sh status   (clears itself once vastnfs builds)

EOF
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# sync: managed nfsmount.conf block (pure helpers are unit-tested)
# ---------------------------------------------------------------------------
read_cluster_conf() { # sets POOL_FQDN VIP_RANGE SHARE_TRANSPORT from the cluster file
  POOL_FQDN="" VIP_RANGE="" SHARE_TRANSPORT=yes
  [[ -r $CLUSTER_CONF ]] || return 1
  POOL_FQDN="$(awk -F= '$1=="POOL_FQDN"{print $2}' "$CLUSTER_CONF" | tr -d '"' | tail -1)"
  VIP_RANGE="$(awk -F= '$1=="VIP_RANGE"{print $2}' "$CLUSTER_CONF" | tr -d '"' | tail -1)"
  local st; st="$(awk -F= '$1=="SHARE_TRANSPORT"{print $2}' "$CLUSTER_CONF" | tr -d '"' | tail -1)"
  [[ ${st,,} == no || ${st,,} == false || $st == 0 ]] && SHARE_TRANSPORT=no
  [[ -n $POOL_FQDN && -n $VIP_RANGE ]]
}

# vast_storage_ids <pool> : nfs storages whose server is the pool or <prefix>.<pool>
vast_storage_ids() {
  awk -v pool="$1" '
    /^[a-z0-9]+:[[:space:]]/ { t = $1; id = $2; next }
    t == "nfs:" && $1 == "server" {
      s = $2; n = length(pool)
      if (s == pool || (length(s) > n && substr(s, length(s) - n) == "." pool)) print id
    }' "$STORAGE_CFG"
}

# storage_nconnect <id> : nconnect from the storage's options in storage.cfg ("" if none)
storage_nconnect() {
  awk -v id="$1" '
    /^[a-z0-9]+:[[:space:]]/ { cur = $2; next }
    cur == id && $1 == "options" { if (match($2, /nconnect=[0-9]+/)) print substr($2, RSTART + 9, RLENGTH - 9) }' "$STORAGE_CFG"
}

# mount_current <mount opts> <want_vast 0|1> <localports ""|x> <nconnect ""|n> : 0 if no remount needed
mount_current() {
  local o="$1" wv="$2" lp="$3" nc="$4"
  if (( wv )); then
    [[ $o == *remoteports=* && $o == *spread_reads* ]] || return 1
    if [[ -n $lp ]]; then [[ $o == *localports=* ]] || return 1; else [[ $o != *localports=* ]] || return 1; fi
  else
    [[ $o != *remoteports=* && $o != *localports=* ]] || return 1
  fi
  [[ -z $nc || ,$o, == *,nconnect=${nc},* ]]
}

# second_storage_nic : NIC stanza carrying the #highspeed2 marker, if any
second_storage_nic() {
  awk '/^[[:space:]]*iface[[:space:]]/{n=$2} /^#highspeed2/{print n; exit}' "$IFACES" 2>/dev/null
}

# render_block <vip_range> <localports|""> <id...> : the managed block text
#   honours SHARE_TRANSPORT=no (adds nosharetransport per storage)
render_block() {
  local range="$1" lp="$2"; shift 2
  local id
  printf '%s\n' "$MARK_BEGIN"
  for id in "$@"; do
    printf '[ MountPoint "/mnt/pve/%s" ]\n' "$id"
    printf 'remoteports=%s\nspread_reads=True\nspread_writes=True\n' "$range"
    [[ -n $lp ]] && printf 'localports=%s\n' "$lp"
    [[ ${SHARE_TRANSPORT:-yes} == no ]] && printf 'nosharetransport=True\n'
  done
  printf '%s\n' "$MARK_END"
}

strip_block() { # file without the managed block (stdout)
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{skip=1; next} $0==e{skip=0; next} !skip' "$1"
}

cmd_sync() {
  local remount=0; [[ ${1:-} == --remount ]] && remount=1
  local want="" ids=() lp="" nic2
  [[ -f $NFSCONF ]] || touch "$NFSCONF"
  if vastnfs_loaded && read_cluster_conf; then
    mapfile -t ids < <(vast_storage_ids "$POOL_FQDN")
    nic2="$(second_storage_nic)"
    if [[ -n $nic2 ]] && ip -4 -o addr show dev "$nic2" 2>/dev/null | gq inet; then
      lp="vmbr1~${nic2}"
    fi
    (( ${#ids[@]} )) && want="$(render_block "$VIP_RANGE" "$lp" "${ids[@]}")"
  elif ! vastnfs_loaded; then
    say "vastnfs not loaded: removing managed options so storages mount with the stock client"
  else
    warn "no ${CLUSTER_CONF}; nothing to manage"
  fi

  local tmp; tmp="$(mktemp)"
  strip_block "$NFSCONF" | cat -s >"$tmp"
  [[ -n $want ]] && printf '\n%s\n' "$want" >>"$tmp"
  if cmp -s "$tmp" "$NFSCONF"; then
    rm -f "$tmp"; say "nfsmount.conf already current (${#ids[@]} storages${lp:+, localports ${lp}})"
  else
    cp -a "$NFSCONF" "${NFSCONF}.vastnfs-bak" 2>/dev/null || true
    cat "$tmp" >"$NFSCONF"; rm -f "$tmp"
    say "nfsmount.conf updated (${#ids[@]} storages${lp:+, localports ${lp}})"
  fi

  (( remount )) || return 0
  # every VAST storage (also when vastnfs is off, to drop stale options)
  local all=() id mp opts wv=0
  [[ -n $want ]] && wv=1
  if [[ -n ${POOL_FQDN:-} ]] || read_cluster_conf; then mapfile -t all < <(vast_storage_ids "$POOL_FQDN"); fi
  for id in "${all[@]}"; do
    mp="/mnt/pve/${id}"
    opts="$(awk -v m="$mp" '$2==m{print $4}' /proc/mounts)"
    [[ -n $opts ]] || continue
    mount_current "$opts" "$wv" "$lp" "$(storage_nconnect "$id")" && continue
    if umount "$mp" 2>/dev/null; then say "remounting ${id} (pvestatd picks it up within ~10s)"
    else warn "${id} is busy; it gets the new options on its next mount (reboot or migrate guests off)"; fi
  done
}

# ---------------------------------------------------------------------------
install_hooks() {
  local self; self="$(readlink -f "$0")"
  [[ $self == "$SELF" ]] || install -m 0755 "$self" "$SELF"
  cat >"$GUARD_BIN" <<'EOF'
#!/bin/sh
# Installed by vastnfs-pve.sh. Runs after DKMS on kernel/header installs.
exec /usr/local/sbin/vastnfs-pve.sh guard "$@"
EOF
  chmod 0755 "$GUARD_BIN"
  ln -sf "$GUARD_BIN" "/etc/kernel/postinst.d/${GUARD_NAME}"
  mkdir -p /etc/kernel/header_postinst.d
  ln -sf "$GUARD_BIN" "/etc/kernel/header_postinst.d/${GUARD_NAME}"
  # PVE headers packages don't run header_postinst.d, so also hook every dpkg run
  echo "DPkg::Post-Invoke { \"[ -x ${GUARD_BIN} ] && ${GUARD_BIN} || true\"; };" >"$APT_HOOK"
  cat >"$SYNC_UNIT" <<EOF
[Unit]
Description=VAST multipath NFS options (vastnfs) for PVE storages
After=pve-cluster.service
Wants=pve-cluster.service
Before=pvestatd.service pve-guests.service pve-storage.target

[Service]
Type=oneshot
ExecStart=${SELF} sync

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable -q vastnfs-sync.service
  mkdir -p /etc/motd.d "$GUARD_STATE"
  say "hooks installed: kernel/header postinst, dpkg post-invoke, boot-time sync unit"
}

cmd_install() {
  [[ $EUID -eq 0 ]] || die "run as root"
  command -v pveversion >/dev/null || die "not a Proxmox VE host"
  local kv; kv="$(uname -r)"
  if [[ -d /sys/firmware/efi ]] && command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | gq enabled; then
    die "Secure Boot is on: the DKMS modules would need MOK signing. Not handled here."
  fi
  if built_for "$kv"; then
    say "vastnfs already built for ${kv}; refreshing hooks only"
    install_hooks; return 0
  fi

  say "packages"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    proxmox-default-headers "proxmox-headers-${kv}" \
    build-essential dkms dh-dkms debhelper devscripts fakeroot lsb-release >/dev/null

  say "download"
  rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
  curl -sSfo download.sh https://vast-nfs.s3.amazonaws.com/download.sh
  if [[ -n $VASTNFS_VERSION ]]; then bash download.sh --version "$VASTNFS_VERSION"; else bash download.sh; fi
  local tarball=""; for tarball in vastnfs-*.tar.xz; do break; done
  [[ -f $tarball ]] || die "download produced no tarball"
  tar xJf "$tarball"; cd "${tarball%.tar.xz}"

  say "build (DKMS package)"
  ./build.sh bin --dkms --no-ofed >"$WORK/build.log" 2>&1 || { tail -20 "$WORK/build.log"; die "build failed"; }
  say "install"
  dpkg -i dist/vastnfs-dkms_*.deb >"$WORK/install.log" 2>&1 || { tail -20 "$WORK/install.log"; die "dpkg failed"; }
  built_for "$kv" || die "DKMS did not produce modules for ${kv}"

  install_hooks
  local k
  for k in /lib/modules/*/; do   # keep other installed kernels bootable with vastnfs
    k="$(basename "$k")"
    [[ $k == "$kv" || ! -d /lib/modules/$k/build ]] && continue
    dkms autoinstall -k "$k" >/dev/null 2>&1 && say "also built for ${k}" || warn "could not build for ${k}"
  done
  update-initramfs -u -k "$kv" >/dev/null 2>&1
  say "done: $(dkms status -m vastnfs | head -1)"
  say "reboot to load the vastnfs modules (the sync unit applies mount options at boot)"
}

cmd_status() {
  local kv; kv="$(uname -r)"
  echo "running kernel : ${kv}"
  echo "vastnfs        : $(vastnfs_loaded && echo loaded || echo 'NOT loaded (stock NFS client running)')"
  echo "dkms           :"; dkms status -m vastnfs 2>/dev/null | sed 's/^/  /' || true
  echo "boot pin       : $(proxmox-boot-tool kernel list 2>/dev/null | awk '/Pinned kernel/{getline; print}')"
  if [[ -f $GUARD_STATE/pinned ]]; then echo "guard          : pinned (default>held): $(cat "$GUARD_STATE/pinned")"; else echo "guard          : no guard pin"; fi
  if read_cluster_conf; then echo "cluster conf   : pool ${POOL_FQDN}, VIPs ${VIP_RANGE}, share transport ${SHARE_TRANSPORT}"; else echo "cluster conf   : none (${CLUSTER_CONF})"; fi
  echo "localports     : $(n=$(second_storage_nic); [[ -n $n ]] && echo "vmbr1~${n}" || echo 'none (single storage NIC)')"
  echo "mounts         :"
  local m o
  while read -r m o; do
    printf '  %-26s %s\n' "$m" "$(tr , '\n' <<<"$o" | grep -oE '^(nconnect|remoteports|localports)=.*|^spread_(reads|writes)$' | tr '\n' ' ')"
  done < <(awk '$2 ~ "^/mnt/pve/" && $3 ~ /^nfs/ {print $2, $4}' /proc/mounts)
  echo "kernels        :"
  local k
  for k in /lib/modules/*/; do
    k="$(basename "$k")"
    printf '  %-20s %s\n' "$k" "$(built_for "$k" && echo vastnfs || echo 'NO vastnfs')"
  done
}

cmd_remove() {
  systemctl disable -q --now vastnfs-sync.service 2>/dev/null || true
  rm -f "$SYNC_UNIT"; systemctl daemon-reload
  if [[ -f $NFSCONF ]]; then
    local t; t="$(mktemp)"; strip_block "$NFSCONF" | cat -s >"$t"
    # nothing but whitespace left means we created the file: remove it
    if grep -q '[^[:space:]]' "$t"; then cat "$t" >"$NFSCONF"; else rm -f "$NFSCONF"; fi
    rm -f "$t"
  fi
  rm -f "/etc/kernel/postinst.d/${GUARD_NAME}" "/etc/kernel/header_postinst.d/${GUARD_NAME}" "$GUARD_BIN" "$APT_HOOK" /etc/motd.d/vastnfs-guard
  [[ -f $GUARD_STATE/pinned ]] && proxmox-boot-tool kernel unpin >/dev/null 2>&1
  rm -rf "$GUARD_STATE"
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -q vastnfs-dkms >/dev/null || true
  update-initramfs -u -k "$(uname -r)" >/dev/null 2>&1
  rm -rf "$WORK" "$SELF"
  say "removed; reboot to load the stock NFS client (build packages left installed)"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  case "${1:-}" in
    install) cmd_install ;;
    hooks)   install_hooks ;;
    sync)    shift; cmd_sync "$@" ;;
    guard)   shift; guard "$@" ;;
    status)  cmd_status ;;
    remove)  cmd_remove ;;
    *) echo "usage: $0 install|hooks|sync [--remount]|status|remove" >&2; exit 2 ;;
  esac
fi
VASTNFS_PVE_EOF
  chmod 0755 "$VASTNFS_HELPER"
}

valid_vip_range() { # a.b.c.d-a.b.c.e (same /24), or a single IP
  [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(-([0-9]{1,3}\.){3}[0-9]{1,3})?$ ]]
}

vast_cluster_conf_setup() {
  if [[ -r $VAST_CLUSTER_CONF ]]; then
    ok "Cluster VAST settings: $(tr '\n' ' ' <"$VAST_CLUSTER_CONF")"
    VAST_POOL_FQDN="${VAST_POOL_FQDN:-$(awk -F= '$1=="POOL_FQDN"{print $2}' "$VAST_CLUSTER_CONF" | tr -d '"')}"
    return 0
  fi
  if [[ $CL_ACTION == join ]]; then
    info "Joining a cluster: VAST settings come from its ${VAST_CLUSTER_CONF} after the join."
    return 0
  fi
  local pool range
  pool="${VAST_POOL_FQDN:-$(ask "VAST VIP pool FQDN (for multipath; VAST DNS delegated)" "")}"
  range="${VAST_VIP_RANGE:-$(ask "VIP pool range for multipath (first-last, e.g. 172.200.201.145-172.200.201.150)" "")}"
  if [[ -z $pool || -z $range ]]; then
    warn "No pool/range given: vastnfs is installed but storages stay on the stock-style options."
    warn "Set them later in ${VAST_CLUSTER_CONF} (POOL_FQDN=, VIP_RANGE=) and run: vastnfs-pve.sh sync --remount"
    return 0
  fi
  valid_vip_range "$range" || die "Bad VIP range: $range"
  printf 'POOL_FQDN=%s\nVIP_RANGE=%s\n' "$pool" "$range" >"$VAST_CLUSTER_CONF"
  VAST_POOL_FQDN="$pool"
  ok "Wrote ${VAST_CLUSTER_CONF} (shared by every node in the cluster)"
}

setup_vastnfs() {
  stage "VAST NFS client (vastnfs)"
  local def=n
  [[ ${WANT_VASTNFS:-} == 1 ]] && def=y
  case "${VASTNFS,,}" in
    yes|y|1|true) WANT_VASTNFS=1 ;;
    no|n|0|false) WANT_VASTNFS=0 ;;
    *)
      info "vastnfs gives multipath to VAST: every mount spreads over all VIPs. Its big win (both"
      info "NICs without LACP, ~2x) needs split mode, which drops failover for VMs on vmbr1."
      info "With a bond, stock NFS + DNS prefixes already spreads well; vastnfs adds little."
      info "Cost: a DKMS kernel module. A guard keeps kernel updates from ever booting without it."
      if confirm "Install the VAST NFS client?" "$def"; then WANT_VASTNFS=1; else WANT_VASTNFS=0; fi
      ;;
  esac
  if [[ $WANT_VASTNFS != 1 ]]; then
    ok "Using the stock NFS client"; summ skip "vastnfs" "not installed (stock NFS client)"; return 0
  fi
  if (( DRY_RUN )); then
    if dkms status -m vastnfs 2>/dev/null | gq ': installed'; then
      info "Dry run: vastnfs already installed; would refresh its hooks."; summ skip "vastnfs" "installed; would refresh hooks"
    else
      info "Dry run: would install vastnfs."; summ skip "vastnfs" "would install"
    fi
    return 0
  fi

  write_vastnfs_helper
  spin "Installing vastnfs (download, DKMS build; a few minutes)" "$VASTNFS_HELPER" install \
    || die "vastnfs install failed (see $LOG). Nothing else was changed by this stage."
  vast_cluster_conf_setup
  if "$VASTNFS_HELPER" status 2>/dev/null | gq 'vastnfs *: loaded'; then
    ok "vastnfs is loaded"
    summ ok "vastnfs" "loaded; guard + boot sync installed"
  else
    NEED_REBOOT=1
    ok "vastnfs installed; it loads on the next boot (the sync unit applies mount options then)"
    summ ok "vastnfs" "installed, guard + boot sync on; REBOOT to load"
  fi
}

# --vastnfs retrofit: an existing node only needs the tools the network stage
# relies on (lldpd for the bond/split recommendation) and a check that nothing
# is running here, since vmbr1 is re-plumbed and the node reboots at the end.
running_guests() { # "vm:101 ct:200 ..." for guests running on this node
  { qm list 2>/dev/null | awk 'NR>1 && $3=="running"{print "vm:"$1}'
    pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print "ct:"$1}'; } | tr '\n' ' ' | sed 's/ $//'
}

retrofit_prep() {
  stage "Retrofit checks"
  local missing=() t
  for t in "${TOOLS[@]}"; do dpkg -s "$t" >/dev/null 2>&1 || missing+=("$t"); done
  if (( ${#missing[@]} )); then
    if (( DRY_RUN )); then
      info "Dry run: would install ${missing[*]}"
    elif ! spin "Installing ${missing[*]}" env DEBIAN_FRONTEND=noninteractive apt-get $APT_WAIT -y -q install "${missing[@]}"; then
      spin "Refreshing package lists" apt-get $APT_WAIT update -q || true
      spin "Installing ${missing[*]}" env DEBIAN_FRONTEND=noninteractive apt-get $APT_WAIT -y -q install "${missing[@]}" \
        || warn "Could not install ${missing[*]}."
    fi
  else
    ok "Tools present (${TOOLS[*]})"
  fi
  (( DRY_RUN )) || systemctl enable -q --now lldpd 2>/dev/null || true

  local g; g="$(running_guests)"
  if [[ -n $g ]]; then
    warn "Guests running on this node: ${g}"
    warn "The storage network is re-plumbed and the node reboots. Migrate them off first."
    (( DRY_RUN )) || confirm "Continue anyway?" n || die "Aborted. Migrate the guests and re-run."
  else
    ok "No guests running on this node"
  fi
  if dkms status -m vastnfs 2>/dev/null | gq ': installed'; then
    info "vastnfs is already installed; this run refreshes hooks and re-checks the network."
  fi
  summ ok "Retrofit" "tools ok, guests: ${g:-none}"
}

# -----------------------------------------------------------------------------
# 4. HA services
# -----------------------------------------------------------------------------
setup_ha() {
  stage "HA services"
  if (( CLUSTERED )); then
    ok "Host is in a cluster; leaving HA services alone"
    return
  fi
  if systemctl is-active -q pve-ha-lrm; then
    if confirm "Standalone host. Disable pve-ha-lrm/crm? (say no if it will join a cluster)" n; then
      systemctl disable -q --now pve-ha-lrm pve-ha-crm
      ok "HA services disabled (re-enable: systemctl enable --now pve-ha-lrm pve-ha-crm)"
      summ ok "HA" "lrm/crm disabled (standalone)"
    fi
  else
    ok "HA services already inactive"
  fi
}

# -----------------------------------------------------------------------------
# 5. network
# -----------------------------------------------------------------------------
declare -A NIC_MAX NIC_CUR NIC_LINK NIC_DRV NIC_MAC NIC_USB NIC_LLDP NIC_CARD NIC_PROBED
declare -A NIC_SW NIC_SWPORT NIC_AGG NIC_MFS   # from LLDP: switch, port, LAG id, max frame
NICS=()

nic_max_speed() { # highest supported link mode in Mb/s, falls back to current speed
  local n="$1" m=""
  if command -v ethtool >/dev/null; then
    m="$(ethtool "$n" 2>/dev/null | awk '/Supported link modes:/{f=1} /Supported pause|Supports auto/{f=0} f' \
        | grep -oE '[0-9]+base' | tr -d 'base' | sort -n | tail -1 || true)"
  fi
  [[ -z $m ]] && m="$(cat "/sys/class/net/$n/speed" 2>/dev/null || echo 0)"
  (( m < 0 )) && m=0
  printf '%s\n' "$m"
}

# parse_lldp_kv : lldpctl -f keyvalue <nic> on stdin -> "switch|port|lagid|mfs"
# The dot3 link-aggregation TLV only carries an ID when the switch port is an
# active member of a bond/LAG (port.aggregation=<id>). lldpd versions differ on
# the exact key, so match any *aggregation* key with a numeric value.
parse_lldp_kv() {
  awk -F= '
    /\.chassis\.name=/      { s = $2 }
    /\.port\.descr=/        { if (p == "") p = $2 }
    /\.port\.ifname=/       { p = $2 }
    /aggregat[a-z]*(\.id)?=[0-9]+$/ { a = $2 }
    /\.port\.mfs=/          { m = $2 }
    END { printf "%s|%s|%s|%s\n", s, p, a, m }'
}

# recommend_bond_mode <nic...> -> "mode|reason"
#   802.3ad only when every NIC's switch port advertises LAG membership.
#   NICs landing on two different switches additionally need MLAG/vPC/VC on
#   that pair, which LLDP can't prove, so the reason says so.
recommend_bond_mode() {
  local n sws=() lag=1 nolldp=()
  (( $# >= 2 )) || { printf 'active-backup|single NIC\n'; return; }
  for n in "$@"; do
    if [[ -z ${NIC_SW[$n]:-} ]]; then nolldp+=("$n"); lag=0; continue; fi
    in_list "${NIC_SW[$n]}" "${sws[@]}" || sws+=("${NIC_SW[$n]}")
    [[ -n ${NIC_AGG[$n]:-} ]] || lag=0
  done
  if (( lag && ! ${#nolldp[@]} )); then
    if (( ${#sws[@]} > 1 )); then
      printf '802.3ad|switch ports are LAG members on %s (an MLAG pair, presumably)\n' "${sws[*]}"
    else
      printf '802.3ad|switch ports are LAG members on %s\n' "${sws[0]}"
    fi
  elif (( ${#nolldp[@]} )); then
    printf 'active-backup|no LLDP from the switch on %s; cannot tell if the ports are bonded\n' "${nolldp[*]}"
  else
    local where="" x
    for x in "$@"; do where+="${NIC_SW[$x]}:${NIC_SWPORT[$x]} "; done
    printf 'active-backup|switch ports %sare not in a LAG. For 802.3ad, bond them on the switch first%s\n' \
      "$where" "$( (( ${#sws[@]} > 1 )) && printf ' (needs MLAG across %s)' "${sws[*]}")"
  fi
}

# Switches send LLDP every ~30s, so right after lldpd starts there are no
# neighbors yet and the bond recommendation would be blind. Wait for some.
LLDP_WAIT_SECS="${LLDP_WAIT_SECS:-40}"
wait_for_lldp() {
  command -v lldpctl >/dev/null || { warn "lldpd not installed; bond mode can't be checked against the switch."; return 0; }
  systemctl is-active -q lldpd 2>/dev/null || systemctl start lldpd 2>/dev/null || return 0
  local t0=$SECONDS i=0
  lldpctl -f keyvalue 2>/dev/null | gq '\.chassis\.name=' && return 0
  while (( SECONDS - t0 < LLDP_WAIT_SECS )); do
    if (( IS_TTY )); then
      printf '\r  %s%s%s waiting for LLDP from the switches %s%ds%s ' "$C_B" "${SPIN[i++ % ${#SPIN[@]}]}" "$C_0" "$C_D" $((SECONDS - t0)) "$C_0"
    fi
    sleep 2
    lldpctl -f keyvalue 2>/dev/null | gq '\.chassis\.name=' && break
  done
  (( IS_TTY )) && printf '\r\e[K'
  if lldpctl -f keyvalue 2>/dev/null | gq '\.chassis\.name='; then ok "LLDP neighbors seen ($(dur $((SECONDS - t0))))"
  else warn "No LLDP neighbors after $(dur "$LLDP_WAIT_SECS"); switch may not run LLDP."; fi
  return 0
}

LINK_PROBE_SECS="${LINK_PROBE_SECS:-12}"
# Fresh installs leave unused NICs admin-down, so carrier is unreadable.
# Bring idle (down, unenslaved) NICs up briefly to see which ones are cabled.
probe_links() {
  local n d probed=() i all
  for n in "$@"; do
    d="/sys/class/net/$n"
    [[ -e $d/master ]] && continue
    ip -o link show "$n" | gq '<[^>]*\bUP\b' && continue
    ip link set "$n" up 2>/dev/null && probed+=("$n")
  done
  (( ${#probed[@]} )) || return 0
  info "Probing link on idle NICs (${probed[*]}), up to ${LINK_PROBE_SECS}s"
  for (( i = 0; i < LINK_PROBE_SECS; i++ )); do
    all=1
    for n in "${probed[@]}"; do [[ "$(cat "/sys/class/net/$n/carrier" 2>/dev/null)" == 1 ]] || all=0; done
    (( all )) && break
    sleep 1
  done
  for n in "${probed[@]}"; do
    NIC_LINK[$n]="$(cat "/sys/class/net/$n/carrier" 2>/dev/null || echo 0)"
    NIC_CUR[$n]="$(cat "/sys/class/net/$n/speed" 2>/dev/null || echo 0)"
    (( NIC_CUR[$n] < 0 )) && NIC_CUR[$n]=0
    NIC_PROBED[$n]=1
    ip link set "$n" down 2>/dev/null || true
  done
}

discover_nics() {
  local d n dev
  NICS=()
  for d in /sys/class/net/*; do
    n="$(basename "$d")"
    [[ -e $d/device ]] || continue            # physical only
    [[ -e $d/wireless || -e $d/phy80211 ]] && continue
    dev="$(readlink -f "$d/device")"
    NICS+=("$n")
    NIC_PROBED[$n]=0
    # PCI card = address minus function (0000:5e:00.1 -> 0000:5e:00)
    NIC_CARD[$n]="$(basename "$dev")"; NIC_CARD[$n]="${NIC_CARD[$n]%.*}"
    NIC_USB[$n]=0; [[ $dev == */usb* ]] && NIC_USB[$n]=1   # BMC/iDRAC USB NICs
    NIC_DRV[$n]="$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)" 2>/dev/null || echo '?')"
    NIC_MAC[$n]="$(cat "$d/address" 2>/dev/null || echo '?')"
    # bond slaves report the bond's MAC; use the permanent one if we can
    if command -v ethtool >/dev/null; then
      local pm; pm="$(ethtool -P "$n" 2>/dev/null | awk '{print $NF}' || true)"
      [[ $pm =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ && $pm != 00:00:00:00:00:00 ]] && NIC_MAC[$n]="$pm"
    fi
    NIC_LINK[$n]="$(cat "$d/carrier" 2>/dev/null || echo 0)"
    NIC_CUR[$n]="$(cat "$d/speed" 2>/dev/null || echo 0)"; (( NIC_CUR[$n] < 0 )) && NIC_CUR[$n]=0
    NIC_MAX[$n]="$(nic_max_speed "$n")"
    NIC_LLDP[$n]="" NIC_SW[$n]="" NIC_SWPORT[$n]="" NIC_AGG[$n]="" NIC_MFS[$n]=""
    if command -v lldpctl >/dev/null; then
      local kv; kv="$(lldpctl -f keyvalue "$n" 2>/dev/null || true)"
      if [[ -n $kv ]]; then
        IFS='|' read -r NIC_SW[$n] NIC_SWPORT[$n] NIC_AGG[$n] NIC_MFS[$n] < <(parse_lldp_kv <<<"$kv")
        [[ -n ${NIC_SW[$n]} ]] && NIC_LLDP[$n]="${NIC_SW[$n]} ${NIC_SWPORT[$n]}"
        [[ -n ${NIC_AGG[$n]} ]] && NIC_LLDP[$n]+=" [LAG ${NIC_AGG[$n]}]"
      fi
    fi
  done
  (( ${#NICS[@]} )) || die "No physical NICs found."
  local idle=()
  for n in "${NICS[@]}"; do (( NIC_USB[$n] )) || idle+=("$n"); done
  probe_links "${idle[@]}"
}

speed_h() { local s="$1"; (( s >= 1000 )) && printf '%sG' "$((s/1000))" || { (( s > 0 )) && printf '%sM' "$s" || printf -- '-'; }; }

MGMT_NICS=()
detect_mgmt_nics() { # ports under vmbr0 (resolving a bond to its slaves)
  local p
  MGMT_NICS=()
  [[ -d /sys/class/net/vmbr0/brif ]] || return 0
  for p in /sys/class/net/vmbr0/brif/*; do
    p="$(basename "$p")"
    if [[ -f /sys/class/net/$p/bonding/slaves ]]; then
      # shellcheck disable=SC2207
      MGMT_NICS+=($(cat "/sys/class/net/$p/bonding/slaves"))
    elif [[ -e /sys/class/net/$p/device ]]; then
      MGMT_NICS+=("$p")
    fi
  done
}

current_hs_nics() { # NICs currently carrying vmbr1 (direct or via bond)
  local p out=()
  [[ -d /sys/class/net/vmbr1/brif ]] || return 0
  for p in /sys/class/net/vmbr1/brif/*; do
    p="$(basename "$p")"
    if [[ -f /sys/class/net/$p/bonding/slaves ]]; then
      # shellcheck disable=SC2207
      out+=($(cat "/sys/class/net/$p/bonding/slaves"))
    elif [[ -e /sys/class/net/$p/device ]]; then
      out+=("$p")
    fi
  done
  local n2; n2="$(split_nic2 "$IFACES")"
  [[ -n $n2 ]] && out+=("$n2")
  printf '%s\n' "${out[*]}"
}

# split_nic2 <interfaces file> : 2nd storage NIC (stanza marked #highspeed2)
split_nic2() { awk '/^[[:space:]]*iface[[:space:]]/{n=$2} /^#highspeed2/{print n; exit}' "$1" 2>/dev/null || true; }

# net_of <a.b.c.d/n> -> network address/n
net_of() {
  local ip="${1%/*}" len="${1#*/}" a b c d m n
  IFS=. read -r a b c d <<<"$ip"
  m=$(( len == 0 ? 0 : (0xffffffff << (32 - len)) & 0xffffffff ))
  n=$(( (a << 24 | b << 16 | c << 8 | d) & m ))
  printf '%d.%d.%d.%d/%s\n' $(( n >> 24 & 255 )) $(( n >> 16 & 255 )) $(( n >> 8 & 255 )) $(( n & 255 )) "$len"
}

# default_nic2_addr <a.b.c.d/n> -> a.b.(c+1).d/n
default_nic2_addr() {
  local ip="${1%/*}" len="${1#*/}" a b c d
  IFS=. read -r a b c d <<<"$ip"
  printf '%s.%s.%s.%s/%s\n' "$a" "$b" $(( (c + 1) % 256 )) "$d" "$len"
}

# gq [grep opts] PATTERN : "grep -q" for pipelines. Reads ALL input first, so the
# writer never takes SIGPIPE when grep -q exits on the first match; with
# pipefail that SIGPIPE would turn a successful match into a failure.
gq() { local in; in="$(cat)"; grep -q "$@" <<<"$in"; }
in_list() { local x="$1"; shift; local y; for y in "$@"; do [[ $x == "$y" ]] && return 0; done; return 1; }

print_nic_table() {
  local n role link
  printf '\n    %s%-14s %-6s %-6s %-5s %-10s %-13s %-18s %s%s\n' "$C_D" NIC LINK SPEED MAX DRIVER "PCI CARD" MAC "LLDP (switch port)" "$C_0"
  for n in "${NICS[@]}"; do
    role=""
    in_list "$n" "${MGMT_NICS[@]}" && role=" ${C_B}<- vmbr0${C_0}"
    (( NIC_USB[$n] )) && role=" ${C_D}(USB/BMC, ignored)${C_0}"
    (( NIC_PROBED[$n] && NIC_LINK[$n] )) && role+=" ${C_G}(idle, cabled)${C_0}"
    if (( NIC_LINK[$n] )); then link="${C_G}$(printf '%-6s' up)${C_0}"; else link="${C_D}$(printf '%-6s' down)${C_0}"; fi
    printf '    %s%-14s%s %s %-6s %-5s %s%-10s %-13s %-18s%s %s%s\n' "$C_BOLD" "$n" "$C_0" "$link" \
      "$(speed_h "${NIC_CUR[$n]}")" "$(speed_h "${NIC_MAX[$n]}")" \
      "$C_D" "${NIC_DRV[$n]}" "${NIC_CARD[$n]}" "${NIC_MAC[$n]}" "$C_0" "${NIC_LLDP[$n]:--}" "$role"
  done
  echo
}

suggest_hs_nics() { # fastest-capable, linked, non-mgmt, non-USB NICs
  local n top=0 out=()
  for n in "${NICS[@]}"; do
    (( NIC_USB[$n] )) && continue
    in_list "$n" "${MGMT_NICS[@]}" && continue
    (( NIC_MAX[$n] >= HS_MIN_SPEED && NIC_MAX[$n] > top )) && top="${NIC_MAX[$n]}"
  done
  (( top )) || return 0
  for n in "${NICS[@]}"; do
    (( NIC_USB[$n] )) && continue
    in_list "$n" "${MGMT_NICS[@]}" && continue
    (( NIC_MAX[$n] == top && NIC_LINK[$n] == 1 )) && out+=("$n")
  done
  (( ${#out[@]} <= 2 )) && { printf '%s\n' "${out[*]}"; return 0; }
  # more than 2 candidates: take the first, then prefer one on a different card
  local second=""
  for n in "${out[@]:1}"; do
    [[ ${NIC_CARD[$n]} != "${NIC_CARD[${out[0]}]}" ]] && { second="$n"; break; }
  done
  printf '%s %s\n' "${out[0]}" "${second:-${out[1]}}"
}

# --- interfaces file rewriting (pure functions, unit-testable) ---------------

# strip_stanzas <file> "<names>" : print file minus iface/auto entries for names
# and minus source lines (re-added at the end by build_interfaces).
strip_stanzas() {
  awk -v drop="$2" '
    BEGIN { n = split(drop, a, " "); for (i = 1; i <= n; i++) D[a[i]] = 1; keep = 1 }
    /^[[:space:]]*(auto|allow-[^[:space:]]+)[[:space:]]/ {
      out = $1; any = 0
      for (i = 2; i <= NF; i++) if (!($i in D)) { out = out " " $i; any = 1 }
      keep = 1; if (any) print out; next
    }
    /^[[:space:]]*iface[[:space:]]/ { keep = !($2 in D); if (keep) print; next }
    /^[[:space:]]*(source|source-directory)[[:space:]]/ { keep = 1; next }
    { if (keep) print }
  ' "$1"
}

source_lines() { grep -E '^[[:space:]]*(source|source-directory)[[:space:]]' "$1" || true; }

# set_vmbr0 : rewrite address/gateway inside the vmbr0 stanza (stdin -> stdout)
set_vmbr0() {
  awk -v A="$1" -v G="$2" '
    /^[[:space:]]*iface[[:space:]]/ { inb = ($2 == "vmbr0") }
    /^[[:space:]]*(auto|allow-|source)/ { inb = 0 }
    inb && A != "" && /^[[:space:]]+address[[:space:]]/ { print "\taddress " A; next }
    inb && G != "" && /^[[:space:]]+gateway[[:space:]]/ { print "\tgateway " G; next }
    { print }
  '
}

# iface names declared anywhere in a file
declared_ifaces() { awk '/^[[:space:]]*iface[[:space:]]/{print $2}' "$1"; }

# bridge-ports / bond-slaves of preserved stanzas, to detect conflicts
used_ports() {
  awk '/^[[:space:]]+(bridge-ports|bond-slaves)[[:space:]]/{for(i=2;i<=NF;i++) print $i}' "$1"
}

# build_interfaces <in> <out>
#   uses: HS_NICS HS_BOND HS_MODE HS_MTU VMBR1_ADDR NEW_VMBR0_ADDR NEW_VMBR0_GW ALL_NICS
#         HS_NIC2_ADDR (split mode)
#   split: vmbr1 bridges the 1st NIC; the 2nd NIC gets its own IP. Per-IP policy
#   routing tables (101/102) make replies and vastnfs localports connections
#   leave through the NIC that owns the source IP (same-subnet multihoming).
build_interfaces() {
  local src="$1" dst="$2" n tmp
  local -a hs; read -r -a hs <<<"$HS_NICS"
  tmp="$(mktemp)"

  strip_stanzas "$src" "vmbr1 ${HS_BOND} ${HS_NICS}" \
    | set_vmbr0 "${NEW_VMBR0_ADDR:-}" "${NEW_VMBR0_GW:-}" >"$tmp"

  # refuse if a preserved stanza still uses one of our NICs or the bond
  local p
  while read -r p; do
    if in_list "$p" "${hs[@]}" "$HS_BOND"; then
      rm -f "$tmp"; die "'$p' is still used by another stanza in $src. Fix that first."
    fi
  done < <(used_ports "$tmp")

  {
    cat "$tmp"
    # make sure every physical NIC has a stanza so the GUI lists it
    for n in ${ALL_NICS:-}; do
      in_list "$n" "${hs[@]}" && continue
      declared_ifaces "$tmp" | gq -x "$n" || printf '\niface %s inet manual\n' "$n"
    done
    echo
    for n in "${hs[@]}"; do
      [[ $HS_MODE == split && $n == "${hs[1]}" ]] && continue
      printf 'auto %s\niface %s inet manual\n\tmtu %s\n\n' "$n" "$n" "$HS_MTU"
    done
    if [[ $HS_MODE == split ]]; then
      local net v1="${VMBR1_ADDR%/*}" v2="${HS_NIC2_ADDR%/*}"
      net="$(net_of "$VMBR1_ADDR")"
      printf 'auto %s\niface %s inet static\n\taddress %s\n\tmtu %s\n' "${hs[1]}" "${hs[1]}" "$HS_NIC2_ADDR" "$HS_MTU"
      printf '\tpost-up ip route replace %s dev %s src %s table 102\n' "$net" "${hs[1]}" "$v2"
      printf '\tpost-up ip rule add from %s table 102 priority 102 || true\n' "$v2"
      printf '\tpre-down ip rule del priority 102 || true\n#highspeed2\n\n'
      printf 'auto vmbr1\niface vmbr1 inet static\n\taddress %s\n' "$VMBR1_ADDR"
      printf '\tbridge-ports %s\n\tbridge-stp off\n\tbridge-fd 0\n\tmtu %s\n' "${hs[0]}" "$HS_MTU"
      printf '\tpost-up ip route replace %s dev vmbr1 src %s table 101\n' "$net" "$v1"
      printf '\tpost-up ip rule add from %s table 101 priority 101 || true\n' "$v1"
      printf '\tpre-down ip rule del priority 101 || true\n#highspeed\n\n'
      source_lines "$src"
      return 0
    fi
    printf 'auto %s\niface %s inet manual\n' "$HS_BOND" "$HS_BOND"
    printf '\tbond-slaves %s\n\tbond-miimon 100\n\tbond-mode %s\n' "${hs[*]}" "$HS_MODE"
    if [[ $HS_MODE == active-backup ]]; then
      printf '\tbond-primary %s\n' "${hs[0]}"
    else
      printf '\tbond-xmit-hash-policy layer3+4\n\tbond-lacp-rate fast\n'
    fi
    printf '\tmtu %s\n\n' "$HS_MTU"
    printf 'auto vmbr1\niface vmbr1 inet static\n\taddress %s\n' "$VMBR1_ADDR"
    printf '\tbridge-ports %s\n\tbridge-stp off\n\tbridge-fd 0\n\tmtu %s\n#highspeed\n' "$HS_BOND" "$HS_MTU"
    echo
    source_lines "$src"
  } | cat -s >"$dst"
  rm -f "$tmp"
}

net_summary() {
  if [[ $HS_MODE == split ]]; then
    local -a h; read -r -a h <<<"$HS_NICS"
    printf 'split: vmbr1 %s on %s, %s %s, mtu %s' "$VMBR1_ADDR" "${h[0]}" "${h[1]}" "$HS_NIC2_ADDR" "$HS_MTU"
  else
    printf 'vmbr1 %s on %s(%s) %s, mtu %s' "$VMBR1_ADDR" "$HS_BOND" "$HS_NICS" "$HS_MODE" "$HS_MTU"
  fi
}

cancel_rollback() { systemctl stop "${ROLLBACK_UNIT}.timer" 2>/dev/null || true; systemctl reset-failed "${ROLLBACK_UNIT}" 2>/dev/null || true; }

setup_network() {
  stage "Network"
  command -v ifreload >/dev/null || die "ifupdown2 (ifreload) not installed."
  wait_for_lldp
  discover_nics
  detect_mgmt_nics
  print_nic_table

  # ---- vmbr0 --------------------------------------------------------------
  local cur0 curgw
  cur0="$(ip -4 -o addr show dev vmbr0 2>/dev/null | awk '{print $4}' | head -1 || true)"
  curgw="$(ip -4 route show default dev vmbr0 2>/dev/null | awk '{print $3}' | head -1 || true)"
  [[ -n $cur0 ]] || die "vmbr0 has no IPv4 address. Fix mgmt networking from the console first."
  info "vmbr0 (mgmt): ${cur0} gw ${curgw:-none} ports: ${MGMT_NICS[*]:-?}"

  NEW_VMBR0_ADDR="" NEW_VMBR0_GW=""
  local a0 g0
  a0="${VMBR0_ADDR:-$(ask "vmbr0 address/CIDR" "$cur0")}"
  g0="${VMBR0_GW:-$(ask "vmbr0 gateway" "${curgw}")}"
  valid_cidr "$a0" || die "Bad vmbr0 address: $a0"
  [[ -z $g0 ]] || valid_ip "$g0" || die "Bad vmbr0 gateway: $g0"
  [[ $a0 != "$cur0" ]] && NEW_VMBR0_ADDR="$a0"
  [[ $g0 != "$curgw" ]] && NEW_VMBR0_GW="$g0"
  if [[ -n $NEW_VMBR0_ADDR ]]; then
    (( CLUSTERED )) && die "Changing the mgmt IP of a clustered node breaks corosync. Not doing that here."
    warn "Changing the mgmt IP drops this SSH session. Run this from the console/iKVM,"
    warn "or the dead-man timer will roll it back when you can't confirm."
    confirm "Continue with mgmt IP change ${cur0} -> ${NEW_VMBR0_ADDR}?" n || die "Aborted."
  fi

  # ---- high-speed NICs -----------------------------------------------------
  local existing suggested
  existing="$(current_hs_nics)"
  suggested="$(suggest_hs_nics)"
  local def="${HS_NICS:-${existing:-$suggested}}"
  if [[ -z $def ]]; then
    warn "No linked NICs >= $(speed_h "$HS_MIN_SPEED") found outside vmbr0. Check cabling/switch."
  else
    [[ -n $existing ]] && info "vmbr1 currently on: ${existing}"
    info "Suggested vmbr1 NICs: ${def}"
  fi
  HS_NICS="$(ask "NICs for vmbr1 (space separated, 1 or 2)" "$def")"
  local -a hs; read -r -a hs <<<"$HS_NICS"
  (( ${#hs[@]} >= 1 )) || die "Need at least one NIC for vmbr1."
  local n
  for n in "${hs[@]}"; do
    in_list "$n" "${NICS[@]}" || die "$n is not a physical NIC on this host."
    in_list "$n" "${MGMT_NICS[@]}" && die "$n is a vmbr0 port. Pick different NICs."
    (( NIC_LINK[$n] )) || warn "$n has no link right now."
  done
  if (( ${#hs[@]} == 2 )) && [[ ${NIC_MAX[${hs[0]}]} != "${NIC_MAX[${hs[1]}]}" ]]; then
    warn "${hs[0]} and ${hs[1]} have different max speeds; primary will be ${hs[0]}."
  fi
  (( ${#hs[@]} == 1 )) && info "Single NIC: still building ${HS_BOND} so a second link is a one-line add later."

  local rec rec_mode rec_why
  rec="$(recommend_bond_mode "${hs[@]}")"; rec_mode="${rec%%|*}"; rec_why="${rec#*|}"
  info "Bond recommendation: ${C_BOLD}${rec_mode}${C_0} (${rec_why})"
  [[ $HS_MODE == auto ]] && HS_MODE="$rec_mode"
  HS_MODE="$(ask "vmbr1 mode (active-backup | 802.3ad needs LACP/MLAG | split needs vastnfs + 2 NICs)" "$HS_MODE")"
  case "$HS_MODE" in
    active-backup|802.3ad) ;;
    split)
      (( ${#hs[@]} == 2 )) || die "split mode needs exactly 2 NICs."
      [[ ${WANT_VASTNFS:-0} == 1 ]] || die "split mode only pays off with vastnfs (localports). Enable vastnfs or pick a bond mode."
      warn "split: vmbr1 runs on ${hs[0]} ONLY. VMs attached to vmbr1 lose that network if ${hs[0]}"
      warn "or its switch fails (host storage survives over ${hs[1]}). Use only if no VMs use vmbr1."
      confirm "Use split mode anyway?" n || die "Aborted. Re-run with HS_MODE=active-backup."
      ;;
    *) die "Mode must be active-backup, 802.3ad or split." ;;
  esac
  if [[ $HS_MODE == 802.3ad && $rec_mode != 802.3ad ]]; then
    warn "802.3ad chosen against the LLDP evidence. If the switch side isn't a LAG, the bond"
    warn "won't find an LACP partner; the post-apply check will catch that and roll back."
  fi
  if [[ -n $PEER_HS_MTU && $PEER_HS_MTU != "$HS_MTU" ]]; then
    warn "Cluster peer runs its high-speed net at MTU ${PEER_HS_MTU}; defaulting to that."
    HS_MTU="$PEER_HS_MTU"
  fi
  HS_MTU="$(ask "MTU for vmbr1 path" "$HS_MTU")"
  [[ $HS_MTU =~ ^[0-9]+$ ]] && (( HS_MTU >= 1280 && HS_MTU <= 9216 )) || die "Bad MTU: $HS_MTU"
  for n in "${hs[@]}"; do
    # switch MFS counts the L2 header (+14, +4 with a VLAN tag); 1522 is the classic non-jumbo value
    if [[ ${NIC_MFS[$n]:-} =~ ^[0-9]+$ ]] && (( NIC_MFS[$n] < HS_MTU + 18 )); then
      warn "${NIC_SW[$n]}:${NIC_SWPORT[$n]} advertises max frame ${NIC_MFS[$n]}; too small for MTU ${HS_MTU}."
    fi
  done

  # don't collide with a bond0 used elsewhere (e.g. a mgmt bond)
  if [[ -f /sys/class/net/${HS_BOND}/bonding/slaves ]]; then
    local s; s="$(cat "/sys/class/net/${HS_BOND}/bonding/slaves")"
    for n in $s; do
      in_list "$n" "${hs[@]}" || { HS_BOND="bond1"; warn "bond0 is in use by other NICs; using bond1."; break; }
    done
  fi

  # ---- vmbr1 address -------------------------------------------------------
  local cur1 octet
  cur1="$(ip -4 -o addr show dev vmbr1 2>/dev/null | awk '{print $4}' | head -1 || true)"
  octet="$(cut -d/ -f1 <<<"${NEW_VMBR0_ADDR:-$cur0}" | cut -d. -f4)"
  local def1="${HS_NET_PREFIX}.${octet}/${HS_CIDR}"
  if [[ -n $PEER_HS_NET3 ]]; then
    def1="${PEER_HS_NET3}.${octet}/${PEER_HS_CIDR}"
    info "Using the cluster's high-speed subnet for vmbr1 (from ${CL_PEER_NODE})"
  fi
  VMBR1_ADDR="${VMBR1_ADDR:-$(ask "vmbr1 address/CIDR" "${cur1:-$def1}")}"
  valid_cidr "$VMBR1_ADDR" || die "Bad vmbr1 address: $VMBR1_ADDR"
  if [[ $HS_MODE == split ]]; then
    local cur2; cur2="$(ip -4 -o addr show dev "${hs[1]}" 2>/dev/null | awk '{print $4}' | head -1 || true)"
    HS_NIC2_ADDR="${HS_NIC2_ADDR:-$(ask "${hs[1]} address/CIDR (2nd storage IP, same subnet as vmbr1)" "${cur2:-$(default_nic2_addr "$VMBR1_ADDR")}")}"
    valid_cidr "$HS_NIC2_ADDR" || die "Bad ${hs[1]} address: $HS_NIC2_ADDR"
    [[ "$(net_of "$HS_NIC2_ADDR")" == "$(net_of "$VMBR1_ADDR")" ]] || die "${hs[1]} must be in the same subnet as vmbr1 ($(net_of "$VMBR1_ADDR"))."
    if [[ -z $cur2 ]] && ping -c1 -W1 "${HS_NIC2_ADDR%/*}" >/dev/null 2>&1; then
      die "${HS_NIC2_ADDR%/*} already answers on the network; pick another."
    fi
  fi

  # ---- build + diff --------------------------------------------------------
  ALL_NICS=""
  for n in "${NICS[@]}"; do (( NIC_USB[$n] )) || ALL_NICS+="$n "; done
  # keep USB/BMC NICs declared too if they already were; add them otherwise
  for n in "${NICS[@]}"; do (( NIC_USB[$n] )) && ALL_NICS+="$n "; done

  local new; new="$(mktemp /root/interfaces.pveb.XXXX)"
  build_interfaces "$IFACES" "$new"

  if command -v ifquery >/dev/null && ! ifquery -a -i "$new" >/dev/null 2>&1; then
    warn "ifquery reported problems parsing the new file:"
    ifquery -a -i "$new" 2>&1 | tail -5 >&2 || true
    confirm "Apply anyway?" n || { info "Left candidate at $new"; return 1; }
  fi

  hdr "Planned change to ${IFACES}"
  if diff -u "$IFACES" "$new" >/dev/null; then
    ok "Config already matches. Nothing to do."
    summ ok "Network" "already configured (vmbr1 ${VMBR1_ADDR})"
    rm -f "$new"
    verify_network
    return 0
  fi
  diff -u --label current --label new "$IFACES" "$new" | colordiff || true
  echo

  if (( DRY_RUN )); then
    info "Dry run: candidate file left at $new (nothing applied)."
    summ skip "Network" "planned: $(net_summary)"
    return 0
  fi
  confirm "Apply this network config?" n || { info "Not applied. Candidate at $new"; return 0; }

  # ---- apply with dead-man rollback ----------------------------------------
  backup "$IFACES"
  backup /etc/hosts
  local bk="${BACKUP_DIR}${IFACES}"
  cancel_rollback
  local rb="cp -f '$bk' '$IFACES' && cp -f '${BACKUP_DIR}/etc/hosts' /etc/hosts"
  # leaving or entering split mode: undo the multihoming bits too
  rb+="; [ -f '${BACKUP_DIR}${SPLIT_SYSCTL}' ] && cp -f '${BACKUP_DIR}${SPLIT_SYSCTL}' '${SPLIT_SYSCTL}' || rm -f '${SPLIT_SYSCTL}'; sysctl -q --system"
  rb+="; ip rule del priority 101 2>/dev/null; ip rule del priority 102 2>/dev/null; ifreload -a"
  backup "$SPLIT_SYSCTL"
  systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active="${ROLLBACK_SECS}" /bin/bash -c "$rb" \
    || die "Could not arm rollback timer; refusing to touch the network."
  ok "Rollback armed: reverts in ${ROLLBACK_SECS}s unless you confirm."

  cp "$new" "$IFACES" && rm -f "$new"
  if [[ -n $NEW_VMBR0_ADDR ]]; then
    local oldip newip; oldip="${cur0%/*}" newip="${NEW_VMBR0_ADDR%/*}"
    sed -i -E "s/^${oldip//./\\.}([[:space:]])/${newip}\1/" /etc/hosts
    ok "/etc/hosts: ${oldip} -> ${newip}"
  fi
  if [[ $HS_MODE == split ]]; then
    cat >"$SPLIT_SYSCTL" <<'EOF'
# pve-bootstrap split mode: same-subnet multihoming for vastnfs localports.
# Each IP answers ARP only on its own NIC, and source routing (tables 101/102)
# sends traffic out the NIC that owns the source IP.
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
EOF
    sysctl -q --system
    ok "multihoming sysctls set (${SPLIT_SYSCTL})"
  else
    # leaving split: drop its multihoming sysctls and source-routing rules
    if [[ -f $SPLIT_SYSCTL ]]; then rm -f "$SPLIT_SYSCTL"; sysctl -q --system; fi
    ip rule del priority 101 2>/dev/null || true
    ip rule del priority 102 2>/dev/null || true
  fi
  # an existing bond under vmbr1 must release its NICs before re-plumbing
  local ob
  for ob in /sys/class/net/vmbr1/brif/bond*; do
    [[ -e $ob ]] || continue; ob="$(basename "$ob")"
    if [[ $HS_MODE == split ]] || [[ $ob != "$HS_BOND" ]]; then ip link del "$ob" 2>/dev/null || true; fi
  done
  info "ifreload -a"
  if ! ifreload -a; then
    err "ifreload failed. Rolling back now."
    systemctl start "${ROLLBACK_UNIT}.service" || { cp -f "$bk" "$IFACES"; ifreload -a; }
    die "Rolled back."
  fi
  sleep 5

  local healthy=1
  verify_network || healthy=0
  if (( ! healthy )); then
    warn "Checks failed. Config will roll back automatically in <${ROLLBACK_SECS}s."
    confirm "Keep it anyway?" n || { systemctl start "${ROLLBACK_UNIT}.service"; die "Rolled back."; }
  fi

  local ans=""
  if (( ASSUME_YES )); then
    ans=keep
  else
    flush_tty
    read -r -t "$((ROLLBACK_SECS - 20))" -p "Type 'keep' to keep this config (anything else or timeout = roll back): " ans </dev/tty || true
    ans="$(tr -d '[:space:]' <<<"$ans")"
  fi
  if [[ ${ans,,} == keep ]]; then
    cancel_rollback
    ok "Network config kept. Backup: $bk"
    summ ok "Network" "$(net_summary)"
  else
    warn "Rolling back (got '${ans}', not 'keep')."
    systemctl start "${ROLLBACK_UNIT}.service" || true
    die "Network rolled back to $bk"
  fi
}

# lacp_state </proc/net/bonding/bondX> -> "ok|detail" or "bad|detail"
#   ok = a real partner (non-zero MAC) and every slave in the active aggregator
lacp_state() {
  awk '
    /^802\.3ad info/          { inf = 1 }
    /^Slave Interface:/       { inf = 0; s = $3; ns++ }
    inf && /Aggregator ID:/   { act = $3 }
    inf && /Partner Mac Address:/ { pm = $4 }
    s != "" && /Aggregator ID:/   { ag[s] = $3 }
    END {
      if (pm == "" || pm == "00:00:00:00:00:00") { print "bad|no LACP partner: switch ports are not an LACP bond"; exit }
      for (k in ag) if (ag[k] != act) odd = odd k "(" ag[k] ") "
      if (odd != "") { print "bad|partner " pm " but slaves outside aggregator " act ": " odd "(switch side only bonded one port, or MLAG not formed)"; exit }
      print "ok|partner " pm ", " ns " slaves in aggregator " act
    }' "$1"
}

verify_network() {
  local rc=0 gw b
  hdr "Network checks"
  gw="$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1 || true)"
  if [[ -n $gw ]] && ping -c 2 -W 2 "$gw" >/dev/null 2>&1; then ok "mgmt gateway $gw reachable"
  else err "mgmt gateway ${gw:-?} NOT reachable"; rc=1; fi

  b=""
  local p
  for p in /sys/class/net/vmbr1/brif/bond*; do [[ -e $p ]] && { b="$(basename "$p")"; break; }; done
  if [[ -n $b && -f /proc/net/bonding/$b ]]; then
    local mode active slaves
    mode="$(awk -F': ' '/Bonding Mode/{print $2}' "/proc/net/bonding/$b")"
    active="$(awk -F': ' '/Currently Active Slave/{print $2}' "/proc/net/bonding/$b")"
    slaves="$(awk -F': ' '/Slave Interface/{s=$2} /MII Status/ && s{print s"="$2; s=""}' "/proc/net/bonding/$b" | xargs)"
    ok "$b: ${mode}  active=${active:-n/a}  ${slaves}"
    grep -q 'MII Status: down' "/proc/net/bonding/$b" && { warn "a $b slave is down"; }
    if [[ $mode == *802.3ad* ]]; then
      local lacp i
      for (( i = 0; i < 15; i++ )); do   # lacp-rate fast converges in ~3s
        lacp="$(lacp_state "/proc/net/bonding/$b")"
        [[ ${lacp%%|*} == ok ]] && break
        sleep 1
      done
      if [[ ${lacp%%|*} == ok ]]; then ok "LACP: ${lacp#*|}"
      else err "LACP: ${lacp#*|}"; rc=1; fi
    fi
  fi

  local i want="${HS_MTU}" line="" n2
  n2="$(split_nic2 "$IFACES")"
  if [[ -n $n2 ]]; then
    local bp="" f; for f in /sys/class/net/vmbr1/brif/*; do [[ -e $f ]] && bp+="$(basename "$f") "; done
    ok "split: vmbr1 on ${bp}, 2nd storage NIC ${n2} $(ip -4 -o addr show dev "$n2" | awk '{print $4}')"
    ip rule | gq -E '^10[12]:' && ok "policy routing rules 101/102 present" || { err "policy routing rules missing"; rc=1; }
  fi
  local bslaves=""; [[ -n $b && -r /sys/class/net/$b/bonding/slaves ]] && bslaves="$(cat "/sys/class/net/$b/bonding/slaves")"
  for i in $bslaves "$b" vmbr1 $n2; do
    [[ -n $i && -e /sys/class/net/$i ]] || continue
    local m; m="$(cat "/sys/class/net/$i/mtu")"
    line+="$i=$m "
    [[ $m == "$want" ]] || rc=1
  done
  [[ -n $line ]] && { (( rc )) && warn "MTU: $line(want $want)" || ok "MTU: $line"; }

  if [[ -n ${HS_TEST_IP}${PEER_HS_IP} ]]; then
    local t; t="$(ask "Jumbo ping target on the high-speed net (blank to skip)" "${PEER_HS_IP:-$HS_TEST_IP}")"
    if [[ -n $t ]]; then
      local src srcs=("")
      [[ -n $n2 ]] && srcs=("$(ip -4 -o addr show dev vmbr1 | awk '{print $4}' | cut -d/ -f1 | head -1)" \
                             "$(ip -4 -o addr show dev "$n2" | awk '{print $4}' | cut -d/ -f1 | head -1)")
      for src in "${srcs[@]}"; do
        [[ -z $src ]] && continue
        if ping -M "do" -s $((want - 28)) -c 3 -W 2 -I "$src" "$t" >/dev/null 2>&1; then ok "Jumbo ping from $src OK"
        else err "Jumbo ping from $src to $t FAILED"; rc=1; fi
      done
      (( ${#srcs[@]} > 1 )) && return $rc
      if ping -M "do" -s $((want - 28)) -c 3 -W 2 "$t" >/dev/null 2>&1; then
        ok "Jumbo ping ${want} to $t OK"
      elif ping -c 2 -W 2 "$t" >/dev/null 2>&1; then
        err "$t answers at 1500 but not at ${want}: switch port or far end is not jumbo"; rc=1
      else
        err "$t not reachable at all over vmbr1"; rc=1
      fi
    fi
  fi
  return $rc
}

# -----------------------------------------------------------------------------
# 5. cluster (join / create)
# -----------------------------------------------------------------------------
API_TICKET=""

# JSON helper: perl + JSON::PP ship with every PVE install (jq may not exist yet)
json() { perl -MJSON::PP -e "my \$d = eval { decode_json(join '', <STDIN>) } // {}; $1"; }

pve_api_login() { # pve_api_login <host> <password>
  local host="$1" pw="$2" out
  out="$(printf '%s' "$pw" | curl -sk --max-time 15 \
        --data-urlencode 'username=root@pam' --data-urlencode 'password@-' \
        "https://${host}:8006/api2/json/access/ticket" || true)"
  API_TICKET="$(json 'print $d->{data}{ticket} // ""' <<<"$out")"
  [[ -n $API_TICKET ]]
}

pve_api_get() { # pve_api_get <host> <path>
  curl -sk --max-time 15 -b "PVEAuthCookie=${API_TICKET}" "https://${1}:8006/api2/json${2}" || true
}

local_ip_of() { ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true; }

live_fingerprint() { # SHA256 fingerprint of the cert actually served on :8006
  openssl s_client -connect "${1}:8006" </dev/null 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr 'a-f' 'A-F' || true
}

wait_quorate() {
  local i
  for (( i = 0; i < 60; i++ )); do
    pvecm status 2>/dev/null | gq -E 'Quorate:[[:space:]]+Yes' && return 0
    sleep 2
  done
  return 1
}

show_cluster_health() {
  pvecm status 2>/dev/null | awk '/^Cluster information/,/^Membership information/' | grep -E 'Name|Nodes|Quorate|Transport' || true
  echo
  pvecm nodes 2>/dev/null || true
  echo
  corosync-cfgtool -n 2>/dev/null | sed 's/^/  /' || true
}

# local checks that must pass before this node joins anything
cluster_local_preflight() {
  local rc=0 h hip mgmt guests
  h="$(hostname)"
  mgmt="$(local_ip_of vmbr0)"
  guests="$(find /etc/pve/qemu-server/ /etc/pve/lxc/ -maxdepth 1 -name '*.conf' -printf '%f ' 2>/dev/null || true)"
  if [[ -n $guests ]]; then
    err "This node has guests (${guests}). A joining node must be empty: back up/move them first."; rc=1
  else ok "No VMs/CTs on this node"; fi

  hip="$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  if [[ $hip == "$mgmt" ]]; then ok "Hostname $h resolves to mgmt IP $mgmt"
  else err "Hostname $h resolves to '${hip:-nothing}', not vmbr0 $mgmt. Fix /etc/hosts."; rc=1; fi

  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == yes ]]; then ok "Clock NTP-synchronized"
  else warn "Clock is not NTP-synchronized (chronyc sources). Corosync and certs dislike skew."; fi
  return $rc
}

local_has_ip() { ip -4 -o addr 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | gq -x "$1"; }

# Cluster work is split in two: a PLAN phase that runs first (asks what you
# want, logs in to the peer, learns its network so vmbr1 is built to match),
# and an EXEC phase that runs after the network stage (link checks + join).
CL_ACTION="" CL_PEER="" CL_PW="" CL_NAME="" CL_LINKS="" CL_PEER_FP="" CL_PEER_NODE=""
CL_NODES=()
PEER_HS_NET3="" PEER_HS_CIDR="" PEER_HS_MTU="" PEER_HS_IP=""

cluster_fetch() { # (re)load cluster facts from the peer; needs API_TICKET
  local out
  out="$(pve_api_get "$CL_PEER" /cluster/config/join)"
  CL_NAME="$(json 'print $d->{data}{totem}{cluster_name} // ""' <<<"$out")"
  [[ -n $CL_NAME ]] || die "${CL_PEER} is not part of a cluster. Run this script there with 'create' first."
  CL_LINKS="$(json 'my $i = $d->{data}{totem}{interface} // {}; my @k = sort keys %$i; @k = (0) unless @k; print join(" ", @k)' <<<"$out")"
  mapfile -t CL_NODES < <(json 'for my $n (@{$d->{data}{nodelist} // []}) {
      print join("|", $n->{name}, $n->{pve_addr} // "", $n->{pve_fp} // "",
                 $n->{ring0_addr} // "", $n->{ring1_addr} // ""), "\n" }' <<<"$out")
  local line n a f r0 r1
  CL_PEER_FP="" CL_PEER_NODE=""
  for line in "${CL_NODES[@]}"; do
    IFS='|' read -r n a f r0 r1 <<<"$line"
    if [[ $a == "$CL_PEER" || $r0 == "$CL_PEER" ]]; then CL_PEER_FP="$f"; CL_PEER_NODE="$n"; PEER_HS_IP="$r1"; fi
  done
  if [[ -z $CL_PEER_NODE ]]; then
    CL_PEER_NODE="$(json 'print $d->{data}{preferred_node} // ""' <<<"$out")"
    CL_PEER_FP="$(json 'my $p = $d->{data}{preferred_node}; for (@{$d->{data}{nodelist} // []}) { print $_->{pve_fp} if $_->{name} eq $p }' <<<"$out")"
  fi
}

cluster_peer_network() { # learn the peer's high-speed subnet/MTU from its own config
  local net hit
  [[ -n $CL_PEER_NODE ]] || return 0
  net="$(pve_api_get "$CL_PEER" "/nodes/${CL_PEER_NODE}/network")"
  # prefer the iface holding the peer's link1 address, else its vmbr1
  hit="$(PEER_IP="$PEER_HS_IP" json '
      my @l = @{$d->{data} // []}; my ($h) = grep { ($_->{address} // "") eq $ENV{PEER_IP} && $ENV{PEER_IP} ne "" } @l;
      ($h) = grep { $_->{iface} eq "vmbr1" } @l unless $h;
      print join("|", $h->{iface}, $h->{cidr} // "", $h->{mtu} // "") if $h' <<<"$net")"
  [[ -n $hit ]] || return 0
  local iface cidr mtu
  IFS='|' read -r iface cidr mtu <<<"$hit"
  if valid_cidr "$cidr"; then
    PEER_HS_NET3="$(cut -d. -f1-3 <<<"${cidr%/*}")"
    PEER_HS_CIDR="${cidr#*/}"
    [[ -z $PEER_HS_IP ]] && PEER_HS_IP="${cidr%/*}"
  fi
  PEER_HS_MTU="${mtu:-1500}"
  ok "Peer high-speed net: ${iface} ${cidr} mtu ${PEER_HS_MTU} (vmbr1 here will match)"
}

cluster_print() {
  local line n a f r0 r1
  printf '  %-18s %-16s %-16s %s\n' NODE MGMT LINK0 LINK1
  for line in "${CL_NODES[@]}"; do
    IFS='|' read -r n a f r0 r1 <<<"$line"
    printf '  %-18s %-16s %-16s %s\n' "$n" "$a" "${r0:--}" "${r1:--}"
  done
  echo "  corosync links in use: ${CL_LINKS}"
  echo
}

cluster_check_version() { # 0 ok/warn, 1 fatal
  local peer_ver local_ver
  peer_ver="$(pve_api_get "$CL_PEER" /version | json 'print $d->{data}{version} // ""')"
  local_ver="$(pveversion | grep -oE 'pve-manager/[0-9.]+' | cut -d/ -f2)"
  if [[ ${peer_ver%%.*} != "${local_ver%%.*}" ]]; then
    err "Major version mismatch: cluster ${peer_ver}, this node ${local_ver}."; return 1
  elif [[ $peer_ver != "$local_ver" ]]; then
    warn "Version differs (cluster ${peer_ver}, this node ${local_ver})."
    (( DO_UPGRADE )) && warn "The upgrade stage runs before the join and should close the gap."
  else ok "PVE version matches (${local_ver})"; fi
  return 0
}

cluster_join_plan() {
  local rc=0
  CL_PEER="${CLUSTER_PEER:-$(ask "IP of an existing cluster node" "")}"
  valid_ip "$CL_PEER" || die "Need the IP of a cluster node (got '${CL_PEER}')."
  ping -c 2 -W 2 "$CL_PEER" >/dev/null 2>&1 || die "$CL_PEER does not answer ping."
  CL_PW="$CLUSTER_PASSWORD"
  if [[ -z $CL_PW ]]; then
    read -r -s -p "root@pam password for ${CL_PEER}: " CL_PW </dev/tty || true
    echo >&2
  fi
  [[ -n $CL_PW ]] || die "No password given."
  pve_api_login "$CL_PEER" "$CL_PW" || die "Login to https://${CL_PEER}:8006 failed (wrong password, or API not reachable)."
  ok "Authenticated to ${CL_PEER} API as root@pam"
  cluster_fetch

  hdr "Cluster '${CL_NAME}' via ${CL_PEER}"
  cluster_print

  # everything that doesn't depend on this node's network: fail fast, before
  # we touch repos, packages or interfaces
  local quorate
  quorate="$(pve_api_get "$CL_PEER" /cluster/status | json 'for (@{$d->{data} // []}) { print $_->{quorate} // 0 if $_->{type} eq "cluster" }')"
  [[ $quorate == 1 ]] && ok "Cluster is quorate" || { err "Cluster is NOT quorate; joins will fail."; rc=1; }

  local me line n a f r0 r1 live_fp
  me="$(hostname)"
  for line in "${CL_NODES[@]}"; do
    IFS='|' read -r n a f r0 r1 <<<"$line"
    if [[ $n == "$me" ]]; then
      err "A node named '${me}' already exists in the cluster (old install?)."
      err "On a cluster node run: pvecm delnode ${me}   (and rm -rf /etc/pve/nodes/${me})"; rc=1
    fi
  done
  live_fp="$(live_fingerprint "$CL_PEER")"
  if [[ -n $CL_PEER_FP && $live_fp == "$CL_PEER_FP" ]]; then ok "Peer cert fingerprint verified (${CL_PEER_FP:0:23}...)"
  else err "Fingerprint mismatch: API says '${CL_PEER_FP:-?}', port 8006 serves '${live_fp:-?}'."; rc=1; fi

  cluster_check_version || rc=1
  cluster_local_preflight || rc=1

  local cl_st lost=() s
  cl_st="$(pve_api_get "$CL_PEER" /storage | json 'print "$_->{storage}\n" for @{$d->{data} // []}')"
  for s in $(awk '/^[a-z]+: /{print $2}' /etc/pve/storage.cfg 2>/dev/null); do
    grep -qx "$s" <<<"$cl_st" || lost+=("$s")
  done
  if (( ${#lost[@]} )); then
    warn "Local storage definitions not in the cluster config will vanish on join: ${lost[*]}"
    warn "(data stays on disk; re-add them afterwards with pvesm add ...)"
  fi

  if [[ " $CL_LINKS " == *" 1 "* ]]; then
    cluster_peer_network
    [[ -n $PEER_HS_NET3 ]] || warn "Couldn't read the peer's link1 network; you'll be asked for vmbr1 manually."
  fi

  (( rc )) && { CL_PW=""; die "Join preflight failed before any changes were made. Fix the items above and rerun."; }
  ok "Pre-join checks passed. Network stage next, then the link checks and the join."
}

cluster_join_exec() {
  local rc=0 me line n a f r0 r1
  me="$(hostname)"
  # ticket may have aged out during a long upgrade; log in again and refresh
  pve_api_login "$CL_PEER" "$CL_PW" || die "Re-login to ${CL_PEER} failed."
  cluster_fetch
  cluster_check_version || rc=1

  local l0 l1="" want1=0
  [[ " $CL_LINKS " == *" 1 "* ]] && want1=1
  l0="${CLUSTER_LINK0:-$(ask "corosync link0 address for this node (mgmt)" "$(local_ip_of vmbr0)")}"
  valid_ip "$l0" || die "Bad link0: $l0"
  if (( want1 )); then
    local d1; d1="$(local_ip_of vmbr1)"; [[ -z $d1 && -n $VMBR1_ADDR ]] && d1="${VMBR1_ADDR%/*}"
    l1="${CLUSTER_LINK1:-$(ask "corosync link1 address for this node (high-speed)" "$d1")}"
    valid_ip "$l1" || die "Cluster uses link1, so this node needs one too (got '${l1}')."
  elif [[ -n $(local_ip_of vmbr1) ]]; then
    warn "Cluster only uses link0. vmbr1 won't carry corosync; adding link1 means editing corosync.conf cluster-wide."
  fi

  # address sanity: ours must be local and must not collide with a member
  local lk ip
  for lk in "0:$l0" "1:$l1"; do
    ip="${lk#*:}"; [[ -n $ip ]] || continue
    for line in "${CL_NODES[@]}"; do
      IFS='|' read -r n a f r0 r1 <<<"$line"
      [[ $ip == "$r0" || $ip == "$r1" || $ip == "$a" ]] && { err "link${lk%%:*} ${ip} is already used by ${n}"; rc=1; }
    done
    if ! local_has_ip "$ip"; then
      if (( DRY_RUN )); then warn "link${lk%%:*} ${ip} isn't configured here yet (dry run); reachability check skipped"
      else err "link${lk%%:*} ${ip} is not configured on any interface here"; rc=1; fi
    fi
  done

  for line in "${CL_NODES[@]}"; do
    IFS='|' read -r n a f r0 r1 <<<"$line"
    if [[ -n $r0 ]] && local_has_ip "$l0"; then
      ping -c 2 -W 1 "$r0" >/dev/null 2>&1 && ok "link0 -> $n ($r0)" || { err "link0: cannot reach $n at $r0"; rc=1; }
    fi
    if (( want1 )) && [[ -n $r1 ]] && local_has_ip "$l1"; then
      ping -c 2 -W 1 "$r1" >/dev/null 2>&1 && ok "link1 -> $n ($r1)" || { err "link1: cannot reach $n at $r1"; rc=1; }
    fi
  done

  (( rc )) && { CL_PW=""; die "Join checks failed; fix the items above and rerun with --cluster-only."; }
  info "Plan: join '${CL_NAME}' via ${CL_PEER}, link0=${l0}${l1:+, link1=${l1}}"
  if (( DRY_RUN )); then CL_PW=""; ok "Dry run: join checks passed. Nothing changed."; summ skip "Cluster" "would join '${CL_NAME}' via ${CL_PEER}"; return 0; fi
  confirm "Join this node to cluster '${CL_NAME}' now?" n || { CL_PW=""; return 0; }

  # same API call the GUI's Join button makes
  # NB: the password is briefly visible in this host's process list during the call.
  local args=(--hostname "$CL_PEER" --fingerprint "$CL_PEER_FP" --password "$CL_PW" --link0 "$l0")
  [[ -n $l1 ]] && args+=(--link1 "$l1")
  info "Joining (pmxcfs restarts; the web UI on this node will reload)"
  local out
  out="$(pvesh create /cluster/config/join "${args[@]}" 2>&1)" || { CL_PW=""; err "$out"; die "Join failed."; }
  CL_PW=""; unset args
  if [[ $out =~ (UPID:[^[:space:]]+) ]]; then
    local upid="${BASH_REMATCH[1]}" st="" i
    for (( i = 0; i < 150; i++ )); do
      st="$(pvesh get "/nodes/${me}/tasks/${upid}/status" --output-format json 2>/dev/null | json 'print $d->{status} // ""' || true)"
      [[ $st == stopped ]] && break
      sleep 2
    done
    pvesh get "/nodes/${me}/tasks/${upid}/log" --limit 1000 --output-format json 2>/dev/null \
      | json 'print "  $_->{t}\n" for @$d' || true
  else
    printf '%s\n' "$out" | sed 's/^/  /'
  fi

  wait_quorate || die "Joined, but not quorate after 2 min. Check: pvecm status / journalctl -u corosync"
  CLUSTERED=1
  ok "Joined cluster '${CL_NAME}'"
  summ ok "Cluster" "joined '${CL_NAME}' via ${CL_PEER} (link0 ${l0}${l1:+, link1 ${l1}})"
  show_cluster_health
}

cluster_create_plan() {
  CL_NAME="${CLUSTER_NAME:-$(ask "New cluster name (permanent, max 15 chars)" "$(hostname | sed -E 's/[0-9]+$//; s/-$//')")}"
  [[ $CL_NAME =~ ^[A-Za-z0-9-]{1,15}$ ]] || die "Cluster name must be 1-15 chars [A-Za-z0-9-]."
  ok "Will create cluster '${CL_NAME}' after the network stage (link0=vmbr0, link1=vmbr1)"
}

cluster_create_exec() {
  local l0 l1 d1
  d1="$(local_ip_of vmbr1)"; [[ -z $d1 && -n $VMBR1_ADDR ]] && d1="${VMBR1_ADDR%/*}"
  l0="${CLUSTER_LINK0:-$(ask "corosync link0 address (mgmt)" "$(local_ip_of vmbr0)")}"
  l1="${CLUSTER_LINK1:-$(ask "corosync link1 address (high-speed, blank for none)" "$d1")}"
  valid_ip "$l0" || die "Bad link0: $l0"
  [[ -z $l1 ]] || valid_ip "$l1" || die "Bad link1: $l1"
  [[ -z $l1 ]] && warn "Single corosync link. Adding link1 later means editing corosync.conf on every node."
  if (( ! DRY_RUN )); then
    local_has_ip "$l0" || die "link0 ${l0} is not configured on any interface here."
    [[ -z $l1 ]] || local_has_ip "$l1" || die "link1 ${l1} is not configured on any interface here."
  fi
  info "Plan: pvecm create ${CL_NAME} --link0 ${l0}${l1:+ --link1 ${l1}}"
  if (( DRY_RUN )); then info "Dry run: not creating."; return 0; fi
  confirm "Create cluster '${CL_NAME}' on this node?" n || return 0
  if [[ -n $l1 ]]; then pvecm create "$CL_NAME" --link0 "$l0" --link1 "$l1"
  else pvecm create "$CL_NAME" --link0 "$l0"; fi
  wait_quorate || die "Cluster created but not quorate after 2 min. Check: pvecm status"
  CLUSTERED=1
  ok "Cluster '${CL_NAME}' created"
  summ ok "Cluster" "created '${CL_NAME}' (link0 ${l0}${l1:+, link1 ${l1}})"
  show_cluster_health
}

cluster_plan() {
  stage "Cluster plan"
  if (( CLUSTERED )); then CL_ACTION=member; ok "Already a cluster member"; summ ok "Cluster" "already a member"; return 0; fi
  CL_ACTION="${CLUSTER_ACTION:-$(ask "Cluster: skip, join an existing cluster, or create a new one? (skip/join/create)" "skip")}"
  case "$CL_ACTION" in
    skip|"") CL_ACTION=skip; ok "Staying standalone"; summ skip "Cluster" "standalone" ;;
    join)   cluster_join_plan ;;
    create) cluster_create_plan ;;
    *) die "Cluster action must be skip, join or create." ;;
  esac
}

cluster_exec() {
  stage "Cluster"
  case "$CL_ACTION" in
    member) show_cluster_health ;;
    join)   cluster_join_exec ;;
    create) cluster_create_exec ;;
    *)      ok "Standalone (no cluster changes)" ;;
  esac
}

# -----------------------------------------------------------------------------
# 7. NFS storage
# -----------------------------------------------------------------------------
setup_storage() {
  stage "NFS storage"
  if [[ $CL_ACTION == join || $CL_ACTION == member ]]; then
    ok "Cluster member: storage comes from the cluster's storage.cfg"
    vast_sync
    summ ok "Storage" "inherited from cluster: $(pvesm status 2>/dev/null | awk 'NR>1{printf "%s ", $1}')"
    pvesm status 2>/dev/null | sed 's/^/  /' || true
    return 0
  fi
  local layout
  layout="${STORAGE_LAYOUT:-$(ask "NFS storage: vast (multi-datastore on DNS prefixes), single, or skip?" "skip")}"
  case "$layout" in
    vast)   setup_storage_vast ;;
    single) setup_storage_single ;;
    *)      ok "No storage added"; summ skip "Storage" "none added" ;;
  esac
}

storage_exists() { pvesm status 2>/dev/null | awk 'NR>1{print $1}' | gq -x "$1"; }

# test_nfs <server> <export> <opts> : mount, root write, unmount
test_nfs() {
  local mp rc=0; mp="$(mktemp -d /mnt/pveb-nfstest.XXXX)"
  if mount -t nfs -o "$3" "$1:$2" "$mp" 2>>"$LOG"; then
    touch "$mp/.pveb-write-test" 2>>"$LOG" && rm -f "$mp/.pveb-write-test" || rc=2
    umount "$mp" 2>/dev/null || true
  else
    rc=1
  fi
  rmdir "$mp" 2>/dev/null || true
  return $rc
}

# hs_link_speed : fastest current link speed (Mb/s) under vmbr1, 0 if unknown
hs_link_speed() {
  local p s top=0 sl
  [[ -d /sys/class/net/vmbr1/brif ]] || { echo 0; return; }
  for p in /sys/class/net/vmbr1/brif/*; do
    p="$(basename "$p")"
    if [[ -f /sys/class/net/$p/bonding/slaves ]]; then sl="$(cat "/sys/class/net/$p/bonding/slaves")"; else sl="$p"; fi
    for s in $sl; do
      local v; v="$(cat "/sys/class/net/$s/speed" 2>/dev/null || echo 0)"
      [[ $v =~ ^[0-9]+$ ]] && (( v > top )) && top="$v"
    done
  done
  echo "$top"
}

# nconnect_for <Mb/s> : per-mount TCP connections. 12 at >=100G: divides evenly
# over 6 VIPs x 1 or 2 local NICs with vastnfs, and is plenty for the stock client.
nconnect_for() {
  local s="$1"
  if (( s >= 100000 )); then echo 12
  else echo 4; fi
}

vast_sync() { # refresh vastnfs mount options for VAST storages, if vastnfs is on
  [[ -x $VASTNFS_HELPER ]] || return 0
  "$VASTNFS_HELPER" sync --remount 2>&1 | sed 's/^  > /  /' || true
}

setup_storage_single() {
  local id server nfs_export content opts
  id="$(ask "Storage ID" "vast-ds1")"
  storage_exists "$id" && { ok "Storage '$id' already defined (cluster-wide config); skipping."; return 0; }
  server="$(ask "NFS server (FQDN or VIP)" "")"
  [[ -n $server ]] || { warn "No server given; skipping."; return 0; }
  nfs_export="$(ask "Export path" "/proxmox/ds-1")"
  content="$(ask "Content types" "images,iso,vztmpl,backup")"
  opts="$(ask "Mount options" "vers=3,nconnect=${NFS_NCONNECT:-$(nconnect_for "$(hs_link_speed)")},hard,proto=tcp")"
  info "Test-mounting ${server}:${nfs_export}"
  test_nfs "$server" "$nfs_export" "$opts" || die "Test mount/write failed (check export rules / root squash)."
  ok "Mount + root write OK"
  pvesm add nfs "$id" --server "$server" --export "$nfs_export" --content "$content" --options "$opts"
  sleep 2
  pvesm status | awk -v id="$id" 'NR==1 || $1==id'
  ok "Storage $id added"
  summ ok "Storage" "${id} -> ${server}:${nfs_export}"
}

# VAST layout: <prefix>-ds1..N (images), <prefix>-iso, <prefix>-dump.
# Each mounts <name>.<pool-fqdn>; VAST DNS answers every prefix with its own VIP,
# so simultaneous mounts (boot) land on different CNode ports instead of one.
setup_storage_vast() {
  local pool base count pfx speed nc
  if [[ -z ${VAST_POOL_FQDN:-} && -r $VAST_CLUSTER_CONF ]]; then
    VAST_POOL_FQDN="$(awk -F= '$1=="POOL_FQDN"{print $2}' "$VAST_CLUSTER_CONF" | tr -d '"')"
  fi
  pool="${VAST_POOL_FQDN:-$(ask "VAST VIP pool FQDN (VAST DNS must be delegated)" "")}"
  [[ -n $pool ]] || { warn "No VIP pool FQDN; skipping."; summ skip "Storage" "no VIP pool given"; return 0; }
  base="${VAST_EXPORT_BASE:-$(ask "View parent path on VAST" "/proxmox/datastores/${CL_NAME:-$(hostname -s)}")}"
  count="${VAST_DS_COUNT}"
  (( ASSUME_YES )) || count="$(ask "Number of image datastores (views ${base}/ds1..dsN must exist)" "$count")"
  [[ $count =~ ^[0-9]+$ ]] && (( count >= 1 && count <= 16 )) || die "Datastore count must be 1-16."
  pfx="${VAST_ID_PREFIX}"
  speed="$(hs_link_speed)"
  nc="${NFS_NCONNECT:-$(nconnect_for "$speed")}"
  info "vmbr1 link $(speed_h "$speed"): nconnect=${nc}"

  # name|export|content|nconnect
  local import=""
  (( PVE_MAJOR >= 9 || (PVE_MAJOR == 8 && PVE_MINOR >= 2) )) && import=",import"
  local plan=() i
  for (( i = 1; i <= count; i++ )); do plan+=("ds${i}|${base}/ds${i}|images,rootdir|${nc}"); done
  plan+=("iso|${base}/iso|iso,vztmpl,snippets${import}|4")
  plan+=("dump|${base}/dump|backup|$(( nc > 8 ? 8 : nc ))")

  # DNS: every prefix must resolve, and the answers should spread
  hdr "VAST DNS check (<prefix>.${pool})"
  local p name ip ips=() bad=0
  for p in "${plan[@]}"; do
    name="${p%%|*}"
    ip="$(getent ahostsv4 "${name}.${pool}" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    if [[ -z $ip ]]; then err "${name}.${pool} does not resolve"; bad=1; continue; fi
    printf '    %-6s -> %s\n' "$name" "$ip"
    in_list "$ip" "${ips[@]}" || ips+=("$ip")
  done
  (( bad )) && die "DNS prefixes don't resolve. Check the VAST DNS delegation for ${pool#*.}."
  if (( ${#ips[@]} == 1 && ${#plan[@]} > 1 )); then
    warn "Every prefix resolved to ${ips[0]}. That's not VAST DNS (or a caching resolver is pinning it);"
    warn "all storages would share one VIP. Fix DNS before relying on this layout."
    confirm "Continue anyway?" n || { summ warn "Storage" "aborted: no DNS spread"; return 0; }
  else
    ok "${#plan[@]} prefixes -> ${#ips[@]} distinct VIPs"
  fi

  hdr "Planned storages (server = <prefix>.${pool})"
  local id ex ct n
  printf '    %s%-12s %-6s %-36s %-28s %s%s\n' "$C_D" ID PREFIX EXPORT CONTENT NCONNECT "$C_0"
  for p in "${plan[@]}"; do
    IFS='|' read -r name ex ct n <<<"$p"
    printf '    %-12s %-6s %-36s %-28s %s\n' "${pfx}-${name}" "$name" "$ex" "$ct" "$n"
  done
  echo
  (( DRY_RUN )) && { info "Dry run: not adding."; return 0; }
  confirm "Test-mount and add these storages?" y || return 0

  local added=() skipped=() failed=()
  for p in "${plan[@]}"; do
    IFS='|' read -r name ex ct n <<<"$p"
    id="${pfx}-${name}"
    if storage_exists "$id"; then skipped+=("$id"); continue; fi
    local opts="vers=3,nconnect=${n}"
    if ! test_nfs "${name}.${pool}" "$ex" "$opts"; then
      err "${id}: mount/write of ${ex} failed (view missing, policy, or root squash?)"; failed+=("$id"); continue
    fi
    if pvesm add nfs "$id" --server "${name}.${pool}" --export "$ex" --content "$ct" --options "$opts" >>"$LOG" 2>&1; then
      added+=("$id"); ok "added ${id}"
    else
      err "pvesm add ${id} failed (see $LOG)"; failed+=("$id")
    fi
  done
  (( ${#skipped[@]} )) && info "Already defined, left alone: ${skipped[*]}"
  vast_sync
  sleep 3
  verify_storage_spread "$pfx"
  if (( ${#failed[@]} )); then
    summ warn "Storage" "added ${#added[@]}, failed: ${failed[*]}"
  else
    summ ok "Storage" "VAST layout: ${#added[@]} added on ${pool} (${#ips[@]} VIPs, nconnect ${nc})"
  fi
}

# verify_storage_spread <prefix> : which VIP each mounted storage actually uses
verify_storage_spread() {
  local m a c seen=() dup=0
  hdr "Mounted storages"
  while read -r m; do
    a="$(grep " ${m} " /proc/mounts | grep -oE 'addr=[0-9.]+' | head -1 | cut -d= -f2)"
    c="$(grep " ${m} " /proc/mounts | grep -oE 'nconnect=[0-9]+' | head -1 | cut -d= -f2)"
    printf '    %-26s %-16s nconnect=%s\n' "$m" "${a:-?}" "${c:-1}"
    if [[ -n $a ]] && in_list "$a" "${seen[@]}"; then dup=1; fi
    [[ -n $a ]] && seen+=("$a")
  done < <(awk -v p="/mnt/pve/$1-" 'index($2, p) == 1 {print $2}' /proc/mounts)
  (( dup )) && info "Some storages share a VIP; fine when there are more storages than VIPs."
  return 0
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
usage() { awk 'NR > 2 && /^# =+$/ { exit } NR > 2' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || echo "see header"; }

main() {
  while (( $# )); do
    case "$1" in
      -y|--yes) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1; DO_REPOS=0 DO_NAG=0 DO_UPGRADE=0 DO_HA=0 DO_STORAGE=0 ;;
      --network-only) DO_REPOS=0 DO_NAG=0 DO_UPGRADE=0 DO_HA=0 DO_CLUSTER=0 DO_STORAGE=0 DO_VASTNFS=0 ;;
      --cluster-only) DO_REPOS=0 DO_NAG=0 DO_UPGRADE=0 DO_HA=0 DO_NETWORK=0 DO_STORAGE=0 DO_VASTNFS=0 ;;
      --skip-repos) DO_REPOS=0; DO_NAG=0 ;;
      --skip-upgrade) DO_UPGRADE=0 ;;
      --skip-network) DO_NETWORK=0 ;;
      --skip-cluster) DO_CLUSTER=0 ;;
      --skip-storage) DO_STORAGE=0 ;;
      --skip-vastnfs) DO_VASTNFS=0 ;;
      --vastnfs) RETROFIT=1; DO_REPOS=0 DO_NAG=0 DO_UPGRADE=0 DO_HA=0 DO_CLUSTER=0 DO_STORAGE=0
                 DO_VASTNFS=1 DO_NETWORK=1; VASTNFS="${VASTNFS:-yes}" ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done

  trap '(( IS_TTY )) && printf "\e[?25h"' EXIT
  local t_start=$SECONDS
  banner
  preflight
  mkdir -p "$BACKUP_DIR"
  STAGE_TOTAL=$(( RETROFIT + DO_CLUSTER * 2 + DO_REPOS + DO_NAG + DO_UPGRADE + DO_VASTNFS + DO_NETWORK + DO_HA + DO_STORAGE ))

  (( RETROFIT ))   && retrofit_prep   # --vastnfs on an existing node
  (( DO_CLUSTER )) && cluster_plan    # first: learn the peer before touching anything
  (( DO_REPOS ))   && setup_repos
  (( DO_NAG ))     && remove_nag
  (( DO_UPGRADE )) && upgrade_and_tools
  (( DO_VASTNFS )) && setup_vastnfs   # before network: decides whether split mode is offered
  (( DO_NETWORK )) && setup_network
  (( DO_CLUSTER )) && cluster_exec
  (( DO_HA ))      && setup_ha        # after cluster: never offered on members
  (( DO_STORAGE )) && setup_storage   # after join: cluster storage is inherited

  local foot
  if (( DRY_RUN )); then foot="dry run complete in $(dur $((SECONDS - t_start))); nothing was changed"; rmdir "$BACKUP_DIR" 2>/dev/null || true
  else foot="done in $(dur $((SECONDS - t_start)))  ${S_INFO} backups: ${BACKUP_DIR}  ${S_INFO} log: ${LOG}"; fi
  print_summary "$foot"
  if (( RETROFIT && ! DRY_RUN && ! NEED_REBOOT )) && [[ -x $VASTNFS_HELPER ]]; then
    info "vastnfs already loaded: applying mount options now (remounts VAST storages not in use)"
    "$VASTNFS_HELPER" sync --remount || warn "sync failed; run: ${VASTNFS_HELPER} sync --remount"
  fi
  if (( NEED_REBOOT )) || { (( DO_UPGRADE )) && kernel_changed; }; then
    (( NEED_REBOOT )) && warn "vastnfs needs a reboot to load (mount options are applied at boot)."
    (( DO_UPGRADE )) && kernel_changed && warn "A new kernel was installed."
    if confirm "Reboot now?" n; then safe_reboot; fi
  fi
}

# run main unless sourced (tests source this file for the pure functions)
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
