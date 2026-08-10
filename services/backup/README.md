# backup — rsync miroir VPS → home server

Sauvegarde des donnees du VPS en miroir rsync vers un dossier dedie sur le home server.

Pas de chiffrement, pas de dedup, pas de snapshots cote VPS : c'est juste un miroir. L'historique est gere **cote home** par le backup Borg qui snapshot ce dossier (cf. `services/backup/install.sh` variante `install_server`).

## Convention data

Tout ce qui doit etre sauvegarde vit sous `/home/$VPS_USER/data/<service>/`. Chaque service declare son `DATA_DIR` dans son `service.conf` et monte ses volumes la-dedans.

Ce qui n'est **pas** sauvegarde :
- `/var/lib/services/<name>/` : stuff operationnel (hooks, logs runtime) — regenerable
- `/etc/nginx/conf/` : vhosts generes depuis le repo
- `/etc/letsencrypt/live/` : certs renouvelables
- `/etc/infisical/` : creds rederivables depuis Infisical cloud
- `/var/www/<name>/` : code build from git

Bref, infra dans le repo + Infisical ; backups uniquement pour la **donnee d'utilisation**.

## Securite de la cle SSH

La cle privee SSH ne touche **jamais** le disque cote VPS :

1. `backup-rsync.sh` fetch la cle depuis Infisical (`infisical secrets get --plain`)
2. La pipe directement dans `ssh-add -` (stdin → memoire de l'agent)
3. `rsync -e ssh` utilise `SSH_AUTH_SOCK` de l'agent pour s'authentifier
4. En fin de run (ou crash via trap), `ssh-agent -k` tue l'agent et la cle disparait de la RAM

Seule fenetre : root sur le VPS pendant un run de backup peut dumper la RAM de ssh-agent. Mitigation : meme si la cle fuit, le user `backup-vps` cote home est restreint en SFTP-chroot et ne voit que son propre dossier ; et Borg cote home snapshote, donc les versions anterieures sont protegees.

## Install

```bash
services install backup
```

Ca :
- Installe `rsync` + `openssh-client`
- Cree `/home/$VPS_USER/data/` (owned by $VPS_USER)
- Deploie `/usr/local/sbin/backup-rsync` et `backup-restore` (symlinks vers le repo)
- Cron 4x/jour (00:15, 06:15, 12:15, 18:15)
- Logrotate hebdo

## Secrets Infisical — `/infra/vps/backup/`

(convention infra du repo, comme `/infra/vps/GITHUB_SSH_PRIVKEY`, `/infra/<host>/GHCR_TOKEN`, etc.)

| Cle | Type | Exemple | Role |
|-----|------|---------|------|
| `HOME_SSH_HOST` | string | `vault.alyss.cc` | domaine (ou IP) du home. Un domaine deja suivi par le dns-sync du home = DDNS gratuit (pas d'IP a maintenir a la main) |
| `HOME_SSH_USER` | string | `backup-vps` | user dedie cote home |
| `HOME_SSH_PRIVKEY` | secret multiligne | `-----BEGIN OPENSSH PRIVATE KEY-----...` | cle privee ed25519 (jamais ecrite sur disque VPS) |
| `REMOTE_PATH` | string | `/media/pi/data/vps-mirror` | dossier de destination cote home (doit etre dans le scope de Borg) |
| `SOURCE_PATH` | string | `/home/choupi/data` | optionnel, defaut `/home/$VPS_USER/data` |
| `HOME_SSH_PORT` | int | `2222` | optionnel. A defaut, le script lit `SSH_PORT` sous `/infra/server`, sinon 22 |

## Setup cote home server — RECEPTION (automatise)

Depuis `install_server`, la reception des backups pousses par le VPS est
configuree **automatiquement** des que `BACKUP_VPS_PUBKEY` est present dans
Infisical `/infra/server/`. Plus de setup manuel : le service cree le user
dedie, le dossier, la traversee des parents, le `authorized_keys` restreint a
`rrsync`, et le drop-in sshd `AllowUsers`.

### Cles Infisical `/infra/server/` (lisibles par le home)

| Cle | Requis | Defaut | Role |
|-----|--------|--------|------|
| `BACKUP_VPS_PUBKEY` | oui | — | pubkey SSH autorisee a pousser (publique). Sa presence **active** la reception |
| `BACKUP_VPS_DEST` | non | `/media/pi/data/vps-mirror` | dossier de destination (doit etre dans le scope Borg) |
| `BACKUP_VPS_USER` | non | `backup-vps` | user de reception |

### Etapes

1. **Genere la paire de cles** (une fois) :
   ```bash
   ssh-keygen -t ed25519 -f ~/vps-backup -N '' -C "vps-to-home-backup"
   ```
   - la **privee** (`~/vps-backup`) → Infisical `/infra/vps/backup/HOME_SSH_PRIVKEY`
   - la **publique** (`~/vps-backup.pub`) → Infisical `/infra/server/BACKUP_VPS_PUBKEY`
     (ou derive-la de la privee : `ssh-keygen -y -f ~/vps-backup`)

2. **Cote home** : `sudo /opt/vps-install/scripts/service.sh install backup`
   (ou `update backup` si deja installe) → configure le receiver tout seul.

3. **Scope Borg** : par defaut `/media/pi/data/vps-mirror` est deja couvert si
   Borg sauvegarde `/media/pi/data`. Sinon, ajoute-le dans
   `/etc/server-backup/backup-borg.env` (`BORG_FOLDERS`).

4. **Cote VPS** : renseigne `/infra/vps/backup/` (voir table plus haut), puis
   `sudo /opt/vps-install/scripts/service.sh install backup` et teste :
   `sudo /usr/local/sbin/hc-run backup /usr/local/sbin/backup-rsync`.

> **Ce que le receiver automatique pose** (equivalent du setup manuel d'avant) :
> user dedie (shell reel + password verrouille, cle only), dossier `-m 750`,
> `chmod o+x` sur les parents pour la traversee (ex `/media/pi` en `700 pi:pi`
> bloque sinon), `authorized_keys` avec `command="rrsync <dest>"` (la cle est
> confinee a du rsync dans ce seul dossier), et drop-in sshd
> `20-backup-vps.conf` (`AllowUsers` cumulatif, ne touche pas le drop-in du
> module 10).
>
> **Note automontage** : si `<dest>` est sous `/media/pi` (udisks), le
> `chmod o+x` peut sauter a un remontage du disque → passe-le en `/etc/fstab`
> pour un montage stable.

## Restore

### Automatique a l'install d'un service

Dans `service.conf` du service :
```
DATA_DIR="/home/$VPS_USER/data/<nom>"
RESTORE_ON_INSTALL="yes"
```

Au `services install <nom>`, si `DATA_DIR` est vide, `service.sh` appelle `backup-restore "$DATA_DIR"` qui pull l'etat courant depuis le miroir home. Si le dossier contient deja des donnees, la restore est skip (safety).

⚠️ La restore automatique ne ramene que **l'etat courant** du miroir. Pour un retour arriere a un point dans le passe, faut piocher manuellement dans les snapshots Borg cote home.

### Manuelle (state courant)

```bash
sudo backup-restore /home/choupi/data/ghost
```

### Manuelle (snapshot historique via Borg cote home)

Sur le home server :
```bash
sudo borg list /path/to/borg/repo
sudo borg extract /path/to/borg/repo::vps-mirror-YYYY-MM-DD_HH-MM data/backups/vps-mirror/ghost
# puis rsync vers le VPS si besoin
```

## Debug

```bash
# Log du cron
sudo tail -f /var/log/vps-backup.log

# Run manuel
sudo backup-rsync

# Lister ce qui est cote home
sudo -E rsync --list-only -e "ssh -p $PORT -i /tmp/k" backup-vps@home:/data/backups/vps-mirror/
```

## Remove

```bash
services remove backup
```

Stoppe le cron et retire les scripts locaux. **Ne touche pas au miroir cote home** (a vider manuellement si besoin).
