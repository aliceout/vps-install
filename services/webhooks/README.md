# Webhooks GitHub

Serveur Node.js qui reçoit les push GitHub, vérifie la signature HMAC, et lance un script de deploy par repo.

Installé en systemd natif (tourne sous `$VPS_USER`), exposé via nginx sur `https://<ADRESS>/webhooks`.

## Secrets Infisical - `/services/webhooks/`

| Cle | Type | Exemple | Role |
|-----|------|---------|------|
| `ADRESS` | string | `webhooks.alyss.cc` | FQDN public |
| `DOMAIN` | string | `alyss.cc` | apex cert wildcard |
| `WEBHOOKS_REPOS` | JSON | `[{"repo":"aliceout/Work-resume","secretEnv":"WORK_SECRET","script":"work.sh"}]` | mapping repo → secret → script |
| `<X_SECRET>` | secret | `Attach8-Catfight-...` | 1 cle par repo, le secret HMAC partage avec GitHub (doit matcher ce que tu poses dans Settings → Webhooks d'un repo) |

Format de `WEBHOOKS_REPOS` :

```json
[
  {"repo": "aliceout/Work-resume",           "secretEnv": "WORK_SECRET",           "script": "work.sh"},
  {"repo": "aliceout/Nodea",                 "secretEnv": "NODEA_SECRET",          "script": "nodea.sh"},
  {"repo": "aliceout/Relationship-spectrum", "secretEnv": "RELATIONSHIP_SECRET",   "script": "relationship.sh"},
  {"repo": "aliceout/Korai",                 "secretEnv": "KORAI_SECRET",          "script": "korai.sh"},
  {"repo": "Watizat/WebApp",                 "secretEnv": "WATIZAT_WEBAPP_SECRET", "script": "watizat-front.sh"}
]
```

Pour ajouter un repo, trois actions :

1. Ajoute une entrée à `WEBHOOKS_REPOS` (JSON)
2. Ajoute le secret correspondant (ex: `WORK_SECRET`)
3. Dépose le script `.sh` dans `/var/lib/services/webhooks/hooks/` sur le VPS

Puis `sudo systemctl restart webhooks` pour que Node recharge l'env.

## Install

```bash
services install webhooks
```

Ça :
- Déploie `app.js` dans `/var/lib/services/webhooks/`
- Crée `/var/lib/services/webhooks/hooks/` (scripts de deploy) et `log/` (sortie des scripts)
- Installe `/etc/systemd/system/webhooks.service`
- Synchronise les secrets Infisical dans `/etc/secrets/webhooks.env`
- Reverse proxy nginx `https://<ADRESS>/webhooks` → `127.0.0.1:8070`
- Cert wildcard `*.<DOMAIN>` (skip si déjà présent)

## Côté GitHub

Pour chaque repo, Settings → Webhooks → Add webhook :

- **Payload URL** : `https://<ADRESS>/webhooks`
- **Content type** : `application/json`
- **Secret** : la même valeur que dans Infisical (`WORK_SECRET`, etc.)
- **Events** : Just the push event (ou selon besoin)

## Debug

```bash
# Logs du service
journalctl -u webhooks -f

# Logs d'execution par repo
ls /var/lib/services/webhooks/log/
tail -f /var/lib/services/webhooks/log/aliceout_Work-resume.log

# Test en local depuis le VPS (simule un ping GitHub)
curl -X POST -H "X-GitHub-Event: ping" -H "Content-Type: application/json" \
  -d '{"repository":{"full_name":"aliceout/Work-resume"}}' \
  http://127.0.0.1:8070/webhooks
# Reponse attendue: pong
```

## Scripts de deploy

Les scripts vivent dans `/var/lib/services/webhooks/hooks/`, tournent sous `$VPS_USER`, et sont totalement libres — ce que tu veux. Chacun gère le repo qu'il reçoit (git pull, build, restart service, etc.).

Le serveur leur fait juste un `bash <script>` en background avec `>> log/<repo>.log 2>&1`.
