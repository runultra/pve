# pve

Two scripts for standing up Proxmox VE hosts on VAST Data storage.

| Script | What it is | Run it |
|---|---|---|
| `pve-bootstrap.sh` | Post-install setup for a PVE host: repos, packages, storage network, cluster join/create, VAST NFS storages | On every new node, once. Re-run any stage later. |
| `vastnfs-pve.sh` | Optional VAST NFS client (vastnfs) with a kernel-upgrade guard and per-node mount options | Only on nodes that use vastnfs. pve-bootstrap installs it for you. |

**Default design:** storage NICs on an active-backup bond under `vmbr1`, MTU 9000, stock Linux NFS client, one VAST view per Proxmox storage, each mounted through its own DNS prefix so mounts spread across VIPs. vastnfs is opt-in (see [When to use vastnfs](#when-to-use-vastnfs)).

---

## Contents

- [Before you start](#before-you-start)
- [pve-bootstrap.sh](#pve-bootstrapsh)
  - [Quick start](#quick-start)
  - [What each stage does](#what-each-stage-does)
  - [Recipes](#recipes)
  - [Network: bond modes and the rollback](#network-bond-modes-and-the-rollback)
  - [Storage: the VAST layout](#storage-the-vast-layout)
  - [Flags and environment variables](#flags-and-environment-variables)
- [vastnfs-pve.sh](#vastnfs-pvesh)
  - [When to use vastnfs](#when-to-use-vastnfs)
  - [Install](#install)
  - [Commands](#commands)
  - [How it works](#how-it-works)
  - [Kernel upgrades](#kernel-upgrades)
  - [Removing vastnfs](#removing-vastnfs)
- [Troubleshooting](#troubleshooting)
- [Files the scripts touch](#files-the-scripts-touch)

---

## Before you start

On the VAST side (once per Proxmox cluster):

1. **VAST DNS** configured, with its domain delegated from corporate DNS. Test: `getent hosts ds1.<pool-fqdn>` and `ds2.<pool-fqdn>` return different VIPs.
2. **One VIP pool** on the same subnet as the Proxmox storage network (e.g. `proxmox.selab-var201.selab.vastdata.com`, `172.200.201.145-150`).
3. **One view policy**: NFS, No Squash + RW for the PVE storage IPs, restricted to that pool.
4. **Views**: `/proxmox/datastores/<cluster>/ds1..dsN`, plus `iso` and `dump`. The script does not create views; they must exist.

On the Proxmox host:

- Fresh PVE 8.x or 9.x install, root shell, management network working on `vmbr0`.
- Storage NICs cabled. LLDP from the switches helps the script recommend a bond mode.
- Run it in `tmux` if you are on SSH (the network stage has a rollback, but tmux keeps the session alive through it). The script installs tmux in its packages stage; on a box without it: `apt install tmux && tmux new -s bootstrap`.

---

## pve-bootstrap.sh

### Quick start

```bash
# fresh node, interactive: answers every question with a sensible default
bash -c "$(curl -fsSL https://raw.githubusercontent.com/runultra/pve/main/pve-bootstrap.sh)"
```

Or keep a copy on the host so you can re-run single stages later:

```bash
curl -fsSL -o /root/pve-bootstrap.sh https://raw.githubusercontent.com/runultra/pve/main/pve-bootstrap.sh
chmod +x /root/pve-bootstrap.sh
/root/pve-bootstrap.sh --dry-run     # see what it would do, change nothing
/root/pve-bootstrap.sh               # do it
```

Every prompt shows its default in `[brackets]`; Enter accepts it. At the end you get a summary of each stage, the backup folder, and the log path (`/root/pve-bootstrap.log`).

### What each stage does

Stages run in this order. Skip any with its `--skip-*` flag.

| # | Stage | What happens | Prompts you'll see |
|---|---|---|---|
| 1 | **Cluster plan** | Asked first: join, create, or skip. For a join it logs in to the peer, runs every check that doesn't need this node's network, and learns the cluster's storage subnet and MTU so vmbr1 matches. Nothing is joined yet. | Join/create/skip, peer IP, root password, cluster name |
| 2 | **Repos** | Disables enterprise repos, enables no-subscription for PVE and Ceph. | none |
| 3 | **Sub nag** | Removes the "No valid subscription" popup; survives updates. | none |
| 4 | **Packages** | `dist-upgrade`, then installs ethtool, iperf3, lldpd, nfs-common, jq, htop, tmux, curl, vim-nox. Starts lldpd. | Run dist-upgrade? |
| 5 | **vastnfs** | Optional. See [vastnfs-pve.sh](#vastnfs-pvesh). Default answer is **no**. | Install the VAST NFS client? |
| 6 | **Network** | Detects NICs, reads LLDP, recommends a bond mode, builds `vmbr1`, shows a diff, applies it with a dead-man rollback, verifies (gateway, bond, MTU, jumbo ping). | vmbr0 addr/gw, vmbr1 NICs, mode, MTU, vmbr1 addr, apply?, jumbo-ping target, type `keep` |
| 7 | **Cluster exec** | Creates or joins the cluster. corosync link0 = vmbr0, link1 = vmbr1. | none (answers came from stage 1) |
| 8 | **HA** | On a standalone host, offers to disable pve-ha-lrm/crm. Members are left alone. | Disable HA? |
| 9 | **Storage** | `vast` layout adds ds1..dsN + iso + dump on DNS prefixes; `single` adds one NFS storage; `skip`. Test-mounts and write-tests each one first. Storage is cluster-wide, so nodes that join a cluster inherit it. | Layout, pool FQDN, view path, datastore count |

If a reboot is needed (new kernel, or vastnfs), it asks at the very end.

### Recipes

**First node of a new cluster**

```bash
./pve-bootstrap.sh
#   cluster: create, name e.g. selab-var
#   network: accept the recommended bond mode
#   storage: vast, pool FQDN, /proxmox/datastores/selab-var, 4 datastores
```

**Every additional node (joins the cluster, inherits storage)**

```bash
# if the cluster has a QDevice (2-node clusters should), remove it first, on any member:
pvecm qdevice remove
# then on the new node:
CLUSTER_ACTION=join CLUSTER_PEER=10.143.11.125 ./pve-bootstrap.sh
#   prompts for the peer's root password; builds vmbr1 on the cluster's own subnet/MTU
```

Proxmox itself does not block a join while a QDevice is configured, but the result is unsupported. pve-bootstrap's join preflight checks for one and stops before changing anything.

**QDevice (2-node clusters)**

Two nodes alone lose quorum when either goes down. A QDevice is a third vote from a small VM or box outside the cluster (`corosync-qnetd`).

```bash
# on the QDevice host (Debian/Ubuntu): apt install -y corosync-qnetd
#   root must accept the cluster nodes' SSH keys (cat /etc/pve/priv/authorized_keys from a node
#   into its /root/.ssh/authorized_keys) and sshd needs PermitRootLogin prohibit-password
# on every PVE node:
apt install -y corosync-qdevice
# on one PVE node:
pvecm qdevice setup <qdevice-ip>
pvecm status        # Expected votes 3, Total votes 3, Flags: Quorate Qdevice
```

| Node count | QDevice |
|---|---|
| 2 | Yes |
| 3, 5, 7, 9 (odd) | No. Proxmox recommends against it |
| 4, 6, 8, 10 (even) | Optional tiebreaker |

Adding or removing a node always means `pvecm qdevice remove` first, then `pvecm qdevice setup` again afterwards if the new count is even.

**Check a node without changing anything**

```bash
./pve-bootstrap.sh --dry-run
```

Shows the network diff it would apply and runs every cluster-join check against the peer.

**Re-do just the network** (re-cable, swap NICs, change bond mode)

```bash
./pve-bootstrap.sh --network-only
HS_MODE=active-backup ./pve-bootstrap.sh --network-only   # force a mode
```

**Switch to LACP after the switch ports are bonded**

1. On both switches, bond the host ports under one MLAG ID (with LACP bypass, so the host keeps forwarding while still active-backup).
2. Migrate VMs off the node.
3. `HS_MODE=802.3ad ./pve-bootstrap.sh --network-only`

The script checks LACP after applying (real partner MAC, both slaves in one aggregator) and rolls back if it didn't form. One node at a time.

**Join an existing cluster only** (network already done)

```bash
./pve-bootstrap.sh --cluster-only
```

**Unattended** (Ansible, PXE post-install)

```bash
CLUSTER_ACTION=join CLUSTER_PEER=10.143.11.125 CLUSTER_PASSWORD='...' \
HS_MODE=active-backup HS_TEST_IP=172.200.201.145 STORAGE_LAYOUT=skip \
./pve-bootstrap.sh -y
```

With `-y` every prompt takes its default and the network config is kept automatically once its checks pass. Note that "Apply this network config?" defaults to no, so `-y` alone will not touch the network; drive that stage interactively or with `--skip-network`.

### Network: bond modes and the rollback

Pick by what the switch side supports:

| Mode | Switch config | Uses both links | VM failover on vmbr1 | When |
|---|---|---|---|---|
| `active-backup` | none | no (one 200G link) | yes | **Default.** Switches can't be touched. Works with 1 NIC too. |
| `802.3ad` | host ports bonded, MLAG across two switches | yes (layer3+4 hash) | yes | Switch ports are a LAG. LLDP shows it and the script recommends it. |
| `split` | none | storage only, via vastnfs | **no** | Only nodes where **no VMs** attach to vmbr1. Opt-in with `HS_MODE=split`. |

`HS_MODE=auto` (the default) picks 802.3ad when LLDP shows the switch ports advertise LAG membership, otherwise active-backup. It never picks split; that has to be asked for, and it warns and asks again.

**How the rollback works.** Before applying, the script backs up `/etc/network/interfaces` and arms a systemd timer (`ROLLBACK_SECS`, default 180 s) that restores it. After `ifreload` it runs its checks, then asks you to type `keep`. Anything else, or no answer, restores the old config. If the checks fail you're asked whether to keep it anyway (default no). The management bridge `vmbr0` is only touched if you change its address, which it refuses on a clustered node.

**Active-backup never fails back on its own.** Bonds are written with `bond-primary <first NIC>` and `bond-primary-reselect failure`: the first NIC is preferred at boot, but once traffic moves to the second NIC it stays there until that NIC fails. A link coming back up is not proof the path works (a replacement switch can have link before its VLAN/MTU config is done), so the bond doesn't jump back onto it.

**Rotating the storage switch pair, one switch at a time** (active-backup):

1. Check every node: `grep -E "Currently Active|Primary Reselect" /proc/net/bonding/bond0`.
2. Before pulling the switch that carries the **active** NIC, move each node off it: `echo nic6 > /sys/class/net/bond0/bonding/active_slave` (no traffic loss). Pulling the standby side needs no prep.
3. Swap the switch. Before cabling hosts back, confirm the new switch: VLAN, MTU 9000, uplinks/peerlink.
4. Verify the path from a node: `ip link show nic4` shows UP, then move one node back with `echo nic4 > /sys/class/net/bond0/bonding/active_slave` and run `ping -M do -s 8972 <vip>`. Then the rest.
5. Repeat for the other switch.

VM disks (host NFS) and every VM's `vmbr1` network ride through all of this; hard NFS mounts pause I/O for the failover instead of erroring.

**Split mode details** (only if you chose it): vmbr1 bridges the first NIC; the second NIC gets its own IP in the same subnet (default: vmbr1's address with the third octet + 1, e.g. `172.200.12.127`); per-IP routing tables 101/102 and `/etc/sysctl.d/90-vast-multihome.conf` (`arp_ignore=1`, `arp_announce=2`, `rp_filter=2`) make each IP answer and send on its own NIC. Leaving split mode removes the rules and sysctls.

### Storage: the VAST layout

`STORAGE_LAYOUT=vast` creates:

| Storage ID | Server | Export | Content | nconnect (200G) |
|---|---|---|---|---|
| `vast-ds1`..`vast-dsN` | `dsN.<pool-fqdn>` | `<base>/dsN` | images, rootdir | 12 |
| `vast-iso` | `iso.<pool-fqdn>` | `<base>/iso` | iso, vztmpl, snippets, import | 4 |
| `vast-dump` | `dump.<pool-fqdn>` | `<base>/dump` | backup | 8 |

Options are `vers=3,nconnect=N` (NFS mounts are hard by default; never add `soft` for VM disks). nconnect is 12 on links of 100G or more, 4 below; override with `NFS_NCONNECT`.

**Why the prefixes:** Linux keeps one transport per server IP, and the first mount's nconnect wins. If every storage used the plain pool name, they'd all land on one VIP at boot. VAST DNS answers any `<prefix>.<pool-fqdn>` with its own VIP, so each storage gets a different one. The stage checks this: it resolves every prefix and warns if they all came back as one IP (not VAST DNS, or a caching resolver).

Check the result on any node:

```bash
awk '$2 ~ "^/mnt/pve/vast"' /proc/mounts | grep -oE '^[^ ]+|addr=[^,]+|nconnect=[0-9]+'
```

Every storage should show a different `addr=`.

### Flags and environment variables

| Flag | Effect |
|---|---|
| `--dry-run` | Plan only: network diff, cluster-join checks. Changes nothing. |
| `--network-only` | Network stage only. |
| `--cluster-only` | Cluster stage only. |
| `--vastnfs` | Retrofit vastnfs on an existing node (see [Install](#install)). |
| `--skip-repos` `--skip-upgrade` `--skip-network` `--skip-cluster` `--skip-storage` `--skip-vastnfs` | Skip that stage. |
| `-y` | Accept every default, non-interactive. |

| Variable | Default | Meaning |
|---|---|---|
| `HS_NICS` | auto | NICs for vmbr1, e.g. `"nic4 nic6"` |
| `HS_MODE` | `auto` | `auto`, `active-backup`, `802.3ad`, `split` |
| `HS_BOND` | `bond0` | Bond name (moves to bond1 if bond0 is used by other NICs) |
| `HS_MTU` | `9000` | MTU for NICs, bond, vmbr1 |
| `VMBR1_ADDR` | `<HS_NET_PREFIX>.<vmbr0 last octet>/<HS_CIDR>` | vmbr1 address |
| `HS_NET_PREFIX` / `HS_CIDR` | `172.200.5` / `16` | Used to build the vmbr1 default |
| `HS_NIC2_ADDR` | vmbr1 with 3rd octet + 1 | Split mode only: 2nd NIC's address |
| `HS_TEST_IP` | `172.200.209.1` | Jumbo-ping target; use a VAST VIP. `""` skips. |
| `ROLLBACK_SECS` | `180` | Dead-man window |
| `VMBR0_ADDR` / `VMBR0_GW` | current | Change mgmt IP (console only; refused on cluster members) |
| `CLUSTER_ACTION` | ask | `join`, `create`, `skip` |
| `CLUSTER_PEER` / `CLUSTER_PASSWORD` | ask | Node to join through, its root@pam password |
| `CLUSTER_NAME` | ask | Name when creating |
| `CLUSTER_LINK0` / `CLUSTER_LINK1` | vmbr0 / vmbr1 IPs | corosync addresses |
| `STORAGE_LAYOUT` | ask | `vast`, `single`, `skip` |
| `VAST_POOL_FQDN` | ask | VIP pool FQDN |
| `VAST_EXPORT_BASE` | `/proxmox/datastores/<cluster>` | Parent of the views |
| `VAST_DS_COUNT` | `4` | Image datastores (views must exist) |
| `VAST_ID_PREFIX` | `vast` | Storage ID prefix |
| `NFS_NCONNECT` | 12 / 4 by link speed | Override nconnect |
| `VASTNFS` | ask (default no) | `yes` / `no` |
| `VAST_VIP_RANGE` | ask | VIP range for vastnfs `remoteports`, e.g. `172.200.201.145-172.200.201.150` |

---

## vastnfs-pve.sh

### When to use vastnfs

The stock client with DNS prefixes already fills one 200G link (24.7 GB/s measured on selab-var), so **most clusters don't need vastnfs**. It adds a DKMS kernel module that has to be rebuilt for every kernel.

It pays off in one case: a node with two storage NICs, switches you can't bond, and **no VMs on vmbr1**. Then split mode plus `localports` drives both NICs (48.5 GB/s measured) and survives losing either link. If VMs use vmbr1, use a bond instead; split mode gives them a single uplink.

| Setup | Throughput per node | VM failover on vmbr1 | Needs vastnfs |
|---|---|---|---|
| active-backup, stock client | 1 link | yes | no |
| 802.3ad over MLAG, stock client | 2 links | yes | no |
| split + vastnfs localports | 2 links (storage only) | no | yes |

### Install

**New node:** run pve-bootstrap and answer yes to "Install the VAST NFS client?", or set `VASTNFS=yes`. For split mode add `HS_MODE=split`.

**Existing node (retrofit):**

```bash
# migrate VMs off first; it warns if any are running
VASTNFS=yes ./pve-bootstrap.sh --vastnfs
VASTNFS=yes HS_MODE=split ./pve-bootstrap.sh --vastnfs    # also switch to split mode
```

`--vastnfs` runs only: prerequisite checks (tools, lldpd, running guests), the vastnfs stage, and the network stage. It skips repos, upgrade, cluster, and storage. The first node asks for the VIP pool FQDN and range and stores them cluster-wide in `/etc/pve/vast-multipath.conf`; later nodes reuse them. Reboot at the end to load the module.

**Standalone** (without pve-bootstrap):

```bash
curl -fsSL -o /usr/local/sbin/vastnfs-pve.sh https://raw.githubusercontent.com/runultra/pve/main/vastnfs-pve.sh
chmod +x /usr/local/sbin/vastnfs-pve.sh
printf 'POOL_FQDN=%s\nVIP_RANGE=%s\n' proxmox.selab-var201.selab.vastdata.com 172.200.201.145-172.200.201.150 \
  > /etc/pve/vast-multipath.conf        # once per cluster
vastnfs-pve.sh install
reboot
```

Needs: no Secure Boot (the installer refuses, DKMS modules would need MOK signing), and outbound HTTPS to `vast-nfs.s3.amazonaws.com`. Pin a version with `VASTNFS_VERSION=4.5.10`.

### Commands

```bash
vastnfs-pve.sh install          # deps, DKMS build, guard hooks, boot sync unit; then reboot
vastnfs-pve.sh status           # loaded?, DKMS per kernel, boot pin, per-mount options
vastnfs-pve.sh sync             # rewrite the managed nfsmount.conf block
vastnfs-pve.sh sync --remount   # ...and remount idle VAST storages so it takes effect now
vastnfs-pve.sh hooks            # reinstall guard hooks + sync unit
vastnfs-pve.sh remove           # undo everything; then reboot
```

Healthy `status` on a vastnfs node:

```
vastnfs        : loaded
cluster conf   : pool proxmox.selab-var201..., VIPs 172.200.201.145-172.200.201.150, share transport yes
localports     : vmbr1~nic6
mounts         :
  /mnt/pve/vast-ds1   nconnect=12 localports=... remoteports=172.200.201.145-172.200.201.150 spread_reads spread_writes
kernels        :
  7.0.14-26-pve        vastnfs
```

**After adding a VAST storage in the GUI**, run `vastnfs-pve.sh sync --remount` on each vastnfs node, or that storage mounts stock-style until the next boot.

### How it works

`storage.cfg` is cluster-wide and keeps only standard options (`vers=3,nconnect=12`), so any node can mount every storage with or without vastnfs. Each vastnfs node adds its own options through `/etc/nfsmount.conf`, which `mount.nfs` reads on every mount, including Proxmox's:

```ini
# >>> vastnfs-pve managed block ...
[ MountPoint "/mnt/pve/vast-ds1" ]
remoteports=172.200.201.145-172.200.201.150
spread_reads=True
spread_writes=True
localports=vmbr1~nic6          # only on split-mode nodes
# <<< vastnfs-pve managed block <<<
```

- `remoteports` spreads every mount over all VIPs.
- `spread_reads` / `spread_writes` are **required** for VM disks; without them one file stays on one connection (measured 40% slower than stock).
- `localports` is added automatically when the node is in split mode (the NIC marked `#highspeed2` in `/etc/network/interfaces`).
- `SHARE_TRANSPORT=no` in `/etc/pve/vast-multipath.conf` gives each storage its own connections (`nosharetransport`) for heavy small-block work.

The `vastnfs-sync.service` unit rewrites this block at every boot, before Proxmox activates storage. **If vastnfs isn't loaded at boot** (say, an odd kernel), it removes the block instead, so storages mount with the stock client rather than failing.

### Kernel upgrades

DKMS rebuilds vastnfs for each new kernel. The guard covers the gaps:

- Hooks run after kernel installs, header installs, and every dpkg run (Proxmox's header packages don't trigger the usual hook), and build vastnfs for any kernel that has headers. `proxmox-default-headers` keeps headers coming.
- If a build fails (a kernel newer than vastnfs supports), boot is **pinned** to a kernel that has vastnfs, and the motd says why. The pin releases itself once a later kernel builds.
- Major PVE upgrades may wait for a vastnfs release covering the new kernel series; until then the node keeps booting the pinned kernel.

Check with `vastnfs-pve.sh status` (`boot pin` and `kernels` lines) and `proxmox-boot-tool kernel list`.

### Removing vastnfs

```bash
vastnfs-pve.sh remove                                     # package, hooks, sync unit, nfsmount.conf block, pin
HS_MODE=active-backup ./pve-bootstrap.sh --network-only   # only if the node was in split mode
reboot                                                    # loads the stock NFS client
rm -f /etc/pve/vast-multipath.conf                        # once no node in the cluster uses vastnfs
```

Do it one node at a time with VMs migrated off. Afterwards `lsmod | grep -c vastnfs` is `0` and each mount shows a different `addr=`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Rolling back (got 'xyz', not 'keep')" | You typed something other than `keep` within the window. Nothing is broken; re-run the stage. |
| Bond recommendation says "no LLDP" | lldpd just started (it waits ~40 s) or the switch doesn't send LLDP. Pick the mode yourself with `HS_MODE`. |
| 802.3ad rolls back with "slaves outside aggregator" | Switch side isn't bonded on both switches, or MLAG isn't formed. Fix the switches, keep active-backup meanwhile. |
| Jumbo ping fails | MTU 9000 isn't end to end: NIC, bond, bridge, switch ports, MLAG peerlink, VAST side. |
| All DNS prefixes resolve to one IP | Not VAST DNS, or a caching resolver (dnsmasq, systemd-resolved, nscd) pinning answers. |
| Storage shows grey `?` in the GUI but `mount` is fine | pvestatd's health check against the server name, not the data path. |
| vastnfs `status` says NOT loaded after a reboot | Booted a kernel without vastnfs. Storages are on the stock client (safe). Check `kernels` and `boot pin` in `status`, the motd, and `dkms status`. A failed first install leaves its log in `/root/vastnfs-build/build.log`. |
| New GUI storage has no vastnfs options | Run `vastnfs-pve.sh sync --remount`. |
| Script stopped with "unexpected failure at line N" | A bug. Send the line, the command shown, and `/root/pve-bootstrap.log`. |

Logs and backups: `/root/pve-bootstrap.log`, `/root/pve-bootstrap-backup/<timestamp>/` (every file the script changed, at its original path).

---

## Files the scripts touch

| Path | By | Purpose |
|---|---|---|
| `/etc/apt/sources.list.d/*` | bootstrap | Repos |
| `/etc/network/interfaces` | bootstrap | vmbr0/vmbr1, bond, split NIC (`#highspeed`, `#highspeed2` markers) |
| `/etc/sysctl.d/90-vast-multihome.conf` | bootstrap | Split mode only |
| `/etc/pve/storage.cfg` | bootstrap (via `pvesm`) | VAST storages, cluster-wide |
| `/etc/pve/vast-multipath.conf` | bootstrap / you | vastnfs pool + VIP range, cluster-wide |
| `/usr/local/sbin/vastnfs-pve.sh` | bootstrap | The helper |
| `/etc/nfsmount.conf` | vastnfs-pve | Managed block only; the rest of the file is left alone |
| `/etc/systemd/system/vastnfs-sync.service` | vastnfs-pve | Boot-time sync |
| `/etc/kernel/postinst.d/`, `/etc/kernel/header_postinst.d/`, `/etc/apt/apt.conf.d/99vastnfs-guard`, `/usr/local/sbin/vastnfs-guard` | vastnfs-pve | Kernel guard |
| `/root/vastnfs-build/` | vastnfs-pve | Build tree and logs |
