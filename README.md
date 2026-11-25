# SeamWin: install script for WinApps on KVM Linux

SeamWin is an installation and automation script around WinApps. WinApps provides the Windows apps as native Linux windows and shares Linux home as `\\tsclient\home`. SeamWin adds one command setup, VM and guest prep, a loading spinner, and idle power management.

WinApps source: <https://github.com/winapps-org/winapps>

## Problem

Linux lacks some Windows apps, for example Microsoft 365. Dual boot needs a reboot. An always-on Windows VM wastes RAM and CPU. Copying files between systems breaks the workflow.

## Solution

WinApps renders Windows apps through FreeRDP and shares Linux home as `\\tsclient\home`. WinApps starts the VM on app launch and pauses after close. SeamWin adds automatic managed save after idle and the loading spinner.

## Comparison

| Option | Base | Weight | App windows | Files | VM power | App support | Setup |
|---|---|---|---|---|---|---|---|
| WinApps + SeamWin | WinApps, libvirt KVM, FreeRDP 3 | Light | RemoteApp, native Linux windows | `\\tsclient\home` | On demand, pause + managed save | Most Windows apps | Install script + WinApps |
| WinBoat | Docker container | Heavier | Full desktop, app integration | Container shares | GUI controls | Broad | Guided app |
| Wine, Bottles, Proton | No Windows VM | Lightest | Native windows | Linux paths | Not applicable | Varies, Office and Adobe weak | Per app config |
| virt-manager alone | KVM VM | Light | Full desktop only | Manual shares | Manual | All Windows apps | Manual |

Pick WinApps + SeamWin for a lean local VM with app entries and automatic power saving. Pick WinBoat for a guided Docker based desktop. Pick Wine for games and simple apps. Pick virt-manager for a plain VM.

WinBoat: <https://github.com/winboat-org/winboat>

Tested: Linux Mint 22.1 Cinnamon, Ubuntu 24.04, X11. Other X11 desktops likely fine, untested.

## Prerequisites

- KVM + libvirt, `virsh`, user in `kvm` and `libvirt` groups
- X11 session
- Windows 10/11 Pro, Enterprise, Education VM, apps installed
- No Home, no RDP host. Lite images need `TermService` + RemoteApp
- Defaults: VM `win10`, user `Admin`, blank password, IP `192.168.122.2`

## Recommended Windows image

Lightweight, no key: Windows X-Lite Micro 10 SE x64 (22H2).

- Project: <https://windowsxlite.com/Micro10-22H2>
- SE x64: <https://windowsxlite.com/Micro10_x64_SE>
- No product key. Watermark normal. `install.sh` enables RDP + RemoteApp.

> Modified ISO. Download only from the official site. Verify the checksum. Keep the VM on the libvirt NAT network. Use at your own risk.

## Install

```bash
./install.sh
```

Script wraps WinApps: VM prep, RDP + RemoteApp enable, WinApps install, MIME + URI registration, spinner, idle timer.

Optional overrides:

```bash
VM_NAME=myvm RDP_IP=192.168.122.5 RDP_USER=MyUser RDP_PASS=secret IDLE_SECONDS=1200 ./install.sh
```

Add apps installed later in Windows:

```bash
winapps-setup --user --add-apps
```

## Use

- `winapps <app> [file]`, example: `winapps word-o365 file.docx`
- `winapps manual notepad.exe`, any executable
- `winapps windows`, full desktop
- `winapps killrdp`, end sessions

Lifecycle:

- Close last app: pause after ~40s
- Idle ~20 min: managed-save, VM off, RAM freed
- Next launch: ~5s restore, no saved state: cold boot ~20 to 30s
- Avoid Force Off. Stale session, "Another user is signed in" prompt
- Fix: console logoff via `virt-viewer`, or `virsh reboot win10`

## Files created

| Path | Purpose | Source |
|---|---|---|
| `~/.config/winapps/winapps.conf` | WinApps config | WinApps |
| `~/.local/bin/winapps-src` | WinApps runtime source | WinApps |
| `~/.local/share/seamwin/winapps-loader` | Loading spinner | SeamWin |
| `~/.local/share/seamwin/setup.sh` | Patched `winapps-setup`, FreeRDP 3.32 fix | SeamWin |
| `~/.local/bin/seamwin-idle` | Stage-2 idle helper | SeamWin |
| `~/.config/systemd/user/seamwin-idle.timer` | Idle check, once per minute | SeamWin |

## Uninstall

Preview: `./uninstall.sh --dry-run`. Run: `./uninstall.sh`.

```bash
./uninstall.sh --dry-run
./uninstall.sh
```

Flags: `--host-only`, `--vm-only`, `--delete-snapshot`, `--with-packages`, `--shutdown-vm`, `-y`. Keeps snapshot and packages by default. Restore: `./install.sh`.
