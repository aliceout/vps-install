# work — Work-resume (CV perso)

Site Next.js [aliceout/Work-resume](https://github.com/aliceout/Work-resume), deploye via pm2 sur le port `4154`. Re-deploye automatiquement a chaque push sur `master` via le service `webhooks`.

## Pre-requis

- Service `webhooks` installe (`services install webhooks`)
- Cle SSH GitHub deployee (`/infra/vps/GITHUB_SSH_PRIVKEY`) pour pull le repo prive
- Subfolder Infisical `/services/webhooks/work/` cree avec :
  - `REPO`   = `aliceout/Work-resume`
  - `SECRET` = HMAC partage avec GitHub (`openssl rand -hex 32`)
  - `SCRIPT` = `work.sh`

## Install

```bash
services install work
```

Ce que ca fait :
1. Cree `/var/www/work/` (owned by `$VPS_USER`)
2. Lance `hook.sh` qui git clone (premier run) ou pull, build Next.js, lance pm2
3. Copie `hook.sh` -> `/var/lib/services/webhooks/hooks/work.sh`
4. Trigger `services update webhooks` -> l'agent Infisical sync les secrets du subfolder, le receiver decouvre le mapping

## Apres l'install

Sur GitHub, [aliceout/Work-resume](https://github.com/aliceout/Work-resume) > Settings > Webhooks > Add :
- **Payload URL** : `https://<ADRESS_webhooks>/webhooks`  (ex: `https://webhooks.backlice.dev/webhooks`)
- **Content type** : `application/json`
- **Secret** : la valeur `SECRET` mise dans Infisical
- **Events** : Just the push event

Apres ca, chaque push sur `master` re-deploie automatiquement.

## Update / Remove

```bash
services update work       # re-deploy manuel (utile pour debug)
services remove work       # arrete pm2 + retire le hook (laisse /var/www/work intact)
```

## Debug

```bash
# Logs du deploy
tail -f /var/lib/services/webhooks/log/aliceout_Work-resume.log

# Status pm2
sudo -u $VPS_USER pm2 list
sudo -u $VPS_USER pm2 logs work
```
