# Template : service natif (systemd)

Squelette pour un service qui n'est ni Docker ni Node+pm2 : binaire, script shell, daemon compile, cron...

## Pour creer un vrai service

```bash
cp -r services/_template_native services/mon-daemon
```

Puis :
1. Edite `service.conf` (UNIT_NAME, INFISICAL_PATH)
2. Edite `unit.service` (ExecStart, User, EnvironmentFile, ...)
3. Edite `secrets.tmpl` (les vars d'env du daemon)
4. Lance `sudo bash scripts/service.sh install mon-daemon`

## Pour du cron plutot qu'un service long-running

Remplace `unit.service` par une paire `unit.service` + `unit.timer` et adapte `install.sh` pour gerer les deux unites. Ou plus simple : utilise `cron` classique et mets le job dans `/etc/cron.d/` via `install.sh`.

## Secrets

`unit.service` fait `EnvironmentFile=-/etc/secrets/mon-daemon.env` (le `-` = optionnel si absent). L'agent Infisical regenere ce fichier selon `secrets.tmpl`.

Un `systemctl restart mon-daemon.service` applique les nouvelles valeurs.

## Debug

```bash
systemctl status mon-daemon.service
journalctl -u mon-daemon.service -n 100 -f
cat /etc/secrets/mon-daemon.env
```
