# Infisical - structure des secrets

Le bootstrap et les services hebergent sur le VPS tirent tous leurs secrets depuis un meme projet Infisical. Seule la Machine Identity (Client ID + Client Secret + Project ID) est saisie au prompt. Tout le reste est lu via l'API.

## Hierarchie attendue

```
<project>/
  <environment>/           ex: prod, staging, ...
    vps/
      _infra/              # bootstrap (charge au demarrage par bootstrap.sh)
        VPS_USER
        VPS_USER_PASSWORD
        SSH_PORT
        SSH_PUBKEY
        CERTBOT_EMAIL
        INFOMANIAK_TOKEN
        CROWDSEC_ENROLL_KEY  # optionnel
        GITHUB_SSH_PRIVKEY   # optionnel
      telegram/            # Notifications Telegram (lu par notify-telegram)
        TELEGRAM_BOT_TOKEN
        TELEGRAM_CHAT_ID     # chat par defaut (fallback)
        TELEGRAM_CHAT_ID_AUDIT    # canal par sujet
        TELEGRAM_CHAT_ID_BACKUP   # ...
        TELEGRAM_CHAT_ID_CERTBOT  # ...
    services/
      backup/              # Sauvegarde restic push ephemere vers home
        HOME_SSH_HOST
        HOME_SSH_PORT
        HOME_SSH_USER
        HOME_SSH_PRIVKEY
        RESTIC_REPOSITORY
        RESTIC_PASSWORD
        BACKUP_PATHS       # optionnel (defaut: /home/$VPS_USER/data)
      pdf/                 # Stirling PDF (stateless, pas de data)
        ADRESS, DOMAIN
      work/                # Work-resume Next.js (stateless, build from git)
        ADRESS, DOMAIN, APP, BRANCH, DIR, PORT, REPO
      webhooks/            # GitHub webhooks receiver
        ADRESS, DOMAIN
        <repo>/            # un sous-dossier par hook (ex: work/, nodea/, ...)
          REPO             # owner/name de GitHub
          SECRET           # HMAC partage avec GitHub
          SCRIPT           # nom du .sh dans /var/lib/services/webhooks/hooks/
      <service-avec-data>/ # services stateful (Ghost, Wiki, etc.)
        ADRESS, DOMAIN
        ... autres secrets/config du service ...
```

Les `/` dans le path Infisical sont litteraux. L'environnement (`prod`, `staging`, etc.) est choisi au prompt du bootstrap et persiste dans `/etc/infisical/environment`.

## `/vps/_infra/` - bootstrap

Lu une seule fois au tout debut de `bootstrap.sh`, avant tout module. Les cles marquees **optionnel** peuvent etre absentes : le bootstrap continue sans l'integration correspondante.

| Cle | Type | Exemple | Utilise par | Role |
|-----|------|---------|-------------|------|
| `VPS_USER` | string | `alice` | `10_user_ssh.sh` | nom du user sudo a creer |
| `VPS_USER_PASSWORD` | secret | `...` | `10_user_ssh.sh` | mdp sudo du user |
| `SSH_PORT` | int | `45675` | `10_user_ssh.sh`, `30_ufw_crowdsec.sh` | port SSH custom (UFW allow + sshd_config) |
| `SSH_PUBKEY` | string | `ssh-ed25519 AAAA...` | `10_user_ssh.sh` | cle(s) publique(s) pour authorized_keys, plusieurs separees par `\n` |
| `CERTBOT_EMAIL` | string | `toi@exemple.fr` | `75_certbot.sh` | email utilise par certbot pour les notifs d'expiration et l'enregistrement compte ACME Let's Encrypt (synce vers `/etc/letsencrypt/email`) |
| `INFOMANIAK_TOKEN` | secret | `...` | `75_certbot.sh`, `scripts/infomaniak-dns-sync.sh` | token API Infomaniak, synce via l'agent dans `/etc/letsencrypt/infomaniak.ini` pour certbot-dns + DNS auto-sync |
| `CROWDSEC_ENROLL_KEY` | secret | `abcdef1234...` | `30_ufw_crowdsec.sh` | **optionnel** - cle d'enrollment CrowdSec (obtenue sur https://app.crowdsec.net). Si absente, CrowdSec tourne en standalone sans dashboard. |
| `GITHUB_SSH_PRIVKEY` | secret | `-----BEGIN OPENSSH PRIVATE KEY-----\n...` | `15_github_ssh.sh` | **optionnel** - cle SSH privee (ed25519) pour pull de repos GitHub prives. Mettre le contenu complet du fichier `id_ed25519`. La cle publique correspondante doit etre ajoutee sur https://github.com/settings/keys. Si absente, le module skip. |

## `/vps/telegram/` - Notifications

Toutes les alertes et digests Telegram passent par `notify-telegram`, qui fetch ces cles a chaque run.

| Cle | Type | Exemple | Role |
|-----|------|---------|------|
| `TELEGRAM_BOT_TOKEN` | secret | `123456789:AAE-...` | token du bot cree via @BotFather, partage par tous les canaux |
| `TELEGRAM_CHAT_ID` | string | `123456789` | chat ID par defaut (fallback si un script notifie sans `--target`) |
| `TELEGRAM_CHAT_ID_<TARGET>` | string | `-1001234567890` | chat ID specifique pour un canal. Ex: `TELEGRAM_CHAT_ID_AUDIT`, `TELEGRAM_CHAT_ID_BACKUP`, `TELEGRAM_CHAT_ID_CERTBOT`. `notify-telegram --target audit` cherche `TELEGRAM_CHAT_ID_AUDIT`, sinon fallback sur `TELEGRAM_CHAT_ID`. |

## `/services/backup/` - Sauvegarde vers home server

Ces cles sont fetchees **a chaque run** par `backup-run.sh` et `backup-restore.sh`. La cle privee SSH n'atterrit jamais sur disque : elle est piped directement dans `ssh-add` via stdin, vit dans la memoire de `ssh-agent` le temps du run, puis disparait quand l'agent est tue (trap EXIT).

| Cle | Type | Exemple | Role |
|-----|------|---------|------|
| `HOME_SSH_HOST` | string | `home.mondomaine.fr` | FQDN ou IP publique du home server |
| `HOME_SSH_PORT` | int | `22` | port SSH du home |
| `HOME_SSH_USER` | string | `backup` | user SFTP-chroot dedie sur le home |
| `HOME_SSH_PRIVKEY` | secret multiligne | `-----BEGIN OPENSSH PRIVATE KEY-----...` | cle privee ed25519 |
| `RESTIC_REPOSITORY` | string | `sftp:backup@home.mondomaine.fr:/storage` | URL du repo restic (format SFTP) |
| `RESTIC_PASSWORD` | secret | `...` | mdp de chiffrement du repo |
| `BACKUP_PATHS` | string | `/home/choupi/data` | optionnel ; defaut `/home/<VPS_USER>/data` |

Setup cote home server : voir `services/backup/README.md`.

## `/services/pdf/` - Stirling PDF

Service ouvert (pas d'auth). Juste les coordonnees de l'expo.

| Cle | Type | Exemple | Role |
|-----|------|---------|------|
| `ADRESS` | string | `pdf.backlice.dev` | FQDN expose (nginx `server_name` + record DNS A) |
| `DOMAIN` | string | `backlice.dev` | apex du cert wildcard |

## `/services/webhooks/` - GitHub webhooks receiver

| Cle | Type | Exemple | Role |
|-----|------|---------|------|
| `ADRESS` | string | `webhooks.alyss.cc` | FQDN de l'expo |
| `DOMAIN` | string | `alyss.cc` | apex cert wildcard |
| `WEBHOOKS_REPOS` | JSON | `[{"repo":"aliceout/Work-resume","secretEnv":"WORK_SECRET","script":"work.sh"}]` | mapping repo -> secret -> script |
| `<X_SECRET>` | secret | `Attach8-Catfight-...` | HMAC partage avec GitHub, 1 par repo (nomme selon `secretEnv` de WEBHOOKS_REPOS) |

Voir `services/webhooks/README.md` pour l'install et l'ajout de repos.

## `/services/<nom>/` - autres services tiers

### Convention commune : `ADRESS` + `DOMAIN`

Pour TOUT service expose via nginx, on met au minimum ces 2 cles dans son path Infisical :

| Cle | Role |
|-----|------|
| `ADRESS` | FQDN = `server_name` nginx + record DNS A chez Infomaniak |
| `DOMAIN` | apex = chemin du cert wildcard `/etc/letsencrypt/live/<apex>/` |

Ces cles sont referencees dans le `nginx.conf` du service via les placeholders `__ADRESS__` et `__DOMAIN__`. Au moment du `services install <nom>`, `scripts/service.sh` substitue automatiquement.

### Secrets applicatifs

Toute autre cle sous `/services/<nom>/` atterrit aussi dans `/etc/secrets/<nom>.env`. Si le service en a besoin, reference-le dans son `docker-compose.yml` :
```yaml
env_file: /etc/secrets/<nom>.env
```
Toutes les cles deviennent alors des variables d'env du conteneur.

### Template Infisical

Chaque service a un `secrets.tmpl` avec le pattern `listSecrets` → rapatrie tout ce qui est sous `/services/<nom>/`. Donc zero friction pour ajouter une cle : tu ajoutes dans Infisical, l'agent la sync dans `/etc/secrets/<nom>.env`.

Pour chaque service sous `services/<nom>/` dans le repo, cree un path Infisical `/services/<nom>/` avec les secrets dont le service a besoin. Le fichier `services/<nom>/secrets.tmpl` utilise le template agent Infisical pour les rapatrier vers `/etc/secrets/<nom>.env` a l'install.

Convention : declare `INFISICAL_PATH=/services/<nom>` dans `services/<nom>/service.conf` et utilise le pattern recommande dans `secrets.tmpl` (voir `services/README.md`). Toutes les cles sous ce path sont automatiquement syncees sans avoir a les declarer explicitement.

## Machine Identity

Cree une Machine Identity (Universal Auth) sur le projet avec la permission **Read** sur tout (ou au minimum sur `/vps/_infra/` + `/services/**`). Note :

- Client ID
- Client Secret
- Project ID (visible dans l'URL du projet Infisical)

Le bootstrap te les demande au 1er run et les persiste en `/etc/infisical/{client-id,client-secret,project-id,environment}` (chmod 600 pour les deux premiers). Les re-runs les reutilisent automatiquement.

## Verifier les secrets syncs sur le VPS

```bash
# Secrets infra (lus une fois, pas persistes sur disque)
infisical secrets --env=prod --path=/vps/_infra

# Secrets d'un service (synces en continu par l'agent)
cat /etc/secrets/<service>.env    # n'existe que si secrets.tmpl est configure

# Agent status
systemctl status infisical-agent
journalctl -u infisical-agent -n 50
```
