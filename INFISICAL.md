# Infisical - structure des secrets

Le bootstrap et les services hebergent sur le VPS tirent tous leurs secrets depuis un meme projet Infisical. Seule la Machine Identity (Client ID + Client Secret + Project ID) est saisie au prompt. Tout le reste est lu via l'API.

## Hierarchie attendue

```
<project>/
  <environment>/               ex: prod, staging, ...
    infra/
      shared/                  # cles communes a tous les hosts (vps + server)
        CROWDSEC_ENROLL_KEY    # optionnel - meme cle d'enrollment partout
        # ... ajoute ici toute cle identique entre hosts
      vps/                     # bootstrap du VPS public
        VPS_USER, VPS_USER_PASSWORD, SSH_PORT, SSH_PUBKEY
        GITHUB_SSH_PRIVKEY     # optionnel - cle dediee a ce host
        GITLAB_SSH_PRIVKEY     # optionnel
        GHCR_TOKEN, GHCR_USER  # optionnel
      server/                  # bootstrap du home server
        VPS_USER, SSH_PORT, SSH_PUBKEY
        GITHUB_SSH_PRIVKEY     # cle distincte (separation des privileges)
        ...

    certbot/                   # Let's Encrypt + DNS multi-provider
      CERTBOT_EMAIL
      infomaniak/
        perso                  # token Infomaniak (label libre, minuscule)
        alice                  # ... autre client
      ovh/
        client1/               # sous-dossier par client OVH (4 valeurs)
          APPLICATION_KEY
          APPLICATION_SECRET
          CONSUMER_KEY
          ENDPOINT             # ovh-eu | ovh-ca | ovh-us

    telegram/                  # Notifications Telegram
      TELEGRAM_BOT_TOKEN
      TELEGRAM_CHAT_ID              # chat par defaut (fallback)
      TELEGRAM_CHAT_ID_AUDIT        # canal par sujet
      TELEGRAM_CHAT_ID_BACKUP       # ...
      TELEGRAM_CHAT_ID_CERTBOT      # ...

    services/
      backup/                  # Sauvegarde restic push ephemere vers home
        HOME_SSH_HOST, HOME_SSH_PORT, HOME_SSH_USER, HOME_SSH_PRIVKEY
        RESTIC_REPOSITORY, RESTIC_PASSWORD
        BACKUP_PATHS           # optionnel (defaut: /home/$VPS_USER/data)
      webhooks/                # Webhooks receiver (GitHub + GitLab) - vhost only
        ADDRESS, DOMAIN, DNS_PROVIDER, DNS_TOKEN_NAME
      pdf/                     # Stirling PDF
        ADDRESS, DOMAIN, DNS_PROVIDER, DNS_TOKEN_NAME
      work/                    # Work-resume Next.js (deploy via webhook)
        ADDRESS, DOMAIN, DNS_PROVIDER, DNS_TOKEN_NAME
        APP, BRANCH, DIR, PORT, REPO
        hook/                  # config webhook pour ce service
          REPO                 # owner/name (GH) ou namespace/name (GL)
          WEBHOOK_SECRET       # HMAC GitHub / token GitLab
          SCRIPT               # nom du .sh dans /var/lib/services/webhooks/hooks/
          GIT_PROVIDER         # github | gitlab
          WORKFLOW             # optionnel, filtre sur nom CI
          BRANCH               # optionnel, filtre sur branche
      korai/                   # Korai (Docker multi-containers, deploy via webhook)
        ADDRESS, DOMAIN, DNS_PROVIDER, DNS_TOKEN_NAME, PORT
        INFISICAL_API_URL, INFISICAL_PROJECT_ID,
        INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET, INFISICAL_ENV
        hook/                  # config webhook (idem)
          REPO, WEBHOOK_SECRET, SCRIPT, GIT_PROVIDER, ...
      <service-avec-data>/     # services stateful (Ghost, Wiki, etc.)
        ADDRESS, DOMAIN, DNS_PROVIDER, DNS_TOKEN_NAME
        ... autres secrets applicatifs ...
        hook/                  # optionnel, si le service a un repo branche
```

Les `/` dans le path Infisical sont litteraux. L'environnement (`prod`, `staging`, etc.) est choisi au prompt du bootstrap et persiste dans `/etc/infisical/environment`.

**Convention de nommage :**
- **Cles de secret** en MAJUSCULES (`APPLICATION_KEY`, `DNS_TOKEN_NAME`, `WEBHOOK_SECRET`)
- **Labels** (noms de token, de client) en minuscules (`perso`, `alice`, `client1`) - pour distinguer visuellement label vs cle

## `/infra/{shared,vps,server}/` - bootstrap

Au tout debut de `bootstrap.sh`, **avant tout module**. Bootstrap fetch d'abord `/infra/shared/` (priorite basse), puis `/infra/$HOST_TYPE/` (host-specific override). En cas de collision sur une cle, le host-specific gagne.

`HOST_TYPE` est determine soit par `/etc/infisical/host-type` (persiste au 1er run), soit par env (`HOST_TYPE=server bash bootstrap.sh`), soit prompte. Valeurs : `vps` ou `server`.

Les cles marquees **optionnel** peuvent etre absentes.

| Cle | Where | Type | Exemple | Utilise par | Role |
|-----|-------|------|---------|-------------|------|
| `VPS_USER` | host-specific | string | `alice` | `10_user_ssh.sh` | nom du user sudo a creer |
| `VPS_USER_PASSWORD` | host-specific | secret | `...` | `10_user_ssh.sh` | mdp sudo du user |
| `SSH_PORT` | host-specific | int | `45675` | `10_user_ssh.sh`, `30_ufw_crowdsec.sh` | port SSH custom |
| `SSH_PUBKEY` | host-specific | string | `ssh-ed25519 AAAA...` | `10_user_ssh.sh` | cle(s) publique(s) pour authorized_keys |
| `CROWDSEC_ENROLL_KEY` | shared (typique) | secret | `abcdef1234...` | `30_ufw_crowdsec.sh` | **optionnel** - meme cle pour tous les hosts (single CrowdSec instance) |
| `GITHUB_SSH_PRIVKEY` | host-specific | secret | `-----BEGIN OPENSSH PRIVATE KEY-----\n...` | `15_git_ssh.sh` | **optionnel** - cle SSH pour pull repos GitHub prives. **Une cle par host** (separation des privileges) |
| `GITLAB_SSH_PRIVKEY` | host-specific | secret | idem | `15_git_ssh.sh` | **optionnel** |
| `GHCR_TOKEN` | host-specific | secret | `ghp_...` | `40_docker.sh` | **optionnel** - PAT GitHub. Une par host pour traçage |
| `GHCR_USER` | host-specific | string | `aliceout` | `40_docker.sh` | **optionnel** - username GitHub. Default: `aliceout` |

### Mode d'install : `fresh` vs `existing`

Au 1er run, bootstrap demande aussi `Le user et SSH sont-ils deja configures sur cette machine ?`. Persistance dans `/etc/infisical/install-mode`. Override : `INSTALL_MODE=existing bash bootstrap.sh`.

- **fresh** (defaut sur VPS neuf) : tous les modules tournent, dont `10_user_ssh.sh` qui cree le user, change le port SSH, deploie `authorized_keys`.
- **existing** (host deja configure) : skip uniquement `10_user_ssh.sh`. Le user doit deja exister sur le systeme (sanity check au boot). `VPS_USER_PASSWORD` et `SSH_PUBKEY` deviennent optionnels cote Infisical.

Mecanique generique : `SKIP_MODULES="10_user_ssh,xxx" bash bootstrap.sh` skip n'importe quel module par prefix de nom.

## `/certbot/` - Let's Encrypt + DNS providers

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

## `/telegram/` - Notifications

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

## `/services/webhooks/<host_type>/`

Le receiver webhooks tourne potentiellement sur plusieurs hosts (`vps` et `server`) avec une `ADDRESS` distincte par host. La config est donc scopee par host_type : `/services/webhooks/vps/` pour le VPS, `/services/webhooks/server/` pour le home server. Le `service.conf` du webhooks utilise `INFISICAL_PATH="/services/webhooks/${HOST_TYPE}"`.

### `/services/webhooks/<host_type>/` : config du vhost

| Cle | Exemple | Role |
|-----|---------|------|
| `ADDRESS` | `webhooks.backlice.dev` (vps) / `hooks.lan.tld` (server) | FQDN de l'expo |
| `DOMAIN` | `backlice.dev` | apex cert wildcard |
| `DNS_PROVIDER` | `infomaniak` | `infomaniak` ou `ovh` |
| `DNS_TOKEN_NAME` | `perso` | label du token sous `/certbot/<provider>/` |

### Sous-dossier `hook/` par service deployee via webhook

Chaque service qui se redeploit via webhook met sa config webhook sous `/services/<nom>/hook/` (et non plus dans `/services/webhooks/<slug>/`). Le receiver scanne `/services/*/hook/` a `services install/update webhooks` pour generer un sink `/etc/secrets/webhooks/<nom>.env` par service-avec-hook.

**Filtre par host** : seuls les services dont le hook script `<svc>.sh` est publie localement dans `/var/lib/services/webhooks/hooks/` sont pris en compte. Donc le VPS ne genere que les sinks pour ses propres services (`2mains`, `nodea`, `korai`, `work`...) et le server ne genere que les siens, meme si l'arborescence Infisical `/services/*` contient les hooks de tous les hosts.

| Cle | Type | Role |
|-----|------|------|
| `REPO` | `aliceout/Work-resume` (GH) ou `riana/projet` (GL) | slug, doit matcher ce que la forge envoie dans le payload |
| `WEBHOOK_SECRET` | secret | GitHub : HMAC (`openssl rand -hex 32`, mis dans Settings > Webhooks). GitLab : token en clair (mis dans Settings > Webhooks > Secret token) |
| `SCRIPT` | `work.sh` | fichier dans `/var/lib/services/webhooks/hooks/` execute par le receiver |
| `GIT_PROVIDER` | `github` ou `gitlab` | **requis**. Branche l'auth et l'extraction du slug. Pas de defaut : pour eviter l'ambiguite, chaque hook declare explicitement sa forge |
| `WORKFLOW` | `Docker build` | **optionnel**. GitHub: filtre `workflow_run.name`. GitLab: filtre `object_attributes.name` des Pipeline Hook |
| `BRANCH` | `main` | **optionnel**. Filtre sur la branche, ignore les runs des feature branches |

Voir `services/webhooks/README.md` pour le flow complet.

## `/services/<service-avec-vhost>/`

### Convention commune

Pour TOUT service expose via nginx, on met au minimum ces 4 cles :

| Cle | Role |
|-----|------|
| `ADDRESS` | FQDN = `server_name` nginx + record DNS A |
| `DOMAIN` | apex du cert wildcard |
| `DNS_PROVIDER` | `infomaniak` ou `ovh` (choisit le plugin certbot et le backend DNS sync) |
| `DNS_TOKEN_NAME` | label du token sous `/certbot/<provider>/` |

Ces cles sont referencees dans le `nginx.conf` du service via `__ADDRESS__` / `__DOMAIN__` / `__PORT__`. `scripts/service.sh` substitue au moment du `services install <nom>`.

**Obligatoire** : sans `DNS_PROVIDER` + `DNS_TOKEN_NAME`, `ensure_cert` refuse d'emettre un cert (le service est deploye sans SSL). Les 2 cles doivent pointer sur un label existant sous `/certbot/<provider>/`.

### Secrets applicatifs

Toute autre cle sous `/services/<nom>/` atterrit aussi dans `/etc/secrets/<nom>.env`. Si le service en a besoin, reference-le dans son `docker-compose.yml` :
```yaml
env_file: /etc/secrets/<nom>.env
```

### Template Infisical

Chaque service a un `secrets.tmpl` avec le pattern `listSecrets` → rapatrie tout ce qui est sous `/services/<nom>/`. Donc zero friction pour ajouter une cle : tu ajoutes dans Infisical, l'agent la sync dans `/etc/secrets/<nom>.env`.

Convention : declare `INFISICAL_PATH=/services/<nom>` dans `services/<nom>/service.conf` et utilise le pattern recommande dans `secrets.tmpl`.

## Machine Identity

Cree une Machine Identity (Universal Auth) sur le projet avec permission **Read** sur tout (ou minimum sur `/infra/**` + `/certbot/**` + `/telegram/**` + `/services/**`).

Note :
- Client ID
- Client Secret
- Project ID (visible dans l'URL du projet Infisical)

Le bootstrap te les demande au 1er run et les persiste en `/etc/infisical/{client-id,client-secret,project-id,environment}` (chmod 600 pour les deux premiers). Les re-runs les reutilisent automatiquement.

## Verifier les secrets syncs sur le VPS

```bash
# Secrets infra (lus une fois, pas persistes sur disque)
infisical secrets --env=prod --path=/infra/vps

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
