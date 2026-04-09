#!/bin/bash
# Claude Code 자동 설정 스크립트
# 사용법: bash claude-setup.sh
# 전제조건: Claude Code가 이미 설치되어 있고 로그인 완료 상태

set -e

echo "========================================"
echo "  Claude Code 자동 설정 스크립트"
echo "========================================"
echo ""

# --- 사용자 입력 ---
read -p "텔레그램 봇 토큰: " BOT_TOKEN
read -p "텔레그램 Chat ID: " CHAT_ID
read -p "에이전트 이름 (예: agent1): " AGENT_NAME

HOME_DIR="$HOME"
AGENT_DIR="$HOME_DIR/$AGENT_NAME"
SESSION_NAME="claude-$AGENT_NAME"
TMUX_SOCKET="/tmp/tmux-$SESSION_NAME"
START_SCRIPT="$HOME_DIR/claude-${AGENT_NAME}-start.sh"
WATCHDOG_SCRIPT="$HOME_DIR/claude-${AGENT_NAME}-watchdog.sh"
WATCHDOG_LOG="$HOME_DIR/watchdog-${AGENT_NAME}.log"

echo ""
echo "설정 정보:"
echo "  에이전트 디렉토리: $AGENT_DIR"
echo "  tmux 세션: $SESSION_NAME"
echo "  시작 스크립트: $START_SCRIPT"
echo "  watchdog 스크립트: $WATCHDOG_SCRIPT"
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
echo "[1/9] 한글/UTF-8 인코딩 설정..."
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
echo "[2/9] cron 설치..."
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
# 3. Telegram 플러그인 자동승인 (전역)
# ========================================
echo ""
echo "[3/9] 전역 설정 (settings.json)..."
GLOBAL_CLAUDE="$HOME_DIR/.claude"
mkdir -p "$GLOBAL_CLAUDE"

cat > "$GLOBAL_CLAUDE/settings.json" << 'SETTINGS'
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
  }
}
SETTINGS

if [ -f "$GLOBAL_CLAUDE/settings.json" ]; then
  ok "전역 settings.json 생성 완료"
else
  fail "전역 settings.json 생성 실패"
fi

# ========================================
# 4. Telegram 플러그인 채널 설정
# ========================================
echo ""
echo "[4/9] Telegram 채널 설정..."

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
# 5. 프로젝트 디렉토리 + 프로젝트 설정
# ========================================
echo ""
echo "[5/9] 프로젝트 디렉토리 설정..."
mkdir -p "$AGENT_DIR/.claude"

cat > "$AGENT_DIR/.claude/settings.json" << 'SETTINGS'
{
  "bypassPermissionsConfirmed": true
}
SETTINGS

if [ -d "$AGENT_DIR/.claude" ] && [ -f "$AGENT_DIR/.claude/settings.json" ]; then
  ok "프로젝트 디렉토리 및 settings.json 생성 완료"
else
  fail "프로젝트 디렉토리 생성 실패"
fi

# ========================================
# 6. 시작 스크립트
# ========================================
echo ""
echo "[6/9] 시작 스크립트 생성..."

cat > "$START_SCRIPT" << EOF
#!/bin/bash
TMUX_SOCKET=$TMUX_SOCKET

export BUN_INSTALL="$HOME_DIR/.bun"
export PATH="\$BUN_INSTALL/bin:$HOME_DIR/.local/bin:/usr/local/bin:/usr/bin:/bin"
tmux -S \$TMUX_SOCKET kill-session -t $SESSION_NAME 2>/dev/null || true
pkill -f "telegram.*start" 2>/dev/null || true
sleep 2

cd $AGENT_DIR

tmux -S \$TMUX_SOCKET new-session -d -s $SESSION_NAME \\
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
# 7. Watchdog 스크립트
# ========================================
echo ""
echo "[7/9] Watchdog 스크립트 생성..."

cat > "$WATCHDOG_SCRIPT" << EOF
#!/bin/bash
TMUX_SOCKET=$TMUX_SOCKET
SESSION_NAME=$SESSION_NAME
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"

send_telegram() {
  curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \\
    -d chat_id="\$CHAT_ID" -d text="\$1" > /dev/null 2>&1
}

# tmux 세션이 없으면 재시작
if ! tmux -S \$TMUX_SOCKET has-session -t \$SESSION_NAME 2>/dev/null; then
  send_telegram "⚠️ 클로드 코드가 죽어있어서 재시작합니다..."
  bash $START_SCRIPT
  sleep 5
  send_telegram "✅ 클로드 코드 재시작 완료!"
  exit 0
fi

# tmux는 있지만 claude 프로세스가 죽었으면 재시작
if ! pgrep -f "claude --channels" > /dev/null 2>&1; then
  send_telegram "⚠️ 클로드 코드 프로세스가 죽어있어서 재시작합니다..."
  tmux -S \$TMUX_SOCKET kill-session -t \$SESSION_NAME 2>/dev/null || true
  pkill -f "telegram.*start" 2>/dev/null || true
  sleep 2
  bash $START_SCRIPT
  sleep 5
  send_telegram "✅ 클로드 코드 재시작 완료!"
fi
EOF

chmod +x "$WATCHDOG_SCRIPT"

if [ -x "$WATCHDOG_SCRIPT" ]; then
  ok "Watchdog 스크립트 생성 완료: $WATCHDOG_SCRIPT"
else
  fail "Watchdog 스크립트 생성 실패"
fi

# ========================================
# 8. crontab 등록
# ========================================
echo ""
echo "[8/9] crontab 등록..."
CRON_LINE="* * * * * /bin/bash $WATCHDOG_SCRIPT >> $WATCHDOG_LOG 2>&1"

(crontab -l 2>/dev/null | grep -v "$WATCHDOG_SCRIPT"; echo "$CRON_LINE") | crontab -

if crontab -l 2>/dev/null | grep -q "$WATCHDOG_SCRIPT"; then
  ok "crontab 등록 완료 (매 1분 watchdog 실행)"
else
  fail "crontab 등록 실패"
fi

# ========================================
# 9. 검증 - 봇 토큰 연결 테스트
# ========================================
echo ""
echo "[9/9] Telegram 봇 연결 테스트..."
RESPONSE=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getMe")

if echo "$RESPONSE" | grep -q '"ok":true'; then
  BOT_NAME=$(echo "$RESPONSE" | grep -o '"first_name":"[^"]*"' | cut -d'"' -f4)
  ok "봇 연결 성공: $BOT_NAME"

  # 테스트 메시지 전송
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" -d text="🎉 Claude Code 설정 완료! ($AGENT_NAME)" > /dev/null 2>&1
  ok "테스트 메시지 전송 완료"
else
  fail "봇 토큰이 유효하지 않습니다"
fi

# ========================================
# 결과 요약
# ========================================
echo ""
echo "========================================"
echo "  설정 완료! ✅ $PASS / ❌ $FAIL"
echo "========================================"
echo ""
echo "시작하려면:"
echo "  bash $START_SCRIPT"
echo ""
echo "상태 확인:"
echo "  tmux -S $TMUX_SOCKET ls"
echo ""
