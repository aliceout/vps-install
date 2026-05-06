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
| `INFISICAL_PATH` | si `secrets.tmpl` | chemin Infisical des secrets (ex: `/services/syncthing`) |
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

Vhost du service, **rendu** dans `/etc/nginx/conf/<nom>.conf` (inclus directement par nginx, pas de jeu sites-available/sites-enabled).

### Placeholders `__KEY__`

Pour ne rien hardcoder (adresse, domaine, ...), le vhost peut contenir des placeholders de la forme `__KEY__`. Juste avant le deploiement, `service.sh` lit `/etc/secrets/<nom>.env` (synce depuis Infisical par l'agent) et substitue chaque `__KEY__` par la valeur correspondante.

Convention minimale pour les services expose via nginx :
- `__ADRESS__` = FQDN (`server_name`, cible du record DNS A)
- `__DOMAIN__` = apex (chemin du cert wildcard `/etc/letsencrypt/live/<apex>/`)

Tu peux ajouter d'autres placeholders : toute cle presente dans Infisical sous `/services/<nom>/` est substituable via `__KEY__`.

### Ce que fait `service.sh apply_nginx`

1. Rend le vhost (substitution des placeholders depuis `/etc/secrets/<nom>.env`)
2. Extrait les `server_name` du vhost rendu
3. Pour chaque FQDN : sync DNS A via `infomaniak-dns-sync`, puis cert wildcard via `certbot-wildcard` sur l'apex
4. Copie le vhost rendu dans `/etc/nginx/conf/<nom>.conf`
5. `nginx -t` + `systemctl reload nginx`

### Bricks nginx communes (factorisees)

Pour eviter de dupliquer 20 lignes par vhost, les includes suivants couvrent 90% du boilerplate :

| Include | Contenu | A mettre dans |
|---------|---------|---------------|
| `/etc/nginx/include/vhost-head.conf` | `listen 443 ssl + http2`, SSL protocols, security headers | server block 443 |
| `/etc/nginx/include/vhost-http-redirect.conf` | `listen 80` + `return 301 https://...` | server block 80 |
| `/etc/nginx/certificat/<apex>.conf` | `ssl_certificate*` pour l'apex (auto-genere par `certbot-wildcard`) | server block 443 |
| `/etc/nginx/include/proxy.conf` | `proxy_set_header *`, timeouts, websocket | block `location` |

Un vhost de service type ressemble donc a :

```nginx
server {
    server_name __ADRESS__;
    include /etc/nginx/include/vhost-head.conf;
    include /etc/nginx/certificat/__DOMAIN__.conf;

    # overrides specifiques au service (client_max_body_size, CSP, ...)

    location / {
        proxy_pass http://127.0.0.1:8080;
        include /etc/nginx/include/proxy.conf;
    }
}

server {
    server_name __ADRESS__;
    include /etc/nginx/include/vhost-http-redirect.conf;
}
```

Tout ce qui est commun est centralise dans les includes. Le vhost ne porte que ce qui est specifique au service.

## Creer un nouveau service

```bash
cp -r services/_template_docker services/mon-nouveau-service
# edite service.conf, install.sh, etc.
sudo bash scripts/service.sh install mon-nouveau-service
```
