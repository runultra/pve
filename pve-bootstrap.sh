#!/usr/bin/env bash
# =============================================================================
# pve-bootstrap.sh : post-install setup for Proxmox VE lab hosts
#
#   1. APT repos       disable enterprise, enable no-subscription (PVE + Ceph)
#   2. Sub nag         remove the "No valid subscription" popup (survives updates)
#   3. Packages        dist-upgrade + tools (ethtool, iperf3, lldpd, nfs-common...)
#   4. Network         vmbr0 (mgmt) + vmbr1 (high-speed) on an active-backup
#                      bond at MTU 9000, auto-detected NICs, dead-man rollback
#   5. Cluster         join an existing cluster or create one; corosync
#                      link0 = vmbr0, link1 = vmbr1, with full preflight checks.
#                      The choice is asked FIRST: for a join, the script logs in
#                      to the peer up front, runs every check that doesn't need
#                      this node's network, and builds vmbr1 on the cluster's
#                      own high-speed subnet/MTU. The join itself runs last.
#   6. HA services     optionally disable on standalone hosts
#   7. Storage         optionally add an NFS datastore (VAST defaults)
#
# Usage:
#   bash -c "$(curl -fsSL <raw-url>/pve-bootstrap.sh)"
#   ./pve-bootstrap.sh [--dry-run] [--network-only] [--cluster-only]
#                      [--skip-repos] [--skip-upgrade] [--skip-network]
#                      [--skip-cluster] [--skip-storage] [-y]
#
#   --dry-run       Show the planned network diff and run every cluster-join
#                   check against the peer. Changes nothing.
#   --network-only  Run only the network stage.
#   --cluster-only  Run only the cluster stage.
#   -y              Accept defaults for every prompt (non-interactive).
#
# Environment overrides (handy for -y / Ansible):
#   HS_NICS="nic5 nic6"   high-speed NICs for vmbr1 (default: auto-detect)
#   HS_BOND=bond0         bond name
#   HS_MODE=active-backup bond mode (active-backup | 802.3ad)
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
# =============================================================================
set -Eeuo pipefail
trap 'printf "\n[xx] unexpected failure at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

VERSION="1.3.0"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/pve-bootstrap-backup/${TS}"
IFACES="/etc/network/interfaces"
ROLLBACK_UNIT="pveb-net-rollback"

HS_NICS="${HS_NICS:-}"
HS_BOND="${HS_BOND:-bond0}"
HS_MODE="${HS_MODE:-active-backup}"
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

ASSUME_YES=0
DRY_RUN=0
DO_REPOS=1 DO_NAG=1 DO_UPGRADE=1 DO_HA=1 DO_NETWORK=1 DO_CLUSTER=1 DO_STORAGE=1

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
ask() { # ask "Prompt" "default" -> echoes answer
  local prompt="$1" def="${2-}" ans
  if (( ASSUME_YES )); then printf '%s\n' "$def"; return; fi
  read -r -p "  ${C_B}${S_Q}${C_0} ${prompt} ${C_D}[${def}]${C_0} " ans </dev/tty || true
  printf '%s\n' "${ans:-$def}"
}
confirm() { # confirm "Prompt" y|n
  local prompt="$1" def="${2:-n}" ans hint
  [[ $def == y ]] && hint="Y/n" || hint="y/N"
  if (( ASSUME_YES )); then [[ $def == y ]]; return; fi
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
TOOLS=(ethtool iperf3 lldpd nfs-common jq htop tmux curl vim-nox)
KERNEL_BEFORE=""
upgrade_and_tools() {
  stage "Packages"
  KERNEL_BEFORE="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 || true)"
  spin "Refreshing package lists" apt-get update -q || die "apt-get update failed (check repos above)."
  local upgr; upgr="$(apt-get -s dist-upgrade 2>/dev/null | grep -c '^Inst ' || true)"
  info "${upgr} package(s) can be upgraded"
  if (( upgr > 0 )) && confirm "Run dist-upgrade now?" y; then
    spin "Upgrading ${upgr} packages" env DEBIAN_FRONTEND=noninteractive apt-get -y -q \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade \
      || die "dist-upgrade failed."
    summ ok "Packages" "upgraded ${upgr} packages, now PVE $(pveversion | grep -oE 'pve-manager/[0-9.]+' | cut -d/ -f2)"
  else
    summ skip "Packages" "no upgrade run"
  fi
  spin "Installing tools (${TOOLS[*]})" env DEBIAN_FRONTEND=noninteractive apt-get -y -q install "${TOOLS[@]}" \
    || warn "Some tools failed to install."
  systemctl enable -q --now lldpd 2>/dev/null || true
  info "lldpd is on: 'lldpctl' shows which switch port each NIC is plugged into"
}

kernel_changed() {
  [[ -n $KERNEL_BEFORE && "$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)" != "$KERNEL_BEFORE" ]]
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

LINK_PROBE_SECS="${LINK_PROBE_SECS:-12}"
# Fresh installs leave unused NICs admin-down, so carrier is unreadable.
# Bring idle (down, unenslaved) NICs up briefly to see which ones are cabled.
probe_links() {
  local n d probed=() i all
  for n in "$@"; do
    d="/sys/class/net/$n"
    [[ -e $d/master ]] && continue
    ip -o link show "$n" | grep -q '<[^>]*\bUP\b' && continue
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
    NIC_LLDP[$n]=""
    if command -v lldpctl >/dev/null; then
      NIC_LLDP[$n]="$(lldpctl -f keyvalue "$n" 2>/dev/null | awk -F= '
        /chassis.name=/{s=$2} /port.descr=/{p=$2} /port.ifname=/{p=$2}
        END{ if(s!="") printf "%s %s", s, p }' || true)"
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
  printf '%s\n' "${out[*]}"
}

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
      declared_ifaces "$tmp" | grep -qx "$n" || printf '\niface %s inet manual\n' "$n"
    done
    echo
    for n in "${hs[@]}"; do
      printf 'auto %s\niface %s inet manual\n\tmtu %s\n\n' "$n" "$n" "$HS_MTU"
    done
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

cancel_rollback() { systemctl stop "${ROLLBACK_UNIT}.timer" 2>/dev/null || true; systemctl reset-failed "${ROLLBACK_UNIT}" 2>/dev/null || true; }

setup_network() {
  stage "Network"
  command -v ifreload >/dev/null || die "ifupdown2 (ifreload) not installed."
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

  HS_MODE="$(ask "Bond mode (active-backup needs no switch config; 802.3ad needs LACP/MLAG)" "$HS_MODE")"
  [[ $HS_MODE == active-backup || $HS_MODE == 802.3ad ]] || die "Bond mode must be active-backup or 802.3ad."
  if [[ -n $PEER_HS_MTU && $PEER_HS_MTU != "$HS_MTU" ]]; then
    warn "Cluster peer runs its high-speed net at MTU ${PEER_HS_MTU}; defaulting to that."
    HS_MTU="$PEER_HS_MTU"
  fi
  HS_MTU="$(ask "MTU for vmbr1 path" "$HS_MTU")"
  [[ $HS_MTU =~ ^[0-9]+$ ]] && (( HS_MTU >= 1280 && HS_MTU <= 9216 )) || die "Bad MTU: $HS_MTU"

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
    summ skip "Network" "planned: vmbr1 ${VMBR1_ADDR} on ${HS_BOND}(${HS_NICS}) mtu ${HS_MTU}"
    return 0
  fi
  confirm "Apply this network config?" n || { info "Not applied. Candidate at $new"; return 0; }

  # ---- apply with dead-man rollback ----------------------------------------
  backup "$IFACES"
  backup /etc/hosts
  local bk="${BACKUP_DIR}${IFACES}"
  cancel_rollback
  systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active="${ROLLBACK_SECS}" \
    /bin/bash -c "cp -f '$bk' '$IFACES' && cp -f '${BACKUP_DIR}/etc/hosts' /etc/hosts && ifreload -a" \
    || die "Could not arm rollback timer; refusing to touch the network."
  ok "Rollback armed: reverts in ${ROLLBACK_SECS}s unless you confirm."

  cp "$new" "$IFACES" && rm -f "$new"
  if [[ -n $NEW_VMBR0_ADDR ]]; then
    local oldip newip; oldip="${cur0%/*}" newip="${NEW_VMBR0_ADDR%/*}"
    sed -i -E "s/^${oldip//./\\.}([[:space:]])/${newip}\1/" /etc/hosts
    ok "/etc/hosts: ${oldip} -> ${newip}"
  fi
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
    read -r -t "$((ROLLBACK_SECS - 20))" -p "Type 'keep' to keep this config (anything else or timeout = roll back): " ans </dev/tty || true
  fi
  if [[ $ans == keep ]]; then
    cancel_rollback
    ok "Network config kept. Backup: $bk"
    summ ok "Network" "vmbr1 ${VMBR1_ADDR} on ${HS_BOND}(${HS_NICS}) mtu ${HS_MTU}"
  else
    warn "Rolling back."
    systemctl start "${ROLLBACK_UNIT}.service" || true
    die "Network rolled back to $bk"
  fi
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
  fi

  local i want="${HS_MTU}" line=""
  for i in $(cat "/sys/class/net/$b/bonding/slaves" 2>/dev/null) "$b" vmbr1; do
    [[ -n $i && -e /sys/class/net/$i ]] || continue
    local m; m="$(cat "/sys/class/net/$i/mtu")"
    line+="$i=$m "
    [[ $m == "$want" ]] || rc=1
  done
  [[ -n $line ]] && { (( rc )) && warn "MTU: $line(want $want)" || ok "MTU: $line"; }

  if [[ -n ${HS_TEST_IP}${PEER_HS_IP} ]]; then
    local t; t="$(ask "Jumbo ping target on the high-speed net (blank to skip)" "${PEER_HS_IP:-$HS_TEST_IP}")"
    if [[ -n $t ]]; then
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
    pvecm status 2>/dev/null | grep -qE 'Quorate:[[:space:]]+Yes' && return 0
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

local_has_ip() { ip -4 -o addr 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$1"; }

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
    summ ok "Storage" "inherited from cluster: $(pvesm status 2>/dev/null | awk 'NR>1{printf "%s ", $1}')"
    pvesm status 2>/dev/null | sed 's/^/  /' || true
    return 0
  fi
  confirm "Add an NFS datastore now?" n || return 0
  local id server nfs_export content opts
  id="$(ask "Storage ID" "vast-ds-1")"
  if pvesm status 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$id"; then
    ok "Storage '$id' already defined (cluster-wide config); skipping."
    return 0
  fi
  server="$(ask "NFS server (FQDN or VIP)" "")"
  [[ -n $server ]] || { warn "No server given; skipping."; return 0; }
  nfs_export="$(ask "Export path" "/proxmox/ds-1")"
  content="$(ask "Content types" "images,iso,vztmpl,backup")"
  opts="$(ask "Mount options" "vers=3,nconnect=16,hard,proto=tcp")"
  info "Test-mounting ${server}:${nfs_export}"
  local mp; mp="$(mktemp -d /mnt/pveb-nfstest.XXXX)"
  if mount -t nfs -o "$opts" "${server}:${nfs_export}" "$mp" && touch "$mp/.pveb-write-test"; then
    rm -f "$mp/.pveb-write-test"; umount "$mp"; rmdir "$mp"
    ok "Mount + root write OK"
  else
    umount "$mp" 2>/dev/null || true; rmdir "$mp" 2>/dev/null || true
    die "Test mount/write failed (check export rules / root squash)."
  fi
  pvesm add nfs "$id" --server "$server" --export "$nfs_export" --content "$content" --options "$opts"
  sleep 2
  pvesm status | awk -v id="$id" 'NR==1 || $1==id'
  ok "Storage $id added"
  summ ok "Storage" "${id} -> ${server}:${nfs_export}"
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
usage() { sed -n '2,45p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || echo "see header"; }

main() {
  while (( $# )); do
    case "$1" in
      -y|--yes) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1; DO_REPOS=0 DO_NAG=0 DO_UPGRADE=0 DO_HA=0 DO_STORAGE=0 ;;
      --network-only) DO_REPOS=0 DO_NAG=0 DO_UPGRADE=0 DO_HA=0 DO_CLUSTER=0 DO_STORAGE=0 ;;
      --cluster-only) DO_REPOS=0 DO_NAG=0 DO_UPGRADE=0 DO_HA=0 DO_NETWORK=0 DO_STORAGE=0 ;;
      --skip-repos) DO_REPOS=0; DO_NAG=0 ;;
      --skip-upgrade) DO_UPGRADE=0 ;;
      --skip-network) DO_NETWORK=0 ;;
      --skip-cluster) DO_CLUSTER=0 ;;
      --skip-storage) DO_STORAGE=0 ;;
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
  STAGE_TOTAL=$(( DO_CLUSTER * 2 + DO_REPOS + DO_NAG + DO_UPGRADE + DO_NETWORK + DO_HA + DO_STORAGE ))

  (( DO_CLUSTER )) && cluster_plan    # first: learn the peer before touching anything
  (( DO_REPOS ))   && setup_repos
  (( DO_NAG ))     && remove_nag
  (( DO_UPGRADE )) && upgrade_and_tools
  (( DO_NETWORK )) && setup_network
  (( DO_CLUSTER )) && cluster_exec
  (( DO_HA ))      && setup_ha        # after cluster: never offered on members
  (( DO_STORAGE )) && setup_storage   # after join: cluster storage is inherited

  local foot
  if (( DRY_RUN )); then foot="dry run complete in $(dur $((SECONDS - t_start))); nothing was changed"; rmdir "$BACKUP_DIR" 2>/dev/null || true
  else foot="done in $(dur $((SECONDS - t_start)))  ${S_INFO} backups: ${BACKUP_DIR}  ${S_INFO} log: ${LOG}"; fi
  print_summary "$foot"
  if (( DO_UPGRADE )) && kernel_changed; then
    warn "A new kernel was installed."
    confirm "Reboot now?" n && { info "Rebooting"; systemctl reboot; }
  fi
}

# run main unless sourced (tests source this file for the pure functions)
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
