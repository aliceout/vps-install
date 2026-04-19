# backup — Restic push ephemere vers home server

Sauvegarde incrementale + chiffree de `/home/$VPS_USER/data/` (racine de toutes les donnees persistantes des services) vers un repo restic heberge sur ton home server, via SFTP.

## Convention data

Tout ce qui doit etre sauvegarde vit sous `/home/$VPS_USER/data/<service>/`.
Chaque service declare son `DATA_DIR` dans son `service.conf` et monte ses volumes la-dedans (ex: `services/pdf/` utilise `/home/choupi/data/pdf/configs/`, etc.).

Ce qui n'est **pas** sauvegarde :
- `/var/lib/services/<name>/` : stuff operationnel (hooks, logs runtime) — regenerable
- `/etc/nginx/conf/` : vhosts generes depuis le repo
- `/etc/letsencrypt/live/` : certs renouvelables
- `/etc/infisical/` : creds rederivables depuis Infisical cloud
- `/var/www/<name>/` : code build from git

Bref, tout ce qui est infrastructure est dans le repo `vps-install` + Infisical ; les backups couvrent uniquement la **donnee d'utilisation**.

## Securite de la cle SSH

La cle privee SSH qui permet au VPS de se connecter au home **n'est jamais ecrite sur disque**. Le pattern :

1. `backup-run.sh` fetch la cle depuis Infisical via `infisical secrets get --plain`
2. La pipe directement dans `ssh-add -` (stdin -> memoire de l'agent)
3. `restic` utilise `SSH_AUTH_SOCK` de l'agent pour authentifier le SFTP
4. A la fin (ou en cas de crash), `ssh-agent -k` tue l'agent et la cle disparait de la RAM

Seule fenetre d'attaque : un attaquant root pendant un run de backup peut dumper la RAM de ssh-agent. Mitigation : le home server a ses propres snapshots/RAID/disque externe, donc meme si la cle fuit et que l'attaquant trash les backups courants, tu restores depuis les snapshots home.

## Install

```bash
services install backup
```

Ca :
- Installe `restic` + `openssh-client`
- Cree `/home/$VPS_USER/data/` (owned by $VPS_USER)
- Deploie `/usr/local/sbin/backup-run` et `backup-restore` (symlinks vers le repo)
- Cron 4x/jour (00:15, 06:15, 12:15, 18:15) : `backup-run >> /var/log/vps-backup.log`
- Logrotate hebdo

Au premier run, le repo restic est initialise automatiquement si absent.

## Secrets Infisical - `/services/backup/`

| Cle | Type | Exemple | Role |
|-----|------|---------|------|
| `HOME_SSH_HOST` | string | `home.mondomaine.fr` | FQDN ou IP publique du home |
| `HOME_SSH_PORT` | int | `22` | port SSH du home |
| `HOME_SSH_USER` | string | `backup` | user dedie sur le home |
| `HOME_SSH_PRIVKEY` | secret multiligne | `-----BEGIN OPENSSH PRIVATE KEY-----...` | cle privee ed25519 (jamais ecrite sur disque VPS) |
| `RESTIC_REPOSITORY` | string | `sftp:backup@home.mondomaine.fr:/storage/vps-restic` | URL restic, format SFTP |
| `RESTIC_PASSWORD` | secret | `...` | mdp de chiffrement du repo restic |
| `BACKUP_PATHS` | string | `/home/choupi/data` | optionnel, defaut `/home/$VPS_USER/data` |

## Setup cote home server (a faire une fois)

### 1. Genere une cle SSH dediee (sur ton laptop, pas sur le home)

```bash
ssh-keygen -t ed25519 -f ~/vps-backup -N '' -C "vps-to-home-backup"
cat ~/vps-backup.pub     # a coller en step 3
cat ~/vps-backup         # a coller dans Infisical (HOME_SSH_PRIVKEY)
```

### 2. Sur le home server, cree un user dedie

```bash
sudo useradd -m -s /usr/sbin/nologin backup
sudo mkdir -p /home/backup/.ssh
sudo chmod 700 /home/backup/.ssh
```

### 3. Colle la cle publique dans son authorized_keys

```bash
sudo -u backup tee /home/backup/.ssh/authorized_keys <<'EOF'
ssh-ed25519 AAAAC3Nza... vps-to-home-backup
EOF
sudo chmod 600 /home/backup/.ssh/authorized_keys
```

### 4. Cree le dossier qui hebergera le repo restic

```bash
sudo mkdir -p /storage/vps-restic
sudo chown backup:backup /storage/vps-restic
sudo chmod 700 /storage/vps-restic
```

### 5. Restreins le user `backup` a du SFTP chroot

Dans `/etc/ssh/sshd_config.d/backup.conf` (ou en fin de `sshd_config`) :

```
Match User backup
    ChrootDirectory /home/backup
    ForceCommand internal-sftp
    AllowTcpForwarding no
    PermitTTY no
    X11Forwarding no
```

**Attention** : `ChrootDirectory` exige que le dossier soit owned par root et non world-writable. Si tu ne respectes pas cette contrainte, sshd refuse le login.

```bash
sudo chown root:root /home/backup
sudo chmod 755 /home/backup
```

Puis cree un sous-dossier writable par `backup` pour le repo restic (via bind mount ou en remapant `RESTIC_REPOSITORY` sur un path relatif au chroot) :

```bash
sudo mkdir -p /home/backup/storage
sudo chown backup:backup /home/backup/storage
sudo mount --bind /storage/vps-restic /home/backup/storage
# Ajoute a /etc/fstab pour persistance :
echo "/storage/vps-restic /home/backup/storage none bind 0 0" | sudo tee -a /etc/fstab
```

Du coup dans Infisical, `RESTIC_REPOSITORY` devient :
```
sftp:backup@home.mondomaine.fr:/storage
```
(chemin vu a travers le chroot depuis `backup`).

Restart sshd :
```bash
sudo systemctl restart ssh
```

### 6. Test depuis ton laptop

```bash
ssh -i ~/vps-backup -p 22 backup@home.mondomaine.fr
# Devrait dire "This service allows sftp connections only."
sftp -i ~/vps-backup -P 22 backup@home.mondomaine.fr
# La tu dois pouvoir ls /storage
```

Si c'est OK, pose la cle privee dans Infisical et `services install backup` sur le VPS.

## Restore

### Automatique a l'install d'un service

Declare dans le `service.conf` :
```
DATA_DIR="/home/$VPS_USER/data/<nom>"
RESTORE_ON_INSTALL="yes"
```

Au `services install <nom>`, si `DATA_DIR` est vide, `service.sh` appelle `backup-restore "$DATA_DIR"` qui pioche le dernier snapshot et restaure pile a cet endroit. Si le dossier contient deja des donnees, la restore est skip (safety).

### Manuelle

```bash
# Restore du dernier snapshot pour un path donne
sudo backup-restore /home/choupi/data/ghost

# Ou pour inspecter les snapshots dispos
sudo -E bash -c '
  source /etc/secrets/backup.env 2>/dev/null || true
  [...]   # fetch via infisical.secrets.get comme dans backup-run
  restic snapshots
'
```

## Debug

```bash
# Log du cron
sudo tail -f /var/log/vps-backup.log

# Run manuel
sudo backup-run

# Snapshots
sudo -E restic snapshots --option sftp.args="-p 22 -o StrictHostKeyChecking=accept-new"
```

## Remove

```bash
services remove backup
```

Stoppe le cron et retire les scripts locaux. **Ne touche pas au repo restic cote home** (tu le videras manuellement si tu veux).
