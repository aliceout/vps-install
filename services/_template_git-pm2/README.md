# Template : app Node.js via git + pm2

Squelette pour une app Node que tu developpes toi-meme : clone du repo, `npm ci`, lancement avec pm2.

## Pour creer un vrai service

```bash
cp -r services/_template_git-pm2 services/mon-app
```

Puis :
1. Edite `service.conf` (REPO_URL, REPO_BRANCH, APP_DIR, PM2_NAME, PM2_SCRIPT, ...)
2. Edite `secrets.tmpl` (liste des secrets que ton app attend)
3. Garde ou supprime `nginx.conf` selon besoin reverse proxy
4. Lance `sudo bash scripts/service.sh install mon-app`

## Adaptation cas par cas

Comme tu l'as dit, tes apps ont des specificites. `install.sh` gere le flow standard (clone / install deps / link env / pm2 start). Pour du custom (build step, migrations DB, etc.), ajoute tes commandes dans la section `install|update` de `install.sh`.

Exemple avec build :
```bash
case "$ACTION" in
  install|update)
    clone_or_pull
    install_deps
    as_user "cd '$APP_DIR' && npm run build"
    as_user "cd '$APP_DIR' && npm run migrate"
    link_env
    pm2_start_or_reload
    ;;
```

## Le .env

L'agent Infisical ecrit `/etc/secrets/mon-app.env`. Ce fichier est 600 root:root. On fait un symlink `$APP_DIR/.env -> $SECRETS_FILE` proprietaire `$APP_USER`. L'utilisateur qui lance pm2 peut le lire via le symlink (le fichier source reste root).

Si ton framework veut un vrai fichier (pas un symlink), remplace la ligne `ln -sf` par une copie + chown dans `link_env()`.

## Secrets Infisical attendus

A declarer sous `/services/mon-app/` :
- `DATABASE_URL`
- `JWT_SECRET`
- `API_KEY`

## Debug

```bash
pm2 logs mon-app
pm2 describe mon-app
journalctl -u infisical-agent -n 50
cat /etc/secrets/mon-app.env
```
