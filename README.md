# vps-bootstrap (Debian 13)

Bootstrap d'un VPS pour services web exposes, avec secrets centralises dans Infisical.

## Principe

Le bootstrap ne te demande **qu'un seul credential** : les identifiants Machine Identity d'Infisical. Tout le reste (utilisateur, port SSH, cle publique, email Let's Encrypt, token Infomaniak, ...) est tire depuis Infisical sous le chemin `/vps/_infra/`.

Cela permet de :
- Reinstaller le VPS en 15 minutes sans notes perdues
- Changer un secret (ex: rotate SSH key) d'un seul endroit
- Garder le repo 100% publiable (aucun secret)

## Pre-requis dans Infisical

Cree un projet Infisical Cloud avec un environnement (ex: `prod`). Sous le path `/vps/_infra/`, declare ces secrets :

| Cle | Exemple | Description |
|-----|---------|-------------|
| `VPS_USER` | `choupi` | utilisateur a creer |
| `VPS_USER_PASSWORD` | `...` | mdp sudo de ce user |
| `SSH_PORT` | `45675` | port SSH custom |
| `SSH_PUBKEY` | `ssh-ed25519 AAAA...` | cle(s) publique(s), multiples separees par `\n` |
| `LE_EMAIL` | `toi@exemple.fr` | email Let's Encrypt |
| `INFOMANIAK_TOKEN` | `...` | token API Infomaniak pour Certbot DNS |

Si tu actives Netdata, ajoute aussi sous `/services/netdata/` :

| Cle | Exemple | Description |
|-----|---------|-------------|
| `NETDATA_DOMAIN` | `netdata.mondomaine.fr` | domaine d'expo HTTPS |
| `NETDATA_AUTH_USER` | `alice` | basic auth nginx |
| `NETDATA_AUTH_PASSWORD` | `...` | basic auth nginx (clair, hashe bcrypt a l'install) |

Cree ensuite une **Machine Identity** (Universal Auth) ayant la permission **Read** sur ce projet et note le **Client ID** + **Client Secret**.

## One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/aliceout/vps-install/main/install.sh | sudo bash
```

Le script te demandera :
- Adresse Infisical (default `https://app.infisical.com`)
- Environnement Infisical (default `prod`)
- Project ID
- Client ID
- Client Secret
- Questions yes/no pour activer features (web / docker / node / netdata)

Les credentials sont ensuite persistes dans `/etc/infisical/` et reutilises automatiquement si tu relances le bootstrap.

## Ce que ca installe

- **User + sudo** (config tiree d'Infisical)
- **SSH durci** : port custom, no-password, no-root, MaxAuthTries=3, cles auto-deployees
- **UFW + Fail2ban** : SSH + blocklists publiques (FireHOL, Emerging Threats...)
- **ZRAM** : swap compresse en RAM
- **Infisical** : CLI + agent systemd pour syncer les secrets vers `/etc/secrets/`
- **Docker Engine + compose** (optionnel)
- **Node.js + pm2** (optionnel)
- **Nginx** reverse proxy + includes TLS (optionnel)
- **Netdata** monitoring (optionnel, expose en HTTPS avec basic auth depuis `/services/netdata/`)
- **Zsh + oh-my-zsh + powerlevel10k** (config p10k + zshrc avec alias, pfetch banner, `histo`, `tools`, alias `services`)
- **Outils CLI** : lsd, bat, zoxide, fzf, btop, htop, ncdu, glances, lnav, ctop, lazydocker, pfetch, lolcat
- **Cron** : apt update/upgrade, fail2ban blocklists, sync DNS Infomaniak (auto-heal records A sur IP publique)
- **Certbot** : DNS Infomaniak via token synce depuis Infisical, renouvellement automatique

## Apres le bootstrap : installer des services

Le repo est persiste en `/opt/vps-install/`. Le zshrc installe un alias `services` qui lance le helper :

```bash
services               # menu interactif
services install syncthing
services list
```

Equivalent direct : `sudo bash /opt/vps-install/scripts/service.sh [...]`.

Chaque service vit dans `services/<nom>/` (voir `services/README.md` pour la structure). Trois templates fournis :
- `_template_docker` - service Docker (Syncthing, Stirling PDF, ...)
- `_template_git-pm2` - app Node.js clone+pm2
- `_template_native` - systemd unit (scripts, daemons)

A l'install, `service.sh` :
1. Sync les secrets du service depuis Infisical (template agent)
2. Demande un cert Let's Encrypt pour le domaine (DNS Infomaniak)
3. Deploie le vhost nginx
4. Delegue au `install.sh` du service pour le lancement

## Structure du repo

```
bootstrap.sh             entree principale (prompts Infisical + orchestration)
install.sh               one-liner (clone + lance bootstrap.sh)
modules/                 etapes numerotees (00 -> 99)
  00_preflight.sh        apt base + ca-certificates
  10_user_ssh.sh         user, sudo, SSH durci
  20_packages.sh         outils CLI (lsd, bat, btop, pfetch, ...)
  25_zram.sh             swap compresse
  30_ufw_fail2ban.sh     firewall + blocklists
  35_infisical.sh        persist creds + agent systemd
  40_docker.sh           Docker Engine + compose (optionnel)
  45_node_pm2.sh         Node.js + pm2 (optionnel)
  50_nginx.sh            reverse proxy (optionnel)
  55_netdata.sh          monitoring (optionnel)
  60_zsh.sh              zsh + oh-my-zsh + p10k + deploiement .zshrc/.p10k.zsh
  70_cron_updates.sh     cron apt + blocklists
  75_certbot.sh          certbot + token Infomaniak via agent (optionnel)
  99_summary.sh          recap post-install
nginx/                   templates vhost + includes globaux
config/
  certbot/domains.ini    base domains.ini pour renouvellements
  zsh/zshrc              .zshrc deploye chez VPS_USER
  zsh/p10k.zsh           config Powerlevel10k deployee chez VPS_USER
scripts/
  service.sh             helper install/update/remove services
  certbot-request.sh     requete cert single-domain (Let's Encrypt DNS Infomaniak)
  certbot-dns.sh         renouvellement cron (wildcards)
  fail2ban-list.sh       refresh blocklists
services/                services heberges sur le VPS (un dossier par service)
  README.md              structure d'un service
  _template_docker/      squelette docker-compose
  _template_git-pm2/     squelette Node.js + pm2
  _template_native/      squelette systemd unit
```

## Logs

- Bootstrap : `/var/log/vps-bootstrap.log`
- Cron : `/var/log/cron/`
- Fail2ban blocklists : `/var/log/fail2ban-list.log`
- Agent Infisical : `journalctl -u infisical-agent`

## Debug

```bash
# Verifier les secrets syncs
ls -la /etc/secrets/
cat /etc/secrets/<service>.env

# Agent Infisical
systemctl status infisical-agent
journalctl -u infisical-agent -n 100

# Fetch manuel
infisical secrets --env=prod --path=/vps/_infra
```
