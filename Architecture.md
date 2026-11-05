# Architecture — FS25-LXC

Document technique décrivant l'architecture du déploiement d'un serveur dédié *Farming Simulator 25* dans un LXC Proxmox VE.

---

## 1. Vue d'ensemble

```
┌──────────────────────────────────────────────────────────────────────────┐
│  HÔTE PROXMOX VE (root)                                                      │
│                                                                          │
│   scripts/fs25-lxc.sh                                                    │
│     1. lit .env (gitignoré) + presets var_* + args CLI                   │
│     2. trouve/télécharge le template Ubuntu 26.04 (pveam ou cloud-images)│
│     3. pct create  → LXC (hostname, root password, net0)                 │
│     4. pct set + pct resize  → RESET CPU / RAM / swap / disque           │
│     5. pct start, récupère l'IP                                          │
│     6. pct push (install-fs25.sh, update-fs25.sh, templates XML, env)    │
│     7. pct exec → install-fs25.sh   (puis supprime /root/fs25.env)       │
│                                                                          │
└──────────────────────────────┬───────────────────────────────────────────┘
                               │ pct exec / pct push
┌──────────────────────────────▼───────────────────────────────────────────┐
│  CONTENEUR LXC (unprivileged, Ubuntu 26.04 LTS)          CTID ex. 120    │
│                                                                          │
│   scripts/install-fs25.sh (lancé en root dans le CT)                     │
│     ├── apt : wine64, xvfb, ufw, openssl, libs steam (lib32gcc-s1…)      │
│     ├── user système `steam` (nologin) — le serveur ne tourne JAMAIS     │
│     │      en root                                                        │
│     ├── /opt/steamcmd/steamcmd.sh                                         │
│     ├── /opt/fs25/  ← app_update 2300320 (Windows forcé)                 │
│     │     ├── dedicatedServer.exe      (binaire serveur GIANTS)          │
│     │     ├── FarmingSimulator2025Game.exe                                 │
│     │     ├── steam_appid.txt           (2300320)                          │
│     │     ├── dedicatedServer.xml      ← rendu depuis config/*.template  │
│     │     ├── cert.pem / pk.pem         (TLS auto-signé, panneau 8443)    │
│     │     └── fs25-update.sh → /usr/local/bin/                            │
│     ├── /home/steam/.fs25server/  (WINEPREFIX, WINEARCH=win64)            │
│     │     └── drive_c/users/steam/Documents/My Games/FarmingSimulator2025/│
│     │           └── dedicated_server/dedicatedServerConfig.xml ← template  │
│     ├── /etc/fs25/fs25.env (0600, SANS mot de passe) → utilisé par le     │
│     │      timer de mise à jour                                           │
│     ├── systemd : fs25.service + fs25-update.service + fs25-update.timer  │
│     └── ufw : 22, 10823 TCP/UDP, 10824–10825/UDP, 8080, 8443              │
│                                                                          │
│   fs25.service ──► /usr/local/bin/fs25-start.sh                          │
│                       └─ xvfb-run -a wine /opt/fs25/dedicatedServer.exe   │
│                          (spawn ensuite FarmingSimulator2025Game.exe -server│
│                           quand on démarre une savegame depuis le panneau) │
└──────────────────────────────────────────────────────────────────────────┘
        ▲ ports exposés côté hôte/routeur
        │  10823 TCP+UDP (jeu) · 10824–10825/UDP · 8080/8443 TCP (panneau web)
        └─ joueurs + admin
```

## 2. Composants

| Composant | Rôle | Fichier |
|---|---|---|
| Orchestrateur hôte | Crée le LXC, applique les presets de ressources, pousse et lance l'installation | `scripts/fs25-lxc.sh` |
| Installateur conteneur | Installe Wine/SteamCMD/FS25, rend les XML, crée services et pare-feu | `scripts/install-fs25.sh` |
| Updater | `app_update` SteamCMD + restart du service (timer hebdo) | `scripts/update-fs25.sh` |
| Templates XML | `dedicatedServer.xml` (web) et `dedicatedServerConfig.xml` (jeu), placeholders `@VAR@` | `config/*.template` |
| Config secrète | `.env` local, gitignoré | `.env` / `.env.example` |
| Config persistante CT | variables non secrètes pour l'updater | `/etc/fs25/fs25.env` (0600) |

## 3. Flux de déploiement (étapes)

0. **Mode one-liner** (optionnel) : `sudo bash -c "$(curl -fsSL …/scripts/fs25-lxc.sh)"` — `BASH_SOURCE` ne pointe pas vers un fichier du dépôt, le script détecte l'absence de `install-fs25.sh` à côté de lui et télécharge les 4 fichiers compagnons depuis `$FS25_RAW_BASE` (défaut `raw.githubusercontent.com/Titouanlvt/FS25-LXC/main`) dans un `mktemp -d`, nettoyé à la sortie (trap EXIT). `bash -c "$(…)"` garde stdin libre pour les prompts interactifs (à préférer à `curl | bash -s`).
1. **Préflight** : root requis, `pct`/`pveam`/`pvesh` présents, CTID libre, mot de passe root (prompt ou généré), identifiants Steam si `STEAM_LOGIN_MODE=account`.
2. **Template** : `pveam available` → `pveam download local <ubuntu-26.04...>` ; sinon téléchargement de l'image cloud `ubuntu-26.04[-1]-server-cloudimg-amd64-root.tar.xz` depuis `cloud-images.ubuntu.com` dans `/var/lib/vz/template/cache/`.
3. **Création** : `pct create <vmid> <template> --hostname --password --net0 --rootfs <storage>:<disk> --unprivileged 1 --features keyctl=1`.
4. **Reset ressources** : `pct set --cores --memory --swap --cpulimit 0 --cpuunits 1024` + `pct resize rootfs <disk>G`.
5. **Démarrage** : `pct start`, attente de boot, lecture de l'IP (`hostname -I`).
6. **Push** : installateur, updater, templates XML et fichier d'env 0600 → `/root/` du CT.
7. **Install** : `pct exec … bash /root/install-fs25.sh` avec l'env sourcé ; le fichier d'env est supprimé juste après.
8. **Vérification** : `systemctl start fs25`, récapitulatif (IP, URLs, ports, commandes).

## 4. Flux de données (configuration → serveur)

```
.env (hôte, gitignoré)
  │  (pct push, 0600, puis supprimé)
  ▼
/root/fs25.env (CT, temporaire)
  │  source dans install-fs25.sh
  ▼
config/dedicatedServer.xml.template ──sed + échappement XML──► /opt/fs25/dedicatedServer.xml
config/dedicatedServerConfig.xml.template ──sed + échappement XML──► <WINEPREFIX>/…/dedicated_server/dedicatedServerConfig.xml
  │
  ▼  lus au démarrage par dedicatedServer.exe (puis FarmingSimulator2025Game.exe -server)
serveur FS25 : panneau web 8080/8443 + jeu 10823 TCP/UDP
```

Échappement XML appliqué sur toutes les valeurs injectées (`& < > " '`), plus échappement des métacaractères `sed` (`\ & |`).

## 5. Réseau et ports

| Port | Proto | Sens | Composant | Exposition |
|---|---|---|---|---|
| 10823 | TCP + UDP | entrée | jeu FS25 | Internet (routeur + pare-feu hôte) |
| 10824–10825 | UDP | entrée | jeu FS25 (secondaire) | idem |
| 8080 | TCP | entrée | panneau web HTTP | LAN recommandé |
| 8443 | TCP | entrée | panneau web HTTPS (TLS auto-signé) | LAN/VPN recommandé |
| 22 | TCP | entrée | SSH du CT | selon politique |

Le conteneur a son propre ufw ; le pare-feu **hôte Proxmox** (et/ou le routeur NAT) doit en plus rediriger 10823/10824/10825 vers l'IP du CT.

## 6. Stockage

| Chemin (dans le CT) | Contenu | Taille indicative |
|---|---|---|
| rootfs (`<CT_STORAGE>`) | système + tout le reste | preset 64 Go (50 Go jeu + marge) |
| `/opt/fs25` | jeu Steam (appid 2300320) | ~50 Go, >65 Go avec tous les DLC |
| `/home/steam/.fs25server` | préfixe Wine + profil + **savegames** | savegames : quelques Go |
| `/etc/fs25/fs25.env` | config updater (sans secret) | 0600 |

Sauvegardes : `vzdump <CTID>` (Proxmox) ou export ciblé du dossier `savegame*` du profil.

## 7. Sécurité

- Conteneur **non privilégié** (`unprivileged=1`, `keyctl=1`), serveur sous l'utilisateur `steam`.
- **Aucun secret dans le git** : `.env` gitignoré ; l'env poussé dans le CT est en 0600 et supprimé après l'installation ; `/etc/fs25/fs25.env` ne contient jamais de mot de passe.
- TLS auto-signé local pour le panneau HTTPS (8443).
- Panneau web = contrôle total du serveur → documenté « LAN/VPN uniquement » ; ufw restreint les entrées.
- Licence : GIANTS exige une **licence dédiée** pour le serveur ; rien n'est contourné (mode `anonymous` documenté comme non viable).

## 8. Mise à jour et supervision

- `fs25-update.timer` (dimanche 04:00, `Persistent=true`) → `fs25-update.service` → `/usr/local/bin/fs25-update.sh` : stop `fs25`, `steamcmd +app_update 2300320 validate` (jeton Steam en cache, ou `anonymous`), start `fs25`.
- Supervision : `systemctl status fs25`, `journalctl -u fs25 -f` (`StandardOutput=journal+console`).
- Reprise sur panne : `Restart=on-failure`, `RestartSec=15`, `KillMode=mixed`, `TimeoutStopSec=180`.

## 9. Choix techniques et alternatives

| Choix | Pourquoi | Alternative écartée |
|---|---|---|
| LXC plutôt que VM | densité, overhead nul, `pct` scriptable | VM Windows Server (lourde, licence Windows en plus) |
| Wine 64 bits + Xvfb | FS25 n'a pas de build Linux natif ; wine-gameservers prouve la viabilité | GE-Proton + client Steam headless (itsmrshow/fs25-steam-dedicated-linux) : plus lourd, réservé au contournement de licence Steam |
| SteamCMD appid 2300320, plateforme Windows forcée | télécharge le jeu complet contenant `dedicatedServer.exe` | app « Dedicated Server » séparée : **n'existe pas** pour FS25 |
| Templates XML + `sed` | config déclarative, versionnée, sans dépendance | génération inline en dur dans le script |
| `.env` gitignoré | secrets hors du VCS | fichier de config commité (dangereux) |

## 10. Points d'extension

- Changer de map/DLC/slots : éditer les variables `FS_*` puis relancer, ou éditer le XML directement + `systemctl restart fs25`.
- Plusieurs serveurs : cloner le script avec un autre `VMID` et un autre `FS_PORT`.
- `FS_SOURCE=eshop` : déposer l'installeur GIANTS eShop dans `/opt/fs25-installer` (bind via `pct set --mp0`) → installation silencieuse Wine.
- Sauvegarde auto des savegames : ajouter un second timer systemd (hors v1).
