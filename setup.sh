#!/usr/bin/env bash
# =============================================================================
#  Brigandry kiosk setup — Ubuntu Server 26.04 LTS
#
#  Turns a fresh minimal Ubuntu Server install into a locked-down web kiosk:
#    - a passwordless "kiosk" user with no sudo
#    - Google Chrome in kiosk mode inside cage (a single-app Wayland compositor)
#    - URL allowlist, downloads/printing/devtools off
#    - idle timeout: after N seconds of no input, Chrome is killed and relaunched
#      back at the homepage (the profile is KEPT so the kiosk login survives)
#    - Wi-Fi on the guest SSID
#    - unattended security updates + nightly 4 AM reboot
#    - SSH key-only login (if you pass a public key)
#
#  USAGE (run at the kiosk's own keyboard, as your admin user):
#      sudo bash setup.sh kiosk1
#      sudo bash setup.sh kiosk1 /home/nick/mac.pub    # also installs SSH key
#
#  Re-running is safe; it rewrites its config files each time.
# =============================================================================

# ---- shell safety flags -----------------------------------------------------
#  -e : stop the script on the first command that fails
#  -u : treat an unset variable as an error (catches typos)
#  -o pipefail : a pipeline fails if any command in it fails, not just the last
set -euo pipefail

# ======================= SETTINGS — EDIT THESE ===============================

# Page the kiosk opens on. TCGplayer Pro's In-Store Kiosk lives here, not on
# the Pro website. It needs a one-time login with a Kiosk User account
# (Seller Portal -> TCGplayer Pro Settings -> Set User Roles -> Add Kiosk User).
# One account per physical kiosk; TCGplayer won't let one account be signed
# in on two devices. Orders it takes are "In-Store Pickup, Pay Later" only.
HOMEPAGE="https://kiosk.tcgplayer.com/"

# Domains customers are allowed to navigate to. Everything else is blocked.
# A bare domain also matches every subdomain, so "tcgplayer.com" covers
# kiosk.tcgplayer.com and its login pages. Add anything else you discover
# the checkout flow needs after a test order.
ALLOWLIST=(
  "tcgplayer.com"
  "tcgplayerpro.com"
)

# Seconds of no keyboard/mouse input before the session resets. 300 = 5 min.
IDLE_SECONDS=300

# Wi-Fi network the kiosk joins. This is only the DEFAULT offered at run time;
# the script asks you to confirm or retype it. The password is also asked for
# at run time so it never lives in this file (which is going on GitHub).
WIFI_SSID_DEFAULT="Brigandry Guest"

TIMEZONE="America/Chicago"

# =============================================================================
#  Nothing below needs editing.
# =============================================================================

# ---- argument handling ------------------------------------------------------
#  $# is the number of arguments; $1 is the first one, $2 the second.
if [[ $# -lt 1 ]]; then
  echo "Usage: sudo bash $0 <hostname> [ssh-public-key-file]" >&2
  exit 1
fi
NEW_HOSTNAME="$1"
SSH_PUBKEY_FILE="${2:-}"          # ${2:-} = "$2 if set, otherwise empty"

#  $EUID is the numeric ID of the user running the script; 0 is root.
if [[ $EUID -ne 0 ]]; then
  echo "Run this with sudo." >&2
  exit 1
fi

#  sudo sets SUDO_USER to the account that invoked it — your admin user.
ADMIN_USER="${SUDO_USER:-}"
if [[ -z "$ADMIN_USER" || "$ADMIN_USER" == "root" ]]; then
  echo "Run this via sudo from your normal admin account, not as root directly." >&2
  exit 1
fi

# A small helper so progress is easy to follow on screen.
step() { echo; echo "==> $*"; }

# ---- 1. hostname and timezone -----------------------------------------------
step "Setting hostname to $NEW_HOSTNAME and timezone to $TIMEZONE"
hostnamectl set-hostname "$NEW_HOSTNAME"
#  sed -i edits a file in place; this rewrites the 127.0.1.1 line in /etc/hosts
#  so sudo doesn't complain about an unknown hostname.
sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
grep -q "^127\.0\.1\.1" /etc/hosts || printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >> /etc/hosts
timedatectl set-timezone "$TIMEZONE"

# ---- 2. packages ------------------------------------------------------------
step "Installing packages"
export DEBIAN_FRONTEND=noninteractive   # never pause for a dialog box
apt-get update
apt-get install -y \
  cage \
  swayidle \
  wpasupplicant \
  unattended-upgrades \
  curl \
  wget \
  fonts-liberation \
  fonts-noto-color-emoji

step "Installing Google Chrome"
#  wget -qO FILE URL : download quietly (-q) to a named output file (-O)
wget -qO /tmp/google-chrome.deb \
  https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
#  apt-get can install a local .deb and pull in its dependencies.
#  Chrome's package also registers Google's apt repo, so it updates via apt.
apt-get install -y /tmp/google-chrome.deb
rm -f /tmp/google-chrome.deb

# ---- 3. kiosk user ----------------------------------------------------------
step "Creating kiosk user"
#  id -u USER exits non-zero if the user doesn't exist; || runs the useradd then.
#  --create-home makes /home/kiosk; --shell nologin means it can't get a shell.
#  No password is ever set, so nobody can log in as it at the console.
id -u kiosk >/dev/null 2>&1 || useradd --create-home --shell /usr/sbin/nologin kiosk

# ---- 4. Chrome policy (the lockdown) ----------------------------------------
step "Writing Chrome policy"
POLICY_DIR=/etc/opt/chrome/policies/managed
mkdir -p "$POLICY_DIR"

#  Build a JSON array string from the ALLOWLIST bash array.
ALLOW_JSON=""
for d in "${ALLOWLIST[@]}"; do
  ALLOW_JSON+="\"$d\","
done
ALLOW_JSON="${ALLOW_JSON%,}"        # strip the trailing comma

#  URL containment is DISARMED. A blocklist of ["*"] blocks not just other
#  sites but the third-party asset/auth/CDN domains the TCGplayer kiosk login
#  pulls from, which breaks the sign-in and the storefront. Enumerating every
#  one of those domains is fragile (TCGplayer can change them anytime and
#  silently break the kiosk), so the blocklist is left empty. Containment now
#  rests on kiosk mode (no address bar to type a URL) plus the isolated guest
#  VLAN. The allowlist below is inert while the blocklist is empty; it's kept
#  as the record of intended sites. To RE-ARM strict lockdown once you've
#  walked the login with DevTools and collected every asset domain, set
#  "URLBlocklist" back to ["*"] and add those domains to the ALLOWLIST array.

#  cat > FILE <<EOF ... EOF writes everything between the markers to FILE.
#  Variables like $HOMEPAGE are expanded because EOF is unquoted.
cat > "$POLICY_DIR/kiosk.json" <<EOF
{
  "URLBlocklist": [],
  "URLAllowlist": [$ALLOW_JSON],

  "HomepageLocation": "$HOMEPAGE",
  "HomepageIsNewTabPage": false,
  "NewTabPageLocation": "$HOMEPAGE",
  "RestoreOnStartup": 4,
  "RestoreOnStartupURLs": ["$HOMEPAGE"],

  "DeveloperToolsAvailability": 2,
  "DownloadRestrictions": 3,
  "PrintingEnabled": false,
  "AllowFileSelectionDialogs": false,
  "ExtensionInstallBlocklist": ["*"],

  "BrowserSignin": 0,
  "SyncDisabled": true,
  "BrowserAddPersonEnabled": false,
  "BrowserGuestModeEnabled": false,
  "IncognitoModeAvailability": 1,
  "PasswordManagerEnabled": false,
  "AutofillAddressEnabled": false,
  "AutofillCreditCardEnabled": false,
  "SavingBrowserHistoryDisabled": true,

  "TranslateEnabled": false,
  "MetricsReportingEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "BackgroundModeEnabled": false,
  "PromotionsEnabled": false,
  "BookmarkBarEnabled": false,
  "ShowHomeButton": false,

  "DefaultNotificationsSetting": 2,
  "DefaultGeolocationSetting": 2,
  "AudioCaptureAllowed": false,
  "VideoCaptureAllowed": false
}
EOF

# ---- 5. kiosk runtime config + session script -------------------------------
step "Writing kiosk session script"
mkdir -p /etc/kiosk
cat > /etc/kiosk/kiosk.conf <<EOF
HOMEPAGE="$HOMEPAGE"
IDLE_SECONDS=$IDLE_SECONDS
EOF

#  This is the program cage launches. It waits for the network, starts the idle
#  watcher, then runs Chrome. When Chrome exits (idle kill, crash, Ctrl+W...)
#  the script ends, cage ends, and systemd restarts the whole thing fresh.
#  'EOF' is QUOTED here so nothing inside is expanded now — it's a file that
#  will run later, with its own variables.
cat > /usr/local/bin/kiosk-session <<'EOF'
#!/usr/bin/env bash
set -u
source /etc/kiosk/kiosk.conf

# Persistent browser profile. This is deliberately NOT wiped between sessions:
# it holds the cookie that keeps the TCGplayer Kiosk User signed in. Run
# kiosk-reset (as root) if you ever need to force a fresh login.
PROFILE="$HOME/.config/kiosk-chrome"
mkdir -p "$PROFILE"

# Wait up to ~60 s for the storefront to be reachable, so Chrome doesn't
# open on an error page while Wi-Fi is still connecting.
for _ in $(seq 1 30); do
  curl -sfI --max-time 3 "$HOMEPAGE" >/dev/null && break
  sleep 2
done

# Launch Chrome in the BACKGROUND and remember its process id ($!).
google-chrome \
  --kiosk "$HOMEPAGE" \
  --ozone-platform=wayland \
  --user-data-dir="$PROFILE" \
  --disk-cache-size=104857600 \
  --no-first-run \
  --noerrdialogs \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --disable-features=TranslateUI \
  --overscroll-history-navigation=0 \
  --disable-pinch \
  --password-store=basic \
  --check-for-update-interval=31536000 &
CHROME_PID=$!

# Remember THIS script's own process id so swayidle can end it by number.
SESSION_PID=$$

# swayidle watches for inactivity. After IDLE_SECONDS with no input it sends
# SIGTERM to this script. That ends the script, which ends cage, and systemd
# (Restart=always) then starts the whole service again from scratch — a clean
# relaunch, not a sniped process left behind as a zombie.
#  -w  finish one command before listening for the next event
#  The command is DOUBLE-quoted so $SESSION_PID is filled in now, giving
#  swayidle a fixed "kill -TERM <number>" to run when it fires.
swayidle -w timeout "$IDLE_SECONDS" "kill -TERM $SESSION_PID" &
SWAYIDLE_PID=$!

# On the way out (for any reason) stop swayidle and Chrome so nothing lingers
# into the next run.
cleanup() {
  kill "$SWAYIDLE_PID" 2>/dev/null || true
  kill "$CHROME_PID"   2>/dev/null || true
}
trap cleanup EXIT
#  When swayidle's SIGTERM arrives, exit cleanly (which runs cleanup above).
trap 'exit 0' TERM

# Block here until Chrome exits on its own (crash, Ctrl+W). If swayidle fires
# first, the TERM trap exits the script before this returns. Either path ends
# the session and hands control back to systemd for a fresh start.
wait "$CHROME_PID"
EOF
chmod +x /usr/local/bin/kiosk-session

#  Staff helper: wipes the browser profile (forcing a fresh TCGplayer login)
#  and restarts the kiosk. Run over SSH:  sudo kiosk-reset
cat > /usr/local/bin/kiosk-reset <<'EOF'
#!/usr/bin/env bash
set -e
systemctl stop kiosk
rm -rf /home/kiosk/.config/kiosk-chrome
systemctl start kiosk
echo "Kiosk profile wiped and restarted. Sign in again at the screen."
EOF
chmod +x /usr/local/bin/kiosk-reset

# ---- 6. systemd service that owns tty1 --------------------------------------
step "Installing kiosk.service"
#  PAMName=login + TTYPath=/dev/tty1 make systemd open a real login session on
#  the first console for the kiosk user. That's what lets cage take over the
#  display and input devices without running as root.
cat > /etc/systemd/system/kiosk.service <<'EOF'
[Unit]
Description=Brigandry web kiosk (cage + Chrome)
After=systemd-user-sessions.service network-online.target
Wants=network-online.target
Conflicts=getty@tty1.service

[Service]
User=kiosk
Group=kiosk
PAMName=login
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty
StandardOutput=journal
StandardError=journal
UtmpIdentifier=tty1
UtmpMode=user
ExecStart=/usr/bin/cage -d -- /usr/local/bin/kiosk-session
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

#  Stop the normal text login from fighting over tty1.
systemctl disable getty@tty1.service
systemctl daemon-reload
systemctl enable kiosk.service

# ---- 7. hardening odds and ends ---------------------------------------------
step "Disabling sleep and Ctrl+Alt+Del"
#  mask = point the unit at /dev/null so nothing can start it
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
systemctl mask ctrl-alt-del.target

# ---- 8. Wi-Fi ---------------------------------------------------------------
step "Configuring Wi-Fi"
#  Find the wireless interface name (wl... e.g. wlp2s0). May differ per machine.
WIFI_IFACE="$(ls /sys/class/net | grep '^wl' | head -n 1 || true)"
if [[ -z "$WIFI_IFACE" ]]; then
  echo "No wireless interface found — skipping Wi-Fi. (Ethernet still works.)"
else
  #  read -r -p PROMPT VAR : ask a question and store the answer in VAR.
  #  ${VAR:-default} means "use VAR, or the default if it was left empty".
  read -r -p "Wi-Fi SSID [$WIFI_SSID_DEFAULT]: " WIFI_SSID
  WIFI_SSID="${WIFI_SSID:-$WIFI_SSID_DEFAULT}"
  #  -s hides what you type (for the password).
  read -r -s -p "Wi-Fi password for '$WIFI_SSID': " WIFI_PASS; echo
  cat > /etc/netplan/60-kiosk-wifi.yaml <<EOF
network:
  version: 2
  wifis:
    $WIFI_IFACE:
      optional: true
      dhcp4: true
      access-points:
        "$WIFI_SSID":
          password: "$WIFI_PASS"
EOF
  chmod 600 /etc/netplan/60-kiosk-wifi.yaml   # owner read/write only — it holds a password
  #  Also mark the wired port optional so boot doesn't stall when it's unplugged.
  sed -i 's/^\(\s*dhcp4: true\)$/\1\n      optional: true/' /etc/netplan/50-cloud-init.yaml 2>/dev/null || true
  netplan generate
  netplan apply
fi

# ---- 9. updates + nightly reboot --------------------------------------------
step "Configuring unattended upgrades and 4 AM reboot"
cat > /etc/apt/apt.conf.d/52kiosk <<'EOF'
// Also pull normal (non-security) updates and Chrome's own repo.
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-updates";
    "Google LLC:stable";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
// Reboots are handled by kiosk-reboot.timer instead.
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/systemd/system/kiosk-reboot.service <<'EOF'
[Unit]
Description=Nightly kiosk reboot

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl reboot
EOF

cat > /etc/systemd/system/kiosk-reboot.timer <<'EOF'
[Unit]
Description=Reboot the kiosk every night at 4 AM

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=false

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now kiosk-reboot.timer

# ---- 10. SSH ----------------------------------------------------------------
step "Configuring SSH"
#  ufw is Ubuntu's simple firewall. Allow SSH, then turn it on.
ufw allow OpenSSH >/dev/null
ufw --force enable >/dev/null

if [[ -n "$SSH_PUBKEY_FILE" ]]; then
  if [[ ! -f "$SSH_PUBKEY_FILE" ]]; then
    echo "SSH key file $SSH_PUBKEY_FILE not found." >&2
    exit 1
  fi
  ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  #  install -d: make a directory with given owner and mode (0700 = owner only)
  install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ADMIN_HOME/.ssh"
  touch "$ADMIN_HOME/.ssh/authorized_keys"
  #  Add the key only if it isn't already there (grep -qF: quiet, fixed-string).
  grep -qF "$(cat "$SSH_PUBKEY_FILE")" "$ADMIN_HOME/.ssh/authorized_keys" \
    || cat "$SSH_PUBKEY_FILE" >> "$ADMIN_HOME/.ssh/authorized_keys"
  chown "$ADMIN_USER:$ADMIN_USER" "$ADMIN_HOME/.ssh/authorized_keys"
  chmod 0600 "$ADMIN_HOME/.ssh/authorized_keys"

  #  sshd reads config.d files in name order and the FIRST value wins,
  #  so "10-" sorts ahead of Ubuntu's "50-cloud-init.conf".
  cat > /etc/ssh/sshd_config.d/10-kiosk.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
  systemctl restart ssh
  echo "SSH is now key-only for $ADMIN_USER."
else
  echo "No SSH key given — leaving password login on. Re-run with a key file to lock it down."
fi

# ---- done -------------------------------------------------------------------
step "Done"
echo "Hostname : $NEW_HOSTNAME"
echo "Homepage : $HOMEPAGE"
echo "Idle     : ${IDLE_SECONDS}s"
echo "Wi-Fi    : ${WIFI_IFACE:-none} -> ${WIFI_SSID:-n/a}"
echo
echo "Reboot to start the kiosk:   sudo reboot"
echo "Then sign in once on screen with this kiosk's TCGplayer Kiosk User."
echo "Watch it from SSH later:     journalctl -fu kiosk"
echo "Force a fresh login later:   sudo kiosk-reset"
