#!/usr/bin/env bash
# =============================================================================
# Renew Lab OS — setup script (DRAFT v0.2, Debian edition)
# Target: fresh Debian 13 "trixie" amd64 install with the Xfce desktop
#
# Workflow per machine:
#   1. Install Debian 13 (netinstall) -> pick "Xfce" + "standard system utilities".
#      Create a temporary prep account (e.g. "prep") with sudo rights.
#   2. sudo ./renewlab-os-setup.sh --logo logo.png --age primary [options]
#   3. Reboot, test everything (splash, apps, Roblox block, theme toggle).
#   4. sudo ./renewlab-os-setup.sh --arm-firstboot prep
#      -> shut down and ship. The buyer gets a first-boot wizard that creates
#         a parent (admin) account and an optional child (standard) account.
#         Your prep account and the wizard account are deleted automatically.
#
# Options:
#   --logo FILE            Transparent PNG for boot splash (~300-400 px wide)
#   --age GROUP            preschool | primary | secondary   (default: primary)
#   --lowspec              zram (compressed RAM swap) + compositor off
#   --disable-panel NAME   Disable dead internal screen (e.g. eDP-1, LVDS-1)
#   --dns-filter MODE      family (default) | cloudflare | off  — family-safe DNS
#                          (parents can change later: sudo renewlab-safety MODE)
#   --arm-firstboot USER   Final step before shipping (see above). USER = prep
#                          account to delete on the buyer's first boot.
#   -h, --help             Show this header
#
# Package names marked in comments as "verified" were checked against the
# Debian package tracker for stable (trixie). Everything is installed through
# install_pkgs(), which skips (and logs) any name apt can't find instead of
# aborting — check the log for "MISSING".
# =============================================================================

set -euo pipefail

LOG="/var/log/renewlab-os-setup.log"
STATE_DIR="/var/lib/renewlab"
THEME_NAME="renewlab"
PLY_THEMES="/usr/share/plymouth/themes"
SETUP_USER="renewlab-setup"

LOGO=""
AGE="primary"
LOWSPEC=0
DISABLE_PANEL=""
ARM_PREP_USER=""
DNS_FILTER="family"

# Roblox: main site, CDN, tracking (per Cisco/OpenDNS guidance)
ROBLOX_DOMAINS=(roblox.com rbxcdn.com rbxtrk.com)

# ---------- helpers ----------------------------------------------------------
say()  { echo -e "\n\033[1;32m==> $*\033[0m" | tee -a "$LOG"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m" | tee -a "$LOG"; }
die()  { echo -e "\033[1;31m[x] $*\033[0m" | tee -a "$LOG"; exit 1; }
usage() { sed -n '2,33p' "$0"; exit 0; }

# Install only packages apt knows about; log the rest as MISSING.
install_pkgs() {
  local ok=() p
  for p in "$@"; do
    if apt-cache show "$p" >/dev/null 2>&1; then ok+=("$p")
    else warn "MISSING package (skipped): $p"; fi
  done
  [[ ${#ok[@]} -gt 0 ]] && apt-get -y install "${ok[@]}" 2>&1 | tee -a "$LOG"
  return 0
}

# ---------- args -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --logo)          LOGO="${2:-}"; shift 2 ;;
    --age)           AGE="${2:-}"; shift 2 ;;
    --lowspec)       LOWSPEC=1; shift ;;
    --disable-panel) DISABLE_PANEL="${2:-}"; shift 2 ;;
    --dns-filter)    DNS_FILTER="${2:-}"; shift 2 ;;
    --arm-firstboot) ARM_PREP_USER="${2:-}"; shift 2 ;;
    -h|--help)       usage ;;
    *)               die "Unknown option: $1 (try --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run with sudo."
mkdir -p "$STATE_DIR"
touch "$LOG"

# =============================================================================
# FIRST-BOOT WIZARD (armed as the very last step before shipping)
# =============================================================================
arm_firstboot() {
  local prep="$1"
  say "Arming first-boot wizard (prep account to remove: $prep)"
  id "$prep" >/dev/null 2>&1 || die "User '$prep' does not exist."
  command -v lightdm >/dev/null || die "LightDM not found (expected with Debian Xfce)."
  install_pkgs zenity            # verified: 4.1.90-1

  # 1) Wizard account: standard user, no password, auto-login
  if ! id "$SETUP_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "Renew Lab" "$SETUP_USER" | tee -a "$LOG"
  fi
  passwd -d "$SETUP_USER" >/dev/null
  getent group autologin >/dev/null || groupadd autologin
  usermod -aG autologin "$SETUP_USER"

  mkdir -p /etc/lightdm/lightdm.conf.d
  cat > /etc/lightdm/lightdm.conf.d/90-renewlab-firstboot.conf <<EOF
[Seat:*]
autologin-user=$SETUP_USER
autologin-user-timeout=0
autologin-session=xfce
EOF

  # 2) The ONLY root command the wizard account may run
  cat > /etc/sudoers.d/renewlab-firstboot <<EOF
$SETUP_USER ALL=(root) NOPASSWD: /usr/local/sbin/renewlab-firstboot-apply
EOF
  chmod 0440 /etc/sudoers.d/renewlab-firstboot
  visudo -cf /etc/sudoers.d/renewlab-firstboot >/dev/null || die "sudoers check failed"

  # 3) Root-side apply script (validates everything it is given)
  cat > /usr/local/sbin/renewlab-firstboot-apply <<'APPLY'
#!/usr/bin/env bash
# Reads key=value lines on stdin: LANGCODE, PNAME, PUSER, PPASS, CNAME, CUSER, CPASS
set -euo pipefail
declare -A V
while IFS='=' read -r k v; do V["$k"]="$v"; done
valid_user() { [[ "$1" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] && ! id "$1" >/dev/null 2>&1; }
valid_user "${V[PUSER]:-}" || { echo "BAD_PARENT_USER"; exit 2; }
PP="${V[PPASS]:-}"; [[ ${#PP} -ge 6 ]] || { echo "SHORT_PARENT_PASS"; exit 2; }
if [[ -n "${V[CUSER]:-}" ]]; then
  if [[ "${V[CUSER]}" == "${V[PUSER]}" ]] || ! valid_user "${V[CUSER]}"; then
    echo "BAD_CHILD_USER"; exit 2
  fi
fi
gecos() { echo "${1//[,:=]/ }"; }

adduser --disabled-password --gecos "$(gecos "${V[PNAME]:-}")" "${V[PUSER]}"
printf '%s:%s\n' "${V[PUSER]}" "$PP" | chpasswd
usermod -aG sudo "${V[PUSER]}"

if [[ -n "${V[CUSER]:-}" ]]; then
  adduser --disabled-password --gecos "$(gecos "${V[CNAME]:-}")" "${V[CUSER]}"
  if [[ -n "${V[CPASS]:-}" ]]; then
    printf '%s:%s\n' "${V[CUSER]}" "${V[CPASS]}" | chpasswd
  else
    passwd -d "${V[CUSER]}"   # no password for small kids
  fi
fi

if [[ "${V[LANGCODE]:-}" == "sv" ]]; then
  localectl set-locale LANG=sv_SE.UTF-8
else
  localectl set-locale LANG=en_GB.UTF-8
fi
localectl set-x11-keymap se

# Stop auto-login, schedule removal of wizard + prep accounts on next boot
rm -f /etc/lightdm/lightdm.conf.d/90-renewlab-firstboot.conf
touch /var/lib/renewlab/cleanup-pending
systemd-run --on-active=10 /usr/bin/systemctl reboot >/dev/null 2>&1 || true
echo "OK"
APPLY
  chmod 0755 /usr/local/sbin/renewlab-firstboot-apply

  # 4) User-side wizard (zenity), bilingual
  cat > /usr/local/bin/renewlab-firstboot-wizard <<'WIZ'
#!/usr/bin/env bash
set -uo pipefail
SEP=$'\x1f'
Z() { zenity --width=460 "$@"; }

while true; do
  LANGCODE=$(Z --list --radiolist --title="Renew Lab" \
    --text="Välj språk / Choose language" --hide-header \
    --column="" --column="code" --column="Language" --hide-column=2 \
    TRUE sv "Svenska" FALSE en "English") || continue
  [[ -z "$LANGCODE" ]] && continue

  if [[ "$LANGCODE" == "sv" ]]; then
    T_WELCOME="Välkommen till din Renew Lab-dator!\n\nFörst skapar vi ett konto för en vuxen. Det kontot styr datorn och skärmtiden."
    T_PARENT="Vuxenkonto"; T_NAME="Namn"; T_USER="Användarnamn (små bokstäver)"
    T_PASS="Lösenord (minst 6 tecken)"; T_PASS2="Upprepa lösenord"
    T_CHILDQ="Vill du skapa ett barnkonto också?"
    T_CHILD="Barnkonto"; T_CPASS="Lösenord (lämna tomt för inget)"
    T_MISMATCH="Lösenorden matchar inte."; T_DONE="Klart! Datorn startar om nu."
    T_ERR="Något blev fel. Kontrollera uppgifterna och försök igen."
  else
    T_WELCOME="Welcome to your Renew Lab computer!\n\nFirst we create an account for an adult. That account controls the computer and screen time."
    T_PARENT="Adult account"; T_NAME="Name"; T_USER="Username (lowercase)"
    T_PASS="Password (at least 6 characters)"; T_PASS2="Repeat password"
    T_CHILDQ="Do you want to create a child account too?"
    T_CHILD="Child account"; T_CPASS="Password (leave empty for none)"
    T_MISMATCH="The passwords don't match."; T_DONE="Done! The computer will now restart."
    T_ERR="Something went wrong. Check the details and try again."
  fi

  Z --info --title="Renew Lab" --text="$T_WELCOME" || continue

  P=$(Z --forms --title="$T_PARENT" --separator="$SEP" \
      --add-entry="$T_NAME" --add-entry="$T_USER" \
      --add-password="$T_PASS" --add-password="$T_PASS2") || continue
  IFS="$SEP" read -r PNAME PUSER PPASS PPASS2 <<<"$P"
  [[ "$PPASS" == "$PPASS2" ]] || { Z --error --text="$T_MISMATCH"; continue; }

  CNAME=""; CUSER=""; CPASS=""
  if Z --question --title="Renew Lab" --text="$T_CHILDQ"; then
    C=$(Z --forms --title="$T_CHILD" --separator="$SEP" \
        --add-entry="$T_NAME" --add-entry="$T_USER" --add-password="$T_CPASS") || continue
    IFS="$SEP" read -r CNAME CUSER CPASS <<<"$C"
  fi

  OUT=$(printf 'LANGCODE=%s\nPNAME=%s\nPUSER=%s\nPPASS=%s\nCNAME=%s\nCUSER=%s\nCPASS=%s\n' \
        "$LANGCODE" "$PNAME" "$PUSER" "$PPASS" "$CNAME" "$CUSER" "$CPASS" \
        | sudo -n /usr/local/sbin/renewlab-firstboot-apply 2>&1)
  if [[ "$OUT" == *OK ]]; then
    Z --info --title="Renew Lab" --text="$T_DONE" --timeout=8
    exit 0
  fi
  Z --error --text="$T_ERR\n\n($OUT)"
done
WIZ
  chmod 0755 /usr/local/bin/renewlab-firstboot-wizard

  local home; home=$(getent passwd "$SETUP_USER" | cut -d: -f6)
  mkdir -p "$home/.config/autostart"
  cat > "$home/.config/autostart/renewlab-firstboot.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Renew Lab setup
Exec=/usr/local/bin/renewlab-firstboot-wizard
X-GNOME-Autostart-enabled=true
EOF
  chown -R "$SETUP_USER:$SETUP_USER" "$home/.config"

  # 5) Cleanup on the boot AFTER the wizard (before the login screen starts)
  echo "$prep" > "$STATE_DIR/prep-user"
  cat > /usr/local/sbin/renewlab-firstboot-cleanup <<EOF
#!/usr/bin/env bash
set -u
userdel -r $SETUP_USER 2>/dev/null
PREP=\$(cat $STATE_DIR/prep-user 2>/dev/null)
[[ -n "\$PREP" ]] && userdel -r "\$PREP" 2>/dev/null
rm -f /etc/sudoers.d/renewlab-firstboot /usr/local/sbin/renewlab-firstboot-apply \\
      /usr/local/bin/renewlab-firstboot-wizard $STATE_DIR/cleanup-pending $STATE_DIR/prep-user
systemctl disable renewlab-firstboot-cleanup.service
rm -f /etc/systemd/system/renewlab-firstboot-cleanup.service
EOF
  chmod 0755 /usr/local/sbin/renewlab-firstboot-cleanup

  cat > /etc/systemd/system/renewlab-firstboot-cleanup.service <<EOF
[Unit]
Description=Renew Lab: remove setup accounts after first-boot wizard
ConditionPathExists=$STATE_DIR/cleanup-pending
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/renewlab-firstboot-cleanup

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable renewlab-firstboot-cleanup.service | tee -a "$LOG"

  say "Armed. Shut down now — do NOT log in again as '$prep'. Next boot = buyer's wizard."
}

if [[ -n "$ARM_PREP_USER" ]]; then
  arm_firstboot "$ARM_PREP_USER"
  exit 0
fi

# =============================================================================
# MAIN SETUP
# =============================================================================
: > "$LOG"
say "Renew Lab OS setup started $(date -Is)"

# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != "debian" || "${VERSION_ID:-}" != "13" ]]; then
  warn "Expected Debian 13, found '${PRETTY_NAME:-unknown}'."
  read -r -p "Continue anyway? [y/N] " ans
  [[ "${ans,,}" == "y" ]] || die "Aborted."
fi
case "$AGE" in preschool|primary|secondary) ;; *) die "--age must be preschool, primary or secondary";; esac
case "$DNS_FILTER" in family|cloudflare|off) ;; *) die "--dns-filter must be family, cloudflare or off";; esac
if [[ -n "$LOGO" ]]; then
  [[ -f "$LOGO" ]] || die "Logo not found: $LOGO"
  file "$LOGO" | grep -qi 'PNG image' || die "Logo must be a PNG."
fi

export DEBIAN_FRONTEND=noninteractive

# ---------- 1. updates -------------------------------------------------------
say "Updating system"
apt-get update 2>&1 | tee -a "$LOG"
apt-get -y full-upgrade 2>&1 | tee -a "$LOG"

# ---------- 2. language, keyboard, time --------------------------------------
say "Swedish + English locales, Swedish keyboard, Stockholm time"
install_pkgs locales
sed -i -E 's/^# *(sv_SE.UTF-8 UTF-8)/\1/; s/^# *(en_GB.UTF-8 UTF-8)/\1/' /etc/locale.gen
locale-gen 2>&1 | tee -a "$LOG"
localectl set-x11-keymap se || warn "Could not set keyboard via localectl"
timedatectl set-timezone Europe/Stockholm || warn "Could not set timezone"
install_pkgs firefox-esr-l10n-sv-se libreoffice-l10n-sv

# ---------- 3. look & feel ---------------------------------------------------
say "Theme, icons, fonts"
install_pkgs arc-theme \
             papirus-icon-theme \
             fonts-inter fonts-sil-andika fonts-opendyslexic \
             fonts-noto-core fonts-noto-color-emoji
# verified (trixie): arc-theme 20221218-1, papirus-icon-theme 20250501-1,
# fonts-inter 4.1+ds-1, fonts-sil-andika 6.200-1, fonts-opendyslexic
# 20160623-4, fonts-noto (fonts-noto-core) 20201225-2,
# fonts-noto-color-emoji 2.051-0+deb13u1

LIGHT_GTK="Arc";      DARK_GTK="Arc-Dark"
LIGHT_ICONS="Papirus-Light"; DARK_ICONS="Papirus-Dark"
[[ -d /usr/share/themes/$LIGHT_GTK ]] || { warn "$LIGHT_GTK not found, using Adwaita"; LIGHT_GTK="Adwaita"; DARK_GTK="Adwaita-dark"; }
[[ -d /usr/share/icons/$LIGHT_ICONS ]] || LIGHT_ICONS="Papirus"
WM_LIGHT="$LIGHT_GTK"; WM_DARK="$DARK_GTK"
[[ -d /usr/share/themes/$WM_LIGHT/xfwm4 ]] || WM_LIGHT="Default"
[[ -d /usr/share/themes/$WM_DARK/xfwm4 ]]  || WM_DARK="$WM_LIGHT"
COMPOSITING=true; [[ $LOWSPEC -eq 1 ]] && COMPOSITING=false

# Defaults for every NEW account (the buyer's accounts are created after this)
XML=/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
mkdir -p "$XML"
cat > "$XML/xsettings.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="$LIGHT_GTK"/>
    <property name="IconThemeName" type="string" value="$LIGHT_ICONS"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="FontName" type="string" value="Inter 10"/>
  </property>
</channel>
EOF
cat > "$XML/xfwm4.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="$WM_LIGHT"/>
    <property name="title_font" type="string" value="Inter Bold 10"/>
    <property name="use_compositing" type="bool" value="$COMPOSITING"/>
  </property>
</channel>
EOF

# Light/dark toggle for users (menu entries)
cat > /usr/local/bin/renewlab-theme <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  dark)  G="$DARK_GTK";  I="$DARK_ICONS";  W="$WM_DARK" ;;
  light) G="$LIGHT_GTK"; I="$LIGHT_ICONS"; W="$WM_LIGHT" ;;
  *) echo "usage: renewlab-theme dark|light"; exit 1 ;;
esac
xfconf-query -c xsettings -p /Net/ThemeName -s "\$G"
xfconf-query -c xsettings -p /Net/IconThemeName -s "\$I"
xfconf-query -c xfwm4 -p /general/theme -s "\$W"
EOF
chmod 0755 /usr/local/bin/renewlab-theme
for mode in light dark; do
  label="Ljust tema / Light theme"; icon="weather-clear"
  [[ $mode == dark ]] && { label="Mörkt tema / Dark theme"; icon="weather-clear-night"; }
  cat > "/usr/share/applications/renewlab-theme-$mode.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$label
Exec=/usr/local/bin/renewlab-theme $mode
Icon=$icon
Categories=Settings;
EOF
done

# ---------- 4. boot splash ---------------------------------------------------
if [[ -n "$LOGO" ]]; then
  say "Renew Lab boot splash"
  install_pkgs plymouth plymouth-themes     # verified: 24.004.60-5 (includes "spinner")
  [[ -f "$PLY_THEMES/spinner/spinner.plymouth" ]] || die "spinner theme not found."
  rm -rf "${PLY_THEMES:?}/$THEME_NAME"
  cp -a "$PLY_THEMES/spinner" "$PLY_THEMES/$THEME_NAME"
  mv "$PLY_THEMES/$THEME_NAME/spinner.plymouth" "$PLY_THEMES/$THEME_NAME/$THEME_NAME.plymouth"
  install -m 0644 "$LOGO" "$PLY_THEMES/$THEME_NAME/watermark.png"
  CFG="$PLY_THEMES/$THEME_NAME/$THEME_NAME.plymouth"
  sed -i -e "s|^Name=.*|Name=Renew Lab|" \
         -e "s|^Description=.*|Description=Renew Lab boot splash|" \
         -e "s|$PLY_THEMES/spinner|$PLY_THEMES/$THEME_NAME|g" "$CFG"
  grep -q '^UseFirmwareBackground=' "$CFG" && \
    sed -i 's|^UseFirmwareBackground=.*|UseFirmwareBackground=false|' "$CFG"
  { echo "--- $CFG ---"; cat "$CFG"; } >> "$LOG"
  plymouth-set-default-theme "$THEME_NAME" | tee -a "$LOG"

  # Debian needs "splash" on the kernel command line
  if ! grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\bsplash\b' /etc/default/grub; then
    cp /etc/default/grub "/etc/default/grub.renewlab.bak.$(date +%s)"
    sed -i -E 's|^(GRUB_CMDLINE_LINUX_DEFAULT=")([^"]*)"|\1\2 splash"|' /etc/default/grub
  fi
fi

# ---------- 5. educational apps ----------------------------------------------
say "Educational apps for: $AGE"
# all verified in trixie: gcompris-qt 25.0.12-1, tuxpaint 0.9.34-2,
# tuxmath 2.0.3-10, tuxtype 1.8.3-7, ktouch 25.04.0-2, kgeography 25.04.0-1,
# stellarium 24.3-1
case "$AGE" in
  preschool) install_pkgs gcompris-qt tuxpaint ;;
  primary)   install_pkgs gcompris-qt tuxpaint tuxmath tuxtype ktouch kgeography \
                          libreoffice-writer libreoffice-impress ;;
  secondary) install_pkgs ktouch kgeography stellarium \
                          libreoffice-writer libreoffice-calc libreoffice-impress ;;
esac

# ---------- 6. parental controls ---------------------------------------------
say "Screen time (timekpr-nExT)"
install_pkgs timekpr-next      # verified: 0.5.4-3

# ---------- 7. Roblox block ---------------------------------------------------
say "Blocking Roblox"
# 7a. No Flatpak: Roblox's only Linux route (Sober) is Flatpak-only, and Flatpak
#     allows per-user installs without admin rights.
if dpkg -s flatpak >/dev/null 2>&1; then
  apt-get -y purge flatpak 2>&1 | tee -a "$LOG"
fi
cat > /etc/apt/preferences.d/renewlab-no-flatpak <<'EOF'
Package: flatpak
Pin: release *
Pin-Priority: -1
EOF

# 7b. System-wide DNS block incl. all subdomains (NetworkManager + dnsmasq)
if command -v NetworkManager >/dev/null; then
  install_pkgs dnsmasq-base
  mkdir -p /etc/NetworkManager/conf.d /etc/NetworkManager/dnsmasq.d
  printf '[main]\ndns=dnsmasq\n' > /etc/NetworkManager/conf.d/90-renewlab-dns.conf
  : > /etc/NetworkManager/dnsmasq.d/renewlab-block.conf
  for d in "${ROBLOX_DOMAINS[@]}"; do
    printf 'address=/%s/0.0.0.0\naddress=/%s/::\n' "$d" "$d" \
      >> /etc/NetworkManager/dnsmasq.d/renewlab-block.conf
  done
  # 7b2. Family-safe DNS for the whole machine (overrides router/Wi-Fi DNS)
  #   family     = CleanBrowsing Family Filter: adult content, proxies/VPNs,
  #                mixed-content sites, malware, phishing; SafeSearch + YouTube
  #                restricted mode enforced. Free tier (throttled per CleanBrowsing).
  #   cloudflare = 1.1.1.1 for Families: malware + adult content. No SafeSearch
  #                enforcement mentioned by Cloudflare.
  #   off        = whatever the network provides (Roblox block still active)
  cat > /usr/local/sbin/renewlab-safety <<'SAFE'
#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Kör med sudo / run with sudo"; exit 1; }
F=/etc/NetworkManager/conf.d/91-renewlab-filter.conf
case "${1:-}" in
  family)     S="185.228.168.168,185.228.169.168,2a0d:2a00:1::,2a0d:2a00:2::" ;;
  cloudflare) S="1.1.1.3,1.0.0.3,2606:4700:4700::1113,2606:4700:4700::1003" ;;
  off)        rm -f "$F"; systemctl restart NetworkManager; echo "Filter: off"; exit 0 ;;
  status)     if [[ -f "$F" ]]; then grep '^servers' "$F"; else echo "Filter: off"; fi; exit 0 ;;
  *) echo "usage: sudo renewlab-safety family|cloudflare|off|status"; exit 1 ;;
esac
printf '[global-dns]\n\n[global-dns-domain-*]\nservers=%s\n' "$S" > "$F"
systemctl restart NetworkManager
echo "Filter: $1"
SAFE
  chmod 0755 /usr/local/sbin/renewlab-safety
  /usr/local/sbin/renewlab-safety "$DNS_FILTER" | tee -a "$LOG" \
    || warn "DNS filter setup failed — check after reboot with: sudo renewlab-safety status"
else
  warn "NetworkManager not found — DNS wildcard block + family DNS skipped (hosts file only)."
fi

# 7c. Hosts file fallback for the main hostnames
if ! grep -q 'renewlab-block' /etc/hosts; then
  {
    echo "# renewlab-block start"
    for d in "${ROBLOX_DOMAINS[@]}"; do echo "0.0.0.0 $d www.$d"; done
    echo "# renewlab-block end"
  } >> /etc/hosts
fi

# 7d. Firefox safety rails (all documented Mozilla enterprise policies):
#   - Roblox sites blocked
#   - DNS-over-HTTPS off + locked  -> can't bypass the family DNS
#   - Proxy off + locked           -> can't route around filters
#   - Private browsing removed     -> history stays visible to parents
#   - about:config blocked         -> policies/settings can't be tinkered with
#   - Extensions: only uBlock Origin (force-installed, blocks ads, trackers and
#     known malicious sites); everything else blocked, e.g. VPN/proxy add-ons
#   Written to both documented Linux locations; confirm via about:policies.
POLICY=$(cat <<EOF
{
  "policies": {
    "DNSOverHTTPS": { "Enabled": false, "Locked": true },
    "Proxy": { "Mode": "none", "Locked": true },
    "DisablePrivateBrowsing": true,
    "BlockAboutConfig": true,
    "ExtensionSettings": {
      "*": { "installation_mode": "blocked" },
      "uBlock0@raymondhill.net": {
        "installation_mode": "force_installed",
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi"
      }
    },
    "WebsiteFilter": {
      "Block": [
$(for d in "${ROBLOX_DOMAINS[@]}"; do printf '        "*://%s/*", "*://*.%s/*",\n' "$d" "$d"; done | sed '$ s/,$//')
      ]
    }
  }
}
EOF
)
for dir in /etc/firefox/policies /usr/lib/firefox-esr/distribution; do
  mkdir -p "$dir"; echo "$POLICY" > "$dir/policies.json"
done
python3 -m json.tool /etc/firefox/policies/policies.json >/dev/null \
  || die "Generated Firefox policy is not valid JSON"

# ---------- 8. low-spec tuning -----------------------------------------------
if [[ $LOWSPEC -eq 1 ]]; then
  say "Low-spec tuning: zram"
  install_pkgs zram-tools        # verified: 0.3.7-1
  if [[ -f /etc/default/zramswap ]]; then
    sed -i -E 's|^#? *ALGO=.*|ALGO=zstd|; s|^#? *PERCENT=.*|PERCENT=50|' /etc/default/zramswap
    systemctl restart zramswap.service || warn "zramswap restart failed — reboot."
  fi
fi

# ---------- 9. optional: dead internal panel ---------------------------------
if [[ -n "$DISABLE_PANEL" ]]; then
  say "Disabling internal panel: $DISABLE_PANEL"
  found=0
  for c in /sys/class/drm/card*-"${DISABLE_PANEL}"; do [[ -e "$c" ]] && found=1; done
  if [[ $found -eq 0 ]]; then
    warn "Connector not found. Available:"
    for c in /sys/class/drm/card*-*; do
      [[ -e "$c" ]] && echo "  ${c##*/card?-} ($(cat "$c/status" 2>/dev/null))" | tee -a "$LOG"
    done
    die "Re-run with the right name (usually eDP-1, older laptops LVDS-1)."
  fi
  if ! grep -q "video=${DISABLE_PANEL}:d" /etc/default/grub; then
    cp /etc/default/grub "/etc/default/grub.renewlab.bak.$(date +%s)"
    sed -i -E "s|^(GRUB_CMDLINE_LINUX_DEFAULT=\")([^\"]*)\"|\1\2 video=${DISABLE_PANEL}:d\"|" /etc/default/grub
  fi
  warn "REPAIR NOTES: if the screen is replaced, remove video=${DISABLE_PANEL}:d from /etc/default/grub and run sudo update-grub"
fi

# ---------- 10. rebuild ------------------------------------------------------
say "Rebuilding initramfs and GRUB"
update-initramfs -u 2>&1 | tee -a "$LOG"
update-grub 2>&1 | tee -a "$LOG"
apt-get -y autoremove 2>&1 | tee -a "$LOG"

MISSING=$(grep -c 'MISSING package' "$LOG" || true)
say "Done. Log: $LOG  (missing packages: $MISSING)"
cat <<'EOF'

Test before arming:
  1. Reboot -> splash shows on internal AND external screen?
  2. Firefox -> about:policies shows the policies as Active; roblox.com blocked?
  3. Terminal: getent hosts www.roblox.com  -> 0.0.0.0
     sudo renewlab-safety status -> shows filter servers; an adult test site is blocked;
     Google/YouTube searches come back in SafeSearch/Restricted mode;
     Firefox: uBlock Origin present, private window option gone.
  4. Menu -> "Mörkt tema / Dark theme" works? (test in a NEW user account)
  5. timekpr-nExT opens, apps for the age group are present.
Then: sudo ./renewlab-os-setup.sh --arm-firstboot <prep-user>   and shut down.
EOF
