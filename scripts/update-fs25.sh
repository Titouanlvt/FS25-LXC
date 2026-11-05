#!/usr/bin/env bash
# ==============================================================================
# FS25-LXC — Mise à jour du serveur FS25 (installé dans le LXC en
# /usr/local/bin/fs25-update.sh, déclenché par le timer fs25-update.timer)
#
# Arrêt du service, app_update SteamCMD, redémarrage. Sans mot de passe,
# SteamCMD réutilise le jeton mis en cache lors du premier login.
# ==============================================================================
set -euo pipefail

if [[ -f /etc/fs25/fs25.env ]]; then
  set -a; source /etc/fs25/fs25.env; set +a
fi

FS_APPID="${FS_APPID:-2300320}"
FS_INSTALL_DIR="${FS_INSTALL_DIR:-/opt/fs25}"
STEAM_LOGIN_MODE="${STEAM_LOGIN_MODE:-account}"
STEAM_USER="${STEAM_USER:-}"
STEAMCMD_DIR="/opt/steamcmd"

systemctl stop fs25.service || true

login_args=(+login)
if [[ "$STEAM_LOGIN_MODE" == "anonymous" ]]; then
  login_args+=(anonymous)
elif [[ -n "$STEAM_USER" ]]; then
  login_args+=("$STEAM_USER")
fi

runuser -u steam -- "$STEAMCMD_DIR/steamcmd.sh" \
  +@sSteamCmdForcePlatformType windows \
  +force_install_dir "$FS_INSTALL_DIR" \
  "${login_args[@]}" \
  +app_update "$FS_APPID" validate \
  +quit

systemctl start fs25.service
echo "FS25 mis à jour (appid $FS_APPID) et service redémarré."
