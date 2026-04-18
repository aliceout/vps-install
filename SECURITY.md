# Securite du VPS

Le bootstrap met en place une stack de defense en profondeur. Rien a gerer au quotidien : tout se met a jour tout seul. Ce doc explique **ce qui tourne, comment verifier que c'est actif, et quoi faire si tu te bannis toi-meme par accident**.

## Les couches

```
Internet
   |
   v
[CAA DNS]                      seul Let's Encrypt peut emettre des certs pour tes domaines
   |
   v
[UFW]                          pare-feu, deny par defaut
   |                           allow uniquement : SSH (port custom) + 80/443
   v
[nftables + CrowdSec bouncer]  drop des IPs bannies par CrowdSec
   |
   v
[nginx / sshd]                 les services ecoutent
   |                           nginx a HSTS + headers durcis (security.conf)
   v
[CrowdSec]                     scan les logs et decide qui bannir
   |
   v
[Kernel hardening]             sysctl anti-spoofing, anti-flood, masquage infos
   |
   v
[Audit: rkhunter / debsecan / lynis]   scans reguliers + logs, pas de prise d'action
```

## Ce qui tourne sans intervention

| Automatisme | Frequence | Quoi |
|---|---|---|
| Scan logs SSH/nginx | temps reel | CrowdSec lit `/var/log/auth.log` + logs nginx, detecte brute-force / scans / CVE |
| Blocklists communautaires | toutes les 2h | CrowdSec tire les IPs bannies par la communaute et par ses partenaires (si enrolle) |
| Refresh CrowdSec hub | dimanche 04:42 | `cscli hub update && cscli hub upgrade` - maj des scenarios et parsers |
| Apt update/upgrade | tous les jours 03:17 | `apt-get update` puis `apt-get upgrade -y` |
| Renouvellement certs | quotidien via certbot.timer | Let's Encrypt |
| DNS auto-sync (A + CAA) | toutes les heures | records A Infomaniak alignes sur l'IP publique + CAA (letsencrypt.org) sur chaque apex |
| rkhunter | quotidien 05:15 | scan rootkits -> `/var/log/audit/rkhunter.log` |
| debsecan | quotidien 05:30 | CVE vs paquets installes -> `/var/log/audit/debsecan.log` |
| lynis | dimanche 05:45 | audit complet -> `/var/log/audit/lynis.log` |

## Enrollment CrowdSec Console

La console en ligne (gratuite) te donne :
- un dashboard web pour voir les attaques en temps reel
- les blocklists premium (plus larges que le free tier)
- alerting par email / Slack / Discord

Pour activer :

1. Cree un compte sur https://app.crowdsec.net
2. Ajoute une "Security Engine" dans la console → recupere la cle d'enrollment
3. Mets-la dans Infisical sous `/vps/_infra/CROWDSEC_ENROLL_KEY`
4. Relance le bootstrap OU fais a la main : `sudo cscli console enroll <cle>`
5. Valide la machine depuis la console web

## Verifier que tout marche

```bash
# Status des services
sudo systemctl status crowdsec crowdsec-firewall-bouncer

# Decisions en cours (qui est banni, pour combien de temps)
sudo cscli decisions list

# Metriques (combien de requetes scannees, alertes levees)
sudo cscli metrics

# Collections / parsers / scenarios installes
sudo cscli hub list

# Status de l'enrollment
sudo cscli console status

# UFW
sudo ufw status verbose
```

## Je me suis banni moi-meme, help

Classique : tu as fait trop de tentatives SSH foireuses depuis ton laptop. Si tu as une session ouverte encore, ou un autre acces (KVM du provider, autre IP) :

```bash
# Liste les decisions actives
sudo cscli decisions list

# Unban par IP
sudo cscli decisions delete --ip <ton-ip>

# Ou unban par ID de decision
sudo cscli decisions delete --id <id>
```

Si tu es totalement out, passe par la console VNC/KVM de ton hebergeur.

## Ajouter / retirer une collection CrowdSec

```bash
# Voir ce qui existe
sudo cscli collections list -a

# Installer (ex: wordpress)
sudo cscli collections install crowdsecurity/wordpress

# Desinstaller
sudo cscli collections remove crowdsecurity/wordpress

# Apres n'importe quel changement
sudo systemctl reload crowdsec
```

Les collections de base (`linux`, `sshd`, `nginx`, `base-http-scenarios`, `http-cve`) sont deja installees par le bootstrap.

## Kernel hardening

Config dans `/etc/sysctl.d/99-hardening.conf`. Pour verifier qu'elle est active :

```bash
sudo sysctl net.ipv4.tcp_syncookies    # doit etre 1
sudo sysctl kernel.kptr_restrict       # doit etre 2
sudo sysctl fs.protected_symlinks      # doit etre 1
```

Pour tout voir : `sudo sysctl -a | grep -f <(cut -d= -f1 /etc/sysctl.d/99-hardening.conf | grep -v '^#' | sed 's/ //g')`.

## Pourquoi ce choix ?

- **CrowdSec** plutot que fail2ban : les blocklists sont communautaires et mises a jour en continu, pas un cron qui tire 3 fichiers une fois par jour. Detection HTTP couverte out-of-the-box (brute-force logins web, scanners, CVE connues).
- **UFW + nftables** : UFW pour la conf simple (allow SSH / 80 / 443), nftables comme moteur bas niveau (le bouncer CrowdSec s'integre dedans sans conflit).
- **Kernel sysctl** : durcissement gratuit, set-and-forget.
- **Pas d'unattended-upgrades** : le cron `apt upgrade` en place est suffisant et evite le comportement de reboot forcee d'unattended-upgrades.

## Lire les rapports d'audit

```bash
# Rootkits / anomalies systeme (rkhunter)
sudo tail -n 100 /var/log/audit/rkhunter.log

# CVE non patchees (debsecan)
sudo tail -n 50 /var/log/audit/debsecan.log

# Audit systeme complet (lynis)
sudo tail -n 50 /var/log/audit/lynis.log
# Score et recommandations:
sudo lynis show report /var/log/audit/lynis-report.dat
```

Les rapports sont gardes 8 semaines (logrotate weekly rotate=8).

## HSTS

Le include `/etc/nginx/include/security.conf` (present sur TOUS les vhosts) ajoute :
```
Strict-Transport-Security: max-age=63072000; includeSubDomains
```
= 2 ans de force-HTTPS apres la 1ere visite.

## Record CAA (DNS)

Le sync DNS Infomaniak (`infomaniak-dns-sync`, cron horaire) cree automatiquement un record CAA sur chaque apex qu'il rencontre :
```
<apex>  CAA  0 issue "letsencrypt.org"
```
= seul Let's Encrypt peut emettre des certs pour ce domaine. Si un attaquant pirate ton DNS et tente d'aller chez un autre CA, le CA refusera l'emission.

## Ce qui n'est PAS fait

- Pas de backup offsite (volontaire tant qu'aucune donnee persistante n'est hebergee).
- Pas de WAF niveau applicatif type ModSecurity (CrowdSec + appsec couvre l'essentiel).
- Pas de AIDE / auditd (file integrity monitoring) : overkill pour un VPS perso.
- Pas de 2FA SSH : on assume que ta cle privee est protegee sur ton laptop. Si tu veux un cran au-dessus, ajoute `pam_google_authenticator`.
- Pas d'alerting CrowdSec (email / Discord) : a activer a la main via `cscli notifications` si besoin.
