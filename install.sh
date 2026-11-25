#!/usr/bin/env bash
# SeamWin installer - one-shot, re-runnable setup for WinApps + KVM Win10 + MS Word.
#
#   ./install.sh
#
# Environment overrides:
#   VM_NAME, RDP_IP, RDP_USER, RDP_PASS, NET_NAME, IDLE_SECONDS, DISPLAY
#
# What it does:
#   1. Installs missing host packages (asks for sudo once).
#   2. Prepares the libvirt VM (snapshot, guest-agent channel, static DHCP lease, no autostart).
#   3. If RDP is not yet available, enables it inside Windows via the SPICE console
#      (virt-viewer + XTEST keyboard automation), then logs the console off.
#   4. Writes the WinApps config and runs WinApps' own installer non-interactively.
#   5. Makes Word the default handler for Office file types.
#   6. Installs and enables the two-stage idle helper (pause -> managed save).
#
# Rollback: `virsh snapshot-revert <VM> pre-winapps` (while the VM is shut off).

set -euo pipefail

VM_NAME="${VM_NAME:-win10}"
RDP_IP="${RDP_IP:-192.168.122.2}"
RDP_USER="${RDP_USER:-Admin}"
RDP_PASS="${RDP_PASS:-}"
NET_NAME="${NET_NAME:-default}"
IDLE_SECONDS="${IDLE_SECONDS:-1200}"
DISPLAY="${DISPLAY:-:0}"
export DISPLAY

WINAPPS_REF="${WINAPPS_REF:-main}"
WINAPPS_RAW="https://raw.githubusercontent.com/winapps-org/winapps/${WINAPPS_REF}"
CONFIG="${HOME}/.config/winapps/winapps.conf"
TMP="$(mktemp -d /tmp/opencode/seamwin-install.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# FreeRDP 3.32 no longer accepts the quoted cmd:"..." value used by WinApps'
# RDP connection test. Make the whole /app argument one quoted shell word and
# leave the cmd value unquoted. This keeps the upstream checkout pristine.
patch_setup() {
    python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '/app:program:"C:\\Windows\\System32\\cmd.exe",cmd:"'
new = '"/app:program:C:\\Windows\\System32\\cmd.exe,cmd:'
if old in s:
    open(p, 'w').write(s.replace(old, new, 1))
PY
}
rdp_open() { timeout 1 bash -c ">/dev/tcp/${RDP_IP}/3389" 2>/dev/null; }
vm_state() { virsh domstate "${VM_NAME}" 2>/dev/null || echo missing; }

# ---------------------------------------------------------------- 1. packages
log "Checking host dependencies"
PKGS=(curl dialog freerdp3-x11 git iproute2 libnotify-bin netcat-openbsd
      virt-viewer wmctrl genisoimage python3-xlib python3-pil zenity)
missing=()
for p in "${PKGS[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
done
if ((${#missing[@]})); then
    log "Installing missing packages: ${missing[*]}"
    sudo -v
    sudo apt-get update -y
    sudo apt-get install -y "${missing[@]}"
else
    echo "All host dependencies already installed."
fi

# ---------------------------------------------------------------- 2. VM prep
log "Preparing libvirt VM '${VM_NAME}'"
virsh dominfo "${VM_NAME}" >/dev/null 2>&1 || die "VM '${VM_NAME}' not found"
virsh autostart --disable "${VM_NAME}" >/dev/null 2>&1 || true

if ! virsh snapshot-list "${VM_NAME}" --name 2>/dev/null | grep -qx pre-winapps; then
    virsh snapshot-create-as "${VM_NAME}" pre-winapps --description "Before WinApps integration"
fi

if ! virsh dumpxml "${VM_NAME}" | grep -q 'org.qemu.guest_agent.0'; then
    virsh dumpxml "${VM_NAME}" >"${TMP}/vm.xml"
    python3 - "${TMP}/vm.xml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
block = """    <channel type='unix'>
      <source mode='bind'/>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
      <address type='virtio-serial' controller='0' bus='0' port='2'/>
    </channel>
"""
s = s.replace('  </devices>', block + '  </devices>')
open(p, 'w').write(s)
PY
    virsh define "${TMP}/vm.xml"
    echo "Added QEMU Guest Agent channel."
fi

MAC="$(virsh domiflist "${VM_NAME}" | grep -oE '([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})' | head -1)"
[ -n "${MAC}" ] || die "Could not determine VM MAC address"
if ! virsh net-dumpxml "${NET_NAME}" | grep -qi "${MAC}"; then
    virsh net-update "${NET_NAME}" add ip-dhcp-host \
        "<host mac='${MAC}' name='${VM_NAME}' ip='${RDP_IP}'/>" --live --config
    echo "Added DHCP reservation ${MAC} -> ${RDP_IP}"
fi

# ---------------------------------------------------------------- 3. guest
# A closed RDP port can simply mean the VM is paused (stage 1), not that RDP is
# unconfigured. Make sure the VM is running before deciding to reconfigure it.
case "$(vm_state)" in
    paused)    virsh resume "${VM_NAME}" >/dev/null 2>&1 || true ;;
    "shut off") virsh start "${VM_NAME}" >/dev/null 2>&1 || true ;;
esac
for _ in $(seq 1 12); do rdp_open && break; sleep 5; done

if rdp_open; then
    log "RDP already enabled in the guest - skipping console automation"
else
    log "RDP is not listening - configuring Windows via the SPICE console"
    command -v virt-viewer >/dev/null || die "virt-viewer is required"
    python3 -c 'import Xlib' 2>/dev/null || die "python3-xlib is required"

    case "$(vm_state)" in
        running) ;;
        paused)  virsh resume "${VM_NAME}" >/dev/null 2>&1 ;;
        *)       virsh start "${VM_NAME}" >/dev/null 2>&1 ;;
    esac
    CD_TARGET="$(virsh domblklist --details "${VM_NAME}" | awk '$2=="cdrom"{print $3; exit}')"
    [ -n "${CD_TARGET}" ] || die "VM has no CD-ROM device (needed to transfer WinApps scripts)"
    ORIG_ISO="$(virsh domblklist "${VM_NAME}" | awk -v t="${CD_TARGET}" '$1==t{$1="";sub(/^ +/,"");print;exit}')"

    mkdir -p "${TMP}/iso"
    for f in RDPApps.reg install.bat TimeSync.ps1 NetProfileCleanup.ps1; do
        curl -fsSL "${WINAPPS_RAW}/oem/${f}" -o "${TMP}/iso/${f}"
    done
    genisoimage -quiet -o "${TMP}/oem.iso" "${TMP}/iso"
    virsh change-media "${VM_NAME}" "${CD_TARGET}" --eject --live >/dev/null
    virsh change-media "${VM_NAME}" "${CD_TARGET}" --insert "${TMP}/oem.iso" --live >/dev/null

    virt-viewer --connect qemu:///system "${VM_NAME}" >"${TMP}/viewer.log" 2>&1 &
    VIEWER_PID=$!
    for _ in $(seq 1 30); do wmctrl -l | grep -F "${VM_NAME}" >/dev/null && break; sleep 1; done
    wmctrl -a "${VM_NAME}" || true
    virsh screenshot "${VM_NAME}" --file "${TMP}/screen.png" >/dev/null
    read -r W H < <(python3 -c "from PIL import Image; s=Image.open('${TMP}/screen.png').size; print(s[0], s[1])")
    wmctrl -r "${VM_NAME}" -e 0,100,100,"${W}","${H}"
    sleep 2

    cat >"${TMP}/xtype.py" <<'PY'
import sys, time
from Xlib import display, X, XK
from Xlib.ext import xtest
d = display.Display()
SPECIAL = {
    ' ': 'space', '\n': 'Return', '\t': 'Tab', '.': 'period', ',': 'comma',
    ':': 'colon', ';': 'semicolon', '\\': 'backslash', '/': 'slash',
    '"': 'quotedbl', "'": 'apostrophe', '-': 'minus', '_': 'underscore',
    '=': 'equal', '+': 'plus', '(': 'parenleft', ')': 'parenright',
    '[': 'bracketleft', ']': 'bracketright', '{': 'braceleft',
    '}': 'braceright', '>': 'greater', '<': 'less', '|': 'bar',
    '&': 'ampersand', '$': 'dollar', '%': 'percent', '#': 'numbersign',
    '@': 'at', '!': 'exclam', '?': 'question', '*': 'asterisk',
    '^': 'asciicircum', '~': 'asciitilde', '`': 'grave',
}
def tap(kc, shift=False, delay=0.012):
    sk = d.keysym_to_keycode(XK.string_to_keysym('Shift_L'))
    if shift: xtest.fake_input(d, X.KeyPress, sk)
    xtest.fake_input(d, X.KeyPress, kc)
    xtest.fake_input(d, X.KeyRelease, kc)
    if shift: xtest.fake_input(d, X.KeyRelease, sk)
    d.sync(); time.sleep(delay)
def type_text(text):
    for ch in text:
        ks = XK.string_to_keysym(SPECIAL.get(ch, ch))
        kc = d.keysym_to_keycode(ks)
        shift = ch.isupper() or (d.keycode_to_keysym(kc, 0) != ks and d.keycode_to_keysym(kc, 1) == ks)
        tap(kc, shift)
def key(name):
    tap(d.keysym_to_keycode(XK.string_to_keysym(name)), delay=0.04)
mode, value = sys.argv[1], sys.argv[2]
(type_text(value) if mode == 'type' else key(value))
PY

    # Open an elevated PowerShell from the Start search (as in the X-Lite image).
    python3 "${TMP}/xtype.py" key Super_L; sleep 2
    python3 "${TMP}/xtype.py" type powershell; sleep 2
    python3 "${TMP}/xtype.py" key Return; sleep 5

    cat >"${TMP}/g1.txt" <<'EOF'
Set-Service TermService -StartupType Automatic; Start-Service TermService; Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0 -Type DWord; Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 0 -Type DWord; Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name LimitBlankPasswordUse -Value 0 -Type DWord
EOF
    cat >"${TMP}/g2.txt" <<'EOF'
New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList' -Force | Out-Null; New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList' -Name fDisabledAllowList -Value 1 -PropertyType DWord -Force | Out-Null; New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Force | Out-Null; New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name fAllowUnlistedRemotePrograms -Value 1 -PropertyType DWord -Force | Out-Null; Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon -Value '0'; Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -Name IgnoreRemoteKeyboardLayout -Value 1 -Type DWord
EOF
    cat >"${TMP}/g3.txt" <<'EOF'
Copy-Item D:\NETPROFI.PS1 C:\Windows\NetProfileCleanup.ps1 -Force; Copy-Item D:\TIMESYNC.PS1 C:\Windows\TimeSync.ps1 -Force
EOF
    cat >"${TMP}/g4.txt" <<'EOF'
schtasks /create /tn WinApps_NetworkProfileCleanup /tr "powershell.exe -ExecutionPolicy Bypass -File C:\Windows\NetProfileCleanup.ps1" /sc onstart /ru SYSTEM /rl HIGHEST /f
EOF
    cat >"${TMP}/g5.txt" <<'EOF'
schtasks /create /tn TimeSync /tr "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Windows\TimeSync.ps1" /sc onlogon /rl HIGHEST /f
EOF
    for f in g1 g2 g3 g4 g5; do
        python3 "${TMP}/xtype.py" type "$(cat "${TMP}/${f}.txt")"
        python3 "${TMP}/xtype.py" key Return
        sleep 3
    done

    ok=0
    for _ in $(seq 1 24); do rdp_open && { ok=1; break; }; sleep 5; done
    [ "${ok}" = 1 ] || die "RDP still not listening - check the guest console"

    python3 "${TMP}/xtype.py" type logoff
    python3 "${TMP}/xtype.py" key Return
    sleep 5
    kill "${VIEWER_PID}" 2>/dev/null || true
    virsh change-media "${VM_NAME}" "${CD_TARGET}" --eject --live >/dev/null
    if [ "${ORIG_ISO}" != "-" ] && [ -n "${ORIG_ISO}" ]; then
        virsh change-media "${VM_NAME}" "${CD_TARGET}" --insert "${ORIG_ISO}" --live >/dev/null
    fi
    echo "RDP enabled; Windows console logged off."
fi

# ---------------------------------------------------------------- 4. WinApps
log "Installing WinApps and registering Word"
mkdir -p "$(dirname "${CONFIG}")"
[ ! -f "${CONFIG}" ] || cp "${CONFIG}" "${CONFIG}.bak"
cat >"${CONFIG}" <<EOF
# Generated by seamwin/install.sh (backup at ${CONFIG}.bak if this file existed)
RDP_USER="${RDP_USER}"
RDP_PASS="${RDP_PASS}"
RDP_ASKPASS=""
RDP_DOMAIN=""
WAFLAVOR="libvirt"
VM_NAME="${VM_NAME}"
RDP_IP="${RDP_IP}"
RDP_PORT="3389"
RDP_SCALE="100"
RDP_DESKTOP_SCALE="inherit"
REMOVABLE_MEDIA="/run/media"
RDP_FLAGS="/cert:tofu /sound /microphone +home-drive"
RDP_FLAGS_NON_WINDOWS=""
RDP_FLAGS_WINDOWS=""
AUTOPAUSE="on"
AUTOPAUSE_TIME="60"
DEBUG="true"
PORT_TIMEOUT="5"
RDP_TIMEOUT="30"
APP_SCAN_TIMEOUT="60"
BOOT_TIMEOUT="180"
HIDEF="on"
EOF
chmod 600 "${CONFIG}"

if [ ! -f "${HOME}/.local/share/applications/word-o365.desktop" ]; then
    curl -fsSL "${WINAPPS_RAW}/setup.sh" -o "${TMP}/setup.sh"
    patch_setup "${TMP}/setup.sh"
    bash "${TMP}/setup.sh" --user --setupAllOfficiallySupportedApps
    # setup.sh always clones `main`; honour a pinned ref if one was requested.
    if [ "${WINAPPS_REF}" != "main" ]; then
        SRC="${HOME}/.local/bin/winapps-src"
        git -C "${SRC}" fetch origin "${WINAPPS_REF}" >/dev/null 2>&1 || git -C "${SRC}" fetch origin >/dev/null 2>&1
        git -C "${SRC}" checkout --detach "${WINAPPS_REF}" >/dev/null 2>&1 || \
            git -C "${SRC}" checkout --detach FETCH_HEAD >/dev/null 2>&1
    fi
else
    echo "Word desktop entry already present - skipping WinApps setup."
fi

# Provide a patched `winapps-setup` wrapper so future --add-apps runs do not
# hit the FreeRDP 3.32 cmd:"..." parsing bug. The upstream clone stays clean.
mkdir -p "${HOME}/.local/share/seamwin"
curl -fsSL "${WINAPPS_RAW}/setup.sh" -o "${HOME}/.local/share/seamwin/setup.sh"
patch_setup "${HOME}/.local/share/seamwin/setup.sh"
chmod +x "${HOME}/.local/share/seamwin/setup.sh"
ln -sf "${HOME}/.local/share/seamwin/setup.sh" "${HOME}/.local/bin/winapps-setup"

# Spinner wrapper: shows a zenity progress dialog while the VM boots/starts
# the app, then closes it once the real FreeRDP session is up.
cat >"${HOME}/.local/share/seamwin/winapps-loader" <<'EOF'
#!/usr/bin/env bash
set -u
REAL="${HOME}/.local/bin/winapps-src/bin/winapps"
CMD="${1:-}"
case "$CMD" in
    killrdp|--help|-h|help) exec "$REAL" "$@" ;;
esac
LABEL="Windows app"
DESKTOP="${HOME}/.local/share/applications/${CMD}.desktop"
if [ -f "$DESKTOP" ]; then
    NAME=$(sed -n 's/^Name=//p' "$DESKTOP" | head -1)
    [ -n "$NAME" ] && LABEL="$NAME"
fi
case "$CMD" in
    windows) LABEL="Windows desktop" ;;
    manual)  LABEL="${2:-Windows app}" ;;
esac
if ! command -v zenity >/dev/null 2>&1; then
    exec "$REAL" "$@"
fi
TMP=$(mktemp -d /tmp/opencode/seamwin-loader.XXXXXX)
FIFO="${TMP}/progress"
mkfifo "$FIFO"
# An open stdin is required for zenity's pulsate animation to keep moving.
( exec >"$FIFO"; sleep 600 ) 2>/dev/null &
WRITER=$!
zenity --progress --pulsate --title="SeamWin" \
    --text="Starting ${LABEL}…" --width=320 --no-cancel <"$FIFO" >/dev/null 2>&1 &
LOADER=$!
trap 'kill "$WRITER" "$LOADER" 2>/dev/null || true; rm -rf "$TMP"' EXIT
# Keep the loader visible above other windows so the animation can be seen.
for _ in $(seq 1 20); do
    wmctrl -l 2>/dev/null | grep -q ' SeamWin$' && break
    sleep 0.1
done
wmctrl -r SeamWin -b add,above 2>/dev/null || true
START=$SECONDS
"$REAL" "$@" &
WPID=$!
DEADLINE=$((SECONDS + 180))
READY_TICKS=0
# WinApps launches xfreerdp3 as a direct child. Once it has been alive for a
# couple of seconds, the RDP session is connected and the spinner can go.
while kill -0 "$WPID" 2>/dev/null && [ "$SECONDS" -lt "$DEADLINE" ]; do
    if pgrep -P "$WPID" -x xfreerdp3 >/dev/null 2>&1; then
        READY_TICKS=$((READY_TICKS + 1))
        [ "$READY_TICKS" -ge 4 ] && break
    else
        READY_TICKS=0
    fi
    sleep 0.5
done
while [ $((SECONDS - START)) -lt 1 ]; do sleep 0.2; done
kill "$WRITER" "$LOADER" 2>/dev/null || true
wait "$WPID"
exit $?
EOF
chmod +x "${HOME}/.local/share/seamwin/winapps-loader"
ln -sf "${HOME}/.local/share/seamwin/winapps-loader" "${HOME}/.local/bin/winapps"

for m in application/msword \
         application/vnd.openxmlformats-officedocument.wordprocessingml.document \
         application/vnd.openxmlformats-officedocument.wordprocessingml.template \
         application/vnd.ms-word.document.macroEnabled.12 \
         application/vnd.ms-word.template.macroEnabled.12; do
    xdg-mime default word-o365.desktop "${m}"
done
for s in ms-word ms-excel ms-powerpoint ms-outlook ms-access ms-visio \
         ms-project ms-teams ms-whiteboard ms-officeapp; do
    xdg-settings set default-url-scheme-handler "${s}" ms-office-protocol-handler.desktop 2>/dev/null || true
done

# ---------------------------------------------------------------- 5. idle helper
log "Installing the two-stage idle helper"
mkdir -p "${HOME}/.local/bin" "${HOME}/.config/systemd/user"
cat >"${HOME}/.local/bin/seamwin-idle" <<'EOF'
#!/usr/bin/env bash
# Stage 2: after WinApps has paused the VM and no Windows app is in use,
# write RAM to disk so the VM is truly off. The next Word launch restores it.
set -u
VM_NAME="win10"
STATE_DIR="${HOME}/.local/share/seamwin"
IDLE_FILE="${STATE_DIR}/idle_since"
WA_SHARE="${HOME}/.local/share/winapps"
IDLE_SECONDS="${SEAMWIN_IDLE_SECONDS:-1200}"
mkdir -p "${STATE_DIR}"
exec 9>"${STATE_DIR}/.lock"
flock -n 9 || exit 0
session_active() {
    compgen -G "${WA_SHARE}/FreeRDP_Process_*.cproc" >/dev/null || pgrep -x xfreerdp3 >/dev/null
}
state=$(virsh domstate "${VM_NAME}" 2>/dev/null || echo "")
case "$state" in paused|running) ;; *) rm -f "${IDLE_FILE}"; exit 0 ;; esac
if session_active; then rm -f "${IDLE_FILE}"; exit 0; fi
now=$(date +%s)
if [ ! -f "${IDLE_FILE}" ]; then echo "${now}" >"${IDLE_FILE}"; exit 0; fi
since=$(cat "${IDLE_FILE}" 2>/dev/null || echo "${now}")
(( now - since < IDLE_SECONDS )) && exit 0
state=$(virsh domstate "${VM_NAME}" 2>/dev/null || echo "")
if session_active || { [ "$state" != paused ] && [ "$state" != running ]; }; then
    rm -f "${IDLE_FILE}"; exit 0
fi
# --running makes the next `virsh start` restore a running domain, which is
# what WinApps' readiness check expects.
if virsh dumpxml "${VM_NAME}" 2>/dev/null | grep -q '<hostdev'; then
    # GPU/USB/PCI passthrough cannot be managed-saved; shut down gracefully instead.
    virsh shutdown "${VM_NAME}" >/dev/null 2>&1 && {
        notify-send --app-name=SeamWin "Windows shut down" "VM powered off; next Word launch boots it." 2>/dev/null || true
        rm -f "${IDLE_FILE}"
    }
elif virsh managedsave --running "${VM_NAME}" >/dev/null 2>&1; then
    notify-send --app-name=SeamWin "Windows saved to disk" "VM powered off; next Word launch restores it." 2>/dev/null || true
    rm -f "${IDLE_FILE}"
fi
EOF
chmod 700 "${HOME}/.local/bin/seamwin-idle"
sed -i "s|^VM_NAME=.*|VM_NAME=\"${VM_NAME}\"|" "${HOME}/.local/bin/seamwin-idle"

cat >"${HOME}/.config/systemd/user/seamwin-idle.service" <<'EOF'
[Unit]
Description=Power down an idle WinApps Windows VM (managed save)
After=graphical-session.target
[Service]
Type=oneshot
Environment=LIBVIRT_DEFAULT_URI=qemu:///system
ExecStart=%h/.local/bin/seamwin-idle
EOF
cat >"${HOME}/.config/systemd/user/seamwin-idle.timer" <<'EOF'
[Unit]
Description=Check every minute for an idle WinApps Windows VM
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
Persistent=true
Unit=seamwin-idle.service
[Install]
WantedBy=timers.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now seamwin-idle.timer

# ---------------------------------------------------------------- 6. done
log "Install complete"
echo "VM state:          $(vm_state)"
echo "RDP:               $(rdp_open && echo reachable || echo not-yet-reachable)"
echo "Word desktop:      $([ -f "${HOME}/.local/share/applications/word-o365.desktop" ] && echo installed || echo MISSING)"
echo "Default .docx:     $(xdg-mime query default application/vnd.openxmlformats-officedocument.wordprocessingml.document)"
echo "Idle timer:        $(systemctl --user is-active seamwin-idle.timer)"
echo "WinApps ref:       ${WINAPPS_REF} (runtime: ~/.local/bin/winapps-src)"
echo "Idle threshold:    ${IDLE_SECONDS}s (edit ~/.local/bin/seamwin-idle or export SEAMWIN_IDLE_SECONDS)"
echo
echo "Try it:  ~/.local/bin/winapps word-o365 ~/Documents/your-file.docx"
echo "Rollback: virsh snapshot-revert ${VM_NAME} pre-winapps  (VM must be shut off)"
