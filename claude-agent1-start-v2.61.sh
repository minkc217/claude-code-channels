#!/bin/bash
TMUX_SOCKET=/tmp/tmux-claude-agent1
START_LOG=/home/hsy/claude-agent1-start.log

# 모델 설정 (2026-04-18 Phase 2 + 폴백)
# PERMANENT_MODEL: 영구 모델. 빈 값이면 --model 플래그 생략 (claude 기본값 Opus 4.7 사용)
PERMANENT_MODEL="claude-opus-4-7"
# TEMP_OVERRIDE_FILE: 1회성 임시 모델 오버라이드 (읽고 즉시 삭제)
TEMP_OVERRIDE_FILE="/tmp/claude-agent1-model-override"

# 텔레그램 알림 (폴백 발생 시)
ENV_FILE="/home/hsy/.claude/channels/telegram/.env"
notify_telegram() {
  if [ -f "$ENV_FILE" ]; then
    local token=$(grep '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" | cut -d'=' -f2)
    local chat=$(grep '^TELEGRAM_CHAT_ID=' "$ENV_FILE" | cut -d'=' -f2)
    if [ -n "$token" ] && [ -n "$chat" ]; then
      curl -s -m 10 "https://api.telegram.org/bot${token}/sendMessage" \
        -d "chat_id=${chat}" --data-urlencode "text=$1" > /dev/null 2>&1
    fi
  fi
}

log() {
  echo "[$(date -Iseconds)] $1" | tee -a "$START_LOG"
}

export BUN_INSTALL="/home/hsy/.bun"
export PATH="$BUN_INSTALL/bin:/home/hsy/.local/bin:/usr/local/bin:/usr/bin:/bin"
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
# 자동 업데이터 차단 (2026-04-26: 2.1.120+ 호환성 이슈로 119 고정)
export DISABLE_AUTOUPDATER=1
# 119 고정 절대경로 (심링크 무시)
CLAUDE_BIN="/home/hsy/.local/share/claude/versions/2.1.119"
tmux -S $TMUX_SOCKET kill-session -t claude-agent1 2>/dev/null || true
pkill -9 -f "claude.*--channels" 2>/dev/null || true
pkill -9 -f "telegram.*start" 2>/dev/null || true
pkill -9 -f "bun server.ts" 2>/dev/null || true
sleep 2

# Groq 음성 패치 자가 복구
if [ -x /home/hsy/claude-agent1-voice-patch.py ]; then
  python3 /home/hsy/claude-agent1-voice-patch.py 2>&1 | grep -v "^$" || true
fi

# 시도할 모델 순서: 임시 → 영구 → 기본(플래그 없음)
ATTEMPT_LABELS=()
ATTEMPT_FLAGS=()
if [ -f "$TEMP_OVERRIDE_FILE" ]; then
  TEMP_MODEL=$(head -1 "$TEMP_OVERRIDE_FILE" | tr -d '[:space:]')
  rm -f "$TEMP_OVERRIDE_FILE"
  if [ -n "$TEMP_MODEL" ]; then
    ATTEMPT_LABELS+=("temp:$TEMP_MODEL")
    ATTEMPT_FLAGS+=("--model $TEMP_MODEL")
  fi
fi
if [ -n "$PERMANENT_MODEL" ]; then
  ATTEMPT_LABELS+=("permanent:$PERMANENT_MODEL")
  ATTEMPT_FLAGS+=("--model $PERMANENT_MODEL")
fi
ATTEMPT_LABELS+=("default")
ATTEMPT_FLAGS+=("")

cd /home/hsy/agent1

SUCCESS=false
for i in "${!ATTEMPT_LABELS[@]}"; do
  LABEL="${ATTEMPT_LABELS[$i]}"
  FLAG="${ATTEMPT_FLAGS[$i]}"
  log "기동 시도 [$((i+1))/${#ATTEMPT_LABELS[@]}]: $LABEL"

  tmux -S $TMUX_SOCKET kill-session -t claude-agent1 2>/dev/null || true
  pkill -9 -f "claude.*--channels" 2>/dev/null || true
  sleep 1

  tmux -u -S $TMUX_SOCKET new-session -d -s claude-agent1 \
    "$CLAUDE_BIN --continue --fork-session $FLAG --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions"

  sleep 6
  if pgrep -f "claude.*--channels" > /dev/null 2>&1; then
    log "기동 성공: $LABEL"
    SUCCESS=true
    if [ "$i" -gt 0 ]; then
      notify_telegram "⚠️ [ALERT type=model_fallback severity=warning] 모델 [${ATTEMPT_LABELS[0]}] 기동 실패 → [$LABEL] 폴백 성공"
    fi
    break
  fi
  log "기동 실패: $LABEL (5초 내 프로세스 미확인)"
done

if [ "$SUCCESS" = false ]; then
  log "모든 기동 시도 실패"
  notify_telegram "🚨 [ALERT type=start_fail severity=critical] start.sh: 모든 모델 시도 실패, watchdog 개입 필요"
fi

sleep 2
chmod 700 $TMUX_SOCKET 2>/dev/null || true
tmux -S $TMUX_SOCKET ls 2>&1 | tee -a "$START_LOG"
