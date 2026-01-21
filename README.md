# vps-bootstrap (Debian 13)

Bootstrap d'un VPS pour services web exposes avec des modules activables.

## Ce que ca installe
- User + sudo (demande a l'execution)
- SSH durci (port et cle demandes a l'execution)
- UFW + Fail2ban (SSH + blocklists publiques)
- ZRAM swap (zram-tools)
- Docker Engine + compose plugin (optionnel)
- Node.js + pm2 (optionnel)
- Netdata via reverse proxy (optionnel)
- Nginx reverse proxy + includes + TLS (template)
- Zsh + oh-my-zsh + config perso
- Cron: apt update/upgrade + certbot dns + fail2ban list

## One-liner
```bash
curl -fsSL https://raw.githubusercontent.com/aliceout/vps-install/main/install.sh | bash
```

## Logique du bootstrap
Le script principal pose des questions (user, port SSH, web, docker, node, netdata)
et n'execute que les modules necessaires.

- Web = installe Nginx, ouvre 80/443, prepare les templates.
- Docker = installe Docker et active la protection UFW (pas de bypass).
- Node = installe Node.js + pm2 et active le service.
- Netdata = installe Netdata (local) et passe par le reverse proxy.

## Nginx
- Includes globaux: `nginx/conf/common.conf` => copie vers `/etc/nginx/conf.d/common.conf`.
- Template vhost: `nginx/conf/template.conf` => copie vers `/etc/nginx/conf/<domaine>.conf` (manuel).
- Certificats: `nginx/certificat/certbot-template.conf` => copie vers `/etc/nginx/certificat/<domaine>.conf` (manuel).

Chaque vhost inclut son fichier certificat:
`/etc/nginx/certificat/<domaine>.conf`

## Certbot DNS Infomaniak
- Script: `scripts/certbot-dns.sh`
- Domaines: `/etc/letsencrypt/domains.ini` (un domaine par ligne)
- Token: `/etc/letsencrypt/infomaniak.ini`
  (cle: `dns_infomaniak_token = ...`)

## Fail2ban blocklists
- Script: `/usr/local/sbin/fail2ban-list.sh`
- Sources publiques (FireHOL, Emerging Threats, BinaryDefense)
- Jail: `badips` avec ban permanent (nftables)

## Cron (unique)
Toutes les taches sont dans `/etc/cron.d/vps-bootstrap`:
- apt update / upgrade
- certbot dns (si installe)
- fail2ban list

## Notes importantes
- Les vhosts nginx ne sont pas crees automatiquement. Utilise `nginx/conf/template.conf`
  pour creer tes fichiers dans `/etc/nginx/conf/` et `/etc/nginx/certificat/`.
- Netdata ecoute en local et passe par le reverse proxy (vhost a creer si besoin).
- Pour certbot DNS, edite `domains.ini` et `infomaniak.ini` apres bootstrap.
