# Stirling PDF

Suite locale de manipulation PDF : merge, split, OCR, compression, conversion, signature, watermark, etc. Image officielle `frooodle/s-pdf:latest`.

## Install

```bash
services install pdf
```

Ca cree `/var/lib/services/pdf/` (configs + logs + tessdata), sync les secrets depuis Infisical dans `/etc/secrets/pdf.env`, deploie le vhost nginx, utilise le cert wildcard du domaine.

## Secrets Infisical (`/services/pdf/`)

Tous ces secrets atterrissent tels quels dans `/etc/secrets/pdf.env` (nom de cle = nom de variable d'env Stirling).

| Cle | Exemple | Role |
|-----|---------|------|
| `LANGS` | `en_GB` | langues OCR, comma-sep (ex: `fr_FR,en_GB`) |
| `DOCKER_ENABLE_SECURITY` | `true` | active le login integre Stirling (**recommande** si expose) |
| `INSTALL_BOOK_AND_ADVANCED_HTML_OPS` | `false` | installe calibre + outils eBook (lourd, pas utile en general) |
| `SECURITY_INITIALLOGIN_USERNAME` | `alice` | username admin cree au premier boot |
| `SECURITY_INITIALLOGIN_PASSWORD` | `<mdp fort>` | mdp admin cree au premier boot |

Les `SECURITY_INITIALLOGIN_*` ne servent qu'au premier lancement pour creer l'utilisateur admin. Apres ca, la gestion des users se fait depuis l'UI Stirling ; changer ces vars n'a plus d'effet.

## Reverse proxy

- Expose : `https://pdf.backlice.dev`
- Cert : wildcard `backlice.dev` (cree par `75_certbot.sh` au bootstrap, ou a la demande via `certbot-wildcard`)
- Upload limit : 200 Mo (`client_max_body_size`)

## Donnees persistentes

`/var/lib/services/pdf/` (hors repo, survit aux re-installs) :
- `configs/` - config additionnelle
- `logs/` - logs conteneur
- `tessdata/` - langues OCR teleschargees au fur et a mesure

## Debug

```bash
docker compose -f /opt/vps-install/services/pdf/docker-compose.yml -p pdf logs -f
cat /etc/secrets/pdf.env
```
