# 🌾 FS25-LXC

**Serveur dédié Farming Simulator 25 dans un conteneur LXC Proxmox VE** — déployé en une commande, basé sur l'esprit de [`ct/ubuntu.sh`](https://github.com/community-scripts/ProxmoxVE/blob/main/ct/ubuntu.sh) (community-scripts), avec toute la partie « Farming » : SteamCMD, Wine, configuration XML complète, service systemd, mises à jour auto et **presets de ressources (CPU / RAM / disque) remis à zéro et modifiables**.

![Ubuntu](https://img.shields.io/badge/Ubuntu-26.04_LTS-E95420?logo=ubuntu&logoColor=white)
![Proxmox](https://img.shields.io/badge/Proxmox_VE-8%2F9-E57000?logo=proxmox&logoColor=white)
![Wine](https://img.shields.io/badge/Wine-server_64bit-9A2A2A?logo=wine&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green)

---

## ✨ Fonctionnalités

- 🐳 Création du LXC **Ubuntu Server 26.04 LTS (Resolute Raccoon)** via `pct` (template Proxmox ou image cloud officielle en repli)
- ⚙️ **Reset des ressources du conteneur** : `pct set --cores/--memory/--swap` + `pct resize rootfs` avec presets GIANTS modifiables (`.env` ou `--cpu/--ram/--disk`)
- 🎮 Installation de **Farming Simulator 25** (Steam appid `2300320`) via **SteamCMD**, login `account` ou `anonymous` configurable
- 🍷 Exécution du serveur dédié Windows (`dedicatedServer.exe`) sous **Wine 64 bits + Xvfb** (pas de build Linux natif chez GIANTS)
- 📝 Génération complète de **`dedicatedServer.xml`** (panneau web, admin initial, TLS) et **`dedicatedServerConfig.xml`** (nom, mots de passe, port, map, auto-save, crossplay…)
- 🔄 Service **systemd `fs25`** + **timer hebdomadaire `fs25-update.timer`** (mise à jour SteamCMD automatique)
- 🔥 Pare-feu **ufw** dans le conteneur (22, 10823 TCP/UDP, 10824-10825/UDP, 8080, 8443)
- 🔒 **Aucun secret dans le git** : `.env` gitignoré, `.env.example` fourni, identifiants passés par variables d'environnement

## 🧱 Architecture

```
Hôte Proxmox VE
└── scripts/fs25-lxc.sh  (root, sur l'hôte)
    ├── pveam / pct create  → LXC Ubuntu 26.04 (CTID, hostname, réseau)
    ├── pct set/resize      → RESET CPU/RAM/swap/disk (presets modifiables)
    └── pct push + pct exec → scripts/install-fs25.sh dans le conteneur
        └── LXC (unprivileged)
            ├── wine64 + xvfb
            ├── /opt/steamcmd (SteamCMD)
            ├── /opt/fs25 (jeu, appid 2300320)
            │   ├── dedicatedServer.exe      ← service fs25 (wine + xvfb-run)
            │   └── dedicatedServer.xml      ← panneau web 8080/8443 + initial_admin
            ├── ~/.fs25server (préfixe Wine)
            │   └── drive_c/users/steam/Documents/My Games/FarmingSimulator2025/
            │       └── dedicated_server/dedicatedServerConfig.xml  ← réglages serveur
            └── fs25-update.timer (hebdo) → /usr/local/bin/fs25-update.sh
```

## 📋 Prérequis

| Élément | Détail |
|---|---|
| Hôte | Proxmox VE 8.x / 9.x, accès **root en SSH** |
| Stockage | un stockage avec contenu `vztmpl` + `rootfs` (ex. `local-lvm`) |
| Réseau | un bridge (ex. `vmbr0`), DHCP ou IP statique |
| Licence | **une seconde licence FS25** (GIANTS impose serveur + client séparés) sur un compte Steam |
| Ressources | voir presets ci-dessous |
| Espace disque | ~50 Go (jeu de base) à 70+ Go (tous DLC) dans le conteneur |

> ⚠️ GIANTS ne fournit **aucun serveur Linux natif** : le binaire `dedicatedServer.exe` (Windows) tourne ici via Wine. Le login SteamCMD `anonymous` ne fonctionnera pas (pas de serveur gratuit) — utilisez `STEAM_LOGIN_MODE=account`.

## 🚀 Installation rapide

**Une seule commande**, sur l'hôte Proxmox en root (les identifiants Steam et le mot de passe root du conteneur vous seront demandés en interactif) :

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Titouanlvt/FS25-LXC/main/scripts/fs25-lxc.sh)"
```

Avec des options (CTID, presets de ressources…) :

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Titouanlvt/FS25-LXC/main/scripts/fs25-lxc.sh)" fs25-lxc --vmid 120 --cpu 4 --ram 8192 --disk 64
```

En **non interactif** (tout passe par variables d'environnement, rien n'est commité) :

```bash
sudo env STEAM_USER=mon-compte STEAM_PASS=******** CT_ROOT_PASSWORD=******** FS_GAME_NAME="Ma Ferme" \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/Titouanlvt/FS25-LXC/main/scripts/fs25-lxc.sh)"
```

> En mode one-liner, le script télécharge à la volée ses fichiers compagnons (`install-fs25.sh`, `update-fs25.sh`, templates XML) depuis `raw.githubusercontent.com`. Dépôt/branche alternatif : `FS25_RAW_BASE=https://raw.githubusercontent.com/<owner>/<repo>/<branche>`.

Le script : crée le LXC Ubuntu 26.04, **reset les ressources** (CPU/RAM/disque/swap), démarre le conteneur, puis installe tout FS25 à l'intérieur (le téléchargement du jeu ~50 Go prend un moment).

### Installation personnalisée (clone du dépôt)

```bash
git clone https://github.com/Titouanlvt/FS25-LXC.git
cd FS25-LXC
cp .env.example .env        # éditez .env : STEAM_USER / STEAM_PASS / nom du serveur...
sudo ./scripts/fs25-lxc.sh  # ou avec options : --vmid 120 --cpu 4 --ram 8192 --disk 64
```

## ⚙️ Configuration (variables)

Toutes les variables sont dans [`.env.example`](.env.example) — copiez-le en `.env` (gitignoré). Les presets de ressources se surchargent aussi en CLI.

| Variable | Défaut | Rôle |
|---|---|---|
| `VMID` | auto (`nextid`) | ID du conteneur |
| `CT_HOSTNAME` | `fs25` | Nom du conteneur |
| `VAR_VERSION` | `26.04` | Version Ubuntu (26.04 LTS / 26.04.1) |
| `CT_STORAGE` | `local-lvm` | Stockage de la rootfs |
| `CT_CPU` / `CT_RAM` / `CT_DISK` / `CT_SWAP` | `4` / `8192` / `64` / `512` | **Presets ressources appliqués au LXC** |
| `CT_NET` | `name=eth0,bridge=vmbr0,ip=dhcp` | Réseau (ou `ip=192.168.1.120/24,gw=...`) |
| `STEAM_LOGIN_MODE` | `account` | `account` (licence requise) ou `anonymous` |
| `STEAM_USER` / `STEAM_PASS` / `STEAM_GUARD` | — | Identifiants Steam (jamais commités) |
| `FS_SOURCE` | `steamcmd` | `steamcmd` ou `eshop` (installeur GIANTS eShop) |
| `FS_WEB_PORT` / `FS_WEB_TLS_PORT` | `8080` / `8443` | Panneau web HTTP / HTTPS |
| `FS_WEB_ADMIN_USER` / `FS_WEB_ADMIN_PASS` | `admin` / — | `initial_admin` du panneau web |
| `FS_GAME_NAME` | `FS25 Server` | Nom dans le navigateur de serveurs (30 car. max) |
| `FS_GAME_PASSWORD` / `FS_ADMIN_PASSWORD` | — | Mot de passe joueurs / admin en jeu |
| `FS_MAX_PLAYERS` / `FS_PORT` | `16` / `10823` | Slots et port jeu TCP+UDP |
| `FS_SAVE_INTERVAL` | `180` | Auto-save en secondes |
| `FS_MAP` | `MapUS` | `MapUS`, `MapFR`, `MapAlpine` |
| `FS_LANGUAGE` / `FS_CROSSPLAY` / `FS_PAUSE_IF_EMPTY` / `FS_ECONOMIC_DIFFICULTY` / `FS_INITIAL_MONEY` / `FS_SAVEGAME_INDEX` | `fr` / `true` / `2` / `2` / `500000` / `1` | Réglages du `dedicatedServerConfig.xml` |

### 💾 Presets de ressources recommandés (GIANTS / wine-gameservers)

| Profil | vCPU | RAM | Disque conteneur |
|---|---|---|---|
| 2–4 joueurs, sans DLC | 3 | 4 Go | 64 Go |
| 5–10 joueurs, avec DLC | 3 | 8 Go | 80 Go |
| Jusqu'à 16 joueurs, tous DLC | 4 | 12 Go | 100 Go |

Exemple : `sudo ./scripts/fs25-lxc.sh --cpu 4 --ram 12288 --disk 100`

## 🌐 Ports

| Port | Protocole | Usage | À ouvrir |
|---|---|---|---|
| `10823` | TCP + UDP | Jeu (multiijoueur) | routeur + pare-feu hôte Proxmox |
| `10824–10825` | UDP | Jeu (secondaire) | idem |
| `8080` | TCP | Panneau web HTTP | LAN uniquement recommandé |
| `8443` | TCP | Panneau web HTTPS | LAN/VPN recommandé |
| `22` | TCP | SSH du conteneur | selon votre politique |

## 🎮 Après l'installation

1. Ouvrez le panneau web : `http://<ip-du-conteneur>:8080` (ou `https://...:8443`), connectez-vous avec `FS_WEB_ADMIN_USER` / `FS_WEB_ADMIN_PASS`.
2. Dans le panneau, **démarrez une savegame** → le serveur de jeu se lance (port `10823`).
3. Les joueurs se connectent via l'IP/hostname + mot de passe `FS_GAME_PASSWORD`.

## 🛠️ Exploitation

```bash
# Revue complète — exit 0 si tout est OK, 1 sinon
sudo ./scripts/fs25-lxc.sh --check --vmid <CTID>     # hôte : prérequis + ressources CT + check interne
# en one-liner : sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Titouanlvt/FS25-LXC/main/scripts/fs25-lxc.sh)" fs25-lxc --check --vmid <CTID>
pct exec <CTID> -- /usr/local/bin/fs25-check.sh      # conteneur seul : fichiers, XML, service, ports, ufw

# État / logs du serveur
pct exec <CTID> -- systemctl status fs25
pct exec <CTID> -- journalctl -u fs25 -f

# Redémarrer / arrêter
pct exec <CTID> -- systemctl restart fs25

# Mise à jour manuelle du jeu (sinon timer hebdo dimanche 04:00)
pct exec <CTID> -- systemctl start fs25-update.service

# Modifier la config serveur (puis restart)
pct exec <CTID> -- nano "/home/steam/.fs25server/drive_c/users/steam/Documents/My Games/FarmingSimulator2025/dedicated_server/dedicatedServerConfig.xml"

# Redimensionner le conteneur (CPU/RAM/disk)
pct set <CTID> --cores 6 --memory 16384
pct resize <CTID> rootfs 100G

# Sauvegarde
vzdump <CTID>                       # backup Proxmox
# ou les savegames seules :
pct exec <CTID> -- tar -czf /root/savegames.tgz -C "/home/steam/.fs25server/drive_c/users/steam/Documents/My Games/FarmingSimulator2025" savegame*
pct pull <CTID> /root/savegames.tgz ./savegames.tgz
```

## 🔒 Sécurité

- `.env` (identifiants Steam, mots de passe) est **gitignoré** — ne commitez jamais de secret (`git diff` avant chaque commit).
- Le panneau web donne un **contrôle total** du serveur : gardez `8080/8443` sur le LAN/VPN, ne les exposez pas sur Internet sans protection.
- Le conteneur tourne **non privilégié** (`--unprivileged 1`), le serveur tourne sous l'utilisateur `steam` (pas root).
- Changez `FS_WEB_ADMIN_PASS` après la première connexion (le panneau web gère ensuite les comptes lui-même).

## 🩺 Dépannage

| Symptôme | Cause probable / action |
|---|---|
| `app_update` échoue en `anonymous` | FS25 n'a pas de serveur gratuit → `STEAM_LOGIN_MODE=account` + licence |
| « Game is not activated » au lancement | La version Steam vérifie la licence via le client Steam ; utilisez le mode `eshop` (clé GIANTS) ou un client Steam actif dans le conteneur |
| Le panneau web ne répond pas | `pct exec <CTID> -- journalctl -u fs25 -f` ; vérifiez ufw (`ufw status`) et le pare-feu hôte Proxmox |
| Les joueurs ne voient pas le serveur | Ouvrez `10823` TCP+UDP sur le routeur (redirection vers l'IP du conteneur) + pare-feu Proxmox |
| Plantage wine | `WINEDEBUG=-all` masque les logs ; relancez avec `WINEDEBUG=warn+all` pour diagnostiquer |

## 📁 Structure du projet

```
FS25-LXC/
├── scripts/
│   ├── fs25-lxc.sh            # hôte Proxmox : crée le LXC, reset ressources, lance l'install
│   ├── install-fs25.sh        # dans le LXC : wine, SteamCMD, FS25, XML, systemd, ufw
│   └── update-fs25.sh         # mise à jour du jeu (timer hebdo)
├── config/
│   ├── dedicatedServer.xml.template        # panneau web (webserver, initial_admin, tls)
│   └── dedicatedServerConfig.xml.template  # réglages serveur (gameserver/settings)
├── .env.example               # toutes les variables (aucun secret)
├── AGENTS.md                  # règles pour les agents IA
├── PRD.md                     # Product Requirements Document
├── Architecture.md            # architecture technique
├── Design-System.md           # conventions de code / docs / logs
└── README.md
```

## 📚 Références

- [community-scripts/ProxmoxVE — ct/ubuntu.sh](https://github.com/community-scripts/ProxmoxVE/blob/main/ct/ubuntu.sh) (inspiration des presets `var_cpu`/`var_ram`/`var_disk`)
- [wine-gameservers/arch-fs25server](https://github.com/wine-gameservers/arch-fs25server) (FS25 sous Wine, schémas XML, presets matériels)
- [GIANTS Software — Farming Simulator 25](https://www.farming-simulator.com/) (licence serveur dédiée requise)
- Steam appid FS25 : `2300320`

## ⚖️ Licence & avertissement

Projet sous licence **MIT** (voir [LICENSE](LICENSE)). Non affilié à GIANTS Software — Farming Simulator 25 est © GIANTS Software. Héberger un serveur dédié nécessite **une licence dédiée en plus de celle du client**.
