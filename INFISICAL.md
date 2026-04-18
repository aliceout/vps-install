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
    services/
      pdf/                 # Stirling PDF (charge a l'install du service)
        ADRESS             # FQDN de l'expo
        DOMAIN             # apex (cert wildcard)
      <service>/           # autres services, meme convention
        ADRESS
        DOMAIN
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

## `/services/pdf/` - Stirling PDF

Service ouvert (pas d'auth). Juste les coordonnees de l'expo.

| Cle | Type | Exemple | Role |
|-----|------|---------|------|
| `ADRESS` | string | `pdf.backlice.dev` | FQDN expose (nginx `server_name` + record DNS A) |
| `DOMAIN` | string | `backlice.dev` | apex du cert wildcard |

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
