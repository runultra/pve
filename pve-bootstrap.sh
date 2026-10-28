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
  if [[ -f $NFSCONF ]]; then local t; t="$(mktemp)"; strip_block "$NFSCONF" | cat -s >"$t"; cat "$t" >"$NFSCONF"; rm -f "$t"; fi
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
