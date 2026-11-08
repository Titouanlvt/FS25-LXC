#!/usr/bin/env bash
# ==============================================================================
# FS25-LXC — Activation de la licence Farming Simulator 25
#
# En root dans le conteneur :
#   pct exec <CTID> -- /usr/local/bin/fs25-activer [--steam|--cle] [--timeout N]
#
# 1. Arrête fs25.service (s'il tourne)
# 2. Lance Xvfb + x11vnc sur 127.0.0.1 seulement, mot de passe aléatoire
#    affiché une fois (fichier temporaire 0600, effacé à la sortie)
# 3. Lance le jeu sous l'utilisateur steam, dans le préfixe Wine du serveur
# 4. Attend les fichiers *.dat du profil (30 min par défaut)
# 5. Arrête tout, y compris sur Ctrl-C ou erreur, et remet fs25 dans son état
#
# Changer de clé = relancer fs25-activer --cle.
# À vérifier : GIANTS ne garantit pas le serveur dédié avec la version Steam.
# Tant que l'activation n'est pas faite, le journal du serveur dit « not activated ».
# ==============================================================================
set -euo pipefail

GN='\033[1;32m' YW='\033[1;33m' RD='\033[1;31m' BL='\033[1;34m' CL='\033[0m'
info() { echo -e "${BL}[INFO]${CL} $*"; }
ok()   { echo -e "${GN}[ OK ]${CL} $*"; }
warn() { echo -e "${YW}[WARN]${CL} $*"; }
die()  { echo -e "${RD}[ERR ]${CL} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "À lancer en root dans le conteneur."

# --- 1. Arguments ---------------------------------------------------------------
TIMEOUT_MIN=30
ACTIVATION_MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --steam)   ACTIVATION_MODE="steam"; shift ;;
    --cle)     ACTIVATION_MODE="cle"; shift ;;
    --timeout) [[ $# -ge 2 ]] || die "--timeout attend un nombre de minutes."
               TIMEOUT_MIN="$2"; shift 2 ;;
    *)         die "Option inconnue : $1 (--steam, --cle ou --timeout N)" ;;
  esac
done
[[ "$TIMEOUT_MIN" =~ ^[1-9][0-9]*$ ]] || die "--timeout : nombre entier de minutes attendu."

# --- 2. Configuration écrite par install-fs25.sh --------------------------------
# FS_INSTALL_DIR y est réécrit en mode eshop : toujours le lire.
# shellcheck source=/dev/null
[[ -f /etc/fs25/fs25.env ]] && { set -a; source /etc/fs25/fs25.env; set +a; }
FS_SOURCE="${FS_SOURCE:-steamcmd}"
FS_INSTALL_DIR="${FS_INSTALL_DIR:-/opt/fs25}"
if [[ -z "$ACTIVATION_MODE" ]]; then
  [[ "$FS_SOURCE" == "eshop" ]] && ACTIVATION_MODE="cle" || ACTIVATION_MODE="steam"
fi

SRV_USER="steam"
SRV_HOME="/home/steam"
WINEPREFIX_DIR="$SRV_HOME/.fs25server"
PROFILE_DIR="$WINEPREFIX_DIR/drive_c/users/$SRV_USER/Documents/My Games/FarmingSimulator2025"
XVFB_DISPLAY=":99"
VNC_PORT=5900

id "$SRV_USER" >/dev/null 2>&1 || die "Utilisateur '$SRV_USER' introuvable."
[[ -d "$WINEPREFIX_DIR" ]] || die "Préfixe Wine '$WINEPREFIX_DIR' introuvable."
command -v x11vnc >/dev/null 2>&1 || die "x11vnc absent (apt-get install x11vnc)."
command -v Xvfb >/dev/null 2>&1 || die "Xvfb absent (apt-get install xvfb)."

# Exécutable du jeu (pas dedicatedServer.exe). À vérifier sur une vraie install.
GAME_EXE=""
for exe in FarmingSimulator2025.exe FarmingSimulator2025Game.exe; do
  if [[ -f "$FS_INSTALL_DIR/$exe" ]]; then GAME_EXE="$FS_INSTALL_DIR/$exe"; break; fi
done
[[ -n "$GAME_EXE" ]] || die "Exécutable du jeu introuvable dans $FS_INSTALL_DIR."

licence_presente() { compgen -G "$PROFILE_DIR/*.dat" >/dev/null; }

info "Mode d'activation : $ACTIVATION_MODE ($GAME_EXE)"

# --- 3. Nettoyage garanti -------------------------------------------------------
FS25_ETAIT_ACTIF=0
XVFB_PID="" X11VNC_PID="" GAME_PID=""
TMP_DIR="$(mktemp -d /tmp/fs25-activer.XXXXXX)"
chmod 700 "$TMP_DIR"

nettoyer() {
  local code=$?
  trap - EXIT INT TERM
  info "Arrêt du jeu, de x11vnc et de Xvfb ..."
  [[ -n "$GAME_PID" ]] && kill "$GAME_PID" 2>/dev/null || true
  # Le PID est celui de runuser : wineserver -k arrête wine et ses enfants.
  runuser -u "$SRV_USER" -- env HOME="$SRV_HOME" WINEPREFIX="$WINEPREFIX_DIR" \
    wineserver -k 2>/dev/null || true
  [[ -n "$X11VNC_PID" ]] && kill "$X11VNC_PID" 2>/dev/null || true
  [[ -n "$XVFB_PID" ]] && kill "$XVFB_PID" 2>/dev/null || true
  rm -rf "$TMP_DIR"
  if [[ $FS25_ETAIT_ACTIF -eq 1 ]]; then
    info "Relance du service fs25 ..."
    systemctl start fs25.service || warn "fs25 n'a pas redémarré : systemctl status fs25"
  fi
  exit "$code"
}
trap nettoyer EXIT
trap 'exit 130' INT TERM

# --- 4. Arrêt du serveur --------------------------------------------------------
if systemctl is-active --quiet fs25.service; then
  FS25_ETAIT_ACTIF=1
  info "Arrêt du service fs25 ..."
  systemctl stop fs25.service
fi

# --- 5. Xvfb et x11vnc (127.0.0.1 seulement) ------------------------------------
VNC_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
x11vnc -storepasswd "$VNC_PASS" "$TMP_DIR/vnc.pass" >/dev/null 2>&1

Xvfb "$XVFB_DISPLAY" -screen 0 1280x800x24 -nolisten tcp &
XVFB_PID=$!
sleep 1
kill -0 "$XVFB_PID" 2>/dev/null || die "Xvfb n'a pas démarré sur $XVFB_DISPLAY."

# Pas de -bg : le PID doit rester celui de x11vnc pour l'arrêter.
x11vnc -display "$XVFB_DISPLAY" -localhost -rfbport "$VNC_PORT" \
  -rfbauth "$TMP_DIR/vnc.pass" -forever -quiet >/dev/null 2>&1 &
X11VNC_PID=$!
sleep 1
kill -0 "$X11VNC_PID" 2>/dev/null || die "x11vnc n'a pas démarré (port $VNC_PORT déjà pris ?)."
ok "VNC prêt sur 127.0.0.1:$VNC_PORT."

# --- 6. Instructions ------------------------------------------------------------
CT_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
# L'hôte PVE vu depuis le conteneur = passerelle par défaut (vmbr0)
PVE_IP="$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"
echo
echo -e "${BL}=== Activation de la licence FS25 ===${CL}"
echo -e "  Mot de passe VNC (affiché une seule fois) : ${YW}${VNC_PASS}${CL}"
echo -e "  VNC à l'écoute dans le conteneur sur 127.0.0.1:${VNC_PORT} (IP du CT : ${CT_IP:-?})."
echo -e "  Depuis TON poste : ${YW}ssh -L ${VNC_PORT}:${CT_IP:-<ip-ct>}:${VNC_PORT} root@${PVE_IP:-<ip-pve>}${CL}"
echo -e "  Puis client VNC sur ${YW}localhost:${VNC_PORT}${CL} — le tunnel passe par l'hôte PVE (pas besoin de sshd dans le CT)."
if [[ "$ACTIVATION_MODE" == "cle" ]]; then
  echo "  Saisis la clé GIANTS quand le jeu la demande, puis attends le menu principal."
else
  echo "  Mode Steam (à vérifier) : laisse le jeu arriver au menu principal."
fi
echo -e "  Délai maximal : ${TIMEOUT_MIN} min. Ctrl-C pour arrêter."
echo

# --- 7. Jeu, sous l'utilisateur steam (shell nologin : runuser, pas su -) -------
runuser -u "$SRV_USER" -- env HOME="$SRV_HOME" WINEPREFIX="$WINEPREFIX_DIR" \
  WINEARCH=win64 WINEDEBUG=-all WINEDLLOVERRIDES="mscoree=d" DISPLAY="$XVFB_DISPLAY" \
  wine "$GAME_EXE" >/dev/null 2>&1 &
GAME_PID=$!

# --- 8. Attente des *.dat -------------------------------------------------------
FIN=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
while (( $(date +%s) < FIN )); do
  if licence_presente; then
    ok "Fichiers de licence (*.dat) présents dans $PROFILE_DIR."
    sleep 10  # laisse le jeu finir d'écrire
    exit 0
  fi
  kill -0 "$GAME_PID" 2>/dev/null || { warn "Le jeu s'est arrêté."; break; }
  sleep 5
done

licence_presente && exit 0
warn "Aucun fichier *.dat dans $PROFILE_DIR : activation non faite."
warn "Relance fs25-activer pour réessayer."
exit 1
