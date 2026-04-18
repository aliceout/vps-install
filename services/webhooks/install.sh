#!/usr/bin/env bash
set -euo pipefail

# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER

DATA_DIR="/var/lib/services/$SERVICE_NAME"
HOOKS_DIR="$DATA_DIR/hooks"
LOG_DIR="$DATA_DIR/log"
HOOKS_ENV_DIR="/etc/secrets/$SERVICE_NAME"          # un .env par hook
UNIT="/etc/systemd/system/${SERVICE_NAME}.service"

INFISICAL_PATH="/services/${SERVICE_NAME}"

: "${VPS_USER:?VPS_USER manquant}"

# --- Helpers Infisical -------------------------------------------------------

infi_login() {
  local cid csec
  cid="$(cat /etc/infisical/client-id)"
  csec="$(cat /etc/infisical/client-secret)"
  infisical login --method=universal-auth \
    --client-id="$cid" --client-secret="$csec" \
    --plain --silent
}

list_subfolders() {
  local path="$1" token pid env
  pid="$(cat /etc/infisical/project-id)"
  env="$(cat /etc/infisical/environment)"
  token="$(infi_login)"

  # `infisical secrets folders get` sort un tableau en Unicode box drawing
  # (│, ─, ┌, etc.). On filtre les lignes de donnees (qui commencent par │)
  # et on extrait la 1ere colonne (le nom du folder).
  infisical secrets folders get \
    --projectId="$pid" --env="$env" --path="$path" \
    --token="$token" 2>/dev/null \
    | awk '
        /^│/ && !/FOLDER NAME/ {
          n = split($0, parts, "│")
          if (n >= 2) {
            name = parts[2]
            gsub(/^[ \t]+|[ \t]+$/, "", name)
            if (name != "") print name
          }
        }' \
    | sort -u
}

# --- Generation des templates Infisical agent --------------------------------

generate_agent_templates() {
  local pid env
  pid="$(cat /etc/infisical/project-id)"
  env="$(cat /etc/infisical/environment)"

  # Template "main" du service (ADRESS, DOMAIN au niveau /services/webhooks/)
  cat > /etc/infisical/templates/_${SERVICE_NAME}.tmpl <<EOF
{{- with listSecrets "${pid}" "${env}" "${INFISICAL_PATH}" }}
{{- range . }}
{{ .Key }}={{ .Value }}
{{- end }}
{{- end }}
EOF

  # Init le fragment agent.d avec le sink "main"
  cat > /etc/infisical/agent.d/_${SERVICE_NAME}.yaml <<EOF
  - source-path: /etc/infisical/templates/_${SERVICE_NAME}.tmpl
    destination-path: ${SECRETS_FILE}
    config:
      polling-interval: 60s
EOF

  # Un template + sink par sous-dossier (work, nodea, ...)
  local subfolders
  subfolders="$(list_subfolders "$INFISICAL_PATH")"

  if [[ -z "$subfolders" ]]; then
    echo "AVERTISSEMENT: aucun sous-dossier sous ${INFISICAL_PATH}, le webhook server n'aura aucun repo configure."
  else
    while IFS= read -r sub; do
      [[ -z "$sub" ]] && continue
      cat > /etc/infisical/templates/_${SERVICE_NAME}_${sub}.tmpl <<EOF
{{- with listSecrets "${pid}" "${env}" "${INFISICAL_PATH}/${sub}" }}
{{- range . }}
{{ .Key }}={{ .Value }}
{{- end }}
{{- end }}
EOF
      cat >> /etc/infisical/agent.d/_${SERVICE_NAME}.yaml <<EOF
  - source-path: /etc/infisical/templates/_${SERVICE_NAME}_${sub}.tmpl
    destination-path: ${HOOKS_ENV_DIR}/${sub}.env
    config:
      polling-interval: 60s
EOF
      echo "  + sous-dossier '${sub}' -> ${HOOKS_ENV_DIR}/${sub}.env"
    done <<< "$subfolders"
  fi

  chmod 600 /etc/infisical/agent.d/_${SERVICE_NAME}.yaml

  # Reconstruit la conf agent globale
  cp /etc/infisical/agent.base.yaml /etc/infisical/agent.yaml
  shopt -s nullglob
  for f in /etc/infisical/agent.d/*.yaml; do
    cat "$f" >> /etc/infisical/agent.yaml
  done
  shopt -u nullglob
  chmod 600 /etc/infisical/agent.yaml

  systemctl restart infisical-agent
}

# --- Actions -----------------------------------------------------------------

case "$ACTION" in
  install|update)
    install -d -m 755 -o "$VPS_USER" -g "$VPS_USER" "$DATA_DIR" "$HOOKS_DIR" "$LOG_DIR"
    install -d -m 700 -o root -g root "$HOOKS_ENV_DIR"
    install -m 644 -o "$VPS_USER" -g "$VPS_USER" "$SERVICE_DIR/app.js" "$DATA_DIR/app.js"

    if [[ -d "$SERVICE_DIR/hooks" ]]; then
      shopt -s nullglob
      for h in "$SERVICE_DIR/hooks/"*.sh; do
        install -m 755 -o "$VPS_USER" -g "$VPS_USER" "$h" "$HOOKS_DIR/$(basename "$h")"
      done
      shopt -u nullglob
      echo "Hook scripts deployes dans $HOOKS_DIR/"
    fi

    echo "Generation des templates Infisical (1 par sous-dossier)..."
    generate_agent_templates

    # Attend que les sinks aient rendu les fichiers une fois
    echo "Attente synchro initiale..."
    for i in $(seq 1 20); do
      [[ -s "$SECRETS_FILE" ]] && break
      sleep 1
    done

    cat > "$UNIT" <<EOF
[Unit]
Description=GitHub webhooks receiver
After=network-online.target infisical-agent.service
Wants=network-online.target
Requires=infisical-agent.service

[Service]
Type=simple
User=${VPS_USER}
Group=${VPS_USER}
WorkingDirectory=${DATA_DIR}
EnvironmentFile=${SECRETS_FILE}
Environment=HOOKS_DIR=${HOOKS_DIR}
Environment=LOG_DIR=${LOG_DIR}
Environment=HOOKS_ENV_DIR=${HOOKS_ENV_DIR}
ExecStart=/usr/bin/node ${DATA_DIR}/app.js
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${DATA_DIR}
ReadOnlyPaths=${HOOKS_ENV_DIR}
ProtectHome=read-only
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$UNIT"

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service" >/dev/null
    systemctl restart "${SERVICE_NAME}.service"

    echo
    echo "Webhooks service demarre."
    echo "Pour ajouter un repo : cree un sous-dossier dans Infisical sous"
    echo "  ${INFISICAL_PATH}/<nom>/ avec REPO, SECRET, SCRIPT, puis"
    echo "  services update webhooks pour reenregistrer les templates."
    ;;

  remove)
    systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "$UNIT"
    rm -f /etc/infisical/agent.d/_${SERVICE_NAME}.yaml
    rm -f /etc/infisical/templates/_${SERVICE_NAME}.tmpl
    rm -f /etc/infisical/templates/_${SERVICE_NAME}_*.tmpl
    rm -rf "$HOOKS_ENV_DIR"

    cp /etc/infisical/agent.base.yaml /etc/infisical/agent.yaml
    shopt -s nullglob
    for f in /etc/infisical/agent.d/*.yaml; do cat "$f" >> /etc/infisical/agent.yaml; done
    shopt -u nullglob
    chmod 600 /etc/infisical/agent.yaml
    systemctl restart infisical-agent

    systemctl daemon-reload
    echo "Service arrete + templates Infisical retires. Data preservee dans ${DATA_DIR}."
    ;;

  status)
    systemctl status "${SERVICE_NAME}.service" --no-pager || true
    echo
    echo "Hooks env files :"
    ls -la "$HOOKS_ENV_DIR/" 2>/dev/null || echo "  (vide)"
    ;;

  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
