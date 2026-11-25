#!/usr/bin/env bash
# SeamWin uninstaller - removes WinApps integration from the Linux host and
# reverses the Windows guest changes made by install.sh.
#
#   ./uninstall.sh                 # full cleanup (keeps snapshot + packages)
#   ./uninstall.sh --dry-run       # show what would be removed
#   ./uninstall.sh --host-only     # skip Windows guest changes
#   ./uninstall.sh --vm-only       # skip Linux host changes
#   ./uninstall.sh --delete-snapshot
#   ./uninstall.sh --with-packages # also apt-remove the installed packages
#   ./uninstall.sh --shutdown-vm   # graceful ACPI shutdown after guest cleanup
#   ./uninstall.sh -y              # skip confirmation

set -euo pipefail

VM_NAME="${VM_NAME:-win10}"
NET_NAME="${NET_NAME:-default}"
RDP_IP="${RDP_IP:-192.168.122.2}"
DISPLAY="${DISPLAY:-:0}"
export DISPLAY

DRY=0; WITH_PACKAGES=0; DELETE_SNAPSHOT=0; HOST_ONLY=0; VM_ONLY=0; SHUTDOWN_VM=0; ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --with-packages) WITH_PACKAGES=1 ;;
        --delete-snapshot) DELETE_SNAPSHOT=1 ;;
        --host-only) HOST_ONLY=1 ;;
        --vm-only) VM_ONLY=1 ;;
        --shutdown-vm) SHUTDOWN_VM=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

TMP="$(mktemp -d /tmp/opencode/seamwin-uninstall.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

log() { printf '\n==> %s\n' "$*"; }
run() {
    if [ "$DRY" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
vm_state() { virsh domstate "$VM_NAME" 2>/dev/null || echo missing; }

if [ "$ASSUME_YES" = 0 ] && [ "$DRY" = 0 ]; then
    printf 'This removes WinApps/SeamWin from the Linux host'
    [ "$VM_ONLY" = 0 ] && printf ' and reverses the Windows guest changes'
    printf '.\nContinue? [y/N] '
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 0 ;; esac
fi

# ---------------------------------------------------------------- helper: XTEST
cat >"$TMP/xtype.py" <<'PY'
import sys, time
from Xlib import display, X, XK
from Xlib.ext import xtest
d = display.Display()
S = {' ': 'space', '\n': 'Return', '\t': 'Tab', '.': 'period', ',': 'comma',
     ':': 'colon', ';': 'semicolon', '\\': 'backslash', '/': 'slash',
     '"': 'quotedbl', "'": 'apostrophe', '-': 'minus', '_': 'underscore',
     '=': 'equal', '+': 'plus', '(': 'parenleft', ')': 'parenright',
     '[': 'bracketleft', ']': 'bracketright', '{': 'braceleft',
     '}': 'braceright', '>': 'greater', '<': 'less', '|': 'bar',
     '&': 'ampersand', '$': 'dollar', '%': 'percent', '#': 'numbersign',
     '@': 'at', '!': 'exclam', '?': 'question', '*': 'asterisk',
     '^': 'asciicircum', '~': 'asciitilde', '`': 'grave'}
def tap(kc, shift=False, delay=0.012):
    sk = d.keysym_to_keycode(XK.string_to_keysym('Shift_L'))
    if shift: xtest.fake_input(d, X.KeyPress, sk)
    xtest.fake_input(d, X.KeyPress, kc); xtest.fake_input(d, X.KeyRelease, kc)
    if shift: xtest.fake_input(d, X.KeyRelease, sk)
    d.sync(); time.sleep(delay)
def typ(text):
    for ch in text:
        ks = XK.string_to_keysym(S.get(ch, ch)); kc = d.keysym_to_keycode(ks)
        tap(kc, ch.isupper() or (d.keycode_to_keysym(kc, 0) != ks and d.keycode_to_keysym(kc, 1) == ks))
def key(name):
    tap(d.keysym_to_keycode(XK.string_to_keysym(name)), delay=0.04)
mode, value = sys.argv[1], sys.argv[2]
(typ(value) if mode == 'type' else key(value))
PY

# ---------------------------------------------------------------- host cleanup
if [ "$VM_ONLY" = 0 ]; then
    log "Removing host-side WinApps/SeamWin integration"
    if [ "$DRY" = 0 ]; then
        systemctl --user stop seamwin-idle.timer 2>/dev/null || true
        systemctl --user disable seamwin-idle.timer 2>/dev/null || true
        rm -f "${HOME}/.config/systemd/user/seamwin-idle.service" \
              "${HOME}/.config/systemd/user/seamwin-idle.timer"
        systemctl --user daemon-reload 2>/dev/null || true
        pkill -x virt-viewer 2>/dev/null || true
        pkill -x xfreerdp3 2>/dev/null || true
        pkill -x zenity 2>/dev/null || true
    fi

    for f in winapps winapps-setup seamwin-idle; do
        run rm -f "${HOME}/.local/bin/${f}"
    done
    for d in winapps-src seamwin; do
        run rm -rf "${HOME}/.local/bin/${d}" "${HOME}/.local/share/${d}"
    done
    run rm -rf "${HOME}/.local/share/winapps"
    run rm -f "${HOME}/.config/winapps/winapps.conf" \
             "${HOME}/.config/winapps/winapps.conf.bak"
    run rmdir "${HOME}/.config/winapps" 2>/dev/null || true

    for d in cmd explorer mspaint powershell powershell-ide publisher-o365 \
             word-o365 windows ms-office-protocol-handler; do
        run rm -f "${HOME}/.local/share/applications/${d}.desktop"
    done

    # Restore the previous MIME/URL defaults (LibreOffice on Linux Mint).
    for m in application/msword \
             application/vnd.openxmlformats-officedocument.wordprocessingml.document \
             application/vnd.openxmlformats-officedocument.wordprocessingml.template \
             application/vnd.ms-word.document.macroEnabled.12 \
             application/vnd.ms-word.template.macroEnabled.12; do
        if [ "$DRY" = 0 ] && command -v xdg-mime >/dev/null; then
            xdg-mime default libreoffice-writer.desktop "$m" 2>/dev/null || true
        fi
    done
    for s in ms-word ms-excel ms-powerpoint ms-outlook ms-access ms-visio \
             ms-project ms-teams ms-whiteboard ms-officeapp; do
        if [ "$DRY" = 0 ] && command -v xdg-settings >/dev/null; then
            xdg-settings set default-url-scheme-handler "$s" libreoffice-startcenter.desktop 2>/dev/null || true
        fi
    done
    run rm -f "${HOME}/.config/freerdp/server/${RDP_IP}_3389.pem"

    if [ "$WITH_PACKAGES" = 1 ]; then
        log "Removing packages (this may affect other software)"
        run sudo apt-get remove -y freerdp3-x11 virt-viewer genisoimage \
            python3-xlib python3-pil zenity
    fi
fi

# ---------------------------------------------------------------- VM cleanup
if [ "$HOST_ONLY" = 0 ]; then
    log "Reversing Windows guest changes"
    virsh dominfo "$VM_NAME" >/dev/null 2>&1 || die "VM '$VM_NAME' not found"
    [ "$(vm_state)" = "running" ] || run virsh start "$VM_NAME"
    sleep 5

    if [ "$DRY" = 0 ]; then
        command -v virt-viewer >/dev/null || die "virt-viewer is required for guest cleanup"
        python3 -c 'import Xlib' 2>/dev/null || die "python3-xlib is required"

        virt-viewer --connect qemu:///system "$VM_NAME" >"${TMP}/viewer.log" 2>&1 &
        VIEWER_PID=$!
        for _ in $(seq 1 30); do wmctrl -l | grep -F "$VM_NAME" >/dev/null && break; sleep 1; done
        ID=$(wmctrl -l | awk -v n="$VM_NAME" 'index($0,n){print $1; exit}')
        wmctrl -ia "$ID" 2>/dev/null || true
        sleep 1
        # Click into the guest, then accept a login screen if present (blank password).
        python3 - <<'PY'
from Xlib import display, X
from Xlib.ext import xtest
import time
d = display.Display()
xtest.fake_input(d, X.MotionNotify, x=1200, y=500); d.sync(); time.sleep(.3)
xtest.fake_input(d, X.ButtonPress, 1); d.sync(); time.sleep(.15)
xtest.fake_input(d, X.ButtonRelease, 1); d.sync(); time.sleep(.4)
PY
        python3 "$TMP/xtype.py" key Return; sleep 3
        # Open an elevated PowerShell from Start search.
        python3 "$TMP/xtype.py" key Super_L; sleep 2
        python3 "$TMP/xtype.py" type powershell; sleep 2
        python3 "$TMP/xtype.py" key Return; sleep 6

        cat >"${TMP}/guest1.txt" <<'EOF'
Set-Service TermService -StartupType Manual; Stop-Service TermService -Force -ErrorAction SilentlyContinue; Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 1 -Type DWord; Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1 -Type DWord; Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name LimitBlankPasswordUse -Value 1 -Type DWord; Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList' -Name fDisabledAllowList -ErrorAction SilentlyContinue; Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name fAllowUnlistedRemotePrograms -ErrorAction SilentlyContinue; Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -Name IgnoreRemoteKeyboardLayout -ErrorAction SilentlyContinue
EOF
        cat >"${TMP}/guest2.txt" <<'EOF'
schtasks /delete /tn TimeSync /f; schtasks /delete /tn WinApps_NetworkProfileCleanup /f; schtasks /delete /tn SeamWin_ConsoleLogoff /f; schtasks /delete /tn SeamWin_SessionCleanup /f; Remove-Item C:\Windows\TimeSync.ps1,C:\Windows\NetProfileCleanup.ps1,C:\Windows\install.bat,C:\Windows\RDPApps.reg,C:\Windows\SeamWinLogoffConsole.cmd,C:\Windows\SeamWinSessionCleanup.ps1,C:\Windows\sec.cfg -Force -ErrorAction SilentlyContinue
EOF
        cat >"${TMP}/guest3.txt" <<'EOF'
net user winapps /delete
EOF
        for f in guest1 guest2 guest3; do
            python3 "$TMP/xtype.py" type "$(cat "${TMP}/${f}.txt")"
            python3 "$TMP/xtype.py" key Return
            sleep 3
        done
        python3 "$TMP/xtype.py" type logoff
        python3 "$TMP/xtype.py" key Return
        sleep 4
        kill "$VIEWER_PID" 2>/dev/null || true
    else
        echo "  [dry-run] guest registry/service/task/file cleanup via SPICE console"
    fi

    # Remove the DHCP reservation and the guest-agent channel we added.
    MAC="$(virsh domiflist "$VM_NAME" 2>/dev/null | grep -oE '([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})' | head -1)"
    if [ -n "$MAC" ]; then
        run virsh net-update "$NET_NAME" delete ip-dhcp-host \
            "<host mac='${MAC}' name='${VM_NAME}' ip='${RDP_IP}'/>" --live --config 2>/dev/null || true
    fi
    if [ "$(vm_state)" = "shut off" ] && [ "$DRY" = 0 ]; then
        virsh dumpxml "$VM_NAME" >"${TMP}/vm.xml"
        python3 - "${TMP}/vm.xml" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
s = re.sub(r"\s*<channel type='unix'>\s*<source mode='bind'/>\s*<target type='virtio' name='org\.qemu\.guest_agent\.0'/>.*?</channel>", "", s, count=1)
open(p, 'w').write(s)
PY
        virsh define "${TMP}/vm.xml" >/dev/null
    fi

    if [ "$DELETE_SNAPSHOT" = 1 ]; then
        run virsh snapshot-delete "$VM_NAME" pre-winapps 2>/dev/null || true
    else
        echo "  Kept snapshot 'pre-winapps' (use --delete-snapshot to remove it)."
    fi
    if [ "$SHUTDOWN_VM" = 1 ]; then
        log "Shutting down VM gracefully"
        run virsh shutdown "$VM_NAME"
    fi
fi

log "Uninstall complete"
echo "Host state:"
echo "  winapps symlink: $([ -e "${HOME}/.local/bin/winapps" ] && echo present || echo removed)"
echo "  config:          $([ -e "${HOME}/.config/winapps/winapps.conf" ] && echo present || echo removed)"
echo "  idle timer:      $(systemctl --user is-active seamwin-idle.timer 2>/dev/null || echo removed)"
echo "  VM state:        $(vm_state)"
echo
echo "Word can be restored by re-running install.sh; snapshot 'pre-winapps' is still available."
