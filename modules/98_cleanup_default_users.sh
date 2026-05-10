#!/usr/bin/env bash
set -euo pipefail

# Fallback quand le module tourne standalone (sans bootstrap.sh qui exporte VPS_USER).
VPS_USER="${VPS_USER:-$(cat /etc/infisical/vps-user 2>/dev/null || true)}"

# Supprime les users par defaut laisses par le provider VPS (debian, ubuntu,
# admin, ...) s'ils existent ET ne sont pas le $VPS_USER qu'on vient de creer.
#
# Safe : le bootstrap tourne en root (via sudo), donc le process n'est pas
# lie a debian. Les sessions SSH debian actives survivent a userdel (elles
# seront coupees au reboot final qui suit juste apres).

DEFAULT_USERS=(debian ubuntu admin centos ec2-user)

for user in "${DEFAULT_USERS[@]}"; do
  if [[ "$user" == "$VPS_USER" ]]; then
    continue
  fi
  if id "$user" >/dev/null 2>&1; then
    echo "Suppression du user par defaut: $user"
    # -r : supprime home + spool mail
    # -f : force meme si utilisateur a des process (attention : ne kill pas
    #      les sessions SSH actives, le reboot qui suit s'en chargera)
    userdel -r -f "$user" 2>/dev/null || {
      # Si userdel refuse (p.ex. user a un cron actif), on nettoie au minimum :
      # le retire des groupes sudo + de sshd AllowUsers (si configure)
      gpasswd -d "$user" sudo 2>/dev/null || true
      usermod -L "$user" 2>/dev/null || true
      echo "AVERTISSEMENT: $user pas totalement supprime, mais lock+sudoers retire."
    }
  fi
done
