# PRD — FS25-LXC

**Product Requirements Document**
Projet : déploiement automatisé d'un serveur dédié *Farming Simulator 25* dans un conteneur LXC Proxmox VE.
Version : 1.0 — Auteur : Titouanlvt — Statut : brouillon

---

## 1. Contexte et problème

Héberger un serveur dédié FS25 « proprement » demande aujourd'hui beaucoup d'étapes manuelles : créer un conteneur Ubuntu récent, installer Wine (FS25 n'a pas de build Linux natif), SteamCMD, télécharger ~50 Go de jeu, configurer deux fichiers XML (`dedicatedServer.xml`, `dedicatedServerConfig.xml`), créer un service, ouvrir les ports, prévoir les mises à jour… et dimensionner le conteneur (CPU/RAM/disque) sans repères.

## 2. Objectifs

- **O1** — Déployer un serveur FS25 fonctionnel en **une seule commande** exécutée sur l'hôte Proxmox.
- **O2** — Fournir des **presets de ressources (CPU/RAM/disque) fondés sur les recommandations GIANTS**, appliqués automatiquement au LXC et **modifiables**.
- **O3** — Générer une **configuration serveur complète et documentée** (XML) pilotée par variables.
- **O4** — Garantir la **pérennité** : service systemd, redémarrage auto, mises à jour SteamCMD automatiques, sauvegardes faciles.
- **O5** — Garantir la **sécurité** : aucun secret dans le git, conteneur non privilégié, service non-root, pare-feu.

## 3. Utilisateurs cibles

- Auto-hébergeurs / joueurs disposant d'un **nœud Proxmox VE** (8.x/9.x) et d'une **seconde licence FS25** (exigence GIANTS : serveur et client séparés).
- Niveau technique : à l'aise avec SSH/root sur Proxmox ; aucune compétence Wine requise.

## 4. Périmètre

### Inclus (v1)
- Déploiement **en une commande** (one-liner) : `sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Titouanlvt/FS25-LXC/main/scripts/fs25-lxc.sh)"` — le script télécharge à la volée ses fichiers compagnons depuis le dépôt (`FS25_RAW_BASE` surchargeable pour un fork/branche).
- Création du LXC **Ubuntu Server 26.04 LTS** (26.04.1 lorsqu'elle sera publiée) : template Proxmox ou image cloud officielle en repli.
- Reset/application des ressources du conteneur : `cores`, `memory`, `swap`, `rootfs` (via `pct set` + `pct resize`), presets modifiables (`.env` ou CLI `--cpu/--ram/--disk/--vmid/--storage`).
- Installation FS25 via **SteamCMD** (appid `2300320`, plateforme Windows forcée), login `account` **ou** `anonymous` configurable ; mode alternatif `eshop` (installeur GIANTS).
- Exécution via **Wine 64 bits + Xvfb**, utilisateur dédié `steam`, conteneur non privilégié.
- Génération de `dedicatedServer.xml` (webserver, `initial_admin`, TLS auto-signé) et `dedicatedServerConfig.xml` (gameserver settings) à partir de templates.
- Service `fs25.service` + timer `fs25-update.timer` (hebdomadaire).
- Pare-feu `ufw` dans le conteneur (22, 10823 TCP/UDP, 10824–10825/UDP, 8080, 8443).
- Documentation : README, PRD, Architecture, Design-System, AGENTS, `.env.example`.

### Exclu (v1)
- Plusieurs instances FS25 sur un même hôte (un CT = un serveur).
- Panneau web custom / reverse proxy / authentification externe.
- Cluster Proxmox, HA, PBS (hors sujet ; `vzdump` suffit).
- Build Linux natif (n'existe pas chez GIANTS) ; VM Windows (alternative documentée).
- Gestion des mods ModHub automatisée.

## 5. Exigences fonctionnelles

| ID | Exigence | Priorité |
|---|---|---|
| EF-01 | `scripts/fs25-lxc.sh` s'exécute en root sur l'hôte Proxmox et crée le LXC Ubuntu 26.04 avec hostname, mot de passe root, réseau configurables. Fonctionne aussi en one-liner (`curl | bash -c`), auquel cas les fichiers compagnons sont téléchargés depuis `raw.githubusercontent.com`. | Must |
| EF-02 | Les ressources du conteneur sont **remises aux presets** à la création (`pct set --cores/--memory/--swap`, `pct resize rootfs`) et surchargeables par `.env` ou CLI. | Must |
| EF-03 | Le template Ubuntu 26.04 est téléchargé via `pveam` s'il existe, sinon via l'image cloud officielle `cloud-images.ubuntu.com` (26.04.1 prioritaire, 26.04 sinon). | Must |
| EF-04 | L'installation dans le conteneur installe Wine64 + Xvfb + SteamCMD et télécharge FS25 (`app_update 2300320 validate`, `@sSteamCmdForcePlatformType windows`). | Must |
| EF-05 | `STEAM_LOGIN_MODE=account\|anonymous` est configurable ; en mode `account`, `STEAM_USER`/`STEAM_PASS`/`STEAM_GUARD` sont demandés (interactif) ou lus depuis `.env`. | Must |
| EF-06 | Les deux XML sont générés depuis `config/*.template` avec échappement XML des valeurs. | Must |
| EF-07 | Service systemd `fs25` (wine + xvfb-run, user `steam`, restart on-failure) + timer `fs25-update` hebdomadaire. | Must |
| EF-08 | Règles ufw appliquées et activées. | Must |
| EF-09 | Aucun secret n'est commité : `.env` gitignoré, `.env.example` avec placeholders uniquement, env du conteneur poussé en 0600 puis supprimé. | Must |
| EF-10 | README avec quickstart, table des variables, presets ressources, ports, exploitation, dépannage. | Must |
| EF-11 | Le script échoue proprement (messages `[ERR]`) si : pas root, pas Proxmox, CTID existant, identifiants manquants en mode account non interactif. | Should |
| EF-12 | Récapitulatif final : IP, URLs du panneau web, port jeu, commandes utiles. | Should |
| EF-13 | Mode one-liner : détection de l'absence des fichiers compagnons (`install-fs25.sh`, `update-fs25.sh`, templates XML) et téléchargement depuis `$FS25_RAW_BASE` (défaut : branche `main` du dépôt) dans un répertoire temporaire nettoyé en sortie. En one-liner, les secrets manquants sont demandés en interactif (stdin libre grâce à `bash -c "$(curl …)"`). | Must |

## 6. Exigences non-fonctionnelles

| ID | Exigence |
|---|---|
| ENF-01 | Scripts bash en `set -euo pipefail`, validés `bash -n` + shellcheck (0 erreur). |
| ENF-02 | Exécution non-root interdite côté hôte ; côté conteneur, le serveur tourne sous `steam`, jamais root. |
| ENF-03 | Conteneur **non privilégié** (`unprivileged=1`, `features keyctl=1`). |
| ENF-04 | Temps de déploiement : création CT < 2 min ; téléchargement du jeu dépendant du débit (~50 Go). |
| ENF-05 | Presets matériels conformes aux recommandations GIANTS (3–4 vCPU, 4–12 Go RAM, 50–65+ Go disque). |
| ENF-06 | Documentation en français, markdown GFM, tables pour variables/ports/presets. |
| ENF-07 | Les templates XML restent modifiables sans toucher au code (séparation config/code). |

## 7. Interface utilisateur (CLI)

- **Commande unique (recommandée)** : `sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Titouanlvt/FS25-LXC/main/scripts/fs25-lxc.sh)"` — aucune étape intermédiaire ; les fichiers compagnons sont téléchargés à la volée et les secrets demandés en interactif. Variante avec options : ajouter ` fs25-lxc --vmid N --cpu N --ram MB --disk GB --storage S` après la commande `bash -c`. Variante non interactive : `sudo env STEAM_USER=… STEAM_PASS=… CT_ROOT_PASSWORD=… bash -c "$(curl …)"`.
- Depuis un clone : `sudo ./scripts/fs25-lxc.sh [--vmid N] [--cpu N] [--ram MB] [--disk GB] [--storage S]` + `.env`.
- Logs colorés normalisés : `[INFO]` bleu, `[ OK ]` vert, `[WARN]` jaune, `[ERR ]` rouge (voir Design-System.md).
- Prompts interactifs pour le mot de passe root du CT et les identifiants Steam si non fournis ; en non interactif, mot de passe root généré et affiché une fois.

## 8. Données et configuration

- Fichier `.env` local (gitignoré) = source de vérité des secrets et réglages.
- Templates XML dans `config/` avec placeholders `@VAR@`, rendus par `sed` + échappement XML (`& < > " '`).
- Config persistante non secrète du conteneur : `/etc/fs25/fs25.env` (0600) pour le timer de mise à jour.
- Savegames : préfixe Wine `~steam/.fs25server/drive_c/users/steam/Documents/My Games/FarmingSimulator2025/savegame*`.

## 9. Sécurité et conformité

- **Licence** : GIANTS exige une licence dédiée pour le serveur (2 achats). Le projet ne contourne aucune protection ; mode `anonymous` documenté comme non fonctionnel pour FS25.
- Secrets : jamais dans le git ni dans les logs du script (le mot de passe Steam n'est passé qu'à SteamCMD en argument de process, usage standard).
- Panneau web (8080/8443) = contrôle total du serveur : documentation « LAN/VPN uniquement ».
- Certificat TLS auto-signé généré localement pour 8443.

## 10. Métriques de succès

- Déploiement complet sans intervention manuelle (hors saisie des identifiants) en < 30 min sur une connexion fibre.
- Le service `fs25` démarre, le panneau web répond sur 8080/8443, une savegame démarre et le port 10823 répond.
- 0 secret détecté dans `git log -p` / le repo.
- shellcheck : 0 erreur sur les 3 scripts.

## 11. Risques et mitigations

| Risque | Impact | Mitigation |
|---|---|---|
| Pas de build Linux natif FS25 | serveur « not activated » selon la source | mode `eshop` (clé GIANTS) documenté ; SteamCMD account + jeton en cache |
| Mises à jour Steam cassant Wine | serveur indisponible | timer hebdo + `validate`, rollback = backup `vzdump` |
| Secrets commités par erreur | fuite de compte Steam | `.env` gitignoré, revue `git diff` avant commit, AGENTS.md |
| Ports mal ouverts (routeur/hôte) | joueurs ne voient pas le serveur | table des ports + section dépannage README |
| Disque trop juste (DLC/mods) | échec sauvegarde | preset 64 Go + table de dimensionnement + `pct resize` documenté |

## 12. Évolutions futures (hors v1)

- Support multi-instance (plusieurs CTID).
- Mode Proton/GE-Proton avec client Steam headless pour la version Steam.
- Intégration PBS pour les sauvegardes incrémentales.
- Script de backup automatique des savegames (timer).
- CI : lint shellcheck + rendu des templates XML en test.

## 13. Références

- `ct/ubuntu.sh` — community-scripts/ProxmoxVE (presets `var_cpu/var_ram/var_disk`)
- wine-gameservers/arch-fs25server (Wine, schémas XML, presets matériels)
- Steam appid FS25 : `2300320` — ports 10823 TCP/UDP (+10824–10825/UDP), web 8080/8443
- Ubuntu cloud images : `cloud-images.ubuntu.com/releases/26.04/`
