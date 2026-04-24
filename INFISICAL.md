# Infisical - structure des secrets

Le bootstrap et les services hebergent sur le VPS tirent tous leurs secrets depuis un meme projet Infisical. Seule la Machine Identity (Client ID + Client Secret + Project ID) est saisie au prompt. Tout le reste est lu via l'API.

## Hierarchie attendue

```
<project>/
  <environment>/               ex: prod, staging, ...
    vps/
      _infra/                  # bootstrap (charge au demarrage par bootstrap.sh)
        VPS_USER
        VPS_USER_PASSWORD
        SSH_PORT
        SSH_PUBKEY
        CROWDSEC_ENROLL_KEY    # optionnel
        GITHUB_SSH_PRIVKEY     # optionnel - cle SSH GitHub
        GITLAB_SSH_PRIVKEY     # optionnel - cle SSH GitLab

      certbot/                 # Let's Encrypt + DNS multi-provider
        CERTBOT_EMAIL
        infomaniak/
          perso                # token Infomaniak (label libre, minuscule)
          alice                # ... autre client
        ovh/
          client1/             # sous-dossier par client OVH (4 valeurs)
            APPLICATION_KEY
            APPLICATION_SECRET
            CONSUMER_KEY
            ENDPOINT           # ovh-eu | ovh-ca | ovh-us

      telegram/                # Notifications Telegram
        TELEGRAM_BOT_TOKEN
        TELEGRAM_CHAT_ID            # chat par defaut (fallback)
        TELEGRAM_CHAT_ID_AUDIT      # canal par sujet
        TELEGRAM_CHAT_ID_BACKUP     # ...
        TELEGRAM_CHAT_ID_CERTBOT    # ...

    services/
      backup/                  # Sauvegarde restic push ephemere vers home
        HOME_SSH_HOST, HOME_SSH_PORT, HOME_SSH_USER, HOME_SSH_PRIVKEY
        RESTIC_REPOSITORY, RESTIC_PASSWORD
        BACKUP_PATHS           # optionnel (defaut: /home/$VPS_USER/data)
      pdf/                     # Stirling PDF
        ADRESS, DOMAIN, DNS_PROVIDER, DNS_TOKEN_NAME
      work/                    # Work-resume Next.js
        ADRESS, DOMAIN, DNS_PROVIDER, DNS_TOKEN_NAME
        APP, BRANCH, DIR, PORT, REPO
      korai/                   # Korai (Docker multi-containers, deploy via webhook)
        ADRESS, DOMAIN, DNS_PROVIDER, DNS_TOKEN_NAME, PORT
        INFISICAL_API_URL, INFISICAL_PROJECT_ID,
        INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET, INFISICAL_ENV
      webhooks/                # Webhooks receiver (GitHub + GitLab)
        ADRESS, DOMAIN, DNS_PROVIDER, DNS_TOKEN_NAME
        <repo-slug>/           # un sous-dossier par hook (ex: work, korai, riana-projet)
          REPO                 # owner/name (GitHub) ou namespace/name (GitLab)
          WEBHOOK_SECRET       # token d'auth (HMAC cote GitHub, plain cote GitLab)
          SCRIPT               # nom du .sh dans /var/lib/services/webhooks/hooks/
          PROVIDER             # github | gitlab (requis, pas de defaut)
          WORKFLOW             # optionnel, filtre sur nom CI
          BRANCH               # optionnel, filtre sur branche
      <service-avec-data>/     # services stateful (Ghost, Wiki, etc.)
        ADRESS, DOMAIN, DNS_PROVIDER, DNS_TOKEN_NAME
        ... autres secrets applicatifs ...
```

Les `/` dans le path Infisical sont litteraux. L'environnement (`prod`, `staging`, etc.) est choisi au prompt du bootstrap et persiste dans `/etc/infisical/environment`.

**Convention de nommage :**
- **Cles de secret** en MAJUSCULES (`APPLICATION_KEY`, `DNS_TOKEN_NAME`, `WEBHOOK_SECRET`)
- **Labels** (noms de token, de client) en minuscules (`perso`, `alice`, `client1`) - pour distinguer visuellement label vs cle

## `/vps/_infra/` - bootstrap

Lu une seule fois au tout debut de `bootstrap.sh`, avant tout module. Les cles marquees **optionnel** peuvent etre absentes.

| Cle | Type | Exemple | Utilise par | Role |
|-----|------|---------|-------------|------|
| `VPS_USER` | string | `alice` | `10_user_ssh.sh` | nom du user sudo a creer |
| `VPS_USER_PASSWORD` | secret | `...` | `10_user_ssh.sh` | mdp sudo du user |
| `SSH_PORT` | int | `45675` | `10_user_ssh.sh`, `30_ufw_crowdsec.sh` | port SSH custom |
| `SSH_PUBKEY` | string | `ssh-ed25519 AAAA...` | `10_user_ssh.sh` | cle(s) publique(s) pour authorized_keys |
| `CROWDSEC_ENROLL_KEY` | secret | `abcdef1234...` | `30_ufw_crowdsec.sh` | **optionnel** - enrollment CrowdSec. Absent = standalone sans dashboard |
| `GITHUB_SSH_PRIVKEY` | secret | `-----BEGIN OPENSSH PRIVATE KEY-----\n...` | `15_git_ssh.sh` | **optionnel** - cle SSH pour pull de repos GitHub prives |
| `GITLAB_SSH_PRIVKEY` | secret | idem | `15_git_ssh.sh` | **optionnel** - cle SSH pour pull de repos GitLab prives |

## `/vps/certbot/` - Let's Encrypt + DNS providers

Permet de gerer des certs et des records DNS chez **plusieurs providers** (et plusieurs comptes chez le meme provider, pour heberger des services de clients differents).

| Cle / Sous-dossier | Role |
|--------------------|------|
| `CERTBOT_EMAIL` | email du compte ACME Let's Encrypt |
| `infomaniak/<label>` | token Infomaniak API. Label libre (`perso`, `alice`, ...), referencable via `DNS_TOKEN_NAME` dans un service |
| `ovh/<label>/APPLICATION_KEY` | creds OVH (4 secrets par label, dans un sous-dossier dedie) |
| `ovh/<label>/APPLICATION_SECRET` | |
| `ovh/<label>/CONSUMER_KEY` | |
| `ovh/<label>/ENDPOINT` | `ovh-eu` / `ovh-ca` / `ovh-us` |

Generer les creds OVH : https://eu.api.ovh.com/createToken/ avec droits GET/POST/DELETE sur `/domain/zone/*` (ou specifique a un domaine : `/domain/zone/alice.fr/*`).

Chaque service qui a un vhost declare dans sa config (`/services/<name>/`) :
- `DNS_PROVIDER=infomaniak` (ou `ovh`)
- `DNS_TOKEN_NAME=perso` (pointe sur le label sous le provider)

Le pre-hook `certbot-refresh-creds` (appele avant chaque `certbot renew`) regenere automatiquement les ini files `/etc/certbot/creds/<provider>/<label>.ini` depuis ces secrets, donc rotation de token transparente.

## `/vps/telegram/` - Notifications

Toutes les alertes et digests Telegram passent par `notify-telegram`, qui fetch ces cles a chaque run.

| Cle | Type | Exemple | Role |
|-----|------|---------|------|
| `TELEGRAM_BOT_TOKEN` | secret | `123456789:AAE-...` | bot cree via @BotFather |
| `TELEGRAM_CHAT_ID` | string | `123456789` | chat par defaut (fallback si `--target` absent) |
| `TELEGRAM_CHAT_ID_<TARGET>` | string | `-1001234567890` | chat pour un canal specifique. Ex: `AUDIT`, `BACKUP`, `CERTBOT`. `notify-telegram --target audit` cherche `TELEGRAM_CHAT_ID_AUDIT` puis fallback sur `TELEGRAM_CHAT_ID` |

## `/services/backup/`

Ces cles sont fetchees **a chaque run** par `backup-run.sh` et `backup-restore.sh`. La cle privee SSH n'atterrit jamais sur disque : piped dans `ssh-add` via stdin, vit en memoire de `ssh-agent` le temps du run.

| Cle | Type | Exemple | Role |
|-----|------|---------|------|
| `HOME_SSH_HOST` | string | `home.mondomaine.fr` | FQDN ou IP du home server |
| `HOME_SSH_PORT` | int | `22` | port SSH du home |
| `HOME_SSH_USER` | string | `backup` | user SFTP-chroot dedie |
| `HOME_SSH_PRIVKEY` | secret | `-----BEGIN OPENSSH...` | cle privee ed25519 |
| `RESTIC_REPOSITORY` | string | `sftp:backup@home:/storage` | URL du repo restic |
| `RESTIC_PASSWORD` | secret | `...` | mdp de chiffrement |
| `BACKUP_PATHS` | string | `/home/choupi/data` | **optionnel**, defaut `/home/<VPS_USER>/data` |

## `/services/webhooks/`

### Racine : config du vhost

| Cle | Exemple | Role |
|-----|---------|------|
| `ADRESS` | `webhooks.backlice.dev` | FQDN de l'expo |
| `DOMAIN` | `backlice.dev` | apex cert wildcard |
| `DNS_PROVIDER` | `infomaniak` | `infomaniak` ou `ovh` |
| `DNS_TOKEN_NAME` | `perso` | label du token sous `/vps/certbot/<provider>/` |

### Sous-dossier par hook

Chaque repo branche a un sous-dossier `/services/webhooks/<slug>/`. Le receiver scanne a chaque requete.

| Cle | Type | Role |
|-----|------|------|
| `REPO` | `aliceout/Work-resume` (GH) ou `riana/projet` (GL) | slug, doit matcher ce que la forge envoie dans le payload |
| `WEBHOOK_SECRET` | secret | GitHub : HMAC (`openssl rand -hex 32`, mis dans Settings > Webhooks). GitLab : token en clair (mis dans Settings > Webhooks > Secret token) |
| `SCRIPT` | `work.sh` | fichier dans `/var/lib/services/webhooks/hooks/` execute par le receiver |
| `PROVIDER` | `github` ou `gitlab` | **requis**. Branche l'auth et l'extraction du slug. Pas de defaut : pour eviter l'ambiguite, chaque hook declare explicitement sa forge |
| `WORKFLOW` | `Docker build` | **optionnel**. GitHub: filtre `workflow_run.name`. GitLab: filtre `object_attributes.name` des Pipeline Hook |
| `BRANCH` | `main` | **optionnel**. Filtre sur la branche, ignore les runs des feature branches |

Voir `services/webhooks/README.md` pour le flow complet.

## `/services/<service-avec-vhost>/`

### Convention commune

Pour TOUT service expose via nginx, on met au minimum ces 4 cles :

| Cle | Role |
|-----|------|
| `ADRESS` | FQDN = `server_name` nginx + record DNS A |
| `DOMAIN` | apex du cert wildcard |
| `DNS_PROVIDER` | `infomaniak` ou `ovh` (choisit le plugin certbot et le backend DNS sync) |
| `DNS_TOKEN_NAME` | label du token sous `/vps/certbot/<provider>/` |

Ces cles sont referencees dans le `nginx.conf` du service via `__ADRESS__` / `__DOMAIN__` / `__PORT__`. `scripts/service.sh` substitue au moment du `services install <nom>`.

**Obligatoire** : sans `DNS_PROVIDER` + `DNS_TOKEN_NAME`, `ensure_cert` refuse d'emettre un cert (le service est deploye sans SSL). Les 2 cles doivent pointer sur un label existant sous `/vps/certbot/<provider>/`.

### Secrets applicatifs

Toute autre cle sous `/services/<nom>/` atterrit aussi dans `/etc/secrets/<nom>.env`. Si le service en a besoin, reference-le dans son `docker-compose.yml` :
```yaml
env_file: /etc/secrets/<nom>.env
```

### Template Infisical

Chaque service a un `secrets.tmpl` avec le pattern `listSecrets` → rapatrie tout ce qui est sous `/services/<nom>/`. Donc zero friction pour ajouter une cle : tu ajoutes dans Infisical, l'agent la sync dans `/etc/secrets/<nom>.env`.

Convention : declare `INFISICAL_PATH=/services/<nom>` dans `services/<nom>/service.conf` et utilise le pattern recommande dans `secrets.tmpl`.

## Machine Identity

Cree une Machine Identity (Universal Auth) sur le projet avec permission **Read** sur tout (ou minimum sur `/vps/**` + `/services/**`).

Note :
- Client ID
- Client Secret
- Project ID (visible dans l'URL du projet Infisical)

Le bootstrap te les demande au 1er run et les persiste en `/etc/infisical/{client-id,client-secret,project-id,environment}` (chmod 600 pour les deux premiers). Les re-runs les reutilisent automatiquement.

## Verifier les secrets syncs sur le VPS

```bash
# Secrets infra (lus une fois, pas persistes sur disque)
infisical secrets --env=prod --path=/vps/_infra

# Secrets d'un service (synces en continu par l'agent)
cat /etc/secrets/<service>.env

# Agent status
systemctl status infisical-agent
journalctl -u infisical-agent -n 50

# Providers certbot connus (ecrit par certbot-wildcard)
cat /etc/certbot/providers.conf

# Creds certbot regenerees par le pre-hook
ls /etc/certbot/creds/infomaniak/ /etc/certbot/creds/ovh/
```
