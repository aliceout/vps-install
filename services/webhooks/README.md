# Webhooks (GitHub + GitLab)

Serveur Node.js qui recoit les webhooks GitHub **et GitLab**, verifie l'auth, et lance un script de deploy par repo.

Installe en systemd natif (tourne sous `$VPS_USER`), expose via nginx sur `https://<ADRESS>/webhooks`.

Auth selon la forge :
- **GitHub** : HMAC SHA-256 sur le body, header `X-Hub-Signature-256`
- **GitLab** : token en clair, header `X-Gitlab-Token`

## Secrets Infisical

### `/services/webhooks/` (config du service)

| Cle | Exemple | Role |
|-----|---------|------|
| `ADRESS` | `webhooks.backlice.dev` | FQDN public |
| `DOMAIN` | `backlice.dev` | apex cert wildcard |
| `DNS_PROVIDER` | `infomaniak` | `infomaniak` ou `ovh` |
| `DNS_TOKEN_NAME` | `perso` | label du token sous `/certbot/<provider>/` |

### `/services/<nom>/hook/` (un sous-dossier `hook/` par service-avec-deploy)

Chaque service deployee via webhook met sa config webhook chez lui sous `hook/` (et **non plus** dans `/services/webhooks/<slug>/`). Le receiver scanne `/services/*/hook/` a `services install/update webhooks`.

| Cle | Exemple | Role |
|-----|---------|------|
| `REPO` | `aliceout/Work-resume` (GH) / `riana/projet` (GL) | slug, doit matcher ce que la forge envoie dans le payload |
| `WEBHOOK_SECRET` | `Attach8-Catfight-...` | **GitHub**: HMAC (`openssl rand -hex 32`, a mettre dans Settings > Webhooks > Secret). **GitLab**: token en clair (Settings > Webhooks > Secret token) |
| `SCRIPT` | `work.sh` | nom du fichier dans `/var/lib/services/webhooks/hooks/` a executer |
| `GIT_PROVIDER` | `github` ou `gitlab` | **requis**. Branche l'auth + l'extraction du slug. Pas de defaut : chaque hook declare explicitement sa forge |
| `WORKFLOW` | `Docker build` | **optionnel**. Filtre sur un workflow/pipeline precis pour eviter de redeployer a chaque CI (lint, test, etc.). GitHub: matche `workflow_run.name`. GitLab: matche `object_attributes.name` des Pipeline Hook |
| `BRANCH` | `main` | **optionnel**. Ignore les runs sur feature branches / PRs |

**Note** : les scripts eux-memes (`work.sh`, etc.) ne sont pas dans Infisical. Ils vivent dans le repo `vps-install` au sein du service qui les consomme (ex: `services/work/hook.sh`). Quand tu `services install <nom>`, le service y copie son hook et declenche `services update webhooks` pour enregistrer le mapping Infisical.

## Flow complet pour brancher un nouveau repo

### Repo GitHub

1. Dans Infisical, cree `/services/<nom>/hook/` avec `REPO`, `WEBHOOK_SECRET`, `SCRIPT`, `GIT_PROVIDER=github`.
2. Dans le repo `vps-install`, cree un `services/<nom>/` avec son `hook.sh` + `install.sh` qui publie le hook.
3. Commit + push, pull sur le VPS.
4. `services install <nom>` → installe l'app, publie le hook, trigger `services update webhooks`.
5. Sur GitHub, Settings > Webhooks > Add : Payload URL `https://<ADRESS>/webhooks`, Content-type `application/json`, Secret = la meme valeur que `WEBHOOK_SECRET`, Events = ce que tu veux (ping + push + workflow_run typiquement).

### Repo GitLab

1. Dans Infisical, cree `/services/<nom>/hook/` avec `REPO` (format `namespace/name`), `WEBHOOK_SECRET`, `SCRIPT`, **`GIT_PROVIDER=gitlab`**.
2. Meme logique cote `services/<nom>/` dans vps-install.
3. Sur GitLab, Settings > Webhooks > Add : URL `https://<ADRESS>/webhooks`, Secret token = la valeur de `WEBHOOK_SECRET`, Trigger = Push events / Pipeline events (et **activer Enable SSL verification**).

## Install du service webhooks lui-meme

```bash
services install webhooks
```

Ca :
- Deploie `app.js` dans `/var/lib/services/webhooks/`
- Cree `/var/lib/services/webhooks/{hooks,log}/`
- Installe `/etc/systemd/system/webhooks.service` avec hardening (ProtectSystem, ReadWritePaths sur `/var/www`, `/home/<user>`, etc.)
- Genere les templates Infisical (un par service ayant `/services/<nom>/hook/`) → `/etc/secrets/webhooks.env` (main) + `/etc/secrets/webhooks/<nom>.env` (un par hook)
- Reverse proxy nginx `https://<ADRESS>/webhooks` → `127.0.0.1:8070`
- Cert wildcard `*.<DOMAIN>` (skip si deja present)

## Update apres ajout d'un nouveau hook

```bash
services update webhooks
```

Rescanne `/services/*/hook/` et (re)genere les templates agent.

## Debug

```bash
# Service status
systemctl status webhooks

# Logs du service (auth, dispatch)
journalctl -u webhooks -f

# Logs d'execution par repo
ls /var/lib/services/webhooks/log/
tail -f /var/lib/services/webhooks/log/aliceout_Work-resume.log

# Test GitHub ping (pas besoin d'auth)
curl -X POST -H "X-GitHub-Event: ping" -H "Content-Type: application/json" \
  -d '{"repository":{"full_name":"aliceout/Work-resume"}}' \
  https://<ADRESS>/webhooks

# Test GitLab (signature requise)
curl -X POST \
  -H "X-Gitlab-Event: Push Hook" \
  -H "X-Gitlab-Token: <le-secret>" \
  -H "Content-Type: application/json" \
  -d '{"project":{"path_with_namespace":"riana/projet"}}' \
  https://<ADRESS>/webhooks
```

## Architecture interne

- `/etc/secrets/webhooks.env` : ADRESS, DOMAIN, DNS_PROVIDER, DNS_TOKEN_NAME (main)
- `/etc/secrets/webhooks/<repo>.env` : REPO, WEBHOOK_SECRET, SCRIPT, GIT_PROVIDER, WORKFLOW, BRANCH par repo
- `/var/lib/services/webhooks/app.js` : le serveur Node (stdlib only, pas de deps)
- `/var/lib/services/webhooks/hooks/` : scripts bash deployes par les services consommateurs
- `/var/lib/services/webhooks/log/` : sortie d'execution des hooks

`app.js` scanne `/etc/secrets/webhooks/*.env` a chaque requete entrante (pas au boot), donc ajouter un nouveau hook prend effet des que l'agent Infisical a synce le nouveau fichier (~60s). Pas besoin de redemarrer.

## Detection du provider

Le receiver detecte la forge par **header** :
- `X-GitHub-Event` → GitHub
- `X-Gitlab-Event` → GitLab

Si ni l'un ni l'autre → 400. Si la config dit `GIT_PROVIDER=github` mais la requete a un header GitLab (ou l'inverse), le receiver refuse avec 400 "Provider mismatch" — protection contre un mis-cable du webhook cote forge.
