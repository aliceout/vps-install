# Template : service docker-compose

Squelette pour un service Docker (ex: Syncthing, Stirling PDF, etc.).

## Pour creer un vrai service

```bash
cp -r services/_template_docker services/mon-service
```

Puis :
1. Edite `service.conf` (TYPE, DOMAIN, UPSTREAM, INFISICAL_PATH)
2. Edite `docker-compose.yml` (image, volumes, port)
3. Edite `secrets.tmpl` (secrets a injecter depuis Infisical)
4. Garde ou supprime `nginx.conf` selon besoin reverse proxy
5. Lance `sudo bash scripts/service.sh install mon-service`

## Secrets Infisical attendus

A declarer dans Infisical Cloud sous `/vps/mon-service/` :
- `EXEMPLE_SECRET`
- `AUTRE_SECRET`

## Debug

```bash
docker compose -f services/mon-service/docker-compose.yml -p mon-service logs -f
journalctl -u infisical-agent -n 50
cat /etc/secrets/mon-service.env
```
