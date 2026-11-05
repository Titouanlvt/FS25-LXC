#!/usr/bin/env bash
# ==============================================================================
# FS25-LXC — Installateur INTÉRIEUR (exécuté dans le LXC par fs25-lxc.sh)
#
# Installe Wine + SteamCMD, télécharge Farming Simulator 25 (appid 2300320),
# génère dedicatedServer.xml / dedicatedServerConfig.xml, crée le service
# systemd fs25, le timer de mise à jour et les règles pare-feu.
#
# Variables attendues : /root/fs25.env (poussé par l'hôte, supprimé ensuite).
# ==============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

GN='\033[1;32m' YW='\033[1;33m' RD='\033[1;31m' BL='\033[1;34m' CL='\033[0m'
info() { echo -e "${BL}[INFO]${CL} $*"; }
ok()   { echo -e "${GN}[ OK ]${CL} $*"; }
warn() { echo -e "${YW}[WARN]${CL} $*"; }
die()  { echo -e "${RD}[ERR ]${CL} $*" >&2; exit 1; }

STEAM_LOGIN_MODE="${STEAM_LOGIN_MODE:-account}"
FS_APPID="${FS_APPID:-2300320}"
FS_SOURCE="${FS_SOURCE:-steamcmd}"
FS_INSTALL_DIR="${FS_INSTALL_DIR:-/opt/fs25}"
FS_WEB_PORT="${FS_WEB_PORT:-8080}"
FS_WEB_TLS_PORT="${FS_WEB_TLS_PORT:-8443}"
FS_WEB_ADMIN_USER="${FS_WEB_ADMIN_USER:-admin}"
FS_WEB_ADMIN_PASS="${FS_WEB_ADMIN_PASS:-}"
FS_GAME_NAME="${FS_GAME_NAME:-FS25 Server}"
FS_GAME_PASSWORD="${FS_GAME_PASSWORD:-}"
FS_ADMIN_PASSWORD="${FS_ADMIN_PASSWORD:-}"
FS_MAX_PLAYERS="${FS_MAX_PLAYERS:-16}"
FS_PORT="${FS_PORT:-10823}"
FS_LANGUAGE="${FS_LANGUAGE:-fr}"
FS_SAVE_INTERVAL="${FS_SAVE_INTERVAL:-180}"
FS_CROSSPLAY="${FS_CROSSPLAY:-true}"
FS_ECONOMIC_DIFFICULTY="${FS_ECONOMIC_DIFFICULTY:-2}"
FS_PAUSE_IF_EMPTY="${FS_PAUSE_IF_EMPTY:-2}"
FS_INITIAL_MONEY="${FS_INITIAL_MONEY:-500000}"
FS_SAVEGAME_INDEX="${FS_SAVEGAME_INDEX:-1}"
FS_MAP="${FS_MAP:-MapUS}"

STEAMCMD_DIR="/opt/steamcmd"
SRV_USER="steam"
SRV_HOME="/home/steam"
WINEPREFIX_DIR="$SRV_HOME/.fs25server"

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}
sed_escape() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}
render_template() {
  local tpl="$1" dest="$2" v val
  cp "$tpl" "$dest"
  local vars=(FS_WEB_PORT FS_WEB_TLS_PORT FS_WEB_ADMIN_USER FS_WEB_ADMIN_PASS
              FS_GAME_NAME FS_GAME_PASSWORD FS_ADMIN_PASSWORD FS_MAX_PLAYERS FS_PORT
              FS_LANGUAGE FS_SAVE_INTERVAL FS_CROSSPLAY FS_ECONOMIC_DIFFICULTY
              FS_PAUSE_IF_EMPTY FS_INITIAL_MONEY FS_SAVEGAME_INDEX FS_MAP)
  for v in "${vars[@]}"; do
    val="$(sed_escape "$(xml_escape "${!v:-}")")"
    sed -i "s|@${v}@|${val}|g" "$dest"
  done
}

# --- 1. Système ------------------------------------------------------------------
info "Mise à jour du système ..."
apt-get update -qq
apt-get upgrade -y -qq

info "Installation des dépendances (wine64, xvfb, ufw, openssl, libs Steam) ..."
dpkg --add-architecture i386 || true
apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates curl wget openssl gnupg software-properties-common \
  ufw xvfb x11-utils \
  wine64 libwine \
  lib32gcc-s1 lib32stdc++6 libstdc++6 \
  winbind cabextract p7zip-full
apt-get install -y --no-install-recommends wine32:i386 libwine:i386 2>/dev/null \
  || warn "wine32 (i386) non installé — optionnel, le serveur FS25 est 64 bits."

# --- 2. Utilisateur dédié ---------------------------------------------------------
info "Création de l'utilisateur système '$SRV_USER' ..."
if ! id "$SRV_USER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "$SRV_HOME" --shell /usr/sbin/nologin "$SRV_USER"
fi
mkdir -p "$FS_INSTALL_DIR" "$STEAMCMD_DIR"
chown -R "$SRV_USER:$SRV_USER" "$SRV_HOME" "$FS_INSTALL_DIR" "$STEAMCMD_DIR"

# --- 3. SteamCMD -------------------------------------------------------------------
info "Installation de SteamCMD dans $STEAMCMD_DIR ..."
curl -fsSL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" -o /tmp/steamcmd_linux.tar.gz
tar -xzf /tmp/steamcmd_linux.tar.gz -C "$STEAMCMD_DIR"
rm -f /tmp/steamcmd_linux.tar.gz
chown -R "$SRV_USER:$SRV_USER" "$STEAMCMD_DIR"

login_args=(+login)
if [[ "$STEAM_LOGIN_MODE" == "anonymous" ]]; then
  login_args+=(anonymous)
else
  [[ -n "${STEAM_USER:-}" ]] || die "STEAM_USER requis (STEAM_LOGIN_MODE=account)."
  login_args+=("${STEAM_USER}" "${STEAM_PASS:-}")
  [[ -z "${STEAM_GUARD:-}" ]] || login_args+=("$STEAM_GUARD")
fi

# --- 4. Téléchargement de FS25 ------------------------------------------------------
if [[ "$FS_SOURCE" == "eshop" ]]; then
  INSTALLER_DIR="/opt/fs25-installer"
  installer="$(ls "$INSTALLER_DIR"/FarmingSimulator2025.exe "$INSTALLER_DIR"/Setup.exe 2>/dev/null | head -n1 || true)"
  [[ -n "$installer" ]] || die "FS_SOURCE=eshop : déposez l'installeur GIANTS eShop dans $INSTALLER_DIR (ou montez-le via pct set --mp0)."
  info "Installation silencieuse via l'installeur GIANTS eShop : $installer ..."
  runuser -u "$SRV_USER" -- env HOME="$SRV_HOME" WINEPREFIX="$WINEPREFIX_DIR" WINEARCH=win64 WINEDEBUG=-all \
    /usr/bin/xvfb-run -a /usr/bin/wine "$installer" /SILENT /NOCANCEL /NOICONS \
    || warn "L'installeur a retourné un code non nul — vérifiez les logs wine."
  FS_INSTALL_DIR="$WINEPREFIX_DIR/drive_c/Program Files (x86)/Farming Simulator 25"
  mkdir -p "$FS_INSTALL_DIR"
else
  info "Téléchargement de Farming Simulator 25 (appid $FS_APPID, ~50 Go) via SteamCMD ..."
  runuser -u "$SRV_USER" -- "$STEAMCMD_DIR/steamcmd.sh" \
    +@sSteamCmdForcePlatformType windows \
    +force_install_dir "$FS_INSTALL_DIR" \
    "${login_args[@]}" \
    +app_update "$FS_APPID" validate \
    +quit
fi
echo "$FS_APPID" > "$FS_INSTALL_DIR/steam_appid.txt"

# --- 5. Préfixe Wine + profil ---------------------------------------------------------
info "Initialisation du préfixe Wine ($WINEPREFIX_DIR) ..."
runuser -u "$SRV_USER" -- env HOME="$SRV_HOME" WINEPREFIX="$WINEPREFIX_DIR" WINEARCH=win64 WINEDEBUG=-all \
  /usr/bin/xvfb-run -a /usr/bin/wineboot --init >/dev/null 2>&1 || true

PROFILE_DIR="$WINEPREFIX_DIR/drive_c/users/$SRV_USER/Documents/My Games/FarmingSimulator2025"
mkdir -p "$PROFILE_DIR/dedicated_server"

# --- 6. Fichiers de configuration XML ---------------------------------------------------
info "Génération de $FS_INSTALL_DIR/dedicatedServer.xml (panneau web, admin initial) ..."
render_template /root/dedicatedServer.xml.template "$FS_INSTALL_DIR/dedicatedServer.xml"
info "Génération de dedicatedServerConfig.xml (réglages du serveur de jeu) ..."
render_template /root/dedicatedServerConfig.xml.template "$PROFILE_DIR/dedicated_server/dedicatedServerConfig.xml"

info "Certificat TLS auto-signé pour le panneau web (port ${FS_WEB_TLS_PORT}) ..."
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$FS_INSTALL_DIR/pk.pem" -out "$FS_INSTALL_DIR/cert.pem" \
  -subj "/CN=${FS_GAME_NAME:-fs25}" >/dev/null 2>&1

chown -R "$SRV_USER:$SRV_USER" "$FS_INSTALL_DIR" "$WINEPREFIX_DIR"

# --- 7. Config persistante (sans secret) pour les mises à jour --------------------------
info "Écriture de /etc/fs25/fs25.env (sans mot de passe) ..."
install -d -m 700 /etc/fs25
{
  printf 'STEAM_LOGIN_MODE=%q\n' "$STEAM_LOGIN_MODE"
  printf 'STEAM_USER=%q\n' "${STEAM_USER:-}"
  printf 'FS_APPID=%q\n' "$FS_APPID"
  printf 'FS_SOURCE=%q\n' "$FS_SOURCE"
  printf 'FS_INSTALL_DIR=%q\n' "$FS_INSTALL_DIR"
} > /etc/fs25/fs25.env
chmod 600 /etc/fs25/fs25.env

# --- 8. Service systemd + timer de mise à jour -------------------------------------------
info "Création du service systemd fs25 ..."
cat > /usr/local/bin/fs25-start.sh <<EOF
#!/usr/bin/env bash
exec /usr/bin/xvfb-run -a /usr/bin/wine "$FS_INSTALL_DIR/dedicatedServer.exe"
EOF
chmod 755 /usr/local/bin/fs25-start.sh
install -m 0755 /root/update-fs25.sh /usr/local/bin/fs25-update.sh
install -m 0755 /root/fs25-check.sh /usr/local/bin/fs25-check.sh

cat > /etc/systemd/system/fs25.service <<EOF
[Unit]
Description=Farming Simulator 25 - Serveur dédié
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$SRV_USER
Group=$SRV_USER
WorkingDirectory=$FS_INSTALL_DIR
Environment=HOME=$SRV_HOME
Environment=WINEPREFIX=$WINEPREFIX_DIR
Environment=WINEARCH=win64
Environment=WINEDEBUG=-all
Environment=LANG=C.UTF-8
ExecStart=/usr/local/bin/fs25-start.sh
Restart=on-failure
RestartSec=15
KillMode=mixed
TimeoutStopSec=180
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/fs25-update.service <<EOF
[Unit]
Description=Mise à jour de Farming Simulator 25 via SteamCMD
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fs25-update.sh
EOF

cat > /etc/systemd/system/fs25-update.timer <<EOF
[Unit]
Description=Mise à jour hebdomadaire de Farming Simulator 25

[Timer]
OnCalendar=Sun 04:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable fs25.service fs25-update.timer

# --- 9. Pare-feu ----------------------------------------------------------------------
info "Pare-feu ufw : 22/tcp, ${FS_PORT} TCP+UDP, 10824-10825/udp, ${FS_WEB_PORT}/${FS_WEB_TLS_PORT} TCP ..."
ufw allow 22/tcp
ufw allow "$FS_PORT/tcp"
ufw allow "$FS_PORT/udp"
ufw allow 10824:10825/udp
ufw allow "$FS_WEB_PORT/tcp"
ufw allow "$FS_WEB_TLS_PORT/tcp"
ufw --force enable

# --- 10. Démarrage ---------------------------------------------------------------------
info "Démarrage du service fs25 ..."
systemctl start fs25.service

rm -f /root/install-fs25.sh /root/update-fs25.sh /root/fs25-check.sh /root/dedicatedServer.xml.template /root/dedicatedServerConfig.xml.template
apt-get autoremove -y -qq || true

sleep 5
info "Revue de l'installation (fs25-check : exit 0 = tout OK, 1 = KO) ..."
if /usr/local/bin/fs25-check.sh; then
  ok "fs25-check : toutes les vérifications passent (exit 0)"
else
  warn "fs25-check : des vérifications échouent (normal si le service démarre encore) — relancez : /usr/local/bin/fs25-check.sh"
fi

ok "Installation terminée."
echo "Panneau web : http://<ip>:${FS_WEB_PORT} et https://<ip>:${FS_WEB_TLS_PORT} (admin : ${FS_WEB_ADMIN_USER})"
echo "Démarrez une savegame depuis le panneau web pour lancer le serveur de jeu (port ${FS_PORT})."
echo "Logs : journalctl -u fs25 -f"
