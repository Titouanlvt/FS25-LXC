#!/usr/bin/env bash
# ==============================================================================
# FS25-LXC — Déploie un serveur dédié Farming Simulator 25 dans un LXC Proxmox
#
# Inspiré de ct/ubuntu.sh (community-scripts/ProxmoxVE) : presets de ressources
# en tête de fichier (var_*), surchargeables par .env (gitignoré) ou par CLI.
#
# À exécuter EN ROOT SUR L'HÔTE PROXMOX VE, en une commande :
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Titouanlvt/FS25-LXC/main/scripts/fs25-lxc.sh)"
# ou depuis un clone :
#   sudo ./scripts/fs25-lxc.sh [--vmid 120] [--cpu 4] [--ram 8192] [--disk 64]
# En mode one-liner, les fichiers compagnons sont téléchargés à la volée.
#
# Aucun secret n'est commité : les identifiants passent par .env / l'env.
# ==============================================================================
set -euo pipefail

GN='\033[1;32m' YW='\033[1;33m' RD='\033[1;31m' BL='\033[1;34m' CL='\033[0m'
info() { echo -e "${BL}[INFO]${CL} $*"; }
ok()   { echo -e "${GN}[ OK ]${CL} $*"; }
warn() { echo -e "${YW}[WARN]${CL} $*"; }
die()  { echo -e "${RD}[ERR ]${CL} $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage :
  sudo ./scripts/fs25-lxc.sh [options]                                   (depuis un clone)
  sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Titouanlvt/FS25-LXC/main/scripts/fs25-lxc.sh)"   (one-liner)

Options :
  --vmid N      ID du conteneur (défaut : prochain ID libre)
  --cpu N       vCPU du conteneur       (défaut : preset CT_CPU, 4)
  --ram MB      RAM du conteneur en Mo   (défaut : preset CT_RAM, 8192)
  --disk GB     Disque du conteneur en Go (défaut : preset CT_DISK, 64)
  --storage S   Stockage de la rootfs    (défaut : preset CT_STORAGE, local-lvm)
  --check       Revue sans rien déployer : prérequis + CT existant si --vmid,
                exit 0 si tout est OK, 1 sinon
  -h, --help    Affiche cette aide

Configuration : variables d'environnement, ou fichier .env (gitignoré) à la racine
du clone, ou FS25_ENV_FILE=/chemin/vers/fichier.env. En mode one-liner, les valeurs
manquantes (STEAM_USER, STEAM_PASS, mot de passe root du conteneur...) sont
demandées en interactif.
USAGE
}

# --- Revue (--check) : compteurs + fonction host_review --------------------------
CHK_PASS=0 CHK_FAIL=0
note() { echo -e "${YW}[WARN]${CL} $*"; }
chk() {
  if [[ "$1" -eq 0 ]]; then
    echo -e "${GN}[PASS]${CL} $2"; CHK_PASS=$((CHK_PASS + 1))
  else
    echo -e "${RD}[FAIL]${CL} $2"; CHK_FAIL=$((CHK_FAIL + 1))
  fi
}

host_review() {
  set +e
  echo -e "${BL}== Revue hôte (fs25-lxc.sh --check) ==${CL}"
  local NODE c tpl conf cores mem rsz bridge rel f ok
  NODE="$(hostname)"

  [[ $EUID -eq 0 ]]; chk $? "exécuté en root (EUID=0)"
  for c in pct pveam pvesh pveversion; do
    command -v "$c" >/dev/null 2>&1; chk $? "outil $c présent"
  done
  if command -v pveversion >/dev/null 2>&1; then
    local pve_major
    pve_major="$(pveversion 2>/dev/null | head -n1 | sed -n 's#.*/\([0-9][0-9]*\)\..*#\1#p')"
    if [[ -n "$pve_major" && "$pve_major" -ge 8 ]]; then
      chk 0 "Proxmox VE $pve_major.x (>= 8 : version testée)"
    else
      note "Proxmox VE ${pve_major:-inconnu} (< 8) : Ubuntu 26.04 en LXC est prévu pour PVE 8/9 ; sur PVE 7 (LXC 4.0, cgroup v1) le déploiement peut nécessiter des ajustements"
    fi
  fi

  pvesh get "/storage/$CT_STORAGE" >/dev/null 2>&1; chk $? "stockage '$CT_STORAGE' déclaré"

  bridge="${CT_NET##*bridge=}"; bridge="${bridge%%,*}"
  if [[ -n "$bridge" && "$bridge" != "$CT_NET" ]]; then
    if pvesh get "/nodes/$NODE/network" 2>/dev/null | grep -q "\"$bridge\"" || grep -q "$bridge" /etc/network/interfaces 2>/dev/null; then
      chk 0 "bridge $bridge existe"
    else
      chk 1 "bridge $bridge introuvable"
    fi
  else
    chk 1 "bridge non détecté dans CT_NET='$CT_NET'"
  fi

  pveam update >/dev/null 2>&1
  tpl="$(pveam available --section system 2>/dev/null | awk -v p="ubuntu-${VAR_VERSION}" '$2 ~ "^"p {print $2}' | sort -V | tail -n1)"
  if [[ -n "$tpl" ]]; then
    chk 0 "template Proxmox ubuntu-$VAR_VERSION disponible ($tpl)"
  elif ls /var/lib/vz/template/cache/ubuntu-${VAR_VERSION}*-root.tar.xz >/dev/null 2>&1; then
    chk 0 "image cloud ubuntu-$VAR_VERSION déjà en cache"
  else
    ok=1
    for rel in "${VAR_VERSION}.1" "$VAR_VERSION"; do
      f="ubuntu-${rel}-server-cloudimg-amd64-root.tar.xz"
      if curl -fsSI --max-time 20 "https://cloud-images.ubuntu.com/releases/${rel}/release/${f}" >/dev/null 2>&1; then ok=0; break; fi
    done
    chk $ok "image cloud ubuntu-$VAR_VERSION téléchargeable (cloud-images.ubuntu.com)"
  fi

  if [[ -z "${VMID:-}" ]] && command -v pvesh >/dev/null 2>&1; then
    VMID="$(pvesh get /nextid 2>/dev/null)"
  fi
  if [[ -n "${VMID:-}" ]]; then
    if command -v pct >/dev/null 2>&1 && pct status "$VMID" >/dev/null 2>&1; then
      chk 0 "CT $VMID existe (revue de l'existant)"
      if pct status "$VMID" 2>/dev/null | grep -q running; then chk 0 "CT $VMID en cours d'exécution"; else chk 1 "CT $VMID arrêté (pct start $VMID)"; fi
      conf="$(pct config "$VMID" 2>/dev/null)"
      cores="$(awk -F': ' '/^cores:/ {print $2}' <<<"$conf")"
      mem="$(awk -F': ' '/^memory:/ {print $2}' <<<"$conf")"
      rsz="$(grep -o 'size=[0-9]*G' <<<"$conf" | head -n1 | cut -d= -f2 | tr -d 'G')"
      if [[ "$cores" == "$CT_CPU" ]]; then chk 0 "cores du CT = $cores (preset $CT_CPU)"; else chk 1 "cores du CT = ${cores:-?} != preset $CT_CPU"; fi
      if [[ "$mem" == "$CT_RAM" ]]; then chk 0 "RAM du CT = $mem Mo (preset $CT_RAM)"; else chk 1 "RAM du CT = ${mem:-?} Mo != preset $CT_RAM"; fi
      if [[ -n "$rsz" ]] && [[ "$rsz" -ge "$CT_DISK" ]]; then chk 0 "rootfs ${rsz}G >= preset ${CT_DISK}G"; else chk 1 "rootfs ${rsz:-?}G < preset ${CT_DISK}G"; fi
      if pct exec "$VMID" -- test -x /usr/local/bin/fs25-check.sh 2>/dev/null; then
        pct exec "$VMID" -- /usr/local/bin/fs25-check.sh
        chk $? "revue interne fs25-check (CT $VMID)"
      else
        chk 1 "fs25-check.sh absent dans le CT $VMID (installation FS25 non faite ?)"
      fi
    elif command -v pct >/dev/null 2>&1; then
      chk 0 "CT $VMID libre (pas encore créé)"
    else
      chk 1 "pct absent : impossible de vérifier le CT $VMID"
    fi
  else
    echo -e "${YW}[WARN]${CL} VMID non determined : vérification CTID sautée"
  fi

  if [[ "${FS_SOURCE:-steamcmd}" == "steamcmd" && "${STEAM_LOGIN_MODE:-account}" == "account" ]]; then
    if [[ -n "${STEAM_USER:-}" && -n "${STEAM_PASS:-}" ]]; then
      chk 0 "identifiants Steam présents (STEAM_USER/STEAM_PASS)"
    elif [[ -t 0 ]]; then
      read -r -p "Compte Steam possédant FS25 (STEAM_USER) : " STEAM_USER
      read -rs -p "Mot de passe Steam (STEAM_PASS) : " STEAM_PASS; echo
      if [[ -n "${STEAM_USER:-}" && -n "${STEAM_PASS:-}" ]]; then chk 0 "identifiants Steam saisis"; else chk 1 "identifiants Steam non saisis"; fi
    else
      chk 1 "STEAM_USER/STEAM_PASS manquants (renseignez .env, FS25_ENV_FILE ou l'environnement)"
    fi
  fi

  echo -e "${BL}== Résultat : $CHK_PASS OK, $CHK_FAIL échec(s) ==${CL}"
  set -e
  [[ $CHK_FAIL -eq 0 ]] && return 0
  return 1
}

# --- 0. Mode one-liner : si les fichiers compagnons sont absents, on les télécharge
RAW_BASE="${FS25_RAW_BASE:-https://raw.githubusercontent.com/Titouanlvt/FS25-LXC/main}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd || pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || pwd)"
BOOTSTRAP_DIR=""
ENVFILE=""
cleanup() {
  [[ -n "$ENVFILE" ]] && rm -f "$ENVFILE"
  [[ -n "$BOOTSTRAP_DIR" && -d "$BOOTSTRAP_DIR" ]] && rm -rf "$BOOTSTRAP_DIR"
}
trap cleanup EXIT

if [[ ! -f "$SCRIPT_DIR/install-fs25.sh" ]]; then
  BOOTSTRAP_DIR="$(mktemp -d /tmp/fs25-lxc.XXXXXX)"
  SCRIPT_DIR="$BOOTSTRAP_DIR"
  REPO_DIR="$BOOTSTRAP_DIR"
  mkdir -p "$REPO_DIR/config"
  info "Mode one-liner : téléchargement des fichiers compagnons depuis $RAW_BASE ..."
  for f in scripts/install-fs25.sh scripts/update-fs25.sh scripts/fs25-check.sh config/dedicatedServer.xml.template config/dedicatedServerConfig.xml.template; do
    dest="$SCRIPT_DIR/$(basename "$f")"
    [[ "$f" == config/* ]] && dest="$REPO_DIR/config/$(basename "$f")"
    curl -fsSL --retry 3 "$RAW_BASE/$f" -o "$dest" || die "Téléchargement de $f impossible depuis $RAW_BASE."
  done
  ok "Fichiers compagnons téléchargés dans $BOOTSTRAP_DIR"
fi

# --- 1. Configuration : FS25_ENV_FILE / .env (gitignoré), presets, puis CLI ----
ENV_FILE="${FS25_ENV_FILE:-$REPO_DIR/.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
  info "Variables chargées depuis $ENV_FILE"
fi

VAR_OS="${VAR_OS:-ubuntu}"
VAR_VERSION="${VAR_VERSION:-26.04}"   # Ubuntu 26.04 LTS (Resolute Raccoon), 26.04.1 si dispo
VAR_UNPRIVILEGED="${VAR_UNPRIVILEGED:-1}"
CT_HOSTNAME="${CT_HOSTNAME:-fs25}"
CT_STORAGE="${CT_STORAGE:-local-lvm}"
# Presets de ressources (recommandations GIANTS / wine-gameservers) :
#   2-4 joueurs : 3 vCPU / 4 Go RAM | 5-10 joueurs : 3 vCPU / 8 Go RAM | 16 joueurs : 4 vCPU / 12 Go RAM
#   Disque : jeu de base > 50 Go, tous les DLC > 65 Go
CT_CPU="${CT_CPU:-4}"
CT_RAM="${CT_RAM:-8192}"
CT_DISK="${CT_DISK:-64}"
CT_SWAP="${CT_SWAP:-512}"
CT_NET="${CT_NET:-name=eth0,bridge=vmbr0,ip=dhcp}"
VMID="${VMID:-}"
CHECK_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)   CHECK_MODE=1; shift ;;
    --vmid)    VMID="$2"; shift 2 ;;
    --cpu)     CT_CPU="$2"; shift 2 ;;
    --ram)     CT_RAM="$2"; shift 2 ;;
    --disk)    CT_DISK="$2"; shift 2 ;;
    --storage) CT_STORAGE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Option inconnue : $1 (voir --help)" ;;
  esac
done

# --- 1b. Mode revue (--check) : exit 0 si tout est OK, 1 sinon -------------------
if [[ "$CHECK_MODE" == "1" ]]; then
  if host_review; then exit 0; else exit 1; fi
fi

# --- 2. Prérequis --------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Ce script doit être exécuté en root sur l'hôte Proxmox VE."
for cmd in pct pveam pvesh; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd introuvable : exécutez ce script sur un nœud Proxmox VE."
done

VMID="${VMID:-$(pvesh get /nextid)}"
pct status "$VMID" >/dev/null 2>&1 && die "Le conteneur $VMID existe déjà (choisissez un autre --vmid)."

if [[ -z "${CT_ROOT_PASSWORD:-}" ]]; then
  if [[ -t 0 ]]; then
    read -rs -p "Mot de passe root du conteneur $VMID : " CT_ROOT_PASSWORD
    echo
  else
    CT_ROOT_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
    warn "CT_ROOT_PASSWORD non défini : mot de passe root généré (affiché une seule fois) :"
    echo -e "  ${YW}${CT_ROOT_PASSWORD}${CL}"
  fi
fi
[[ -n "$CT_ROOT_PASSWORD" ]] || die "Un mot de passe root est requis pour le conteneur."

# Identifiants Steam (jamais écrits dans le repo)
STEAM_LOGIN_MODE="${STEAM_LOGIN_MODE:-account}"
FS_SOURCE="${FS_SOURCE:-steamcmd}"
if [[ "$FS_SOURCE" == "steamcmd" && "$STEAM_LOGIN_MODE" == "account" ]]; then
  if [[ -z "${STEAM_USER:-}" && -t 0 ]]; then
    read -r -p "Compte Steam possédant FS25 (STEAM_USER) : " STEAM_USER
    read -rs -p "Mot de passe Steam (STEAM_PASS) : " STEAM_PASS
    echo
    read -r -p "Code Steam Guard (vide si inutile) : " STEAM_GUARD || true
  fi
  if [[ -z "${STEAM_USER:-}" || -z "${STEAM_PASS:-}" ]]; then
    die "STEAM_USER et STEAM_PASS requis (STEAM_LOGIN_MODE=account) : renseignez .env ou lancez en interactif."
  fi
fi
if [[ "$STEAM_LOGIN_MODE" == "anonymous" ]]; then
  warn "STEAM_LOGIN_MODE=anonymous : FS25 n'a pas de serveur dédié gratuit — app_update échouera sans licence."
fi

# --- 3. Template Ubuntu --------------------------------------------------------
info "Recherche d'un template Ubuntu $VAR_VERSION ..."
pveam update >/dev/null 2>&1 || true
TEMPLATE="$(pveam available --section system 2>/dev/null | awk -v p="ubuntu-${VAR_VERSION}" '$2 ~ "^"p {print $2}' | sort -V | tail -n1 || true)"
if [[ -n "$TEMPLATE" ]]; then
  pveam list local 2>/dev/null | grep -q "vztmpl/${TEMPLATE}$" || pveam download local "$TEMPLATE"
  TEMPLATE_VOL="local:vztmpl/${TEMPLATE}"
  ok "Template Proxmox : $TEMPLATE"
else
  warn "Pas de template ubuntu-${VAR_VERSION} dans le dépôt Proxmox : repli sur l'image cloud officielle Ubuntu."
  CACHE_DIR="/var/lib/vz/template/cache"
  TEMPLATE=""
  for rel in "${VAR_VERSION}.1" "$VAR_VERSION"; do
    f="ubuntu-${rel}-server-cloudimg-amd64-root.tar.xz"
    url="https://cloud-images.ubuntu.com/releases/${rel}/release/${f}"
    if [[ ! -f "$CACHE_DIR/$f" ]]; then
      info "Téléchargement de $url ..."
      curl -fsSL --retry 3 -o "$CACHE_DIR/$f" "$url" || rm -f "$CACHE_DIR/$f"
    fi
    if [[ -f "$CACHE_DIR/$f" ]]; then TEMPLATE="$f"; break; fi
  done
  [[ -n "$TEMPLATE" ]] || die "Impossible de télécharger une image Ubuntu ${VAR_VERSION}."
  TEMPLATE_VOL="local:vztmpl/${TEMPLATE}"
  ok "Image cloud Ubuntu : $TEMPLATE"
fi

# --- 4. Création du LXC ---------------------------------------------------------
info "Création du conteneur $VMID (${VAR_OS} ${VAR_VERSION}, stockage ${CT_STORAGE}) ..."
pct create "$VMID" "$TEMPLATE_VOL" \
  --hostname "$CT_HOSTNAME" \
  --password "$CT_ROOT_PASSWORD" \
  --ostype "$VAR_OS" \
  --storage "$CT_STORAGE" \
  --rootfs "${CT_STORAGE}:${CT_DISK}" \
  --net0 "$CT_NET" \
  --features "keyctl=1" \
  --unprivileged "$VAR_UNPRIVILEGED"

# --- 5. Reset des ressources (CPU / RAM / Disque / Swap) ------------------------
info "Application des presets de ressources sur le conteneur $VMID ..."
pct set "$VMID" \
  --cores "$CT_CPU" \
  --memory "$CT_RAM" \
  --swap "$CT_SWAP" \
  --cpulimit 0 \
  --cpuunits 1024 \
  --features "keyctl=1"
pct resize "$VMID" rootfs "${CT_DISK}G" 2>/dev/null || true
ok "Ressources : ${CT_CPU} vCPU | ${CT_RAM} Mo RAM | ${CT_SWAP} Mo swap | ${CT_DISK} Go disque"

# --- 6. Démarrage ---------------------------------------------------------------
info "Démarrage du conteneur $VMID ..."
pct start "$VMID"
for _ in $(seq 1 30); do
  pct exec "$VMID" -- true 2>/dev/null && break
  sleep 2
done
pct exec "$VMID" -- true 2>/dev/null || die "Le conteneur $VMID ne répond pas après le démarrage."
CT_IP="$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}')"
ok "Conteneur démarré (IP : ${CT_IP:-dhcp})"

# --- 7. Installation de FS25 dans le conteneur ----------------------------------
FS_VARS=(STEAM_LOGIN_MODE STEAM_USER STEAM_PASS STEAM_GUARD FS_APPID FS_SOURCE FS_INSTALL_DIR
         FS_WEB_PORT FS_WEB_TLS_PORT FS_WEB_ADMIN_USER FS_WEB_ADMIN_PASS
         FS_GAME_NAME FS_GAME_PASSWORD FS_ADMIN_PASSWORD FS_MAX_PLAYERS FS_PORT FS_LANGUAGE
         FS_SAVE_INTERVAL FS_CROSSPLAY FS_ECONOMIC_DIFFICULTY FS_PAUSE_IF_EMPTY
         FS_INITIAL_MONEY FS_SAVEGAME_INDEX FS_MAP)
ENVFILE="$(mktemp /tmp/fs25-lxc-env.XXXXXX)"
chmod 600 "$ENVFILE"
for v in "${FS_VARS[@]}"; do
  printf '%s=%q\n' "$v" "${!v:-}" >> "$ENVFILE"
done

push_ct() {  # push_ct <src> <dest> <mode> — compatible PVE 7+ (repli sans --perms, puis chmod)
  pct push "$VMID" "$1" "$2" --perms "$3" 2>/dev/null || pct push "$VMID" "$1" "$2"
}
push_ct "$SCRIPT_DIR/install-fs25.sh" /root/install-fs25.sh 0700
push_ct "$SCRIPT_DIR/update-fs25.sh" /root/update-fs25.sh 0700
push_ct "$SCRIPT_DIR/fs25-check.sh" /root/fs25-check.sh 0700
push_ct "$REPO_DIR/config/dedicatedServer.xml.template" /root/dedicatedServer.xml.template 0600
push_ct "$REPO_DIR/config/dedicatedServerConfig.xml.template" /root/dedicatedServerConfig.xml.template 0600
push_ct "$ENVFILE" /root/fs25.env 0600
pct exec "$VMID" -- chmod 700 /root/install-fs25.sh /root/update-fs25.sh /root/fs25-check.sh
pct exec "$VMID" -- chmod 600 /root/fs25.env /root/dedicatedServer.xml.template /root/dedicatedServerConfig.xml.template

info "Installation de Farming Simulator 25 dans le conteneur (téléchargement ~50 Go, peut durer longtemps) ..."
pct exec "$VMID" -- bash -c 'set -a; source /root/fs25.env; set +a; bash /root/install-fs25.sh'
pct exec "$VMID" -- rm -f /root/fs25.env

# --- 8. Récapitulatif ------------------------------------------------------------
FS_WEB_PORT="${FS_WEB_PORT:-8080}" FS_WEB_TLS_PORT="${FS_WEB_TLS_PORT:-8443}" FS_PORT="${FS_PORT:-10823}"
ok "Déploiement terminé !"
cat <<EOF

  Conteneur   : $VMID ($CT_HOSTNAME) — IP : ${CT_IP:-<dhcp>}
  Ressources  : ${CT_CPU} vCPU | ${CT_RAM} Mo RAM | ${CT_SWAP} Mo swap | ${CT_DISK} Go
  Panneau web : http://${CT_IP:-<ip>}:${FS_WEB_PORT}  /  https://${CT_IP:-<ip>}:${FS_WEB_TLS_PORT}
  Port jeu    : ${FS_PORT} TCP+UDP
  Service     : pct exec $VMID -- systemctl status fs25
  Logs        : pct exec $VMID -- journalctl -u fs25 -f
  Mise à jour : pct exec $VMID -- systemctl start fs25-update.service (timer hebdo fs25-update.timer)
  Sauvegarde  : vzdump $VMID
EOF
