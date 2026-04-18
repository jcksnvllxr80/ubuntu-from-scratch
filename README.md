# ubuntu-from-scratch

Two ways to build a minimal **Ubuntu 26.04 LTS** (Resolute Raccoon) server
image and boot it in VirtualBox. Same end result; different routes to get
there. Pick whichever matches how you want to reason about the build.

| Approach | What it does | When to pick it |
|---|---|---|
| **[Autoinstall](_autoinstall/)** | Boots Ubuntu's live-server ISO in a VM and feeds it a `cidata.iso` full of cloud-init YAML. Subiquity/curtin does the install. | You want Canonical's installer doing the heavy lifting. Runs on Linux / macOS / WSL / Git Bash / Windows PowerShell. |
| **[debootstrap](_debootstrap/)** | Pulls packages straight from the Ubuntu archive, unpacks into a rootfs, runs a chroot to finish it, installs GRUB. Produces a bootable raw disk image — no installer runs. | You want no ISO download, faster rebuilds, or a starting point for golden-image / bare-metal deployment. Build needs Linux or WSL; VM runner works anywhere. |

---

## Documentation

### Autoinstall approach

- **[_autoinstall/README.md](_autoinstall/README.md)** — quick start, tunables, adding packages / kernels / desktops
- **[_autoinstall/docs/ubuntu-autoinstall.md](_autoinstall/docs/ubuntu-autoinstall.md)** — deep-dive: full pipeline reference (sysprep, compress, factory utility, nightly apt)
- **[_autoinstall/docs/ubuntu-autoinstall.html](_autoinstall/docs/ubuntu-autoinstall.html)** — same deep-dive, styled for the browser

### debootstrap approach

- **[_debootstrap/README.md](_debootstrap/README.md)** — quick start, tunables, adding packages / kernels / desktops
- **[_debootstrap/docs/ubuntu-debootstrap.md](_debootstrap/docs/ubuntu-debootstrap.md)** — deep-dive: what `build.sh` does step by step, sysprep, compress, deploy, nightly apt
- **[_debootstrap/docs/ubuntu-debootstrap.html](_debootstrap/docs/ubuntu-debootstrap.html)** — same deep-dive, styled for the browser

---

## Side-by-side

| | Autoinstall | debootstrap |
|---|---|---|
| Host OS | Linux / macOS / WSL / Git Bash / Windows | Linux / WSL (build); anywhere (run-vm) |
| ISO download | Ubuntu live-server (~2 GB) | none |
| Root required | no | yes (loop mount + chroot) |
| Install time | 10–20 min (Subiquity runs) | ~3–5 min (one pass) |
| What drives it | YAML in `autoinstall/user-data` | shell script + `config/` files |
| Installer / bootloader | Subiquity + curtin handle them | you call `grub-install` yourself |
| VM firmware | BIOS | EFI (grub `--removable`) |
| Output | installed disk inside a VM | `ubuntu.img` raw, portable to any EFI host |
| Typical use case | hands-off install in a VM | golden image for cloning / bare-metal deploy |

---

## Layout

```
ubuntu-from-scratch/
├── README.md              # this file
├── _autoinstall/          # autoinstall approach (build via Ubuntu's installer)
│   ├── README.md
│   ├── autoinstall/       # cloud-init user-data + meta-data
│   ├── build.sh / .ps1    # builds cidata.iso
│   ├── run-vm.sh / .ps1   # boots the VM with Ubuntu ISO + cidata.iso attached
│   └── docs/              # deep-dive: ubuntu-autoinstall.md + .html
└── _debootstrap/          # debootstrap approach (build straight from the archive)
    ├── README.md
    ├── config/            # packages.list, netplan.yaml, firstboot.sh, firstboot.service
    ├── build.sh / .ps1    # builds build/ubuntu.img (.ps1 wraps WSL)
    ├── run-vm.sh / .ps1   # converts raw -> VDI, boots the VM with EFI firmware
    └── docs/              # deep-dive: ubuntu-debootstrap.md + .html
```

Each subdirectory is self-contained — pick a path, `cd` into its folder,
and follow its README. Generated artifacts live under each path's own
`build/` directory and are gitignored.
