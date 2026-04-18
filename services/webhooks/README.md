# Webhooks GitHub

Serveur Node.js qui reçoit les push GitHub, vérifie la signature HMAC, et lance un script de deploy par repo.

Installé en systemd natif (tourne sous `$VPS_USER`), exposé via nginx sur `https://<ADRESS>/webhooks`.

## Secrets Infisical

### `/services/webhooks/` (config du service)

| Cle | Type | Exemple | Role |
|-----|------|---------|------|
| `ADRESS` | string | `webhooks.backlice.dev` | FQDN public |
| `DOMAIN` | string | `backlice.dev` | apex cert wildcard |

### `/services/webhooks/<repo>/` (un sous-dossier par webhook)

Chaque repo GitHub que tu veux brancher a son propre sous-dossier :

| Cle | Exemple | Role |
|-----|---------|------|
| `REPO` | `aliceout/Work-resume` | slug GitHub (`owner/name`), doit matcher le `full_name` envoye par GitHub dans le payload |
| `SECRET` | `Attach8-Catfight-...` | HMAC partage avec GitHub (`openssl rand -hex 32`), doit etre identique a ce que tu poses dans Settings > Webhooks > Secret cote repo |
| `SCRIPT` | `work.sh` | nom du fichier dans `/var/lib/services/webhooks/hooks/` a executer |

**Note** : les scripts eux-memes (`work.sh`, etc.) ne sont pas dans Infisical. Ils vivent dans le repo `vps-install` au sein du service qui les consomme (ex: `services/work/hook.sh`). Quand tu `services install <nom>`, le service y copie son hook et declenche `services update webhooks` pour enregistrer le mapping Infisical.

## Flow complet pour brancher un nouveau repo

1. Dans Infisical, cree le sous-dossier `/services/webhooks/<nom>/` avec `REPO`, `SECRET`, `SCRIPT`.
2. Dans le repo `vps-install`, cree un `services/<nom>/` avec son `hook.sh` + `install.sh` qui publie le hook dans `/var/lib/services/webhooks/hooks/`.
3. Commit + push le repo `vps-install`, pull sur le VPS.
4. `services install <nom>` → installe l'app, publie le hook, trigger `services update webhooks`.
5. Sur GitHub, Settings > Webhooks > Add : Payload URL `https://<ADRESS>/webhooks`, Content-type `application/json`, Secret = la meme valeur que dans Infisical, Events = Just push.

## Install du service webhooks lui-meme

```bash
services install webhooks
```

Ca :
- Deploie `app.js` dans `/var/lib/services/webhooks/`
- Cree `/var/lib/services/webhooks/hooks/` (scripts de deploy) et `log/` (sortie)
- Installe `/etc/systemd/system/webhooks.service` avec hardening (ProtectSystem, ReadWritePaths, NoNewPrivileges)
- Genere les templates Infisical (un par sous-dossier sous `/services/webhooks/`) → `/etc/secrets/webhooks.env` (main) + `/etc/secrets/webhooks/<repo>.env` (un par hook)
- Reverse proxy nginx `https://<ADRESS>/webhooks` → `127.0.0.1:8070`
- Cert wildcard `*.<DOMAIN>` (skip si deja present)

## Update apres ajout d'un sous-dossier Infisical

```bash
services update webhooks
```

Rescanne les sous-dossiers sous `/services/webhooks/` (via `infomaniak secrets folders get`) et (re)genere les templates Infisical + fragments agent.

## Debug

```bash
# Service status
systemctl status webhooks

# Logs du service
journalctl -u webhooks -f

# Logs d'execution par repo
ls /var/lib/services/webhooks/log/
tail -f /var/lib/services/webhooks/log/aliceout_Work-resume.log

# Test en local (simule un ping GitHub, pas de HMAC requis)
curl -X POST -H "X-GitHub-Event: ping" -H "Content-Type: application/json" \
  -d '{"repository":{"full_name":"aliceout/Work-resume"}}' \
  https://<ADRESS>/webhooks
# Reponse attendue: pong
```

## Architecture interne

- `/etc/secrets/webhooks.env` : ADRESS, DOMAIN (main)
- `/etc/secrets/webhooks/<repo>.env` : REPO, SECRET, SCRIPT par repo
- `/var/lib/services/webhooks/app.js` : le serveur Node (stdlib only, pas de deps)
- `/var/lib/services/webhooks/hooks/` : scripts bash deployes par les services consommateurs
- `/var/lib/services/webhooks/log/` : sortie d'execution des hooks (rotated par logrotate si tu l'ajoutes)

`app.js` scanne `/etc/secrets/webhooks/*.env` a chaque requete entrante (pas au boot), donc ajouter un nouveau hook prend effet des que l'agent Infisical a synce le nouveau fichier (~60s). Pas besoin de redemarrer le service.
