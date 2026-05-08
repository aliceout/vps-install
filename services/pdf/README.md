# Stirling PDF

Suite locale de manipulation PDF : merge, split, OCR, compression, conversion, signature, watermark, etc. Image officielle `frooodle/s-pdf:latest`.

Ce service est volontairement **ouvert** (pas d'auth).

## Install

```bash
services install pdf
```

## Secrets Infisical - `/services/pdf/`

| Cle | Exemple | Role |
|-----|---------|------|
| `ADDRESS` | `pdf.backlice.dev` | FQDN expose (server_name nginx + record DNS A) |
| `DOMAIN` | `backlice.dev` | apex pour le cert wildcard |

`service.sh` lit ces cles depuis `/etc/secrets/pdf.env` (synce par l'agent Infisical) et substitue `__ADDRESS__` / `__DOMAIN__` dans `nginx.conf` au moment du deploiement.

## Reverse proxy

- Expose : `https://<ADDRESS>`
- Cert : wildcard sur `<DOMAIN>`
- Upload max : 200 Mo

## Config de l'image (dans `docker-compose.yml`)

Ces vars sont en dur car non sensibles et pas susceptibles de changer :
- `DOCKER_ENABLE_SECURITY=false` (pas d'auth)
- `INSTALL_BOOK_AND_ADVANCED_HTML_OPS=false` (pas besoin de Calibre)
- `LANGS=en_GB` (langue OCR)

Pour ajouter des langues OCR ou activer l'auth : edite directement `docker-compose.yml`.

## Donnees persistentes

`/var/lib/services/pdf/` (hors repo, survit aux re-installs) :
- `configs/` - config additionnelle
- `logs/` - logs conteneur
- `tessdata/` - langues OCR telechargees au fur et a mesure

## Debug

```bash
docker compose -f /opt/vps-install/services/pdf/docker-compose.yml -p pdf logs -f
cat /etc/secrets/pdf.env
```
