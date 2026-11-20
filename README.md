# Incus lab for MAAS + kolla-ansible + Ceph

Scripts and Incus profiles for a laptop lab: a MAAS VM provisions empty VMs over
PXE, which then become kolla-ansible (OpenStack) and Ceph nodes.

```
                 incusbr0 (Incus NAT, internet)
                     │
                  ┌──┴───┐
                  │ maas │ 10.20.0.2  MAAS region+rack, DHCP/PXE
                  └──┬───┘
maas-pxe 10.20.0.0/24│(Incus DHCP off, NAT on)
     ┌───────────────┼────────────────┐
  ┌──┴───┐        ┌──┴───┐         ┌──┴─────┐
  │ cn01 │        │ hv01 │         │ ceph01 │ + 6 OSD disks
  └──┬───┘        └──┬───┘         └────────┘
     └─ eth1, eth2 ──┴── kolla-ext (L2 only: neutron external, bonding)
```

## Contents

| Path | What it does |
|---|---|
| `setup.sh` | Creates the `maas-pxe` and `kolla-ext` networks and the profiles below |
| `profiles/maas-node.yaml` | MAAS VM: fixed MACs, static 10.20.0.2, cloud-init installs MAAS 3.7 from the PPA and mounts `/etc/kolla` |
| `profiles/kolla-node.yaml` | Empty PXE-booting VM: 4 vCPU, 6 GiB, PXE NIC + 2 NICs on `kolla-ext` |
| `profiles/ceph-node.yaml` | Empty PXE-booting VM: 4 vCPU, 4 GiB, PXE NIC |
| `bin/incus-maas-node` | Creates/deletes the MAAS VM, shares the kolla config folder, waits for the web UI |
| `bin/incus-kolla-node` | Creates/deletes kolla node VMs |
| `bin/incus-ceph-node` | Creates/deletes Ceph node VMs, each with 6 OSD block volumes |

## Usage

```sh
./setup.sh                                        # --ssh-key FILE to pick a key
ln -s "$PWD"/bin/incus-* ~/.local/bin/

incus-maas-node                                   # ~10-20 min: installs MAAS
ssh ubuntu@10.20.0.2 sudo maas createadmin
# In the MAAS UI: enable DHCP on 10.20.0.0/24, gateway 10.20.0.1, add your SSH key

incus-kolla-node --memory 8GiB cn01
incus-kolla-node hv01 hv02
incus-ceph-node ceph0{1..3}
incus start cn01 hv01 hv02 ceph01 ceph02 ceph03   # PXE boot -> MAAS enlists them

incus-kolla-node --delete cn01 hv01 hv02
incus-ceph-node --delete ceph0{1..3}              # also deletes the OSD volumes
incus-maas-node --delete
```

Each script has `--help`, which lists the environment variables it reads
(profile names, OSD count, kolla config folder, ...).

Each rebuild gives the MAAS VM a new SSH host key. If `ssh ubuntu@10.20.0.2`
warns that the host key changed, run `ssh-keygen -R 10.20.0.2`.

There is no power driver yet: start the node VMs yourself when MAAS waits for
them (`incus start <name>`).

## Tested with

- Arch Linux host, Incus 7.5.1, btrfs storage pool
- MAAS 3.7.5 (`ppa:maas/3.7`) on Ubuntu 24.04
- Nested virtualization enabled (`/sys/module/kvm_intel/parameters/nested` = `Y`)

## MAAS VM as the kolla-ansible deployment host

The MAAS VM is also where kolla-ansible runs. `incus-maas-node` shares a folder
on the host into the VM as `/etc/kolla` (virtiofs), so `globals.yml`,
`passwords.yml` and `config/` overrides stay on the host and survive rebuilding
the VM.

```sh
incus-maas-node                                   # shares ~/kolla-config
incus-maas-node --kolla-config ~/lab/etc-kolla    # or any other folder
incus-maas-node --no-kolla-config                 # no share
```

`KOLLA_CONFIG_DIR` sets the default folder. It is created if missing and never
deleted, not even by `--delete`.

User IDs are not remapped: files the VM's `ubuntu` user (UID 1000) writes are
owned by UID 1000 on the host, which is usually you. Run kolla-ansible as
`ubuntu`, not with `sudo`, or the files end up owned by root on the host.

## Known problems and why things are the way they are

- **Official Ubuntu image.** `incus-maas-node` uses Canonical's official
  Ubuntu 24.04 image. It has no Incus agent, so use SSH, not `incus exec`.
- **Canonical's simplestreams server can't be added as an Incus remote.** It
  publishes in LXD's format, which Incus doesn't list. The script imports the
  `lxd.tar.xz` + `disk1.img` pair by hand and checks the SHA256 sums.
- **ufw + `br_netfilter` drop PXE traffic.** With `br_netfilter` loaded,
  traffic between VMs on the same bridge goes through the host firewall, and
  ufw's default forward policy is DROP. Fix:
  ```sh
  sudo rmmod br_netfilter          # NOT modprobe -r: that also unloads "bridge"
                                   # and deletes every bridge on the host
  sudo ufw route allow in on maas-pxe
  sudo ufw route allow out on maas-pxe
  ```
  If the bridges did disappear, re-applying any network setting makes Incus
  recreate them, e.g. `incus network set maas-pxe bridge.mtu=1500 && incus network unset maas-pxe bridge.mtu`.
- **Two NICs on one managed network.** Incus refuses this because of DNS name
  conflicts. `kolla-ext` uses `dns.mode=none` and the NICs attach with
  `nictype: bridged`.
- **Launchpad PPA returns 503s at times.** The `maas-node` profile sets apt to retry
  10 times.
- **LACP won't negotiate** across an Incus bridge. Use `active-backup` or
  `balance-xor` when testing bonds.
- **Memory:** VM RAM isn't returned to the host. MAAS (4 GiB) + 1 controller
  (8 GiB) + 2 hypervisors (6 GiB) + 3 Ceph nodes (4 GiB) is about 36 GiB, so
  size the lab to your host. Set Ceph's `osd_memory_target` low (~512–768 MiB).

## Profile templates

The files in `profiles/` are templates. `setup.sh` replaces `${NAME}` with these
values when it loads them into Incus, and stops if a profile uses any other
`${...}`:

| Variable | Default | Used for |
|---|---|---|
| `POOL` | `default` | storage pool for every VM's disks |
| `PXE_GATEWAY` | `10.20.0.1` | host address on `maas-pxe` (only when creating it) |
| `PXE_PREFIX` | `24` | prefix length of `maas-pxe` |
| `MAAS_IP` | `10.20.0.2` | static address of the MAAS VM and its MAAS URL |
| `SSH_PUBLIC_KEY` | see below | key allowed to log in to the MAAS VM as `ubuntu` |
| `SSH_IDENTITY` | set automatically | matching private key, used by `incus-maas-node` |

Change a value by setting it when running `setup.sh`, e.g.
`MAAS_IP=10.20.0.5 ./setup.sh`. The scripts read the values back from the
profiles, so nothing else needs to change. The Ceph OSD disks go on the same
pool as the `ceph-node` profile's root disk.

The SSH key is the file given with `--ssh-key FILE`, else the `SSH_PUBLIC_KEY`
environment variable, else the first of `~/.ssh/id_ed25519.pub`, `id_ecdsa.pub`,
`id_rsa.pub`. When it comes from a file, the matching private key is recorded as
`SSH_IDENTITY`.

## License

MIT, see [LICENSE](LICENSE).
