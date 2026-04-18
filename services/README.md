# services/

Chaque sous-dossier = un service. Les dossiers prefixes par `_` (ex: `_template_docker`) sont des squelettes ignores par `scripts/service.sh`.

## Structure d'un service

```
services/<nom>/
  service.conf        # metadata (TYPE, INFISICAL_PATH, ...)        [obligatoire]
  install.sh          # logique install/update/remove/status         [obligatoire]
  secrets.tmpl        # template Infisical -> /etc/secrets/<nom>.env [optionnel]
  nginx.conf          # vhost (domaine + upstream en dur dedans)     [optionnel]
  docker-compose.yml  # si TYPE=docker-compose                       [optionnel]
  README.md           # doc du service
```

## `service.conf`

Shell source-able. Variables reconnues par `service.sh` :

| Variable | Requis | Description |
|----------|--------|-------------|
| `TYPE` | oui | `docker-compose` \| `git-pm2` \| `native` |
| `INFISICAL_PATH` | si `secrets.tmpl` | chemin Infisical des secrets (ex: `/vps/syncthing`) |
| `DESCRIPTION` | non | texte libre |

Toute autre variable est disponible dans `install.sh` via `source service.conf`.

Le **domaine** du service est lu directement depuis `server_name` dans `nginx.conf`. Pas de duplication dans `service.conf`.

## `install.sh`

Recoit en env :
- `ACTION` : `install` \| `update` \| `remove` \| `status`
- `SERVICE_NAME` : nom du dossier
- `SERVICE_DIR` : chemin absolu du dossier
- `SECRETS_FILE` : `/etc/secrets/<nom>.env` (peut ne pas exister si pas de `secrets.tmpl`)

Le script fait `case "$ACTION"` et agit en consequence. Doit etre idempotent.

## `secrets.tmpl`

Template de l'agent Infisical (syntaxe Go template, fonctions `listSecrets` / `getSecretByName`).

Le helper `service.sh` injecte trois placeholders avant de copier le template chez l'agent :
- `${PROJECT_ID}` (depuis `/etc/infisical/project-id`)
- `${INFISICAL_ENV}` (depuis `/etc/infisical/environment`)
- `${INFISICAL_PATH}` (depuis `service.conf`)

**Pattern recommande** (recupere TOUS les secrets sous le path) :
```
{{- with listSecrets "${PROJECT_ID}" "${INFISICAL_ENV}" "${INFISICAL_PATH}" }}
{{- range . }}
{{ .Key }}={{ .Value }}
{{- end }}
{{- end }}
```

**Pattern selectif** (un secret precis) :
```
SECRET={{- with getSecretByName "${PROJECT_ID}" "${INFISICAL_ENV}" "${INFISICAL_PATH}" "MY_SECRET" }} {{ .Value }}{{- end }}
```

Voir la doc Infisical : https://infisical.com/docs/integrations/platforms/infisical-agent

## `nginx.conf`

Vhost du service, **copie tel quel** dans `/etc/nginx/conf/<nom>.conf` (inclus directement par nginx, pas de jeu sites-available/sites-enabled). Valeurs en dur (domaine, upstream, chemin du cert), pas de placeholders.

`service.sh` extrait les `server_name` du fichier et demande automatiquement un cert Let's Encrypt pour chaque domaine (via Certbot DNS Infomaniak).

Inclut les bricks communes via `include /etc/nginx/include/*.conf`.

## Creer un nouveau service

```bash
cp -r services/_template_docker services/mon-nouveau-service
# edite service.conf, install.sh, etc.
sudo bash scripts/service.sh install mon-nouveau-service
```
