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
        LE_EMAIL
        INFOMANIAK_TOKEN
        CROWDSEC_ENROLL_KEY  # optionnel
    services/
      pdf/                 # Stirling PDF
        LANGS
        DOCKER_ENABLE_SECURITY
        INSTALL_BOOK_AND_ADVANCED_HTML_OPS
        SECURITY_INITIALLOGIN_USERNAME
        SECURITY_INITIALLOGIN_PASSWORD
      <service>/           # charge a l'install du service via scripts/service.sh
        ...
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
| `LE_EMAIL` | string | `toi@exemple.fr` | `75_certbot.sh` | email Let's Encrypt (ecrit dans `/etc/letsencrypt/email`) |
| `INFOMANIAK_TOKEN` | secret | `...` | `75_certbot.sh`, `scripts/infomaniak-dns-sync.sh` | token API Infomaniak, synce via l'agent dans `/etc/letsencrypt/infomaniak.ini` pour certbot-dns + DNS auto-sync |
| `CROWDSEC_ENROLL_KEY` | secret | `abcdef1234...` | `30_ufw_crowdsec.sh` | **optionnel** - cle d'enrollment CrowdSec (obtenue sur https://app.crowdsec.net). Si absente, CrowdSec tourne en standalone sans dashboard. |

## `/services/pdf/` - Stirling PDF

Les cles sont copies tel quel dans `/etc/secrets/pdf.env` (nom de cle = variable d'env consommee par l'image `frooodle/s-pdf`).

| Cle | Type | Exemple | Role |
|-----|------|---------|------|
| `LANGS` | string | `en_GB` ou `fr_FR,en_GB` | langues OCR |
| `DOCKER_ENABLE_SECURITY` | bool | `true` | active le login integre de Stirling - **recommande si expose** |
| `INSTALL_BOOK_AND_ADVANCED_HTML_OPS` | bool | `false` | installe calibre + outils eBook (lourd) |
| `SECURITY_INITIALLOGIN_USERNAME` | string | `alice` | user admin cree au premier lancement |
| `SECURITY_INITIALLOGIN_PASSWORD` | secret | `...` | mdp admin initial (a changer via l'UI apres le premier login) |

## `/services/<nom>/` - autres services tiers

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
