# ubuntu-from-scratch

A working, minimal Ubuntu 26.04 server image built via unattended autoinstall
and booted in VirtualBox. Install runs hands-off, then `firstboot.service` runs
once on the first real boot. No desktop — desktop packages live in the YAML as
labeled comment blocks you can uncomment later.

Two build paths ship in this repo, picking whichever fits your host:

- **[Linux / macOS / WSL / Git Bash](#approach-a--linux--macos--wsl--git-bash)** — `build.sh` + `run-vm.sh`
- **[Windows (PowerShell)](#approach-b--windows-powershell)** — `build.ps1` + `run-vm.ps1`

Both produce the same `build/cidata.iso` from the same `autoinstall/user-data`,
and both drive the same VirtualBox VM. Pick one and stick with it.

---

## Contents

1. [Layout](#layout)
2. [Approach A — Linux / macOS / WSL / Git Bash](#approach-a--linux--macos--wsl--git-bash)
3. [Approach B — Windows (PowerShell)](#approach-b--windows-powershell)
4. [Verify firstboot ran](#verify-firstboot-ran)
5. [Adding or removing packages](#adding-or-removing-packages)
6. [Updating the kernel](#updating-the-kernel)
7. [Adding a desktop](#adding-a-desktop)
8. [Tunables](#tunables)
9. [Rebuild / rerun](#rebuild--rerun)
10. [Troubleshooting](#troubleshooting)
11. [Out of scope](#out-of-scope)

---

## Layout

```
ubuntu-from-scratch/
├── README.md                   # this file
├── autoinstall/
│   ├── user-data               # cloud-init autoinstall config — the file you edit
│   └── meta-data               # cidata instance id
├── build.sh                    # Linux/macOS/WSL/Git Bash — builds cidata.iso
├── run-vm.sh                   # Linux/macOS/WSL/Git Bash — creates + boots VM
├── build.ps1                   # Windows PowerShell — builds cidata.iso (IMAPI2)
├── run-vm.ps1                  # Windows PowerShell — creates + boots VM
├── build/                      # generated (cidata.iso, VM disk) — gitignored
└── docs/
    ├── ubuntu-autoinstall.md   # full pipeline reference (sysprep, factory, etc.)
    └── ubuntu-autoinstall.html # same content, rendered
```

Everything you tune lives in `autoinstall/user-data`. The build scripts are
mechanical — you shouldn't need to edit them for normal changes.

Download the Ubuntu 26.04 **live-server** ISO (amd64) from
<https://releases.ubuntu.com/26.04/>. If 26.04 isn't final on release day,
daily / RC builds live at <https://cdimage.ubuntu.com/daily-live/current/>.

---

## Approach A — Linux / macOS / WSL / Git Bash

Use this path on anything with bash available (Ubuntu, WSL, macOS, Git Bash on
Windows). Uses `openssl` + `genisoimage` / `mkisofs` / `xorriso`.

### Prerequisites

| Tool | WSL / Ubuntu | macOS | Git Bash (Windows) |
|---|---|---|---|
| VirtualBox | run from host | [virtualbox.org](https://www.virtualbox.org/) | [virtualbox.org](https://www.virtualbox.org/) |
| ISO creator | `sudo apt install genisoimage` | `brew install cdrtools` | `choco install cdrtools` |
| openssl | ships with Ubuntu | ships with macOS | ships with Git |

### Build and boot

```bash
# 1. Build cidata.iso (defaults: user=ubuntu, password=ubuntu)
./build.sh
# or: PASSWORD=mypass ./build.sh

# 2. Point at the Ubuntu ISO and boot the VM
UBUNTU_ISO=/path/to/ubuntu-26.04-live-server-amd64.iso ./run-vm.sh
```

Tunables are environment variables — see [Tunables](#tunables).

---

## Approach B — Windows (PowerShell)

Use this path from a plain Windows terminal (no WSL, no Git Bash needed). The
ISO is built with Windows' built-in **IMAPI2** — no `mkisofs` install required.

### Prerequisites

| Tool | How to get it |
|---|---|
| PowerShell 5.1+ | ships with Windows 10/11 |
| VirtualBox | [virtualbox.org](https://www.virtualbox.org/) or `winget install Oracle.VirtualBox` |
| openssl.exe **or** python.exe on PATH | `winget install Git.Git` (ships openssl) or `winget install Python.Python.3` |
| ISO creator | **none needed** — IMAPI2 is built into Windows |

If PowerShell refuses to run the scripts, either invoke with `-ExecutionPolicy Bypass`
(as shown) or allow scripts for your user:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Unblock-File .\build.ps1, .\run-vm.ps1
```

### Build and boot

```powershell
# 1. Build cidata.iso (defaults: user=ubuntu, password=ubuntu)
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
# or: $env:PASSWORD='mypass'; .\build.ps1

# 2. Point at the Ubuntu live-server ISO you downloaded above and boot the VM
$env:UBUNTU_ISO = 'C:\iso\ubuntu-26.04-live-server-amd64.iso'
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-vm.ps1
```

Tunables are environment variables or `-Param` flags — see [Tunables](#tunables).

---

## Verify firstboot ran

Same on both paths. At the GRUB menu pick "Try or Install Ubuntu Server"
(default). If you see "Continue with autoinstall?", press Enter once. Install
takes 10–20 min. The VM reboots automatically and `firstboot.service` runs.

```bash
ssh -p 2222 ubuntu@localhost              # password: ubuntu

sudo systemctl status firstboot.service   # expect: inactive (ran + disabled)
sudo cat /etc/firstboot-complete          # marker written by firstboot.sh
sudo cat /var/log/firstboot.log           # firstboot stdout
```

---

## Adding or removing packages

Everything is driven by the `packages:` list in `autoinstall/user-data`, no
matter which build script you use. Two places in the install can remove things:
the `packages:` list (what gets installed) and `late-commands:` (what gets
purged after).

### Add a package that's in the standard Ubuntu archives

Edit `autoinstall/user-data`:

```yaml
  packages:
    - openssh-server
    - curl
    - tmux         # <- new
    - git          # <- new
```

Then rebuild + boot again (Approach A or B).

### Remove a package from the default set

Delete the line from `packages:`. If a package you don't want is pulled in as
a dependency of Ubuntu Server, purge it in `late-commands:` (`snapd` already is):

```yaml
  late-commands:
    - curtin in-target --target=/target -- apt-get purge -y snapd ubuntu-advantage-tools
    - curtin in-target --target=/target -- apt-get purge -y motd-news-config byobu   # <- add
    - curtin in-target --target=/target -- apt-get autoremove -y
```

### Install from a third-party apt repo

Add the repo + key under `apt:` in `autoinstall/user-data` and then list the
package in `packages:`. Docker CE is used here as an example — the same pattern
works for any third-party apt repo:

```yaml
  apt:
    sources:
      docker:
        # Use the current Ubuntu codename (run `lsb_release -cs` on a 26.04 box).
        # Docker typically lags a few months behind new Ubuntu releases, so check
        # https://download.docker.com/linux/ubuntu/dists/ first.
        source: "deb [arch=amd64 signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $RELEASE stable"
        keyid: 9DC858229FC7DD38854AE2D88D81803C0EBFCD88

  packages:
    - docker-ce
    - docker-ce-cli
```

### Install a local `.deb` the installer can't reach

Stage it under `autoinstall/` and copy it in with `late-commands`:

```yaml
  late-commands:
    - cp /cdrom/your-pkg_1.0_amd64.deb /target/tmp/
    - curtin in-target --target=/target -- dpkg -i /tmp/your-pkg_1.0_amd64.deb
```

> The `/cdrom/` path refers to the cidata ISO. Both `build.sh` and `build.ps1`
> currently only place `user-data` + `meta-data` on it — drop extra files into
> `autoinstall/` and extend the staging step (the `mkisofs` call in `build.sh`
> or `$fsi.Root.AddTree` in `build.ps1`) to include them.

### Change something on the running VM (no rebuild)

Once the VM is up, it's a normal Ubuntu box:

```bash
sudo apt update
sudo apt install <pkg>         # add
sudo apt purge <pkg>           # remove
sudo apt autoremove
```

Use the `packages:` list for anything that must be present on every freshly
built image. Use `apt install` for one-off tweaks on a VM you've already built.

---

## Updating the kernel

Ubuntu 26.04 LTS ships two kernel tracks:

| Meta-package | Kernel | Notes |
|---|---|---|
| `linux-generic` | GA (frozen at release) | default, security updates for the full LTS window |
| `linux-generic-hwe-26.04` | HWE (rolls forward) | newer hardware support, tracks latest point release |

### Switch to the HWE kernel at install time

Add it to `packages:` in `autoinstall/user-data`:

```yaml
  packages:
    - openssh-server
    - linux-generic-hwe-26.04    # <- HWE kernel, newer than the GA default
    - curl
```

Rebuild cidata and reinstall. The HWE meta-package coexists with `linux-generic`
and GRUB will boot the newer kernel by default.

### Pin a specific kernel version

If you need a known-good version rather than "whatever HWE is today":

```yaml
  packages:
    - linux-image-X.Y.Z-generic      # replace with the exact version you want
    - linux-headers-X.Y.Z-generic
```

List what's actually available on a running 26.04 box with:

```bash
apt-cache search '^linux-image-[0-9].*generic$'
```

### Update the kernel on an already-built VM

```bash
sudo apt update
sudo apt full-upgrade            # includes kernel point releases on the current track
sudo reboot
uname -r                         # confirm new version is running
```

To switch tracks on a VM that's already installed:

```bash
sudo apt install linux-generic-hwe-26.04    # GA -> HWE
# or
sudo apt install linux-generic              # HWE -> GA
sudo reboot
```

### Clean up old kernels

Ubuntu keeps a few previous kernels for rollback. After confirming the new one
boots fine:

```bash
sudo apt autoremove --purge
dpkg -l 'linux-image-*' | grep ^ii      # verify what's still installed
```

### Bleeding-edge mainline kernels

Not recommended for anything you rely on, but if you need it: Canonical publishes
unsigned mainline builds at <https://kernel.ubuntu.com/mainline/>. Download the
`linux-image-*-generic*.deb` + `linux-modules-*.deb` and install with `dpkg -i`.
Mainline kernels are unsigned, so disable Secure Boot if the VM uses it.

---

## Adding a desktop

Two sections in `autoinstall/user-data` are labeled:

- `DESKTOP PACKAGES` / `END DESKTOP PACKAGES`
- `DESKTOP-ONLY FIRSTBOOT STEPS` / `END DESKTOP-ONLY`

Uncomment the lines inside them, rerun the build + VM scripts for your path,
and the installed VM boots into a GNOME login screen. Bump `MEMORY_MB` to
4096+ and `DISK_SIZE_MB` to 25000+ for a comfortable desktop experience.

---

## Tunables

Same semantics on both paths; set them via environment variables. PowerShell
also accepts named `-Param` flags.

| Variable | Default | Used by | Notes |
|---|---|---|---|
| `PASSWORD` | `ubuntu` | build scripts | hashed with SHA-512 at build time |
| `VM_NAME` | `ubuntu-minimal` | run-vm scripts | VirtualBox VM name |
| `UBUNTU_ISO` | — | run-vm scripts | **required**, path to live-server ISO |
| `MEMORY_MB` | `4096` | run-vm scripts | RAM for install (can lower after) |
| `CPUS` | `2` | run-vm scripts | |
| `DISK_SIZE_MB` | `20480` | run-vm scripts | 20 GB virtual disk |
| `SSH_PORT` | `2222` | run-vm scripts | host port forwarded to guest 22 |

Bash:

```bash
PASSWORD='s3cret' ./build.sh
VM_NAME=ubuntu-desktop MEMORY_MB=8192 DISK_SIZE_MB=40960 \
  UBUNTU_ISO=~/iso/ubuntu-26.04-live-server-amd64.iso ./run-vm.sh
```

PowerShell:

```powershell
$env:PASSWORD = 's3cret'
.\build.ps1

.\run-vm.ps1 -VmName ubuntu-desktop -MemoryMb 8192 -DiskSizeMb 40960 `
  -UbuntuIso 'C:\iso\ubuntu-26.04-live-server-amd64.iso'
```

---

## Rebuild / rerun

Both `run-vm.sh` and `run-vm.ps1` destroy any existing VM with the same
`VM_NAME` and rebuild from scratch. To iterate on the YAML:

```
# edit autoinstall/user-data
# then re-run build + run-vm for your path
```

Nothing outside `build/` and the VirtualBox VM registry is touched.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `error: need one of genisoimage / mkisofs / xorriso` | bash path, ISO tooling missing | install per prereqs table, or switch to the PowerShell path |
| `Need openssl.exe or python.exe on PATH` | PowerShell path, neither tool on PATH | `winget install Git.Git` or `winget install Python.Python.3` |
| `VBoxManage not found` | VirtualBox not on PATH | install VirtualBox, reopen shell |
| Installer sits at "Continue with autoinstall?" | first-run confirmation prompt | press Enter (one-time) |
| Install hangs on a yellow screen | cidata not detected | check `build/cidata.iso` exists, volume label is `CIDATA` |
| SSH "connection refused" on 2222 | VM still installing, or firstboot not done | wait, then `VBoxManage showvminfo $VM_NAME` |
| `firstboot-complete` missing after boot | `firstboot.service` failed | `ssh` in, `journalctl -u firstboot.service` |
| PowerShell: script refuses to run | execution policy | run with `-ExecutionPolicy Bypass` or `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |

### Verbose installer logging

If the install appears stuck on a step (e.g. "installing kernel") and you want
to see what it's actually doing, switch to a shell on the live installer system
without interrupting the install:

1. Press **Right Ctrl + F2** in the VirtualBox window to open a shell.
2. Tail the installer's debug log:
   ```bash
   tail -f /var/log/subiquity/server-debug.log
   ```
   This shows exactly what subiquity is waiting on — a network request, a
   package download, a disk write, etc.
3. Press **Right Ctrl + F1** to switch back to the installer console.

---

## Out of scope

Sysprep, compression to `.raw.xz`, the factory utility, and nightly apt are
covered in [`docs/ubuntu-autoinstall.md`](docs/ubuntu-autoinstall.md). This
example stops once firstboot has run — enough to prove the install + firstboot
pipeline works end to end in VirtualBox.
