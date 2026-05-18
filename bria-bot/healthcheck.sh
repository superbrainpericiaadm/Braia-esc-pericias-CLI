#!/bin/bash
# Health-check da arquitetura Bria v3 (bot externo + claude code)
# Roda a cada 2 min via cron. Alerta no Telegram do Chefe se algo crashar.
# Auto-restart de servicos parados.

LOG=/opt/bria-bot/logs/healthcheck.log
TOKEN=$(grep ^TELEGRAM_BOT_TOKEN= /opt/bria-bot/.env | cut -d= -f2-)
CHAT_ID=$(grep ^ALLOWED_USERS= /opt/bria-bot/.env | cut -d= -f2- | cut -d, -f1)
ALERT_FILE=/tmp/bria-health-last-alert
NOW=$(date '+%Y-%m-%d %H:%M:%S')

log() { echo "[$NOW] $*" >> "$LOG"; }

alert() {
    local msg="$1"
    # Throttle: nao manda mesmo alerta mais de 1x a cada 5 minutos
    local key=$(echo "$msg" | md5sum | cut -c1-16)
    local last=$(grep "^$key:" "$ALERT_FILE" 2>/dev/null | cut -d: -f2)
    local now_ts=$(date +%s)
    if [ -n "$last" ] && [ $((now_ts - last)) -lt 300 ]; then
        log "alert SUPPRESSED (throttled): $msg"
        return
    fi
    grep -v "^$key:" "$ALERT_FILE" 2>/dev/null > "${ALERT_FILE}.tmp" || true
    echo "$key:$now_ts" >> "${ALERT_FILE}.tmp"
    mv "${ALERT_FILE}.tmp" "$ALERT_FILE"

    log "ALERT: $msg"
    curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        --data-urlencode "text=⚠️ BRIA HEALTH ALERT: ${msg}" \
        > /dev/null 2>&1 || true
}

# Check 1: bot Python esta rodando?
if ! systemctl is-active --quiet bria-telegram-bot; then
    alert "Bot Python parado. Reiniciando..."
    systemctl restart bria-telegram-bot
fi

# Check 2: Bria Claude Code esta rodando?
if ! systemctl is-active --quiet bria-agent; then
    alert "Bria Claude parada. Reiniciando..."
    systemctl restart bria-agent
fi

# Check 3: claude --continue do Bria esta rodando dentro do tmux?
if ! pgrep -u bria -f 'claude --continue' >/dev/null; then
    alert "Processo claude da Bria nao encontrado. Reiniciando bria-agent..."
    systemctl restart bria-agent
fi

# Check 4: tmux session bria existe?
if ! sudo -u bria tmux has-session -t bria 2>/dev/null; then
    alert "tmux session bria nao existe. Reiniciando bria-agent..."
    systemctl restart bria-agent
fi

log "OK - tudo saudavel"
