#!/bin/bash
# Claude Code 자동 설정 스크립트 v2.5
# 사용법: bash claude-setup-v2.5.sh
# 전제조건: Claude Code가 이미 설치되어 있고 로그인 완료 상태
#
# v2.0 변경사항:
#   - Watchdog 강화: 텔레그램 헬스체크(getMe + 프로세스 상태), 재시작 루프 방지, 상세 로깅
#   - 하트비트 시스템: PostToolUse hook, 파이프라인 상태 연동
#   - 독립에이전트 인프라: workspace/, run-independent-agent.sh, CLAUDE.md
#   - crontab 안전 처리
# v2.1 변경사항:
#   - Watchdog 파이프라인 인식 (재시작 알림에 상태 포함, 완료 감지)
# v2.2 변경사항:
#   - swappiness=80 제거 (플러그인 사망 원인이 메모리가 아님)
#   - 독립에이전트 메모리 제한 3개 제거 (게이트/NODE_OPTIONS/감시루프)
#   - workspace settings.local.json 추가 (독립에이전트에서 플러그인 비활성화 — 플러그인 사망 방지 핵심)
# v2.3 변경사항:
#   - 독립에이전트 플러그인 옵션(--channels) 절대 추가 금지 규칙 명시 (봇 서버 중복 충돌 방지)
# v2.5 변경사항:
#   - 전역 enabledPlugins: true 유지 (false로 하면 --channels만으로 플러그인 로드 안 됨)
#   - 독립에이전트 tmux 소켓: 오퍼와 동일 소켓 사용으로 통일
#   - 서브에이전트(Agent tool) 사용 규칙 추가 (CLAUDE.md 섹션 2)
#   - 플러그인 설정 섹션 추가 (CLAUDE.md 시스템 구성)

echo "========================================"
echo "  Claude Code 자동 설정 스크립트 v2.5"
echo "========================================"
echo ""

# --- 사용자 입력 ---
read -p "에이전트 이름 (예: agent1): " AGENT_NAME

# 기존 설정 확인
GLOBAL_CLAUDE="$HOME/.claude"
EXISTING_TOKEN=""
EXISTING_CHATID=""

if [ -f "$GLOBAL_CLAUDE/channels/telegram/.env" ]; then
  EXISTING_TOKEN=$(grep "TELEGRAM_BOT_TOKEN=" "$GLOBAL_CLAUDE/channels/telegram/.env" 2>/dev/null | cut -d'=' -f2)
fi
if [ -f "$GLOBAL_CLAUDE/channels/telegram/access.json" ]; then
  EXISTING_CHATID=$(grep -o '"[0-9]*"' "$GLOBAL_CLAUDE/channels/telegram/access.json" 2>/dev/null | head -1 | tr -d '"')
fi

if [ -n "$EXISTING_TOKEN" ] && [ -n "$EXISTING_CHATID" ]; then
  echo ""
  echo "기존 설정이 발견되었습니다:"
  echo "  봇 토큰: ${EXISTING_TOKEN:0:10}...${EXISTING_TOKEN: -5}"
  echo "  Chat ID: $EXISTING_CHATID"
  echo ""
  read -p "기존 설정을 유지할까요? (y=유지, n=재입력): " KEEP_EXISTING
  if [ "$KEEP_EXISTING" = "y" ]; then
    BOT_TOKEN="$EXISTING_TOKEN"
    CHAT_ID="$EXISTING_CHATID"
  else
    read -p "텔레그램 봇 토큰: " BOT_TOKEN
    read -p "텔레그램 Chat ID: " CHAT_ID
  fi
else
  read -p "텔레그램 봇 토큰: " BOT_TOKEN
  read -p "텔레그램 Chat ID: " CHAT_ID
fi

HOME_DIR="$HOME"
AGENT_DIR="$HOME_DIR/$AGENT_NAME"
WORKSPACE_DIR="$HOME_DIR/workspace"
SESSION_NAME="claude-$AGENT_NAME"
TMUX_SOCKET="/tmp/tmux-$SESSION_NAME"
HEARTBEAT_DIR="/tmp/claude-heartbeats"
START_SCRIPT="$HOME_DIR/claude-${AGENT_NAME}-start.sh"
WATCHDOG_SCRIPT="$HOME_DIR/claude-${AGENT_NAME}-watchdog.sh"
WATCHDOG_LOG="$HOME_DIR/watchdog-${AGENT_NAME}.log"
IND_SCRIPT="$AGENT_DIR/run-independent-agent.sh"

echo ""
echo "설정 정보:"
echo "  에이전트 디렉토리: $AGENT_DIR"
echo "  독립에이전트 작업 디렉토리: $WORKSPACE_DIR"
echo "  tmux 세션: $SESSION_NAME"
echo "  시작 스크립트: $START_SCRIPT"
echo "  watchdog 스크립트: $WATCHDOG_SCRIPT"
echo "  독립에이전트 스크립트: $IND_SCRIPT"
echo ""
read -p "계속 진행할까요? (y/n): " CONFIRM
if [ "$CONFIRM" != "y" ]; then
  echo "취소되었습니다."
  exit 0
fi

PASS=0
FAIL=0

ok() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

# ========================================
# 1. 한글/UTF-8 인코딩
# ========================================
echo ""
echo "[1/13] 한글/UTF-8 인코딩 설정..."
if ! grep -q "LANG=C.UTF-8" "$HOME_DIR/.bashrc" 2>/dev/null; then
  echo 'export LANG=C.UTF-8' >> "$HOME_DIR/.bashrc"
fi
export LANG=C.UTF-8

if [ "$LANG" = "C.UTF-8" ]; then
  ok "LANG=C.UTF-8 설정 완료"
else
  fail "LANG 설정 실패"
fi

# ========================================
# 2. cron 설치
# ========================================
echo ""
echo "[2/13] cron 설치..."
if ! command -v crontab &>/dev/null; then
  sudo apt update -qq && sudo apt install -y -qq cron
fi
sudo systemctl enable cron 2>/dev/null || true
sudo systemctl start cron 2>/dev/null || true

if systemctl is-active --quiet cron; then
  ok "cron 설치 및 실행 중"
else
  fail "cron 실행 실패"
fi

# ========================================
# 3. 전역 설정 (settings.json + 하트비트 hook)
# ========================================
echo ""
echo "[3/13] 전역 설정 (settings.json)..."
GLOBAL_CLAUDE="$HOME_DIR/.claude"
mkdir -p "$GLOBAL_CLAUDE"

# 기존 settings.json 백업
if [ -f "$GLOBAL_CLAUDE/settings.json" ]; then
  cp "$GLOBAL_CLAUDE/settings.json" "$GLOBAL_CLAUDE/settings.json.bak.$(date +%Y%m%d%H%M%S)"
  echo "  📦 기존 settings.json 백업 완료"
fi

cat > "$GLOBAL_CLAUDE/settings.json" << SETTINGS
{
  "extraKnownMarketplaces": {
    "claude-plugins-official": {
      "source": {
        "source": "github",
        "repo": "anthropics/claude-plugins-official"
      }
    }
  },
  "skipDangerousModePermissionPrompt": true,
  "bypassPermissionsConfirmed": true,
  "enabledPlugins": {
    "telegram@claude-plugins-official": true
  },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "date +%s > $HEARTBEAT_DIR/$SESSION_NAME"
          }
        ]
      }
    ]
  }
}
SETTINGS

if [ -f "$GLOBAL_CLAUDE/settings.json" ]; then
  ok "전역 settings.json 생성 완료 (하트비트 hook 포함)"
else
  fail "전역 settings.json 생성 실패"
fi

# ========================================
# 4. Telegram 플러그인 채널 설정
# ========================================
echo ""
echo "[4/13] Telegram 채널 설정..."

# 기존 프로젝트별 채널 정리 (충돌 방지)
for OLD_CH in "$GLOBAL_CLAUDE/channels/telegram-"*; do
  if [ -d "$OLD_CH" ]; then
    rm -rf "$OLD_CH"
    echo "  🧹 중복 채널 삭제: $OLD_CH"
  fi
done

CHANNEL_DIR="$GLOBAL_CLAUDE/channels/telegram"
mkdir -p "$CHANNEL_DIR"

echo "TELEGRAM_BOT_TOKEN=$BOT_TOKEN" > "$CHANNEL_DIR/.env"

cat > "$CHANNEL_DIR/access.json" << EOF
{
  "dmPolicy": "allowlist",
  "allowFrom": [
    "$CHAT_ID"
  ],
  "groups": {},
  "pending": {}
}
EOF

if [ -f "$CHANNEL_DIR/.env" ] && [ -f "$CHANNEL_DIR/access.json" ]; then
  ok "Telegram 채널 설정 완료 (봇 토큰 + allowlist)"
else
  fail "Telegram 채널 설정 실패"
fi

# ========================================
# 5. 프로젝트 디렉토리 + 하트비트 디렉토리
# ========================================
echo ""
echo "[5/13] 프로젝트 디렉토리 설정..."
mkdir -p "$AGENT_DIR"
mkdir -p "$WORKSPACE_DIR"
mkdir -p "$HEARTBEAT_DIR"

if [ -d "$AGENT_DIR" ] && [ -d "$WORKSPACE_DIR" ] && [ -d "$HEARTBEAT_DIR" ]; then
  ok "디렉토리 생성 완료 (agent + workspace + heartbeat)"
else
  fail "디렉토리 생성 실패"
fi

# workspace 플러그인 비활성화 (독립에이전트에서 텔레그램 플러그인 spawn 방지)
mkdir -p "$WORKSPACE_DIR/.claude"
cat > "$WORKSPACE_DIR/.claude/settings.local.json" << WSSETTINGS
{
  "enabledPlugins": {
    "telegram@claude-plugins-official": false
  }
}
WSSETTINGS

if [ -f "$WORKSPACE_DIR/.claude/settings.local.json" ]; then
  ok "workspace settings.local.json 생성 완료 (독립에이전트 플러그인 비활성화)"
else
  fail "workspace settings.local.json 생성 실패"
fi

# ========================================
# 6. 시작 스크립트
# ========================================
echo ""
echo "[6/13] 시작 스크립트 생성..."

if [ -f "$START_SCRIPT" ]; then
  cp "$START_SCRIPT" "$START_SCRIPT.bak.$(date +%Y%m%d%H%M%S)"
  echo "  📦 기존 시작 스크립트 백업 완료"
fi

cat > "$START_SCRIPT" << EOF
#!/bin/bash
TMUX_SOCKET=$TMUX_SOCKET

export BUN_INSTALL="$HOME_DIR/.bun"
export PATH="\$BUN_INSTALL/bin:$HOME_DIR/.local/bin:/usr/local/bin:/usr/bin:/bin"
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
tmux -S \$TMUX_SOCKET kill-session -t $SESSION_NAME 2>/dev/null || true
pkill -f "telegram.*start" 2>/dev/null || true
sleep 2

cd $AGENT_DIR

tmux -u -S \$TMUX_SOCKET new-session -d -s $SESSION_NAME \\
  "claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions"

sleep 2
chmod 700 \$TMUX_SOCKET
tmux -S \$TMUX_SOCKET ls
EOF

chmod +x "$START_SCRIPT"

if [ -x "$START_SCRIPT" ]; then
  ok "시작 스크립트 생성 완료: $START_SCRIPT"
else
  fail "시작 스크립트 생성 실패"
fi

# ========================================
# 7. Watchdog 스크립트 (v2.0 강화)
# ========================================
echo ""
echo "[7/13] Watchdog 스크립트 생성 (v2.0)..."

if [ -f "$WATCHDOG_SCRIPT" ]; then
  cp "$WATCHDOG_SCRIPT" "$WATCHDOG_SCRIPT.bak.$(date +%Y%m%d%H%M%S)"
  echo "  📦 기존 watchdog 스크립트 백업 완료"
fi

cat > "$WATCHDOG_SCRIPT" << 'WATCHDOG_EOF'
#!/bin/bash
TMUX_SOCKET=__TMUX_SOCKET__
SESSION_NAME=__SESSION_NAME__
BOT_TOKEN="__BOT_TOKEN__"
CHAT_ID="__CHAT_ID__"
HEARTBEAT_DIR="__HEARTBEAT_DIR__"
OPERATOR_HEARTBEAT="${HEARTBEAT_DIR}/__SESSION_NAME__"
OPERATOR_TIMEOUT=600
IND_TIMEOUT=300
START_SCRIPT="__START_SCRIPT__"
PIPELINE_STATE="__AGENT_DIR__/pipeline-state.json"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

send_telegram() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" -d text="$1" > /dev/null 2>&1
}

NOW=$(date +%s)
MEM_AVAIL=$(awk '/MemAvailable/ {printf "%.0fMB", $2/1024}' /proc/meminfo)
log "--- watchdog 체크 시작 (메모리: ${MEM_AVAIL}) ---"

# 파이프라인 상태 요약 함수
get_pipeline_summary() {
  if [ ! -f "$PIPELINE_STATE" ]; then
    echo "파이프라인 없음"
    return
  fi
  local P_NAME=$(grep -o '"pipeline"[[:space:]]*:[[:space:]]*"[^"]*"' "$PIPELINE_STATE" | grep -o '"[^"]*"$' | tr -d '"')
  local P_STEP=$(grep -o '"current_step"[[:space:]]*:[[:space:]]*"[^"]*"' "$PIPELINE_STATE" | grep -o '"[^"]*"$' | tr -d '"')
  local P_STATUS=$(grep -o '"current_status"[[:space:]]*:[[:space:]]*"[^"]*"' "$PIPELINE_STATE" | grep -o '"[^"]*"$' | tr -d '"')
  local P_AGENT=$(grep -o '"current_agent"[[:space:]]*:[[:space:]]*"[^"]*"' "$PIPELINE_STATE" | grep -o '"[^"]*"$' | tr -d '"')
  local P_OUTPUT=$(grep -o '"output_file"[[:space:]]*:[[:space:]]*"[^"]*"' "$PIPELINE_STATE" | grep -o '"[^"]*"$' | tr -d '"')

  local SUMMARY="파이프라인: ${P_NAME}, 단계: ${P_STEP}, 상태: ${P_STATUS}"

  if [ -n "$P_OUTPUT" ]; then
    if [ -f "${P_OUTPUT}.done" ]; then
      SUMMARY="${SUMMARY}, 결과: 완료됨(done 플래그 존재)"
    elif [ -f "${P_OUTPUT}.error" ]; then
      local ERR_MSG=$(cat "${P_OUTPUT}.error" 2>/dev/null)
      SUMMARY="${SUMMARY}, 결과: 실패(${ERR_MSG})"
    fi
  fi

  if [ -n "$P_AGENT" ]; then
    if tmux -S $TMUX_SOCKET has-session -t "$P_AGENT" 2>/dev/null; then
      SUMMARY="${SUMMARY}, 에이전트 ${P_AGENT} 동작 중"
    else
      SUMMARY="${SUMMARY}, 에이전트 ${P_AGENT} 세션 없음"
    fi
  fi

  echo "$SUMMARY"
}

# ============================================
# 1단계: 오퍼 감시
# ============================================

# 재시작 루프 방지: 최근 10분 내 3회 이상 재시작 시 중단
RESTART_COUNT_FILE="/tmp/claude-watchdog-restart-count"
check_restart_loop() {
  if [ -f "$RESTART_COUNT_FILE" ]; then
    LAST_RESTART=$(head -1 "$RESTART_COUNT_FILE")
    COUNT=$(tail -1 "$RESTART_COUNT_FILE")
    ELAPSED=$((NOW - LAST_RESTART))
    if [ "$ELAPSED" -lt 600 ]; then
      COUNT=$((COUNT + 1))
      if [ "$COUNT" -ge 3 ]; then
        if [ "$COUNT" -eq 3 ]; then
          log "ACTION: 재시작 루프 감지 (10분 내 ${COUNT}회) → 재시작 일시 중단"
          send_telegram "🛑 재시작 루프 감지! 10분 내 ${COUNT}회 재시작 시도. 자동 재시작을 일시 중단합니다. 10분 후 재시도합니다."
        else
          log "ACTION: 재시작 루프 차단 중 (${COUNT}회째, 10분 후 리셋)"
        fi
        echo "$LAST_RESTART" > "$RESTART_COUNT_FILE"
        echo "$COUNT" >> "$RESTART_COUNT_FILE"
        exit 0
      fi
    else
      COUNT=1
    fi
  else
    COUNT=1
  fi
  echo "$NOW" > "$RESTART_COUNT_FILE"
  echo "$COUNT" >> "$RESTART_COUNT_FILE"
}

# tmux 세션이 없으면 재시작
if ! tmux -S $TMUX_SOCKET has-session -t $SESSION_NAME 2>/dev/null; then
  log "ACTION: tmux 세션 없음 → 재시작"
  check_restart_loop
  send_telegram "⚠️ 클로드 코드가 죽어있어서 재시작합니다..."
  mkdir -p "$HEARTBEAT_DIR"
  date +%s > "$OPERATOR_HEARTBEAT"
  bash $START_SCRIPT
  sleep 5
  P_SUMMARY=$(get_pipeline_summary)
  send_telegram "✅ 클로드 코드 재시작 완료! [${P_SUMMARY}]"
  exit 0
fi

# tmux는 있지만 claude 프로세스가 죽었으면 재시작
if ! pgrep -f "claude --channels" > /dev/null 2>&1; then
  log "ACTION: tmux 있으나 claude 프로세스 없음 → 재시작"
  check_restart_loop
  send_telegram "⚠️ 클로드 코드 프로세스가 죽어있어서 재시작합니다..."
  tmux -S $TMUX_SOCKET kill-session -t $SESSION_NAME 2>/dev/null || true
  pkill -f "telegram.*start" 2>/dev/null || true
  sleep 2
  mkdir -p "$HEARTBEAT_DIR"
  date +%s > "$OPERATOR_HEARTBEAT"
  bash $START_SCRIPT
  sleep 5
  P_SUMMARY=$(get_pipeline_summary)
  send_telegram "✅ 클로드 코드 재시작 완료! [${P_SUMMARY}]"
  exit 0
fi

# 텔레그램 플러그인 프로세스가 없으면 재시작
if ! pgrep -f "telegram.*start" > /dev/null 2>&1; then
  log "ACTION: tmux+claude 있으나 텔레그램 플러그인 프로세스 없음 → 재시작"
  check_restart_loop
  send_telegram "⚠️ 텔레그램 플러그인이 죽어서 재시작합니다..."
  tmux -S $TMUX_SOCKET kill-session -t $SESSION_NAME 2>/dev/null || true
  pkill -f "claude --channels" 2>/dev/null || true
  sleep 2
  mkdir -p "$HEARTBEAT_DIR"
  date +%s > "$OPERATOR_HEARTBEAT"
  bash $START_SCRIPT
  sleep 5
  P_SUMMARY=$(get_pipeline_summary)
  send_telegram "✅ 텔레그램 플러그인 복구 완료! [${P_SUMMARY}]"
  exit 0
fi

# 텔레그램 헬스체크 (2단계)

# 1단계: Bot API 네트워크 연결 확인
TELEGRAM_HEALTH=$(curl -s -m 5 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null)
if ! echo "$TELEGRAM_HEALTH" | grep -q '"ok":true'; then
  log "ACTION: 텔레그램 Bot API 응답 없음/실패 (네트워크 문제) → 재시작"
  check_restart_loop
  send_telegram "⚠️ 텔레그램 Bot API 헬스체크 실패 → 재시작합니다..."
  tmux -S $TMUX_SOCKET kill-session -t $SESSION_NAME 2>/dev/null || true
  pkill -f "claude --channels" 2>/dev/null || true
  pkill -f "telegram.*start" 2>/dev/null || true
  sleep 2
  mkdir -p "$HEARTBEAT_DIR"
  date +%s > "$OPERATOR_HEARTBEAT"
  bash $START_SCRIPT
  sleep 5
  P_SUMMARY=$(get_pipeline_summary)
  send_telegram "✅ 텔레그램 헬스체크 실패 후 복구 완료! [${P_SUMMARY}]"
  exit 0
fi

# 2단계: 로컬 플러그인 프로세스 상태 확인 (좀비/멈춤 감지)
TELEGRAM_PID=$(pgrep -f "bun server.ts" 2>/dev/null | head -1)
if [ -n "$TELEGRAM_PID" ]; then
  PROC_STATE=$(cat /proc/$TELEGRAM_PID/status 2>/dev/null | grep "^State:" | awk '{print $2}')
  if [ "$PROC_STATE" = "Z" ] || [ "$PROC_STATE" = "T" ]; then
    log "ACTION: 텔레그램 플러그인 프로세스 비정상 상태(${PROC_STATE}) → 재시작"
    check_restart_loop
    send_telegram "⚠️ 텔레그램 플러그인이 멈춤 상태(${PROC_STATE}) → 재시작합니다..."
    tmux -S $TMUX_SOCKET kill-session -t $SESSION_NAME 2>/dev/null || true
    pkill -f "claude --channels" 2>/dev/null || true
    pkill -f "telegram.*start" 2>/dev/null || true
    sleep 2
    mkdir -p "$HEARTBEAT_DIR"
    date +%s > "$OPERATOR_HEARTBEAT"
    bash $START_SCRIPT
    sleep 5
    P_SUMMARY=$(get_pipeline_summary)
    send_telegram "✅ 텔레그램 플러그인 멈춤 상태 복구 완료! [${P_SUMMARY}]"
    exit 0
  fi
  log "STATUS: 텔레그램 정상 (Bot API 연결 OK, 플러그인 프로세스 상태: ${PROC_STATE})"
else
  log "STATUS: 텔레그램 Bot API 연결 정상 (bun server.ts PID 못 찾음)"
fi

# 오퍼 하트비트 체크 (파이프라인 활성 + 독립에이전트 실제 존재 시에만)
PIPELINE_ACTIVE=false
IND_AGENTS_EXIST=false
if [ -f "$PIPELINE_STATE" ]; then
  CURRENT_STATUS=$(grep -o '"current_status"[[:space:]]*:[[:space:]]*"[^"]*"' "$PIPELINE_STATE" | grep -o '"[^"]*"$' | tr -d '"')
  [ "$CURRENT_STATUS" = "running" ] && PIPELINE_ACTIVE=true
fi
# 실제 claude-ind-* tmux 세션이 존재하는지 확인
if tmux -S $TMUX_SOCKET ls 2>/dev/null | grep -q "^claude-ind-"; then
  IND_AGENTS_EXIST=true
fi

if [ "$PIPELINE_ACTIVE" = true ] && [ "$IND_AGENTS_EXIST" = true ] && [ -f "$OPERATOR_HEARTBEAT" ]; then
  LAST_BEAT=$(cat "$OPERATOR_HEARTBEAT" 2>/dev/null || echo "0")
  ELAPSED=$((NOW - LAST_BEAT))
  log "STATUS: 파이프라인 활성, 오퍼 하트비트 ${ELAPSED}초 전"
  if [ "$ELAPSED" -gt "$OPERATOR_TIMEOUT" ]; then
    log "ACTION: 오퍼 hang 감지 (${ELAPSED}초) → 강제 재시작"
    check_restart_loop
    send_telegram "⚠️ 오퍼가 파이프라인 실행 중 ${ELAPSED}초간 무응답(hang) → 강제 재시작합니다..."
    tmux -S $TMUX_SOCKET kill-session -t $SESSION_NAME 2>/dev/null || true
    pkill -f "claude --channels" 2>/dev/null || true
    pkill -f "telegram.*start" 2>/dev/null || true
    sleep 2
    mkdir -p "$HEARTBEAT_DIR"
    date +%s > "$OPERATOR_HEARTBEAT"
    bash $START_SCRIPT
    sleep 5
    P_SUMMARY=$(get_pipeline_summary)
    send_telegram "✅ 오퍼 강제 재시작 완료! [${P_SUMMARY}]"
    exit 0
  fi
else
  log "STATUS: 정상 (파이프라인 비활성 또는 하트비트 없음)"
fi

# ============================================
# 2단계: 독립에이전트(claude-ind-*) 감시
# ============================================

[ ! -d "$HEARTBEAT_DIR" ] && exit 0

for HEARTBEAT_FILE in "$HEARTBEAT_DIR"/claude-ind-*; do
  [ ! -f "$HEARTBEAT_FILE" ] && continue

  IND_SESSION=$(basename "$HEARTBEAT_FILE")

  # tmux 세션 없으면 하트비트 파일 정리
  if ! tmux -S $TMUX_SOCKET has-session -t "$IND_SESSION" 2>/dev/null; then
    rm -f "$HEARTBEAT_FILE"
    continue
  fi

  # 하트비트 타임아웃 체크 (파이프라인 활성 중에만)
  if [ "$PIPELINE_ACTIVE" = true ]; then
    LAST_BEAT=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo "0")
    ELAPSED=$((NOW - LAST_BEAT))
    if [ "$ELAPSED" -gt "$IND_TIMEOUT" ]; then
      log "ACTION: 독립에이전트 [${IND_SESSION}] hang 감지 (${ELAPSED}초) → 강제 종료"
      send_telegram "⚠️ 독립에이전트 [${IND_SESSION}] ${ELAPSED}초간 무응답 → 강제 종료합니다"
      tmux -S $TMUX_SOCKET kill-session -t "$IND_SESSION" 2>/dev/null || true
      rm -f "$HEARTBEAT_FILE"
      send_telegram "🔴 독립에이전트 [${IND_SESSION}] 종료 완료"
    fi
  fi
done

# ============================================
# 3단계: 파이프라인 완료 감지 (오퍼가 모르는 상태 대비)
# ============================================

if [ -f "$PIPELINE_STATE" ]; then
  P_STATUS=$(grep -o '"current_status"[[:space:]]*:[[:space:]]*"[^"]*"' "$PIPELINE_STATE" | grep -o '"[^"]*"$' | tr -d '"')
  P_OUTPUT=$(grep -o '"output_file"[[:space:]]*:[[:space:]]*"[^"]*"' "$PIPELINE_STATE" | grep -o '"[^"]*"$' | tr -d '"')
  P_AGENT=$(grep -o '"current_agent"[[:space:]]*:[[:space:]]*"[^"]*"' "$PIPELINE_STATE" | grep -o '"[^"]*"$' | tr -d '"')
  P_STEP=$(grep -o '"current_step"[[:space:]]*:[[:space:]]*"[^"]*"' "$PIPELINE_STATE" | grep -o '"[^"]*"$' | tr -d '"')

  if [ "$P_STATUS" = "running" ] && [ -n "$P_OUTPUT" ]; then
    NOTIFY_FLAG="/tmp/claude-watchdog-pipeline-notified"
    if [ -f "${P_OUTPUT}.done" ] && [ ! -f "$NOTIFY_FLAG" ]; then
      log "ACTION: 파이프라인 단계 [${P_STEP}] 완료됨, 오퍼 미인지 → 사용자 알림 + 상태 업데이트"
      # pipeline-state를 done으로 자동 업데이트
      sed -i 's/"current_status"[[:space:]]*:[[:space:]]*"running"/"current_status": "done"/' "$PIPELINE_STATE"
      send_telegram "📋 독립에이전트 [${P_AGENT}] 단계 '${P_STEP}' 완료됨! 오퍼에게 메시지를 보내서 다음 단계를 진행해주세요."
      date +%s > "$NOTIFY_FLAG"
    elif [ -f "${P_OUTPUT}.error" ] && [ ! -f "$NOTIFY_FLAG" ]; then
      ERR_MSG=$(cat "${P_OUTPUT}.error" 2>/dev/null)
      log "ACTION: 파이프라인 단계 [${P_STEP}] 실패(${ERR_MSG}), 오퍼 미인지 → 사용자 알림 + 상태 업데이트"
      # pipeline-state를 failed로 자동 업데이트
      sed -i 's/"current_status"[[:space:]]*:[[:space:]]*"running"/"current_status": "failed"/' "$PIPELINE_STATE"
      send_telegram "🔴 독립에이전트 [${P_AGENT}] 단계 '${P_STEP}' 실패! (${ERR_MSG}) 오퍼에게 메시지를 보내서 상황을 확인해주세요."
      date +%s > "$NOTIFY_FLAG"
    fi
  else
    rm -f "/tmp/claude-watchdog-pipeline-notified"
  fi
fi
WATCHDOG_EOF

# 플레이스홀더 치환
sed -i "s|__TMUX_SOCKET__|$TMUX_SOCKET|g" "$WATCHDOG_SCRIPT"
sed -i "s|__SESSION_NAME__|$SESSION_NAME|g" "$WATCHDOG_SCRIPT"
sed -i "s|__BOT_TOKEN__|$BOT_TOKEN|g" "$WATCHDOG_SCRIPT"
sed -i "s|__CHAT_ID__|$CHAT_ID|g" "$WATCHDOG_SCRIPT"
sed -i "s|__HEARTBEAT_DIR__|$HEARTBEAT_DIR|g" "$WATCHDOG_SCRIPT"
sed -i "s|__START_SCRIPT__|$START_SCRIPT|g" "$WATCHDOG_SCRIPT"
sed -i "s|__AGENT_DIR__|$AGENT_DIR|g" "$WATCHDOG_SCRIPT"

chmod +x "$WATCHDOG_SCRIPT"

if [ -x "$WATCHDOG_SCRIPT" ]; then
  ok "Watchdog 스크립트 생성 완료 (v2.0): $WATCHDOG_SCRIPT"
else
  fail "Watchdog 스크립트 생성 실패"
fi

# ========================================
# 8. 독립에이전트 실행 스크립트
# ========================================
echo ""
echo "[8/13] 독립에이전트 실행 스크립트 생성..."

cat > "$IND_SCRIPT" << 'IND_EOF'
#!/bin/bash
# 독립에이전트를 별도 tmux 세션에서 실행
# 주의: --channels, plugin:telegram 등 플러그인 옵션 절대 추가 금지 (봇 서버 중복 → 충돌)
# 사용법: ./run-independent-agent.sh <에이전트이름> <프롬프트파일> <출력파일> [작업디렉토리]

TMUX_SOCKET=__TMUX_SOCKET__
HEARTBEAT_DIR=__HEARTBEAT_DIR__
DEFAULT_WORKDIR=__WORKSPACE_DIR__

AGENT_NAME=$1
PROMPT_FILE=$2
OUTPUT_FILE=$3
WORK_DIR=${4:-$DEFAULT_WORKDIR}

if [ -z "$AGENT_NAME" ] || [ -z "$PROMPT_FILE" ] || [ -z "$OUTPUT_FILE" ]; then
  echo "사용법: $0 <에이전트이름> <프롬프트파일> <출력파일> [작업디렉토리]"
  exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "오류: 프롬프트 파일이 없습니다: $PROMPT_FILE"
  exit 1
fi

SESSION="claude-ind-$AGENT_NAME"
HEARTBEAT_FILE="$HEARTBEAT_DIR/$SESSION"

# 디렉토리 생성
mkdir -p "$HEARTBEAT_DIR"
mkdir -p "$WORK_DIR"

# 이전 플래그/하트비트 정리
rm -f "${OUTPUT_FILE}.done" "${OUTPUT_FILE}.error" "$HEARTBEAT_FILE"

# 프롬프트 읽기
PROMPT=$(cat "$PROMPT_FILE")

# 내부 실행 스크립트 생성 (임시파일)
INNER_SCRIPT=$(mktemp /tmp/claude-ind-XXXXXX.sh)
cat > "$INNER_SCRIPT" << INNER
#!/bin/bash
# 하트비트 백그라운드 루프
(
  while true; do
    date +%s > "$HEARTBEAT_FILE"
    sleep 30
  done
) &
HB_PID=\$!

cd "$WORK_DIR"

claude -p "\$(cat $PROMPT_FILE)" --dangerously-skip-permissions &
CLAUDE_PID=\$!

# claude 프로세스 완료 대기
wait \$CLAUDE_PID
EXIT_CODE=\$?

if [ \$EXIT_CODE -eq 0 ] && [ ! -f "${OUTPUT_FILE}.error" ]; then
  echo "ok" > "${OUTPUT_FILE}.done"
elif [ ! -f "${OUTPUT_FILE}.error" ]; then
  echo "error:exit_code_\${EXIT_CODE}" > "${OUTPUT_FILE}.error"
fi

# 하트비트 루프 종료 + 파일 삭제
kill \$HB_PID 2>/dev/null
rm -f "$HEARTBEAT_FILE"

# 자기 삭제
rm -f "$INNER_SCRIPT"
INNER

chmod +x "$INNER_SCRIPT"

# 기존 동일 세션 제거
tmux -S $TMUX_SOCKET kill-session -t "$SESSION" 2>/dev/null || true

# 새 세션에서 실행
tmux -S $TMUX_SOCKET new-session -d -s "$SESSION" "bash $INNER_SCRIPT"

# 초기 하트비트
date +%s > "$HEARTBEAT_FILE"

echo "독립에이전트 시작: $SESSION (작업디렉토리: $WORK_DIR)"
echo "완료 확인: ${OUTPUT_FILE}.done 또는 ${OUTPUT_FILE}.error"
IND_EOF

sed -i "s|__TMUX_SOCKET__|$TMUX_SOCKET|g" "$IND_SCRIPT"
sed -i "s|__HEARTBEAT_DIR__|$HEARTBEAT_DIR|g" "$IND_SCRIPT"
sed -i "s|__WORKSPACE_DIR__|$WORKSPACE_DIR|g" "$IND_SCRIPT"

chmod +x "$IND_SCRIPT"

if [ -x "$IND_SCRIPT" ]; then
  ok "독립에이전트 스크립트 생성 완료: $IND_SCRIPT"
else
  fail "독립에이전트 스크립트 생성 실패"
fi

# ========================================
# 9. CLAUDE.md 파일 생성
# ========================================
echo ""
echo "[9/13] CLAUDE.md 파일 생성..."

# 독립에이전트 workspace CLAUDE.md
if [ -f "$WORKSPACE_DIR/CLAUDE.md" ]; then
  cp "$WORKSPACE_DIR/CLAUDE.md" "$WORKSPACE_DIR/CLAUDE.md.bak.$(date +%Y%m%d%H%M%S)"
  echo "  📦 기존 workspace CLAUDE.md 백업 완료"
fi

cat > "$WORKSPACE_DIR/CLAUDE.md" << 'CLAUDE_WS'
# 독립에이전트 공통 규칙

이 CLAUDE.md는 독립에이전트(claude -p)에게 적용되는 공통 규칙이다.

## 1. 금지 사항
- 텔레그램 사용 금지 (settings.local.json으로 플러그인 비활성화됨)
- 다른 독립에이전트 실행 금지
- Agent tool(서브에이전트) 사용 금지
- 사용자와 직접 대화 금지 (파일로만 소통)

## 2. 출력 규칙
- 결과는 프롬프트에서 지정된 출력 파일에 작성
- 파일 경로는 프롬프트에 명시된 절대경로 사용
- 작업 대상 파일이 다른 디렉토리에 있을 수 있음 → 절대경로로 접근

## 3. 실행 환경
- 작업 완료 후 프로세스 자동 종료
- 하트비트: 백그라운드에서 30초마다 자동 갱신 (스크립트가 처리, 신경 쓸 필요 없음)

## 4. 작업 원칙
- 프롬프트에 명시된 작업만 수행
- 프롬프트에 참조 파일 경로가 있으면 반드시 읽고 반영
- 작업 범위를 벗어나는 수정 금지
CLAUDE_WS

if [ -f "$WORKSPACE_DIR/CLAUDE.md" ]; then
  ok "workspace CLAUDE.md 생성 완료"
else
  fail "workspace CLAUDE.md 생성 실패"
fi

# 독립에이전트 역할 파일
echo "  역할 파일 생성 (roles/)..."
mkdir -p "$WORKSPACE_DIR/roles"

cat > "$WORKSPACE_DIR/roles/planner.md" << 'ROLE_PLANNER'
# 역할: 기획자

당신은 기획 전문가입니다.

## 역량
- 주어진 주제에 대해 체계적인 조사/작업 기획안을 수립합니다
- 보고서 섹션 구성, 분량 배분, 조사 방향을 설계합니다
- 웹 검색 키워드 목록을 제시합니다

## 작업 원칙
- 최종 결과물의 목적과 분량을 고려하여 기획합니다
- 각 섹션별 핵심 조사 내용을 구체적으로 명시합니다
- 다음 단계(작성자)가 바로 작업할 수 있도록 명확한 가이드를 제공합니다
ROLE_PLANNER

cat > "$WORKSPACE_DIR/roles/writer.md" << 'ROLE_WRITER'
# 역할: 작성자

당신은 리서처이자 작성 전문가입니다.

## 역량
- 기획안을 바탕으로 웹 검색을 통해 정보를 수집합니다
- 수집한 정보를 체계적으로 정리하여 보고서를 작성합니다
- 간결하고 핵심 중심의 문서를 작성합니다

## 작업 원칙
- 기획안의 섹션 구성과 분량 배분을 반드시 따릅니다
- 동명이인 등 정보 혼동에 주의합니다
- 통계 수치는 교차 검증 후 사용합니다
- 출처가 불확실한 정보는 제외합니다
- 마크다운 형식으로 작성합니다
ROLE_WRITER

cat > "$WORKSPACE_DIR/roles/reviewer.md" << 'ROLE_REVIEWER'
# 역할: 검증자

당신은 검증 전문 에디터입니다.

## 역량
- 보고서의 사실관계를 웹 검색으로 교차 검증합니다
- 기획안 대비 구조와 분량이 적절한지 확인합니다
- 오류를 수정하고 부족한 부분을 보완합니다

## 작업 원칙
- 핵심 수치(통계, 날짜, 이름 등)를 반드시 교차 검증합니다
- 동명이인 정보가 섞이지 않았는지 확인합니다
- 최신 정보가 반영되었는지 확인합니다
- 검증 결과 요약 + 최종 수정본을 함께 출력합니다
ROLE_REVIEWER

if [ -d "$WORKSPACE_DIR/roles" ] && [ -f "$WORKSPACE_DIR/roles/planner.md" ]; then
  ok "역할 파일 생성 완료 (planner, writer, reviewer)"
else
  fail "역할 파일 생성 실패"
fi

# 오퍼 CLAUDE.md
if [ -f "$AGENT_DIR/CLAUDE.md" ]; then
  cp "$AGENT_DIR/CLAUDE.md" "$AGENT_DIR/CLAUDE.md.bak.$(date +%Y%m%d%H%M%S)"
  echo "  📦 기존 오퍼 CLAUDE.md 백업 완료"
fi

cat > "$AGENT_DIR/CLAUDE.md" << CLAUDE_OP
# 오퍼($SESSION_NAME) 프로젝트 규칙

이 CLAUDE.md는 오퍼 전용이다. 독립에이전트는 $WORKSPACE_DIR/CLAUDE.md를 따른다.

## 1. 시스템 구성

### 파일 위치
- 오퍼 시작 스크립트: $START_SCRIPT
- Watchdog: $WATCHDOG_SCRIPT (cron 매 1분)
- 독립에이전트 스크립트: $IND_SCRIPT
- 오퍼 하트비트 hook: ~/.claude/settings.json (PostToolUse)
- 하트비트 폴더: $HEARTBEAT_DIR/
- 오퍼 tmux 소켓: $TMUX_SOCKET
- 독립에이전트 tmux 소켓: $TMUX_SOCKET (오퍼와 동일 소켓)

### 디렉토리 구조
- $AGENT_DIR/ → 오퍼 작업 디렉토리 (이 CLAUDE.md)
- $WORKSPACE_DIR/ → 독립에이전트 작업 디렉토리 (독립 CLAUDE.md)
- 독립에이전트는 절대경로로 $AGENT_DIR/ 파일 접근 가능

### 프로세스 구조
- 오퍼($SESSION_NAME): 항상 상주, 텔레그램 연결, 작업 오케스트레이션
- 독립에이전트(claude-ind-*): 별도 tmux 세션, $WORKSPACE_DIR/에서 실행, 작업 후 종료
- Watchdog(cron): 오퍼+독립 감시, 시스템 레벨

### 오퍼 프로세스 계층
\`\`\`
tmux ($SESSION_NAME 세션)
  └─ sh
      └─ claude --channels plugin:telegram... (Claude Code 본체)
          └─ bun run ... telegram start (플러그인 런처)
              └─ bun server.ts (텔레그램 봇 서버)
\`\`\`

- channels: Claude Code의 플러그인 시스템. --channels 옵션으로 플러그인 선택
- bun: 선택된 플러그인 코드를 실행하는 런타임 (JS/TS)
- server.ts: 플러그인 진입점. 텔레그램 Bot API와 polling 통신
- 플러그인 캐시: ~/.claude/plugins/cache/claude-plugins-official/telegram/
- 메시지 흐름: 텔레그램 서버 ↔ server.ts ↔ claude code
- 플러그인만 단독 재시작 불가 → claude 전체 재시작 필요

### 플러그인 설정
- 전역: ~/.claude/settings.json → enabledPlugins: true (오퍼용)
- 프로젝트: $WORKSPACE_DIR/.claude/settings.local.json → enabledPlugins: false (독립에이전트 플러그인 차단)
- 오퍼 봇 서버: 시작 스크립트의 --channels plugin:telegram으로만 실행
- 다른 claude 인스턴스에서 봇 서버 자동 실행 안 됨 → 충돌 방지

## 2. 서브에이전트(Agent tool) 사용 규칙

### 사용 범위
- 오퍼에서 짧은 작업(검색, 분석 등)에 Agent tool 사용 가능
- 긴 작업(글쓰기, 대규모 코드 작업 등)은 독립에이전트 사용

### 주의
- Agent tool 실행 중 오퍼는 텔레그램 응답 불가 (서브에이전트 완료까지 대기)
- 오퍼 재시작 시 서브에이전트 결과 소실 (파일로 저장되지 않음)
- 독립에이전트 작업을 Agent tool로 대체 금지

## 3. 독립에이전트 실행 규칙

### 트리거
사용자가 "독립" 또는 "독립에이전트" 키워드를 포함하여 지시할 경우 적용

### 금지
- Agent tool(서브에이전트) 사용 금지
- 같은 프로세스 내 하위 작업 금지
- 독립에이전트에 --channels, plugin:telegram 등 플러그인 옵션 절대 추가 금지 (봇 서버 중복 실행 → 충돌)

### 실행 방법
1. 프롬프트 파일 작성 (역할 파일 참조 + 작업 지시 + 이전 결과물 경로 포함)
2. run-independent-agent.sh 호출 → 별도 tmux + claude -p 실행 (작업디렉토리: $WORKSPACE_DIR/)
3. done/error 플래그 감시로 완료 확인
4. 완료 후 결과 파일 확인 → 다음 단계 진행

### 역할 파일 (재사용, 수정하지 않음)
- $WORKSPACE_DIR/roles/planner.md → 기획자
- $WORKSPACE_DIR/roles/writer.md → 작성자
- $WORKSPACE_DIR/roles/reviewer.md → 검증자
- 필요한 역할이 roles/에 없으면 오퍼가 새 역할 파일을 생성한 후 사용

### 프롬프트 파일 작성 규칙
- 역할: 역할 파일 경로를 명시하여 참조 지시 (예: "$WORKSPACE_DIR/roles/planner.md를 읽고 역할을 따르세요")
- 작업 지시: 구체적인 작업 내용 (주제, 분량, 조건 등)
- 참조 파일: 이전 단계 결과물의 절대경로 (예: $AGENT_DIR/output-plan.md)
- 출력 파일: 결과를 저장할 절대경로 (예: $AGENT_DIR/output-implement.md)

### 스크립트 사용법
\`\`\`bash
$IND_SCRIPT <에이전트이름> <프롬프트파일> <출력파일> [작업디렉토리]
# 기본 작업디렉토리: $WORKSPACE_DIR/
# 완료: <출력파일>.done 존재
# 실패: <출력파일>.error 존재
\`\`\`

### 실행 원칙
- 기본 직렬, 사용자가 병렬 지시 시 최대 3개까지 병렬 실행
- 3개 초과 요청 시 "3개까지 가능합니다. 3개씩 나눠서 진행할까요?" 안내
- 이전 에이전트(또는 배치) 완료 확인 후 다음 진행
- 오퍼는 중간 진행 상황을 텔레그램으로 보고

### tmux 네이밍
- 독립에이전트 tmux 세션: claude-ind-<에이전트이름> (오퍼와 동일 소켓 $TMUX_SOCKET 사용)
- 하트비트 파일: $HEARTBEAT_DIR/claude-ind-<에이전트이름>
- watchdog은 claude-ind-* 접두사 세션만 감시 (수동 tmux와 구분)

## 4. 감시 체계

### 오퍼 하트비트
- 방식: settings.json hook (도구 호출 시 자동 갱신)
- 파일: $HEARTBEAT_DIR/$SESSION_NAME

### 독립에이전트 하트비트
- 방식: 스크립트 내 백그라운드 루프 (30초마다 자동 갱신)
- 파일: $HEARTBEAT_DIR/claude-ind-<이름>

### Watchdog 체크 항목
오퍼:
1. tmux 세션 없음(kill) → 자동 재시작 (하트비트 리셋)
2. claude 프로세스 없음(kill) → 자동 재시작 (하트비트 리셋)
3. 텔레그램 플러그인 프로세스 없음(죽음) → 자동 재시작 (하트비트 리셋)
4. 텔레그램 헬스체크 (프로세스는 있지만 동작 안 하는 경우 감지)
   - Bot API getMe 호출 → 네트워크 연결 확인. 실패 시 재시작
   - bun server.ts 프로세스 상태(/proc/PID/status) → 좀비(Z)/멈춤(T) 감지 시 재시작
5. 하트비트 10분 초과(hang) → 파이프라인 활성(current_status="running") + 독립에이전트(claude-ind-*) tmux 세션이 실제 존재할 때만 체크

독립에이전트:
6. 하트비트 5분 초과(hang) → 파이프라인 활성 중에만 체크. 유휴 상태에서는 하트비트 체크 안 함
7. 파이프라인 완료 감지: 독립에이전트 .done/.error 플래그 발견 시 pipeline-state를 자동으로 done/failed로 업데이트
8. tmux 없는데 하트비트만 남음 → 파일 정리 (항상)

### 재시작 루프 방지
- /tmp/claude-watchdog-restart-count 파일로 재시작 횟수 추적
- 10분 내 3회 이상 재시작 시도 → 자동 재시작 일시 중단, 10분 후 재시도
- 알림은 3회째 최초 1번만 전송, 이후 로그만 기록

### Watchdog 로깅
- 로그 파일: $WATCHDOG_LOG
- 매 체크마다: 타임스탬프 + 메모리 잔량(MemAvailable) 기록
- ACTION 로그: 어떤 체크에서 걸렸는지 (tmux없음/claude없음/플러그인없음/API실패/프로세스멈춤/hang)
- STATUS 로그: 정상일 때도 상태 기록

## 5. 중단 시 처리 규칙

### 독립에이전트 중단 시 (오퍼가 처리)
1. 텔레그램으로 사용자에게 중단 보고 (어떤 에이전트가, 어떤 작업 중에, 왜 중단됐는지)
2. 사용자에게 재실행 여부를 질문
3. 사용자가 승인한 후에만 재실행
- 절대 자동 재실행 금지. 반드시 사용자 승인 필요.

### 오퍼 중단/kill 시 (watchdog이 처리)
1. watchdog이 오퍼의 하트비트 또는 프로세스 상태를 감지하여 자동 재시작
2. 재시작된 오퍼는 pipeline-state.json을 확인하여 이전 작업 상태 파악
3. 텔레그램으로 사용자에게 상황 보고 + 이어서 진행할지 승인 요청

## 6. 파이프라인 상태 관리

파일: $AGENT_DIR/pipeline-state.json

\`\`\`json
{
  "pipeline": "작업명",
  "steps": ["step1", "step2", "step3"],
  "current_step": "step2",
  "current_status": "running",
  "current_agent": "claude-ind-step2",
  "output_file": "output-step2.md",
  "completed_steps": ["step1"],
  "updated_at": "2026-04-11T08:00:00Z"
}
\`\`\`

규칙:
- 독립에이전트 실행 전: current_step, current_status="running" 기록
- 독립에이전트 완료 후: current_status="done", completed_steps에 추가
- 독립에이전트 실패 시: current_status="failed"
- 모든 단계 완료 시: current_status="all_done"

## 7. 스크립트 명세

스크립트 파일이 없으면 아래 명세에 따라 생성할 수 있다.

### 시작 스크립트 ($START_SCRIPT)
- 역할: 오퍼($SESSION_NAME) 시작
- 동작:
  1. 환경변수 설정 (BUN_INSTALL, PATH, LANG=C.UTF-8, LC_ALL=C.UTF-8)
  2. 기존 telegram 플러그인 프로세스 kill
  3. 커스텀 소켓($TMUX_SOCKET)으로 tmux -u 새 세션 생성 (UTF-8 강제)
  4. 세션 안에서 claude 실행 (--channels plugin:telegram, --dangerously-skip-permissions)
  5. tmux ls로 확인
- 주의: LANG/LC_ALL/tmux -u 없으면 이모티콘 포함 메시지에서 채널 멈춤 발생

### Watchdog ($WATCHDOG_SCRIPT)
- 역할: 오퍼 + 독립에이전트 감시 (cron 매 1분 실행)
- 설정값: 오퍼 타임아웃 600초, 독립 타임아웃 300초
- 동작:
  1. 오퍼 tmux 세션 존재 체크 → 없으면 재시작
  2. claude --channels 프로세스 존재 체크 → 없으면 재시작
  3. 텔레그램 플러그인 프로세스 존재 체크 → 없으면 재시작
  4. 텔레그램 헬스체크:
     - Bot API getMe 호출 → 네트워크 연결 확인
     - bun server.ts 프로세스 상태 확인 → 좀비(Z)/멈춤(T) 감지
  5. 오퍼 하트비트 체크 → pipeline-state.json의 current_status="running"일 때만 검사
  6. 독립에이전트 하트비트 순회
- 재시작 루프 방지: 10분 내 3회 이상 재시작 시 일시 중단, 10분 후 재시도 (알림 1회)
- 상세 로깅: 타임스탬프 + 메모리 잔량 + ACTION/STATUS
- 텔레그램 알림: Bot API 직접 호출 (curl)

### 독립에이전트 실행 ($IND_SCRIPT)
- 역할: 독립에이전트를 별도 tmux 세션에서 실행
- 입력: 에이전트이름, 프롬프트파일, 출력파일, [작업디렉토리(기본: $WORKSPACE_DIR)]
- tmux 소켓: $TMUX_SOCKET (오퍼와 동일 소켓, watchdog 감시 호환)

## 8. 오퍼 시작 시 체크 사항 (필수)

오퍼가 시작(또는 재시작)되면 반드시 아래를 확인한다:

1. 스크립트 파일 존재 확인 (3개)
   - 없으면 텔레그램으로 "스크립트가 없습니다. 명세에 따라 생성할까요?" 질문
   - 사용자 승인 후 7번 명세에 따라 생성
2. $WORKSPACE_DIR/ 디렉토리 + CLAUDE.md 존재 확인
   - 없으면 텔레그램으로 알리고 생성 여부 질문
3. tmux에 claude-ind-* 세션이 있는지 체크
4. $HEARTBEAT_DIR/claude-ind-* 하트비트 파일 확인
5. 작업 폴더의 pipeline-state.json 확인
6. 위 정보를 종합하여 텔레그램으로 사용자에게 보고
7. 사용자 승인 후 이어서 진행
CLAUDE_OP

if [ -f "$AGENT_DIR/CLAUDE.md" ]; then
  ok "오퍼 CLAUDE.md 생성 완료"
else
  fail "오퍼 CLAUDE.md 생성 실패"
fi

# ========================================
# 10. pipeline-state.json 초기화
# ========================================
echo ""
echo "[10/13] pipeline-state.json 초기화..."

if [ ! -f "$AGENT_DIR/pipeline-state.json" ]; then
  cat > "$AGENT_DIR/pipeline-state.json" << PIPELINE
{
  "pipeline": "",
  "steps": [],
  "current_step": "",
  "current_status": "idle",
  "current_agent": "",
  "output_file": "",
  "completed_steps": [],
  "updated_at": "$(date -Iseconds)"
}
PIPELINE
  ok "pipeline-state.json 초기화 완료"
else
  echo "  📦 기존 pipeline-state.json 유지"
  ok "pipeline-state.json 이미 존재"
fi

# ========================================
# 11. 검증/복구 스크립트 생성
# ========================================
echo ""
echo "[11/13] 검증/복구 스크립트 생성..."

VERIFY_SCRIPT="$HOME_DIR/claude-setup-verify.sh"

cat > "$VERIFY_SCRIPT" << 'VERIFY_EOF'
#!/bin/bash
# Claude Code 설정 검증 및 복구 스크립트
# 사용법:
#   검증: bash claude-setup-verify.sh [에이전트이름]
#   복구: bash claude-setup-verify.sh --restore [에이전트이름]
#   setup에서 자동 호출: bash claude-setup-verify.sh --auto 에이전트이름

MODE="verify"
AUTO=false
AGENT_NAME=""

for ARG in "$@"; do
  case "$ARG" in
    --restore) MODE="restore" ;;
    --auto) AUTO=true ;;
    *) AGENT_NAME="$ARG" ;;
  esac
done

echo "========================================"
if [ "$MODE" = "verify" ]; then
  echo "  Claude Code 설정 검증"
else
  echo "  Claude Code 설정 복구 (백업에서)"
fi
echo "========================================"
echo ""

if [ -z "$AGENT_NAME" ]; then
  read -p "에이전트 이름 (예: agent1): " AGENT_NAME
fi

HOME_DIR="$HOME"
AGENT_DIR="$HOME_DIR/$AGENT_NAME"
WORKSPACE_DIR="$HOME_DIR/workspace"
SESSION_NAME="claude-$AGENT_NAME"
TMUX_SOCKET="/tmp/tmux-$SESSION_NAME"
HEARTBEAT_DIR="/tmp/claude-heartbeats"
START_SCRIPT="$HOME_DIR/claude-${AGENT_NAME}-start.sh"
WATCHDOG_SCRIPT="$HOME_DIR/claude-${AGENT_NAME}-watchdog.sh"
WATCHDOG_LOG="$HOME_DIR/watchdog-${AGENT_NAME}.log"
IND_SCRIPT="$AGENT_DIR/run-independent-agent.sh"
GLOBAL_CLAUDE="$HOME_DIR/.claude"
CHANNEL_DIR="$GLOBAL_CLAUDE/channels/telegram"

PASS=0
FAIL=0

ok() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
info() { echo "  ℹ️  $1"; }

# ========================================
# 복구 모드
# ========================================
if [ "$MODE" = "restore" ]; then
  echo "백업 파일 검색 중..."
  echo ""

  restore_file() {
    local TARGET="$1"
    local DIR=$(dirname "$TARGET")
    local BASE=$(basename "$TARGET")
    local LATEST=$(ls -t "$DIR/${BASE}.bak."* 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
      echo "  복구 대상: $TARGET"
      echo "  백업 파일: $LATEST"
      read -p "  복구할까요? (y/n): " CONFIRM
      if [ "$CONFIRM" = "y" ]; then
        cp "$LATEST" "$TARGET"
        ok "$BASE 복구 완료"
      else
        info "$BASE 복구 건너뜀"
      fi
    else
      info "$BASE 백업 파일 없음"
    fi
    echo ""
  }

  delete_file() {
    local TARGET="$1"
    local BASE=$(basename "$TARGET")
    if [ -f "$TARGET" ]; then
      echo "  삭제 대상: $TARGET"
      read -p "  삭제할까요? (y/n): " CONFIRM
      if [ "$CONFIRM" = "y" ]; then
        rm -f "$TARGET"
        ok "$BASE 삭제 완료"
      else
        info "$BASE 삭제 건너뜀"
      fi
    else
      info "$BASE 이미 없음"
    fi
    echo ""
  }

  delete_dir() {
    local TARGET="$1"
    local BASE=$(basename "$TARGET")
    if [ -d "$TARGET" ]; then
      echo "  삭제 대상 디렉토리: $TARGET"
      read -p "  삭제할까요? (y/n): " CONFIRM
      if [ "$CONFIRM" = "y" ]; then
        rm -rf "$TARGET"
        ok "$BASE/ 삭제 완료"
      else
        info "$BASE/ 삭제 건너뜀"
      fi
    else
      info "$BASE/ 이미 없음"
    fi
    echo ""
  }

  echo "=== 1단계: 백업에서 복구 (덮어쓴 파일) ==="
  echo ""
  restore_file "$GLOBAL_CLAUDE/settings.json"
  restore_file "$START_SCRIPT"
  restore_file "$WATCHDOG_SCRIPT"
  restore_file "$AGENT_DIR/CLAUDE.md"
  restore_file "$WORKSPACE_DIR/CLAUDE.md"

  echo "=== 2단계: v2.0에서 새로 만든 것 삭제 ==="
  echo ""
  delete_file "$IND_SCRIPT"
  delete_file "$AGENT_DIR/pipeline-state.json"

  if crontab -l 2>/dev/null | grep -q "$WATCHDOG_SCRIPT"; then
    echo "  crontab에서 watchdog 항목 발견"
    read -p "  제거할까요? (y/n): " CONFIRM
    if [ "$CONFIRM" = "y" ]; then
      CRON_TMP=$(mktemp)
      crontab -l 2>/dev/null | grep -v "$WATCHDOG_SCRIPT" > "$CRON_TMP"
      crontab "$CRON_TMP"
      rm -f "$CRON_TMP"
      ok "crontab watchdog 항목 제거"
    else
      info "crontab 제거 건너뜀"
    fi
    echo ""
  fi

  if [ -d "$WORKSPACE_DIR" ]; then
    WS_FILES=$(ls -A "$WORKSPACE_DIR" 2>/dev/null | grep -v "CLAUDE.md.bak" | wc -l)
    if [ "$WS_FILES" -le 1 ]; then
      delete_dir "$WORKSPACE_DIR"
    else
      info "workspace/에 파일이 있어서 삭제하지 않음 (${WS_FILES}개 파일)"
      echo ""
    fi
  fi

  echo "========================================"
  echo "  복구 완료! ✅ $PASS 처리됨"
  echo "========================================"
  echo ""
  exit 0
fi

# ========================================
# 검증 모드
# ========================================

echo "[1/13] UTF-8 인코딩..."
if grep -q "LANG=C.UTF-8" "$HOME_DIR/.bashrc" 2>/dev/null; then
  ok "LANG=C.UTF-8 설정됨"
else
  fail "LANG=C.UTF-8 미설정 (.bashrc)"
fi

echo "[2/13] cron 서비스..."
if systemctl is-active --quiet cron 2>/dev/null; then
  ok "cron 실행 중"
else
  fail "cron 미실행"
fi

echo "[3/13] 전역 settings.json..."
if [ -f "$GLOBAL_CLAUDE/settings.json" ]; then
  grep -q "extraKnownMarketplaces" "$GLOBAL_CLAUDE/settings.json" && ok "마켓플레이스 설정 있음" || fail "마켓플레이스 설정 없음"
  grep -q '"telegram@claude-plugins-official": true' "$GLOBAL_CLAUDE/settings.json" && ok "텔레그램 플러그인 활성화(true)" || fail "텔레그램 플러그인 미활성화"
  grep -q "PostToolUse" "$GLOBAL_CLAUDE/settings.json" && ok "하트비트 hook 설정됨" || fail "하트비트 hook 없음"
  BACKUP_COUNT=$(ls "$GLOBAL_CLAUDE/settings.json.bak."* 2>/dev/null | wc -l)
  [ "$BACKUP_COUNT" -gt 0 ] && info "백업 파일: ${BACKUP_COUNT}개"
else
  fail "settings.json 없음"
fi

echo "[4/13] 텔레그램 채널 설정..."
[ -f "$CHANNEL_DIR/.env" ] && grep -q "TELEGRAM_BOT_TOKEN=" "$CHANNEL_DIR/.env" && ok "봇 토큰 설정됨" || fail "봇 토큰 없음"
[ -f "$CHANNEL_DIR/access.json" ] && grep -q "allowFrom" "$CHANNEL_DIR/access.json" && ok "allowlist 설정됨" || fail "allowlist 없음"
DUP_COUNT=$(ls -d "$GLOBAL_CLAUDE/channels/telegram-"* 2>/dev/null | wc -l)
[ "$DUP_COUNT" -gt 0 ] && fail "중복 채널 폴더 ${DUP_COUNT}개 발견" || ok "중복 채널 없음"

echo "[5/13] 디렉토리..."
[ -d "$AGENT_DIR" ] && ok "에이전트 디렉토리" || fail "에이전트 디렉토리 없음"
[ -d "$WORKSPACE_DIR" ] && ok "workspace 디렉토리" || fail "workspace 디렉토리 없음"
[ -d "$HEARTBEAT_DIR" ] && ok "하트비트 디렉토리" || fail "하트비트 디렉토리 없음"

echo "[6/13] workspace settings.local.json (플러그인 비활성화)..."
if [ -f "$WORKSPACE_DIR/.claude/settings.local.json" ] && grep -q '"telegram@claude-plugins-official": false' "$WORKSPACE_DIR/.claude/settings.local.json"; then
  ok "독립에이전트 플러그인 비활성화 설정됨"
else
  fail "settings.local.json 없음 또는 플러그인 비활성화 미설정 (독립에이전트에서 플러그인 충돌 위험)"
fi

echo "[7/13] claude-${AGENT_NAME}-start.sh..."
if [ -x "$START_SCRIPT" ] && grep -q "claude --channels" "$START_SCRIPT"; then
  ok "시작 스크립트 정상"
  grep -q "LANG=C.UTF-8" "$START_SCRIPT" && ok "UTF-8 로캘 설정" || fail "LANG=C.UTF-8 미설정 (이모지 메시지 처리 실패 위험)"
  grep -q "tmux -u" "$START_SCRIPT" && ok "tmux UTF-8 플래그" || fail "tmux -u 미설정 (이모지 렌더링 실패 위험)"
else
  fail "시작 스크립트 없음 또는 불완전"
fi

echo "[8/13] claude-${AGENT_NAME}-watchdog.sh..."
if [ -x "$WATCHDOG_SCRIPT" ]; then
  grep -q "has-session" "$WATCHDOG_SCRIPT" && ok "tmux 세션 체크" || fail "tmux 세션 체크 없음"
  grep -q 'pgrep -f "claude --channels"' "$WATCHDOG_SCRIPT" && ok "claude 프로세스 체크" || fail "claude 프로세스 체크 없음"
  grep -q 'pgrep -f "telegram.*start"' "$WATCHDOG_SCRIPT" && ok "텔레그램 플러그인 체크" || fail "텔레그램 플러그인 체크 없음"
  grep -q "getMe" "$WATCHDOG_SCRIPT" && ok "Bot API 헬스체크" || fail "Bot API 헬스체크 없음"
  grep -q "bun server.ts" "$WATCHDOG_SCRIPT" && ok "프로세스 상태(Z/T) 체크" || fail "프로세스 상태 체크 없음"
  grep -q "check_restart_loop" "$WATCHDOG_SCRIPT" && ok "재시작 루프 방지" || fail "재시작 루프 방지 없음"
  grep -q "MEM_AVAIL" "$WATCHDOG_SCRIPT" && ok "메모리 로깅" || fail "메모리 로깅 없음"
  grep -q "claude-ind-" "$WATCHDOG_SCRIPT" && ok "독립에이전트 감시" || fail "독립에이전트 감시 없음"
else
  fail "watchdog 스크립트 없음 또는 실행 권한 없음"
fi

echo "[9/13] run-independent-agent.sh..."
if [ -x "$IND_SCRIPT" ] && grep -q "claude -p" "$IND_SCRIPT"; then
  ok "독립에이전트 스크립트 정상"
else
  fail "독립에이전트 스크립트 없음 또는 불완전"
fi

echo "[10/13] CLAUDE.md 파일..."
[ -f "$WORKSPACE_DIR/CLAUDE.md" ] && ok "workspace CLAUDE.md" || fail "workspace CLAUDE.md 없음"
if [ -f "$AGENT_DIR/CLAUDE.md" ]; then
  grep -q "서브에이전트.*Agent tool" "$AGENT_DIR/CLAUDE.md" && ok "오퍼 CLAUDE.md: 서브에이전트 규칙" || fail "서브에이전트 규칙 없음"
  grep -q "플러그인 설정" "$AGENT_DIR/CLAUDE.md" && ok "오퍼 CLAUDE.md: 플러그인 설정" || fail "플러그인 설정 없음"
  grep -q "독립에이전트" "$AGENT_DIR/CLAUDE.md" && ok "오퍼 CLAUDE.md: 독립에이전트 규칙" || fail "독립에이전트 규칙 없음"
  grep -q "감시 체계" "$AGENT_DIR/CLAUDE.md" && ok "오퍼 CLAUDE.md: 감시 체계" || fail "감시 체계 없음"
  grep -q "파이프라인" "$AGENT_DIR/CLAUDE.md" && ok "오퍼 CLAUDE.md: 파이프라인 관리" || fail "파이프라인 관리 없음"
  grep -q "헬스체크" "$AGENT_DIR/CLAUDE.md" && ok "오퍼 CLAUDE.md: 헬스체크" || fail "헬스체크 없음"
else
  fail "오퍼 CLAUDE.md 없음"
fi

echo "[11/13] pipeline-state.json..."
if [ -f "$AGENT_DIR/pipeline-state.json" ] && grep -q "current_status" "$AGENT_DIR/pipeline-state.json"; then
  STATUS=$(grep -o '"current_status"[[:space:]]*:[[:space:]]*"[^"]*"' "$AGENT_DIR/pipeline-state.json" | grep -o '"[^"]*"$' | tr -d '"')
  ok "pipeline-state.json 정상 (상태: $STATUS)"
else
  fail "pipeline-state.json 없음 또는 형식 오류"
fi

echo "[12/13] crontab..."
crontab -l 2>/dev/null | grep -q "$WATCHDOG_SCRIPT" && ok "watchdog crontab 등록됨" || fail "watchdog crontab 미등록"

echo "[13/13] Telegram 봇 연결..."
if [ -f "$CHANNEL_DIR/.env" ]; then
  BOT_TOKEN=$(grep "TELEGRAM_BOT_TOKEN=" "$CHANNEL_DIR/.env" | cut -d'=' -f2)
  if [ -n "$BOT_TOKEN" ]; then
    RESPONSE=$(curl -s -m 5 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null)
    if echo "$RESPONSE" | grep -q '"ok":true'; then
      BOT_NAME=$(echo "$RESPONSE" | grep -o '"first_name":"[^"]*"' | cut -d'"' -f4)
      ok "봇 연결 성공: $BOT_NAME"
    else
      fail "봇 연결 실패"
    fi
  else
    fail "봇 토큰 비어있음"
  fi
else
  fail "채널 .env 없음"
fi

echo ""
echo "--- 런타임 상태 ---"
tmux -S "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null && ok "오퍼 tmux 세션 실행 중" || info "오퍼 tmux 세션 없음"
pgrep -f "claude --channels" > /dev/null 2>&1 && ok "claude 프로세스 실행 중" || info "claude 프로세스 없음"
pgrep -f "telegram.*start" > /dev/null 2>&1 && ok "텔레그램 플러그인 실행 중" || info "텔레그램 플러그인 없음"
if [ -f "$HEARTBEAT_DIR/$SESSION_NAME" ]; then
  LAST_BEAT=$(cat "$HEARTBEAT_DIR/$SESSION_NAME" 2>/dev/null)
  NOW=$(date +%s)
  ELAPSED=$((NOW - LAST_BEAT))
  ok "오퍼 하트비트: ${ELAPSED}초 전"
else
  info "오퍼 하트비트 파일 없음"
fi

echo ""
echo "========================================"
echo "  검증 결과: ✅ $PASS / ❌ $FAIL"
echo "========================================"
HAS_BACKUPS=false
ls "$GLOBAL_CLAUDE/settings.json.bak."* "$START_SCRIPT.bak."* "$WATCHDOG_SCRIPT.bak."* "$AGENT_DIR/CLAUDE.md.bak."* 2>/dev/null | head -1 > /dev/null 2>&1 && HAS_BACKUPS=true

if [ "$FAIL" -eq 0 ]; then
  echo "  모든 항목 정상!"
  echo ""
elif [ "$HAS_BACKUPS" = true ]; then
  echo "  $FAIL개 항목에 문제가 있습니다."
  echo ""
  read -p "  백업에서 복구할까요? (y/n): " DO_RESTORE
  if [ "$DO_RESTORE" = "y" ]; then
    echo ""
    exec bash "$0" --restore "$AGENT_NAME"
  else
    echo ""
    echo "  수동 복구: bash $0 --restore $AGENT_NAME"
    echo "  재설치: bash claude-setup-v2.5.sh"
    echo ""
  fi
else
  echo "  $FAIL개 항목에 문제가 있습니다."
  echo "  재설치: bash claude-setup-v2.5.sh"
  echo ""
fi
VERIFY_EOF

chmod +x "$VERIFY_SCRIPT"

if [ -x "$VERIFY_SCRIPT" ]; then
  ok "검증/복구 스크립트 생성 완료: $VERIFY_SCRIPT"
else
  fail "검증/복구 스크립트 생성 실패"
fi

# ========================================
# 12. 봇 토큰 연결 테스트
# ========================================
echo ""
echo "[12/13] Telegram 봇 연결 테스트..."
RESPONSE=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getMe")

if echo "$RESPONSE" | grep -q '"ok":true'; then
  BOT_NAME=$(echo "$RESPONSE" | grep -o '"first_name":"[^"]*"' | cut -d'"' -f4)
  ok "봇 연결 성공: $BOT_NAME"
else
  fail "봇 토큰이 유효하지 않습니다"
fi

# ========================================
# 13. claude 시작 + 플러그인 대기 + crontab 등록
# ========================================
echo ""
echo "[13/13] Claude 시작 + 플러그인 캐시 + crontab 등록..."

# claude 시작
echo "  Claude 시작 중..."
bash "$START_SCRIPT"
sleep 5

# 플러그인 프로세스 대기 (최대 3분, 10초 간격)
echo ""
echo "  ⏳ 플러그인 설치 확인 중..."
echo ""
PLUGIN_READY=false
for i in $(seq 1 18); do
  if pgrep -f "telegram.*start" > /dev/null 2>&1; then
    PLUGIN_READY=true
    break
  fi
  ELAPSED=$((i * 10))
  echo "  ⏳ 플러그인 설치 대기 중... (${ELAPSED}초/180초)"
  sleep 10
done

if [ "$PLUGIN_READY" = true ]; then
  ok "플러그인 정상 시작!"
else
  echo ""
  echo "  ⚠️ 플러그인이 3분 내 시작되지 않았습니다."
  echo "  원인: 네트워크 문제 / 인증 미완료 / 채널 활성화 대기"
  echo "  확인: tmux -S /tmp/tmux-claude-${AGENT_NAME} attach -t claude-${AGENT_NAME}"
  echo ""
  fail "플러그인 미설치 (watchdog이 재시작을 시도합니다)"
fi

# 테스트 메시지 전송
curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -d chat_id="$CHAT_ID" -d text="🎉 Claude Code 설정 완료! ($AGENT_NAME) v2.5" > /dev/null 2>&1
ok "테스트 메시지 전송 완료"

# crontab 등록
CRON_LINE="* * * * * /bin/bash $WATCHDOG_SCRIPT >> $WATCHDOG_LOG 2>&1"
CRON_TMP=$(mktemp)
( crontab -l 2>/dev/null | grep -v "$WATCHDOG_SCRIPT"; echo "$CRON_LINE" ) > "$CRON_TMP"
crontab "$CRON_TMP"
rm -f "$CRON_TMP"

if crontab -l 2>/dev/null | grep -q "$WATCHDOG_SCRIPT"; then
  ok "crontab 등록 완료 (매 1분 watchdog 실행)"
else
  fail "crontab 등록 실패"
fi

# ========================================
# 설치 결과 요약
# ========================================
echo ""
echo "========================================"
echo "  설치 완료! ✅ $PASS / ❌ $FAIL"
echo "========================================"

# ========================================
# 검증 자동 실행
# ========================================
VERIFY_SCRIPT="$HOME_DIR/claude-setup-verify.sh"
if [ -x "$VERIFY_SCRIPT" ]; then
  echo ""
  echo "검증 스크립트를 자동 실행합니다..."
  echo ""
  bash "$VERIFY_SCRIPT" --auto "$AGENT_NAME"
else
  echo ""
  echo "⚠️ 검증 스크립트($VERIFY_SCRIPT)가 없습니다."
  echo "  검증 스크립트를 같은 폴더에 두면 설치 후 자동 검증됩니다."
fi

echo ""
echo "텔레그램에서 봇 응답을 확인한 후 exit를 입력하세요."
echo "exit 후 watchdog이 자동으로 재시작합니다."
echo ""
echo "검증 재실행:"
echo "  bash $VERIFY_SCRIPT $AGENT_NAME"
echo ""
echo "복구:"
echo "  bash $VERIFY_SCRIPT --restore $AGENT_NAME"
echo ""
