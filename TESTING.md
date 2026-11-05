# TESTING.md — Plan de test sur un nœud Proxmox VE de test

Objectif : valider le déploiement FS25-LXC de bout en bout sur un PVE de test, avec les revues `--check` (exit 0 = OK / 1 = KO).

---

## 1. Prérequis (nœud PVE de test)

| Élément | Détail |
|---|---|
| Proxmox VE | **8.x/9.x recommandé** (version testée), accès **root en SSH**. Sur PVE 7 (LXC 4.0) : possible mais non garanti — le `--check` affiche un avertissement |
| Stockage | un stockage avec contenus `vztmpl` + `rootfs` (ex. `local-lvm`), **≥ 80 Go libres** (image ~1 Go + jeu ~50 Go) |
| Réseau | bridge `vmbr0` (sinon adaptez `CT_NET`) |
| Internet | le nœud doit joindre `download.proxmox.com` / `cloud-images.ubuntu.com` / `steamcdn-a.akamaihd.net` |
| Licence | **compte Steam dédié possédant Farming Simulator 25** (licence serveur séparée, exigée par GIANTS), Steam Guard à portée (app mobile) |
| Ports côté LAN | rien à ouvrir pour un test LAN ; pour Internet : 10823 TCP/UDP (+10824–10825/UDP) en NAT vers l'IP du CT |

## 2. Test rapide (one-liner)

> **Sur le shell root de Proxmox (`root@pve:~#`), `sudo` n'est pas installé : lancez les commandes SANS `sudo`.** Les `sudo` ci-dessous servent uniquement si vous partez d'un utilisateur non-root.

```bash
# 0) Revue AVANT déploiement — attendre : exit 0
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Titouanlvt/FS25-LXC/main/scripts/fs25-lxc.sh)" fs25-lxc --check
echo "exit=$?"   # 0 attendu

# 1) Déploiement (CTID de test 900, presets : 4 vCPU / 8 Go / 64 Go)
#    a) non interactif :
sudo env STEAM_USER=compte-test STEAM_PASS=******** CT_ROOT_PASSWORD=******** FS_GAME_NAME="Test PVE" \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/Titouanlvt/FS25-LXC/main/scripts/fs25-lxc.sh)" \
  fs25-lxc --vmid 900 --cpu 4 --ram 8192 --disk 64
#    b) ou interactif (questions posées) :
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Titouanlvt/FS25-LXC/main/scripts/fs25-lxc.sh)" fs25-lxc --vmid 900

# 2) Revue APRÈS déploiement — attendre : exit 0
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Titouanlvt/FS25-LXC/main/scripts/fs25-lxc.sh)" fs25-lxc --check --vmid 900
echo "exit=$?"
pct exec 900 -- /usr/local/bin/fs25-check.sh; echo "exit=$?"

# 3) Vérifications manuelles
IP=$(pct exec 900 -- hostname -I | awk '{print $1}')
pct exec 900 -- systemctl status fs25 --no-pager
pct exec 900 -- ss -ltn          # attendre : 8080 et 8443
pct exec 900 -- ss -lnu          # attendre : 10823 (et 10824/10825)
echo "Panneau web : http://$IP:8080  (https://$IP:8443)"
```

Puis, depuis un navigateur : `http://<IP_CT>:8080`, login `FS_WEB_ADMIN_USER` / `FS_WEB_ADMIN_PASS`, **démarrer une savegame** → le serveur de jeu démarre. Depuis un client FS25 en LAN : rejoindre `<IP_CT>` (port 10823).

## 3. Scénarios de test

| # | Scénario | Résultat attendu |
|---|---|---|
| T1 | `--check` avant déploiement sur PVE sain | exit 0, tous `[PASS]` |
| T2 | Déploiement complet one-liner | exit 0, CT 900 créé, ressources = presets, install FS25 terminée |
| T3 | `--check --vmid 900` après déploiement | exit 0 (hôte + `fs25-check` interne) |
| T4 | Panneau web 8080/8443 | login OK, savegame démarrable |
| T5 | Port jeu 10823 TCP/UDP | à l'écoute (`ss`), rejoignable depuis un client LAN |
| T6 | Mise à jour manuelle | `pct exec 900 -- systemctl start fs25-update.service` → OK |
| T7 | Redémarrage CT | `pct reboot 900` → service `fs25` repart (enabled) |
| T8 | Rollback propre | `pct stop 900 && pct destroy 900` → plus de CT 900 |

## 4. En cas d'échec : collecte d'infos

```bash
pct exec 900 -- journalctl -u fs25 -n 200 --no-pager
pct exec 900 -- /usr/local/bin/fs25-check.sh; echo "exit=$?"
pct config 900
pvesh get /storage/local-lvm --content rootfs   # espace dispo
sudo ./scripts/fs25-lxc.sh --check --vmid 900   # ou one-liner --check
```

Cas connus :
- `app_update` échoue en `anonymous` → normal, FS25 n'a pas de serveur gratuit : repassez en `STEAM_LOGIN_MODE=account`.
- « Game is not activated » au lancement → la version Steam vérifie la licence ; testez d'abord avec un compte Steam valide + Steam Guard accepté, ou le mode `FS_SOURCE=eshop` (installeur GIANTS eShop).
- Steam Guard : renseignez `STEAM_GUARD` (code app mobile) au déploiement.

## 5. Rollback / nettoyage

```bash
pct stop 900 && pct destroy 900
# optionnel : libérer le template téléchargé
pveam remove local:vztmpl/ubuntu-26.04-*.tar.* 2>/dev/null || true
```
