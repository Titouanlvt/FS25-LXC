# AGENTS.md — Règles pour les agents IA sur FS25-LXC

Ce fichier s'adresse à tout agent (Mistral Vibe, etc.) travaillant sur ce dépôt.
**Lecture obligatoire avant toute modification** : [README.md](README.md), [PRD.md](PRD.md), [Architecture.md](Architecture.md), [Design-System.md](Design-System.md).

## 1. Mission du projet

Déployer en une commande un **serveur dédié Farming Simulator 25 dans un LXC Proxmox** (Ubuntu 26.04 LTS), inspiré de `ct/ubuntu.sh` (community-scripts), avec presets de ressources CPU/RAM/disque appliqués au conteneur et modifiables, installation SteamCMD/Wine, génération des XML de config, service systemd, mises à jour auto — **sans aucun secret dans le git**.

## 2. Règles de code (obligatoires)

1. Bash strict : `#!/usr/bin/env bash` + `set -euo pipefail` dans tous les scripts.
2. Avant chaque commit : `bash -n scripts/*.sh` doit passer ; lancer `shellcheck scripts/*.sh` si disponible (0 erreur visé).
3. Suivre le Design-System : nommage (`kebab-case`, `UPPER_SNAKE_CASE`, presets `CT_*`/`var_*`), helpers de log `info/ok/warn/die` avec les codes ANSI définis, sections numérotées, pas d'echo de secrets.
4. **Sécurité des secrets** : `.env` reste gitignoré ; ne jamais commiter de mot de passe/clé. Avant chaque commit, vérifier le diff : `git diff` et `git log -p | grep -iE 'pass|token|secret'` ne doivent rien trouver. Toute nouvelle variable sensible va dans `.env.example` avec une valeur vide + commentaire « JAMAIS commité ».
5. Les templates XML (`config/*.template`) utilisent des placeholders `@VAR@` ; le rendu passe par `xml_escape` + `sed_escape` (déjà en place dans `install-fs25.sh`). Ne pas casser la validité XML : valider avec `python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" <fichier rendu>`.
6. Toute nouvelle variable d'environnement doit être ajoutée **en même temps** dans `.env.example` et dans le tableau des variables du README.
7. Ne pas modifier les ports par défaut (10823 TCP/UDP, 10824–10825/UDP, 8080, 8443) ni l'appid Steam (2300320) sans mettre à jour PRD + Architecture + README.
8. Pas de nouvelles dépendances logicielles côté hôte hors l'API Proxmox (`pct`, `pveam`, `pvesh`, `curl`). Côté conteneur, se limiter aux paquets Ubuntu archive (`wine64`, `xvfb`, `ufw`, `openssl`…), pas de dépôts tiers.

## 3. Workflow git

1. Ne jamais pousser directement sur `main`. Créer une branche `vibe/<sujet>-<id>` (ex. `vibe/fs25-lxc-c6a56d`), y commiter, pousser, ouvrir une **PR draft** vers `main`.
2. Commits en [Conventional Commits](https://www.conventionalcommits.org/fr/) (`feat:`, `fix:`, `docs:`, `refactor:`…).
3. La description de PR doit indiquer : objectif, variables ajoutées/modifiées, tests effectués (`bash -n`, shellcheck, rendu XML), et `Closes #N` si une issue est résolue.

## 4. Tests / vérification

- Minimum avant PR : `bash -n` sur chaque script, rendu d'un exemple de chaque template XML puis validation XML avec python3, revue du diff à la recherche de secrets.
- Test d'intégration réel (sur un vrai nœud Proxmox, hors CI) : `sudo ./scripts/fs25-lxc.sh` avec un `.env` de test, puis `pct exec <CTID> -- systemctl status fs25` et ouverture du panneau web `http://<ip>:8080`. Documenter le résultat dans la PR.

## 5. Interdictions

- Ne pas exposer de ressource du sandbox/de l'hôte publiquement (pas de tunnel, proxy, ingress).
- Ne pas ajouter de credentials, tokens ou URLs signées dans le code, les docs ou les logs.
- Ne pas supprimer ni réécrire l'historique git ; pas de force-push sans accord explicite.
- Ne pas « nettoyer » ou modifier des fichiers hors du périmètre de la tâche demandée.

## 6. Où poser les questions

En cas d'ambiguïté sur le périmètre (ex. : ajouter un mode Proton, changer les ports, supporter plusieurs instances), documenter l'hypothèse dans la PR plutôt que de demander, sauf si cela change les secrets, la sécurité ou la licence du projet.
