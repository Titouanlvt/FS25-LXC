#!/usr/bin/env bash
# ==============================================================================
# FS25-LXC — Revue de l'installation FS25 (à exécuter DANS le conteneur)
#
#   pct exec <CTID> -- /usr/local/bin/fs25-check.sh
#
# Exit 0 si toutes les vérifications passent, 1 sinon. Installé par
# install-fs25.sh. Les chemins sont surchargeables par variables d'env
# (FS_INSTALL_DIR, STEAMCMD_DIR, SRV_USER, WINEPREFIX_DIR, FS_PORT, …).
# ==============================================================================
set -uo pipefail

GN='\033[1;32m' RD='\033[1;31m' YW='\033[1;33m' BL='\033[1;34m' CL='\033[0m'
PASS=0 FAIL=0
pass() { echo -e "${GN}[PASS]${CL} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "${RD}[FAIL]${CL} $*"; FAIL=$((FAIL + 1)); }
note() { echo -e "${YW}[WARN]${CL} $*"; }

FS_APPID="${FS_APPID:-2300320}"
FS_INSTALL_DIR="${FS_INSTALL_DIR:-/opt/fs25}"
STEAMCMD_DIR="${STEAMCMD_DIR:-/opt/steamcmd}"
SRV_USER="${SRV_USER:-steam}"
SRV_HOME="${SRV_HOME:-/home/steam}"
WINEPREFIX_DIR="${WINEPREFIX_DIR:-$SRV_HOME/.fs25server}"
LOCALBIN_DIR="${LOCALBIN_DIR:-/usr/local/bin}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
FS_PORT="${FS_PORT:-10823}"
FS_WEB_PORT="${FS_WEB_PORT:-8080}"
FS_WEB_TLS_PORT="${FS_WEB_TLS_PORT:-8443}"
PROFILE_DIR="$WINEPREFIX_DIR/drive_c/users/$SRV_USER/Documents/My Games/FarmingSimulator2025"

xml_ok() {
  local f="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import xml.dom.minidom, sys; xml.dom.minidom.parse(sys.argv[1])' "$f" 2>/dev/null
  elif command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$f" 2>/dev/null
  else
    grep -qE '</(server|gameserver)>' "$f"
  fi
}

echo -e "${BL}== Revue FS25 (fs25-check) ==${CL}"

id "$SRV_USER" >/dev/null 2>&1 && pass "utilisateur $SRV_USER présent" || fail "utilisateur $SRV_USER absent"
[[ -x "$STEAMCMD_DIR/steamcmd.sh" ]] && pass "SteamCMD présent ($STEAMCMD_DIR/steamcmd.sh)" || fail "SteamCMD absent ($STEAMCMD_DIR/steamcmd.sh)"
[[ -f "$FS_INSTALL_DIR/dedicatedServer.exe" ]] && pass "dedicatedServer.exe présent" || fail "dedicatedServer.exe absent dans $FS_INSTALL_DIR"
[[ -f "$FS_INSTALL_DIR/FarmingSimulator2025Game.exe" ]] && pass "FarmingSimulator2025Game.exe présent" || fail "FarmingSimulator2025Game.exe absent dans $FS_INSTALL_DIR"
[[ "$(cat "$FS_INSTALL_DIR/steam_appid.txt" 2>/dev/null)" == "$FS_APPID" ]] && pass "steam_appid.txt = $FS_APPID" || fail "steam_appid.txt absent ou incorrect dans $FS_INSTALL_DIR"

ds_xml="$FS_INSTALL_DIR/dedicatedServer.xml"
if [[ -f "$ds_xml" ]] && xml_ok "$ds_xml" && grep -q '<initial_admin>' "$ds_xml" 2>/dev/null; then
  pass "dedicatedServer.xml présent, XML valide, initial_admin renseigné"
else
  fail "dedicatedServer.xml absent ou invalide dans $FS_INSTALL_DIR"
fi

cfg_xml="$PROFILE_DIR/dedicated_server/dedicatedServerConfig.xml"
if [[ -f "$cfg_xml" ]] && xml_ok "$cfg_xml" && grep -q '<gameserver>' "$cfg_xml" 2>/dev/null; then
  pass "dedicatedServerConfig.xml présent et XML valide ($PROFILE_DIR/dedicated_server)"
else
  fail "dedicatedServerConfig.xml absent ou invalide dans $PROFILE_DIR/dedicated_server"
fi

# Contrôle licence : présence des fichiers *.dat
if ls "$PROFILE_DIR"/*.dat >/dev/null 2>&1; then
  pass "fichiers de licence (*.dat) présents"
else
  note "Aucun fichier de licence (*.dat) trouvé dans $PROFILE_DIR — activation nécessaire : /usr/local/bin/fs25-activer"
fi

for u in fs25.service fs25-update.service fs25-update.timer; do
  if [[ -f "$SYSTEMD_DIR/$u" ]]; then pass "unité $u présente"; else fail "unité $u absente ($SYSTEMD_DIR/$u)"; fi
done
[[ -x "$LOCALBIN_DIR/fs25-start.sh" ]] && pass "fs25-start.sh exécutable" || fail "fs25-start.sh absent/non exécutable ($LOCALBIN_DIR)"
[[ -x "$LOCALBIN_DIR/fs25-update.sh" ]] && pass "fs25-update.sh exécutable" || fail "fs25-update.sh absent/non exécutable ($LOCALBIN_DIR)"

if [[ -d /run/systemd/system ]]; then
  systemctl is-active --quiet fs25 && pass "service fs25 actif" || fail "service fs25 inactif (systemctl start fs25)"
  systemctl is-enabled --quiet fs25 && pass "service fs25 activé au boot" || fail "service fs25 non activé (systemctl enable fs25)"
  systemctl is-enabled --quiet fs25-update.timer && pass "timer fs25-update activé" || fail "timer fs25-update non activé"
  if systemctl is-active --quiet fs25 && command -v ss >/dev/null 2>&1; then
    ss -ltn | grep -q ":$FS_PORT " && pass "port jeu $FS_PORT/TCP à l'écoute" || fail "port $FS_PORT/TCP non à l'écoute"
    ss -lnu | grep -q ":$FS_PORT " && pass "port jeu $FS_PORT/UDP à l'écoute" || fail "port $FS_PORT/UDP non à l'écoute"
    ss -ltn | grep -q ":$FS_WEB_PORT " && pass "panneau web $FS_WEB_PORT/TCP à l'écoute" || fail "port $FS_WEB_PORT/TCP non à l'écoute"
    ss -ltn | grep -q ":$FS_WEB_TLS_PORT " && pass "panneau web $FS_WEB_TLS_PORT/TCP (HTTPS) à l'écoute" || fail "port $FS_WEB_TLS_PORT/TCP non à l'écoute"
  fi
else
  note "systemd non fonctionnel dans ce contexte : état des services et ports non vérifié (fichiers d'unités contrôlés)"
fi

if command -v ufw >/dev/null 2>&1; then
  ufw status 2>/dev/null | grep -q 'Status: active' && pass "ufw actif" || fail "ufw inactif (ufw enable)"
else
  note "ufw non installé : pare-feu non vérifié"
fi

echo -e "${BL}== Résultat : $PASS OK, $FAIL échec(s) → exit $(( FAIL > 0 ? 1 : 0 )) ==${CL}"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
