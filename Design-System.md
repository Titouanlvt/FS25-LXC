# Design System — FS25-LXC

Conventions de code, de logs, de documentation et de gestion de projet pour FS25-LXC.
Tout contributeur (humain ou agent IA — voir [AGENTS.md](AGENTS.md)) doit les suivre.

---

## 1. Identité

Projet d'automation d'infrastructure (shell + docs) : sobre, terminal-first, orienté fiabilité.
Langue des docs et des messages utilisateur : **français**. Langue des noms de fichiers/variables : anglais.

## 2. Conventions de nommage

| Élément | Convention | Exemple |
|---|---|---|
| Scripts | `kebab-case` + `.sh` | `scripts/fs25-lxc.sh` |
| Variables d'environnement utilisateur | `UPPER_SNAKE_CASE` | `FS_GAME_NAME`, `STEAM_PASS` |
| Presets « style ct/ubuntu.sh » | `var_*` / `CT_*` en tête de script | `var_cpu="${var_cpu:-4}"` → ici `CT_CPU="${CT_CPU:-4}"` |
| Placeholders dans les templates | `@UPPER_SNAKE@` | `@FS_WEB_PORT@` |
| Services systemd | `fs25`, `fs25-update` | `fs25.service`, `fs25-update.timer` |
| Dossiers | `kebab-case` | `scripts/`, `config/` |
| Commits | [Conventional Commits](https://www.conventionalcommits.org/fr/) en français ou anglais | `feat(scripts): ajout du reset des ressources LXC` |

## 3. Structure des scripts bash

Tout script commence par :

```bash
#!/usr/bin/env bash
set -euo pipefail
```

Puis, dans l'ordre : en-tête de commentaires (rôle, prérequis, exemple d'appel) → helpers de log → chargement `.env` (gitignoré) → presets avec valeurs par défaut → parsing des arguments → préflight (dépendances, droits) → étapes numérotées en commentaires `# --- 1. … ---` → récapitulatif final.

Règles :
- Jamais de `eval` ; citer toutes les variables (`"$VAR"`).
- Chemins d'exécutables importants en absolu (`/usr/bin/wine`, `/usr/bin/xvfb-run`) quand on passe par `runuser`.
- `|| true` uniquement quand l'échec est réellement tolérable (et commenté implicitement par le contexte).
- Pas de secrets dans les logs : ne jamais `echo` un mot de passe ; le mot de passe root généré est affiché **une seule fois** avec un avertissement.

## 4. Palette et logs (CLI)

Codes ANSI centralisés en tête de script :

| Rôle | Code | Rendu |
|---|---|---|
| Info | `BL='\033[1;34m'` | `[INFO]` bleu |
| Succès | `GN='\033[1;32m'` | `[ OK ]` vert |
| Avertissement | `YW='\033[1;33m'` | `[WARN]` jaune |
| Erreur | `RD='\033[1;31m'` | `[ERR ]` rouge (stderr + `exit 1`) |
| Succès (check) | `GN='\033[1;32m'` | `[PASS]` vert |
| Échec (check) | `RD='\033[1;31m'` | `[FAIL]` rouge |
| Reset | `CL='\033[0m'` | — |

Les modes revue (`--check`, `fs25-check.sh`) agrègent les contrôles en `[PASS]`/`[FAIL]` et rendent **exit 0 si tout passe, 1 sinon**.

Helpers obligatoires : `info`, `ok`, `warn`, `die`.
Format : `[ROLE] message` — alignés, courts, sans emoji dans les logs (les emojis sont réservés au README).

## 5. Gestion des secrets

- `.env` est **gitignoré** (voir [.gitignore](.gitignore)) ; seul `.env.example` (placeholders vides) est versionné.
- Avant chaque commit : vérifier qu'aucun secret n'apparaît (`git diff`, `git log -p`).
- Côté conteneur : l'env poussé par l'hôte est en mode `0600` et **supprimé** après l'installation ; `/etc/fs25/fs25.env` ne contient jamais de mot de passe.

## 6. Documentation (Markdown)

- Markdown GFM, **français**, titres ATX (`#`, `##`, `###`), blocs de code avec langage précisé (```bash, ```xml, ```text).
- Tableaux pour toutes les listes structurées (variables, ports, presets, risques…).
- README en vitrine : badges, emojis de section, quickstart en 3 commandes, puis détails.
- Les 4 documents de gouvernance : [PRD.md](PRD.md) (quoi/pourquoi), [Architecture.md](Architecture.md) (comment, schémas), [Design-System.md](Design-System.md) (ce fichier, conventions), [AGENTS.md](AGENTS.md) (règles pour agents IA).
- Chaque nouvelle variable `FS_*`/`CT_*`/`STEAM_*` doit être ajoutée **simultanément** à `.env.example` et au tableau du README.

## 7. Templates de configuration

- `config/*.template` = source de vérité des XML ; placeholders `@VAR@`.
- Rendu par `sed` avec double échappement : XML (`& < > " '`) puis métacaractères `sed` (`\ & |`) — fonctions `xml_escape` / `sed_escape` dans `install-fs25.sh`.
- Ne jamais modifier la structure XML à la légère : elle reflète le schéma de GIANTS (voir `wine-gameservers/arch-fs25server`).

## 8. Qualité et tests

- `bash -n` sur chaque script (syntaxe) — obligatoire avant commit.
- `shellcheck` (0 erreur visé) quand disponible.
- Les templates rendus doivent rester du **XML valide** (vérifiable avec `python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])"`).
- Test réel sur un nœud Proxmox avant toute release : déploiement complet, démarrage d'une savegame depuis le panneau web, connexion d'un joueur sur le port 10823.

## 9. Git

- Branche de travail : `vibe/<sujet>-<id>` ; PR vers `main` (jamais de push direct sur `main`).
- Un commit = un changement logique ; message conventionnel.
- La PR décrit : objectif, variables ajoutées, tests effectués, et lien éventuel vers une issue (`Closes #N`).
