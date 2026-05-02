#!/bin/bash
# Claude Code 자동 설정 스크립트 v2.7.6
# 사용법: bash claude-setup-v2.7.6.sh
# 전제조건: Claude Code가 이미 설치되어 있고 로그인 완료 상태
#
# v2.7.6 변경사항 (2026-05-02):
#   - 고정 버전을 2.1.119 → 2.1.126으로 갱신 (검증된 안정 버전 업데이트)
#   - 119/126 모두 sandbox 환경 무관하게 동작 확인됨
#   - 절대경로·자동 업데이트 차단 구조는 동일 유지
#   - 심링크를 설치된 버전으로 강제 정리 추가 (신규/기존 VM 모두 일관 보장)
#   - 재배포 자동 감지: 운영 중인 claude 있으면 자동 pkill (즉시 적용)
#
# v2.7.5 변경사항 (2026-04-26):
#   - start.sh 119 고정: claude 자동 업데이트 차단(DISABLE_AUTOUPDATER=1) + 절대경로(CLAUDE_BIN) 사용
#   - 2.1.120 호환성 이슈 대응 (sandbox 요구로 tmux+plugin 모드에서 멈춤 발생)
#   - 119 절대경로 직접 호출로 심링크 변경에 무관하게 안정 운영
#   - 설치 시점에 119 존재 확인 → 없으면 npm install 자동 실행 (미보유 VM도 자동 설치)
#
# v2.7 변경사항 (2026-04-24):
#   - Groq API 키 설치 중 프롬프트 추가 (케이스1: 기존 있음 → 유지/재입력/삭제, 케이스2: 없음 → 입력/건너뛰기)
#   - 생성 파일에 "# Generated from claude-setup v2.7" 버전 마커 추가 (start.sh, watchdog.sh, run-independent-agent.sh, voice-patch.py, daily-review.sh, 자동 핸들러)
#   - 생성 파일의 기능·로직은 v2.6과 완전히 동일 (문서적 변경만)
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
# v2.6 변경사항:
#   - start.sh: claude 호출에 --continue --fork-session 추가 (OOM 재시작 시 세션 컨텍스트 자동 복원)
#   - pgrep/pkill 패턴 regex화 ("claude --channels" → "claude.*--channels"): claude 플래그가 중간에 끼어도 매칭 성공
#   - 세션 파일 30일 자동 정리 cron 추가 (매일 03:00, /home/hsy/cleanup-sessions.log 로깅)
#   - CLAUDE.md에 §5 재시작 복원 동작, §7 pgrep regex 주의, §9 세션 파일 관리 섹션 동기화

SETUP_VERSION="2.7.6"
SETUP_DATE="$(date +%Y-%m-%d)"

echo "========================================"
echo "  Claude Code 자동 설정 스크립트 v${SETUP_VERSION}"
echo "========================================"
echo ""

# --- 사용자 입력 ---
read -p "에이전트 이름 (예: agent1): " AGENT_NAME

# 기존 설정 확인
GLOBAL_CLAUDE="$HOME/.claude"
EXISTING_TOKEN=""
EXISTING_CHATID=""
EXISTING_GROQ=""

if [ -f "$GLOBAL_CLAUDE/channels/telegram/.env" ]; then
  EXISTING_TOKEN=$(grep "^TELEGRAM_BOT_TOKEN=" "$GLOBAL_CLAUDE/channels/telegram/.env" 2>/dev/null | cut -d'=' -f2)
  EXISTING_GROQ=$(grep "^GROQ_API_KEY=" "$GLOBAL_CLAUDE/channels/telegram/.env" 2>/dev/null | cut -d'=' -f2)
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

# --- Groq API 키 설정 (음성 메시지 지원) ---
echo ""
echo "[Groq Whisper 음성 메시지 설정]"
echo "- 무료 발급: https://console.groq.com"
echo "- 하루 2,000건 한도, 한국어 지원"
echo ""

GROQ_KEY=""
if [ -n "$EXISTING_GROQ" ]; then
  # 케이스1: 기존 키 있음
  MASKED="${EXISTING_GROQ:0:8}...${EXISTING_GROQ: -4}"
  echo "✓ 기존 Groq API 키가 등록되어 있습니다 ($MASKED)."
  read -p "선택: (y=유지, n=재입력, s=삭제): " GROQ_CHOICE
  case "$GROQ_CHOICE" in
    y|Y)
      GROQ_KEY="$EXISTING_GROQ"
      ;;
    n|N)
      read -p "Groq API 키: " GROQ_KEY
      ;;
    s|S)
      GROQ_KEY=""
      echo "✓ Groq 키 삭제됨. 음성 기능 비활성화."
      ;;
    *)
      GROQ_KEY="$EXISTING_GROQ"
      echo "(알 수 없는 선택 → 유지로 처리)"
      ;;
  esac
else
  # 케이스2: 기존 키 없음
  echo "Groq API 키를 등록하세요. 없으면 엔터만 눌러 건너뛰기."
  read -p "Groq API 키: " GROQ_KEY
  # 공백 제거 (사용자가 스페이스만 입력한 경우 방지)
  GROQ_KEY="$(echo -n "$GROQ_KEY" | tr -d '[:space:]')"
  if [ -z "$GROQ_KEY" ]; then
    echo "✓ 건너뛰기. 음성 기능 비활성화. 나중에 .env에 GROQ_API_KEY=xxx 추가로 활성 가능."
  fi
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

# --- 2.1.126 버전 사전 확인/설치 (v2.7.5) ---
# start.sh가 절대경로로 126 호출하므로 설치 시점에 126 존재 보장 필요
echo ""
echo "[사전] 2.1.126 버전 파일 확인..."
CLAUDE_126="$HOME_DIR/.local/share/claude/versions/2.1.126"
if [ ! -x "$CLAUDE_126" ]; then
  echo "  ⚠️ 126 없음 → npm으로 자동 설치 시도..."
  if ! command -v npm >/dev/null 2>&1; then
    echo "  ❌ npm 명령 없음. 126 수동 설치 후 setup 재실행하세요."
    exit 1
  fi
  if ! npm install -g @anthropic-ai/claude-code@2.1.126; then
    echo "  ❌ npm install 실패. 네트워크/권한 확인 후 재시도."
    exit 1
  fi
  if [ ! -x "$CLAUDE_126" ]; then
    echo "  ❌ 설치 후에도 $CLAUDE_126 없음. 수동 점검 필요."
    exit 1
  fi
  echo "  ✓ 126 설치 완료"
else
  echo "  ✓ 126 버전 존재"
fi

# 심링크를 사용 버전으로 강제 정리 (v2.7.6, 2026-05-02)
# 신규 설치 시: npm이 이미 설정한 심링크를 명시적 재설정 (안전)
# 기존 환경: 다른 버전 가리키던 심링크를 사용 버전으로 교체
SYMLINK="$HOME_DIR/.local/bin/claude"
if ln -sfn "$CLAUDE_126" "$SYMLINK" 2>/dev/null; then
  echo "  ✓ 심링크 → 2.1.126"
else
  echo "  ⚠️ 심링크 변경 실패 (권한 등). 운영엔 영향 없음 (start.sh가 절대경로 사용)"
fi

PASS=0
FAIL=0

ok() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

# 생성 파일에 버전 마커 삽입 (shebang 다음 줄)
# 용법: add_version_marker <파일경로> [코멘트 접두사, 기본 "#"]
add_version_marker() {
  local f="$1"
  local prefix="${2:-#}"
  local marker="${prefix} Generated from claude-setup v${SETUP_VERSION} (${SETUP_DATE})"
  [ -f "$f" ] || return 0
  if head -1 "$f" | grep -q '^#!'; then
    sed -i "1a ${marker}" "$f"
  else
    sed -i "1i ${marker}" "$f"
  fi
}

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
echo "TELEGRAM_CHAT_ID=$CHAT_ID" >> "$CHANNEL_DIR/.env"
if [ -n "$GROQ_KEY" ]; then
  echo "GROQ_API_KEY=$GROQ_KEY" >> "$CHANNEL_DIR/.env"
fi
chmod 600 "$CHANNEL_DIR/.env"

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
# claude-${AGENT_NAME} 시작 스크립트
#
# 변경 이력:
#   2026-04-18: Phase 2 모델 폴백체인 추가 (임시 → 영구 → 기본)
#               PERMANENT_MODEL=claude-opus-4-7 영구 모델 설정
#               임시 오버라이드 파일(/tmp/claude-${AGENT_NAME}-model-override) 지원
#   2026-04-26: 2.1.120 sandbox 호환성 이슈 대응 (setup v2.7.5)
#               - DISABLE_AUTOUPDATER=1 자동 업데이트 차단
#               - CLAUDE_BIN 절대경로 사용으로 119 강제 (심링크 무시)
#               - 119 부재 시 npm install 자동 복구 + 알림
#   2026-05-02: 고정 버전을 119 → 126으로 갱신 (setup v2.7.6)
#
TMUX_SOCKET=$TMUX_SOCKET
START_LOG=$HOME_DIR/claude-${AGENT_NAME}-start.log

# 모델 설정 (2026-04-18 Phase 2 + 폴백)
PERMANENT_MODEL="claude-opus-4-7"
TEMP_OVERRIDE_FILE="/tmp/claude-${AGENT_NAME}-model-override"
ENV_FILE="$HOME_DIR/.claude/channels/telegram/.env"

notify_telegram() {
  if [ -f "\$ENV_FILE" ]; then
    local token=\$(grep '^TELEGRAM_BOT_TOKEN=' "\$ENV_FILE" | cut -d'=' -f2)
    local chat=\$(grep '^TELEGRAM_CHAT_ID=' "\$ENV_FILE" | cut -d'=' -f2)
    if [ -n "\$token" ] && [ -n "\$chat" ]; then
      curl -s -m 10 "https://api.telegram.org/bot\${token}/sendMessage" \\
        -d "chat_id=\${chat}" --data-urlencode "text=\$1" > /dev/null 2>&1
    fi
  fi
}
log() { echo "[\$(date -Iseconds)] \$1" | tee -a "\$START_LOG"; }

export BUN_INSTALL="$HOME_DIR/.bun"
export PATH="\$BUN_INSTALL/bin:$HOME_DIR/.local/bin:/usr/local/bin:/usr/bin:/bin"
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
# 자동 업데이터 차단 (2026-05-02: 검증된 안정 버전 126 고정)
export DISABLE_AUTOUPDATER=1
# 126 고정 절대경로 (심링크 무시)
CLAUDE_BIN="$HOME_DIR/.local/share/claude/versions/2.1.126"

# 126 부재 시 npm으로 자동 복구 (2026-04-26)
if [ ! -x "\$CLAUDE_BIN" ]; then
  log "126 없음 → npm install 자동 시도"
  if command -v npm >/dev/null 2>&1; then
    if npm install -g @anthropic-ai/claude-code@2.1.126 >/dev/null 2>&1; then
      log "126 npm install 성공"
      notify_telegram "🤖 [자동 처리 완료 type=claude_126_install action=npm_install] 126 파일 부재 → npm으로 자동 설치 완료"
    else
      log "126 npm install 실패"
      notify_telegram "🚨 [ALERT type=claude_126_install_fail severity=critical] 126 파일 부재 + npm install 실패. 수동 점검 필요."
    fi
  else
    log "npm 명령 없음, 126 자동 복구 불가"
    notify_telegram "🚨 [ALERT type=claude_126_missing severity=critical] 126 파일 없고 npm도 없음. 수동 설치 필요."
  fi
fi

tmux -S \$TMUX_SOCKET kill-session -t $SESSION_NAME 2>/dev/null || true
pkill -9 -f "claude.*--channels" 2>/dev/null || true
pkill -9 -f "telegram.*start" 2>/dev/null || true
pkill -9 -f "bun server.ts" 2>/dev/null || true
sleep 2

if [ -x $HOME_DIR/claude-${AGENT_NAME}-voice-patch.py ]; then
  python3 $HOME_DIR/claude-${AGENT_NAME}-voice-patch.py 2>&1 | grep -v "^\$" || true
fi

ATTEMPT_LABELS=()
ATTEMPT_FLAGS=()
if [ -f "\$TEMP_OVERRIDE_FILE" ]; then
  TEMP_MODEL=\$(head -1 "\$TEMP_OVERRIDE_FILE" | tr -d '[:space:]')
  rm -f "\$TEMP_OVERRIDE_FILE"
  if [ -n "\$TEMP_MODEL" ]; then
    ATTEMPT_LABELS+=("temp:\$TEMP_MODEL")
    ATTEMPT_FLAGS+=("--model \$TEMP_MODEL")
  fi
fi
if [ -n "\$PERMANENT_MODEL" ]; then
  ATTEMPT_LABELS+=("permanent:\$PERMANENT_MODEL")
  ATTEMPT_FLAGS+=("--model \$PERMANENT_MODEL")
fi
ATTEMPT_LABELS+=("default")
ATTEMPT_FLAGS+=("")

cd $AGENT_DIR
SUCCESS=false
for i in "\${!ATTEMPT_LABELS[@]}"; do
  LABEL="\${ATTEMPT_LABELS[\$i]}"
  FLAG="\${ATTEMPT_FLAGS[\$i]}"
  log "기동 시도 [\$((i+1))/\${#ATTEMPT_LABELS[@]}]: \$LABEL"
  tmux -S \$TMUX_SOCKET kill-session -t $SESSION_NAME 2>/dev/null || true
  pkill -9 -f "claude.*--channels" 2>/dev/null || true
  sleep 1
  tmux -u -S \$TMUX_SOCKET new-session -d -s $SESSION_NAME \\
    "\$CLAUDE_BIN --continue --fork-session \$FLAG --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions"
  sleep 6
  if pgrep -f "claude.*--channels" > /dev/null 2>&1; then
    log "기동 성공: \$LABEL"
    SUCCESS=true
    if [ "\$i" -gt 0 ]; then
      notify_telegram "⚠️ [ALERT type=model_fallback severity=warning] 모델 [\${ATTEMPT_LABELS[0]}] 기동 실패 → [\$LABEL] 폴백 성공"
    fi
    break
  fi
  log "기동 실패: \$LABEL (5초 내 프로세스 미확인)"
done

if [ "\$SUCCESS" = false ]; then
  log "모든 기동 시도 실패"
  notify_telegram "🚨 [ALERT type=start_fail severity=critical] start.sh: 모든 모델 시도 실패, watchdog 개입 필요"
fi

sleep 2
chmod 700 \$TMUX_SOCKET 2>/dev/null || true
tmux -S \$TMUX_SOCKET ls 2>&1 | tee -a "\$START_LOG"
EOF

chmod +x "$START_SCRIPT"
add_version_marker "$START_SCRIPT"

if [ -x "$START_SCRIPT" ]; then
  ok "시작 스크립트 생성 완료: $START_SCRIPT"
else
  fail "시작 스크립트 생성 실패"
fi

# ========================================
# 6-b. Groq 음성 패치 자가 복구 스크립트
# ========================================
VOICE_PATCH_SCRIPT="$HOME_DIR/claude-${AGENT_NAME}-voice-patch.py"
cat > "$VOICE_PATCH_SCRIPT" << 'VOICE_PATCH_EOF'
#!/usr/bin/env python3
"""
Groq 음성 인식 패치 자가 복구 스크립트
- 조건: GROQ_API_KEY가 .env에 있을 때만 동작
- 동작: 최신 telegram 플러그인의 server.ts에 패치가 없으면 자동 적용
- 호출: start.sh에서 claude 실행 전
"""
import os
import glob
import sys

HOME = os.path.expanduser("~")
ENV_FILE = f"{HOME}/.claude/channels/telegram/.env"
PLUGIN_GLOB = f"{HOME}/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts"

if not os.path.isfile(ENV_FILE):
    sys.exit(0)
with open(ENV_FILE) as f:
    env = f.read()
if "GROQ_API_KEY=" not in env:
    sys.exit(0)

server_ts_list = sorted(glob.glob(PLUGIN_GLOB))
if not server_ts_list:
    sys.exit(0)
server_ts = server_ts_list[-1]

with open(server_ts) as f:
    content = f.read()
if "transcribeVoice" in content:
    sys.exit(0)

groq_code = """const GROQ_API_KEY = process.env.GROQ_API_KEY

// Groq Whisper STT: transcribe a voice/audio buffer to text
async function transcribeVoice(fileBuffer: Buffer, mimeType?: string): Promise<string> {
  if (!GROQ_API_KEY) return '(음성 변환 실패: GROQ_API_KEY 미설정)'
  try {
    const formData = new FormData()
    const ext = mimeType?.includes('ogg') ? 'ogg' : 'mp3'
    formData.append('file', new Blob([fileBuffer], { type: mimeType ?? 'audio/ogg' }), `voice.${ext}`)
    formData.append('model', 'whisper-large-v3-turbo')
    formData.append('language', 'ko')
    formData.append('response_format', 'text')
    const res = await fetch('https://api.groq.com/openai/v1/audio/transcriptions', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${GROQ_API_KEY}` },
      body: formData,
    })
    if (!res.ok) {
      const errText = await res.text()
      process.stderr.write(`telegram channel: Groq STT error: ${res.status} ${errText}\\n`)
      return `(음성 변환 실패: HTTP ${res.status})`
    }
    const text = (await res.text()).trim()
    return text || '(음성 내용 없음)'
  } catch (err) {
    process.stderr.write(`telegram channel: Groq STT exception: ${err}\\n`)
    return `(음성 변환 실패: ${err})`
  }
}

"""

marker_a = "const STATIC = process.env.TELEGRAM_ACCESS_MODE === 'static'"
if marker_a in content:
    content = content.replace(marker_a, marker_a + "\n" + groq_code, 1)
else:
    sys.stderr.write("voice-patch: STATIC marker not found, abort\n")
    sys.exit(1)

old_handler = """bot.on('message:voice', async ctx => {
  const voice = ctx.message.voice
  const text = ctx.message.caption ?? '(voice message)'
  await handleInbound(ctx, text, undefined, {
    kind: 'voice',
    file_id: voice.file_id,
    size: voice.file_size,
    mime: voice.mime_type,
  })
})"""

new_handler = """bot.on('message:voice', async ctx => {
  const voice = ctx.message.voice
  let text = ctx.message.caption ?? '(voice message)'
  // Groq Whisper STT: download and transcribe voice
  if (GROQ_API_KEY) {
    try {
      const file = await ctx.api.getFile(voice.file_id)
      if (file.file_path) {
        const url = `https://api.telegram.org/file/bot${TOKEN}/${file.file_path}`
        const res = await fetch(url)
        if (res.ok) {
          const buf = Buffer.from(await res.arrayBuffer())
          const transcribed = await transcribeVoice(buf, voice.mime_type)
          text = transcribed
        }
      }
    } catch (err) {
      process.stderr.write(`telegram channel: voice download/transcribe failed: ${err}\\n`)
    }
  }
  await handleInbound(ctx, text, undefined, {
    kind: 'voice',
    file_id: voice.file_id,
    size: voice.file_size,
    mime: voice.mime_type,
  })
})"""

if old_handler in content:
    content = content.replace(old_handler, new_handler, 1)
else:
    sys.stderr.write("voice-patch: voice handler pattern not found, abort\n")
    sys.exit(1)

with open(server_ts, "w") as f:
    f.write(content)
print(f"voice-patch: applied to {server_ts}")
VOICE_PATCH_EOF

chmod +x "$VOICE_PATCH_SCRIPT"
add_version_marker "$VOICE_PATCH_SCRIPT"
ok "Groq 음성 패치 자가 복구 스크립트 생성 완료: $VOICE_PATCH_SCRIPT"

# ========================================
# 6-c. Phase 3 자동 핸들러 스크립트 (auto-handlers)
# ========================================
AUTO_HANDLERS_DIR="$HOME_DIR/claude-${AGENT_NAME}-auto-handlers"
mkdir -p "$AUTO_HANDLERS_DIR"

cat > "$AUTO_HANDLERS_DIR/zombie_bun_restart.sh" << 'HANDLER_EOF'
#!/bin/bash
# 좀비/멈춤 상태의 bun server.ts 프로세스만 재기동 (claude 전체 재시작 회피)
BUN_PID=$(pgrep -f "bun server.ts" 2>/dev/null | head -1)
if [ -z "$BUN_PID" ]; then
  echo "zombie_bun_restart: bun PID 없음"
  exit 1
fi
PROC_STATE=$(cat /proc/$BUN_PID/status 2>/dev/null | grep "^State:" | awk '{print $2}')
if [ "$PROC_STATE" != "Z" ] && [ "$PROC_STATE" != "T" ]; then
  echo "zombie_bun_restart: 프로세스 정상 상태(${PROC_STATE}) — 조건 미충족"
  exit 2
fi
kill -9 $BUN_PID 2>/dev/null
sleep 3
NEW_PID=$(pgrep -f "bun server.ts" 2>/dev/null | head -1)
if [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$BUN_PID" ]; then
  echo "zombie_bun_restart: 성공 (old PID=$BUN_PID → new PID=$NEW_PID)"
  exit 0
else
  echo "zombie_bun_restart: bun 재생성 실패 — claude 재시작 필요"
  exit 3
fi
HANDLER_EOF

cat > "$AUTO_HANDLERS_DIR/tmp_cleanup.sh" << 'HANDLER_EOF'
#!/bin/bash
# /tmp의 claude 관련 30일+ 방치 파일 정리
CLEANUP_LOG="/home/hsy/claude-preventive-restart.log"
PATTERNS=(
  "/tmp/claude-heartbeats/*"
  "/tmp/claude-watchdog-*"
  "/tmp/claude-b*-cwd"
)
DELETED_COUNT=0
for pattern in "${PATTERNS[@]}"; do
  while IFS= read -r f; do
    if [ -n "$f" ]; then
      echo "[$(date -Iseconds)] tmp_cleanup: 삭제 $f" >> "$CLEANUP_LOG"
      rm -f "$f"
      DELETED_COUNT=$((DELETED_COUNT + 1))
    fi
  done < <(find $pattern -type f -mtime +30 2>/dev/null)
done
echo "tmp_cleanup: ${DELETED_COUNT}개 파일 정리 완료"
exit 0
HANDLER_EOF

chmod +x "$AUTO_HANDLERS_DIR"/*.sh
add_version_marker "$AUTO_HANDLERS_DIR/zombie_bun_restart.sh"
add_version_marker "$AUTO_HANDLERS_DIR/tmp_cleanup.sh"
ok "Phase 3 auto-handlers 스크립트 생성 완료: $AUTO_HANDLERS_DIR"

# ========================================
# 6-d. Daily Review 스크립트
# ========================================
DAILY_REVIEW_SCRIPT="$HOME_DIR/claude-${AGENT_NAME}-daily-review.sh"
cat > "$DAILY_REVIEW_SCRIPT" << DAILY_EOF
#!/bin/bash
# 매일 09:00 KST 실행되는 일일 리뷰 (v2: §13 6개 항목 완결)
# 1. 자동 처리 건수 (어제·오늘, type별)
# 2. 허용 목록 현황
# 3. 승격 후보 (5회+ 이력)
# 4. 강등 후보 (폴백 과다)
# 5. 허용 목록 변경 이력 (24h)
# 6. 시스템 상태 스냅샷
set +e
ENV_FILE="\$HOME/.claude/channels/telegram/.env"
[ -f "\$ENV_FILE" ] && source "\$ENV_FILE"
BOT_TOKEN="\${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="\${TELEGRAM_CHAT_ID:-}"
WATCHDOG_LOG="$HOME_DIR/watchdog-${AGENT_NAME}.log"
CLAUDE_MD="$AGENT_DIR/CLAUDE.md"
DAILY_LOG="$HOME_DIR/daily-review.log"
MEM_DIR="\$HOME/.claude/projects/-home-\$USER-${AGENT_NAME}/memory"

send_telegram() {
  if [ -n "\$BOT_TOKEN" ] && [ -n "\$CHAT_ID" ]; then
    curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \\
      -d chat_id="\$CHAT_ID" --data-urlencode "text=\$1" > /dev/null 2>&1
  fi
}

YESTERDAY=\$(date -d 'yesterday' '+%Y-%m-%d')
TODAY=\$(date '+%Y-%m-%d')

# 1. 자동 처리 (어제·오늘)
AUTO_COUNT=0
AUTO_TYPES=""
if [ -f "\$WATCHDOG_LOG" ]; then
  AUTO_LINES=\$(grep "자동 처리 완료" "\$WATCHDOG_LOG" 2>/dev/null | grep -E "\[\$YESTERDAY|\[\$TODAY")
  AUTO_COUNT=\$(echo "\$AUTO_LINES" | grep -c "자동 처리 완료" || echo 0)
  AUTO_TYPES=\$(echo "\$AUTO_LINES" | sed -E 's/.*type=([a-z_]+).*/\1/' | sort | uniq -c | head -10)
fi

# 2. 허용 목록 현황
GREEN_COUNT=\$(awk '/### 🟢/,/### 🟡/' "\$CLAUDE_MD" 2>/dev/null | grep -c "^| [a-z_]" || echo 0)
YELLOW_COUNT=\$(awk '/### 🟡/,/### 🔴/' "\$CLAUDE_MD" 2>/dev/null | grep -c "^| [a-z_]" || echo 0)

# 3. 승격 후보 (5회+ 이력)
PROMO_CANDIDATES=""
if [ -d "\$MEM_DIR" ]; then
  for f in "\$MEM_DIR"/alert_*.md; do
    [ -f "\$f" ] || continue
    TYPE=\$(basename "\$f" .md | sed 's/^alert_//')
    COUNT=\$(grep -c "^-\|^2026-" "\$f" 2>/dev/null || echo 0)
    if [ "\$COUNT" -ge 5 ]; then
      PROMO_CANDIDATES+=\$'\n'"- \${TYPE} (\${COUNT}회 이력)"
    fi
  done
fi

# 4. 강등 후보 (폴백 과다)
DEMO_CANDIDATES=""
if [ -f "\$WATCHDOG_LOG" ]; then
  FALLBACK_COUNT=\$(grep -E "\[\$YESTERDAY|\[\$TODAY" "\$WATCHDOG_LOG" 2>/dev/null | grep -c "실패 → .* 폴백")
  FALLBACK_COUNT=\${FALLBACK_COUNT:-0}
  if [ "\$FALLBACK_COUNT" -ge 3 ] 2>/dev/null; then
    DEMO_CANDIDATES=\$'\n'"- 어제~오늘 폴백 \${FALLBACK_COUNT}회 → handler 신뢰도 재검토"
  fi
fi

# 5. 허용 목록 변경 이력 (24h)
CHANGE_HIST=""
if [ -f "\$CLAUDE_MD" ]; then
  MD_MTIME=\$(stat -c %Y "\$CLAUDE_MD")
  NOW_TS=\$(date +%s)
  DIFF_HOURS=\$(( (NOW_TS - MD_MTIME) / 3600 ))
  if [ "\$DIFF_HOURS" -lt 24 ]; then
    CHANGE_HIST=\$'\n'"- CLAUDE.md 최근 수정: \${DIFF_HOURS}시간 전 (허용 목록 변경 가능성)"
  fi
fi

# 6. 시스템 상태
MEM_TOTAL=\$(awk '/MemTotal/ {print \$2}' /proc/meminfo)
MEM_AVAIL=\$(awk '/MemAvailable/ {print \$2}' /proc/meminfo)
MEM_PCT=\$(awk -v t=\$MEM_TOTAL -v a=\$MEM_AVAIL 'BEGIN{printf "%.0f", (t-a)*100/t}')
DISK_PCT=\$(df /home | awk 'NR==2 {print \$5}' | tr -d '%')
SESSION_COUNT=\$(ls \$HOME/.claude/projects/-home-\$USER-${AGENT_NAME}/*.jsonl 2>/dev/null | wc -l)

# tmp 정리 (🟡 조건부)
TMP_HANDLER=$AUTO_HANDLERS_DIR/tmp_cleanup.sh
TMP_RESULT=""
if [ -x "\$TMP_HANDLER" ]; then
  TMP_RESULT=\$("\$TMP_HANDLER" 2>&1)
fi

REPORT=\$(cat <<EOR
📊 [일일 리뷰 \${TODAY}]

■ 자동 처리 (어제~오늘)
- 총 건수: \${AUTO_COUNT}건
\${AUTO_TYPES:+\$AUTO_TYPES}

■ 허용 목록 현황
- 🟢 자동: \${GREEN_COUNT}개
- 🟡 조건부: \${YELLOW_COUNT}개

■ 승격 후보 (5회+ 이력)\${PROMO_CANDIDATES:- 없음}

■ 강등 후보 (폴백 과다)\${DEMO_CANDIDATES:- 없음}

■ 허용 목록 변경 (24h)\${CHANGE_HIST:- 없음}

■ 시스템 상태
- 메모리: \${MEM_PCT}% 사용
- 디스크: \${DISK_PCT}% 사용
- 세션 파일: \${SESSION_COUNT}개

■ tmp 정리
\${TMP_RESULT}
EOR
)

send_telegram "\$REPORT"
echo "[\$(date -Iseconds)] daily-review: 리포트 전송 완료" >> "\$DAILY_LOG"
DAILY_EOF

chmod +x "$DAILY_REVIEW_SCRIPT"
add_version_marker "$DAILY_REVIEW_SCRIPT"
ok "Daily Review 스크립트 생성 완료: $DAILY_REVIEW_SCRIPT"

# ========================================
# 6-e. Log Rotation 스크립트 (2026-04-18 보안 감사 후 추가)
# ========================================
LOGROTATE_SCRIPT="$HOME_DIR/claude-${AGENT_NAME}-logrotate.sh"
cat > "$LOGROTATE_SCRIPT" << 'LOGROTATE_EOF'
#!/bin/bash
# Claude Agent 로그 회전 (sudo 불필요, bash 구현)
# 1MB 초과 시 회전, 14개 보관, gzip 압축

LOGS=(
  "__HOME__/watchdog-__AGENT__.log"
  "__HOME__/cleanup-sessions.log"
  "__HOME__/claude-preventive-restart.log"
  "__HOME__/daily-review.log"
)
MAX_SIZE=1048576
KEEP_COUNT=14

rotate_log() {
  local logfile="$1"
  [ ! -f "$logfile" ] && return 0
  local size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
  [ "$size" -lt "$MAX_SIZE" ] && return 0
  local stamp=$(date '+%Y%m%d_%H%M%S')
  cp "$logfile" "${logfile}.${stamp}"
  : > "$logfile"
  gzip "${logfile}.${stamp}" 2>/dev/null
  local old_count=$(ls -1 "${logfile}".*.gz 2>/dev/null | wc -l)
  if [ "$old_count" -gt "$KEEP_COUNT" ]; then
    ls -1t "${logfile}".*.gz | tail -n +$((KEEP_COUNT + 1)) | xargs -r rm -f
  fi
  echo "[$(date -Iseconds)] rotated: $logfile (size=$size)"
}

for log in "${LOGS[@]}"; do
  rotate_log "$log"
done
LOGROTATE_EOF

sed -i "s|__HOME__|$HOME_DIR|g" "$LOGROTATE_SCRIPT"
sed -i "s|__AGENT__|$AGENT_NAME|g" "$LOGROTATE_SCRIPT"
chmod +x "$LOGROTATE_SCRIPT"
add_version_marker "$LOGROTATE_SCRIPT"
ok "Log Rotation 스크립트 생성 완료: $LOGROTATE_SCRIPT"

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

# Bot Token/Chat ID는 .env에서 로드 (2026-04-18 보안 개선, 하드코딩 제거)
ENV_FILE="__ENV_FILE__"
if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a
fi
BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
CHAT_ID="${TELEGRAM_CHAT_ID}"
HEARTBEAT_DIR="__HEARTBEAT_DIR__"
OPERATOR_HEARTBEAT="${HEARTBEAT_DIR}/__SESSION_NAME__"
OPERATOR_TIMEOUT=600
IND_TIMEOUT=300
START_SCRIPT="__START_SCRIPT__"
WATCHDOG_LOG="__WATCHDOG_LOG__"
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

# Phase 1-A: 메모리 사용률 85% 초과 경고 (1시간 중복 방지, 2026-04-18)
MEM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_AVAIL_KB=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
MEM_USED_PCT=$(awk -v t="$MEM_TOTAL" -v a="$MEM_AVAIL_KB" 'BEGIN{printf "%.0f", (t-a)*100/t}')
MEM_WARN_FILE=/tmp/claude-watchdog-mem-warn
if [ "$MEM_USED_PCT" -ge 85 ]; then
  LAST_WARN=0
  [ -f "$MEM_WARN_FILE" ] && LAST_WARN=$(cat "$MEM_WARN_FILE")
  if [ $((NOW - LAST_WARN)) -gt 3600 ]; then
    log "WARN: 메모리 사용률 ${MEM_USED_PCT}% (임계 85% 초과) → OOM 임박 가능"
    send_telegram "⚠️ [ALERT type=memory_warn severity=warning used_pct=${MEM_USED_PCT}] 메모리 사용률 ${MEM_USED_PCT}% (임계 85% 초과). OOM 임박 가능. 사용자 승인 시 pkill로 재시작 가능."
    echo "$NOW" > "$MEM_WARN_FILE"
  fi
fi

# Phase 1-A-auto: 새벽(02:00~06:00 KST) + 90%+ → 자동 재시작 (🟡 조건부, 2026-04-18)
CUR_HOUR=$(date '+%H')
if [ "$MEM_USED_PCT" -ge 90 ] && [ "$CUR_HOUR" -ge 2 ] && [ "$CUR_HOUR" -lt 6 ]; then
  log "AUTO: memory_warn_auto 조건 충족 (시각 ${CUR_HOUR}시 + ${MEM_USED_PCT}%) → pkill claude"
  send_telegram "🤖 [자동 처리 완료 type=memory_warn_auto action=pkill_claude used_pct=${MEM_USED_PCT}] 새벽 시간대 + 메모리 ${MEM_USED_PCT}% → claude 재시작 (watchdog이 1분 내 --continue로 복구)"
  pkill -9 -f "claude.*--channels" 2>/dev/null || true
  exit 0
fi

# Phase 1-B: 재시작 빈도 이상 감지 (1시간 내 4회 이상, 1시간 중복 방지, 2026-04-18)
FREQ_WARN_FILE=/tmp/claude-watchdog-freq-warn
if [ -f "$WATCHDOG_LOG" ]; then
  HOUR_AGO_TS=$(date -d '60 minutes ago' '+%Y-%m-%d %H:%M:%S')
  RECENT_RESTARTS=$(awk -v cutoff="[$HOUR_AGO_TS]" '$0 ~ /ACTION.*재시작$/ && !/루프/ && !/중단/ && $0 > cutoff {c++} END{print c+0}' "$WATCHDOG_LOG")
  if [ "$RECENT_RESTARTS" -ge 4 ]; then
    LAST_FREQ=0
    [ -f "$FREQ_WARN_FILE" ] && LAST_FREQ=$(cat "$FREQ_WARN_FILE")
    if [ $((NOW - LAST_FREQ)) -gt 3600 ]; then
      log "WARN: 1시간 내 재시작 ${RECENT_RESTARTS}회 (이상 빈도) → 근본 원인 점검 필요"
      send_telegram "⚠️ [ALERT type=restart_freq severity=warning count=${RECENT_RESTARTS} window=1h] 1시간 내 ${RECENT_RESTARTS}회 재시작 발생. 근본 원인 점검 필요."
      echo "$NOW" > "$FREQ_WARN_FILE"
    fi
  fi
fi

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
  send_telegram "⚠️ [ALERT type=tmux_dead severity=critical] 클로드 코드 tmux 세션이 없어서 재시작합니다..."
  mkdir -p "$HEARTBEAT_DIR"
  date +%s > "$OPERATOR_HEARTBEAT"
  bash $START_SCRIPT
  sleep 5
  P_SUMMARY=$(get_pipeline_summary)
  send_telegram "✅ 클로드 코드 재시작 완료! [${P_SUMMARY}]"
  exit 0
fi

# tmux는 있지만 claude 프로세스가 죽었으면 재시작
if ! pgrep -f "claude.*--channels" > /dev/null 2>&1; then
  log "ACTION: tmux 있으나 claude 프로세스 없음 → 재시작"
  check_restart_loop
  send_telegram "⚠️ [ALERT type=claude_dead severity=critical] 클로드 코드 프로세스가 죽어있어서 재시작합니다..."
  tmux -S $TMUX_SOCKET kill-session -t $SESSION_NAME 2>/dev/null || true
  pkill -9 -f "telegram.*start" 2>/dev/null || true
  pkill -9 -f "bun server.ts" 2>/dev/null || true
  sleep 2
  mkdir -p "$HEARTBEAT_DIR"
  date +%s > "$OPERATOR_HEARTBEAT"
  bash $START_SCRIPT
  sleep 5
  P_SUMMARY=$(get_pipeline_summary)
  send_telegram "✅ 클로드 코드 재시작 완료! [${P_SUMMARY}]"
  exit 0
fi

# 텔레그램 플러그인 프로세스 체크 (재시도 + 재생성 대기, 2026-04-18 보강)
PLUGIN_OK=false
for attempt in 1 2 3; do
  if pgrep -f "telegram.*start" > /dev/null 2>&1; then
    PLUGIN_OK=true
    [ $attempt -gt 1 ] && log "STATUS: 플러그인 프로세스 ${attempt}회차 확인 성공 (재생성 완료)"
    break
  fi
  log "STATUS: 플러그인 프로세스 미확인 (시도 ${attempt}/3)"
  [ $attempt -lt 3 ] && sleep 5
done

if [ "$PLUGIN_OK" = false ]; then
  log "ACTION: 텔레그램 플러그인 프로세스 3회 연속 부재 → 재시작"
  check_restart_loop
  send_telegram "⚠️ [ALERT type=plugin_dead severity=warning attempts=3] 텔레그램 플러그인이 15초 내 재생성 안 됨 → 전체 재시작합니다..."
  tmux -S $TMUX_SOCKET kill-session -t $SESSION_NAME 2>/dev/null || true
  pkill -9 -f "claude.*--channels" 2>/dev/null || true
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

# 1단계: Bot API 네트워크 연결 확인 (재시도 + 원인 분류, 2026-04-18)
# 타임아웃 10초, 5초 간격으로 최대 3회 시도. 일시적 네트워크 장애로 인한 불필요한 재시작 방지.
TELEGRAM_OK=false
for attempt in 1 2 3; do
  TELEGRAM_HEALTH=$(curl -s -m 10 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null)
  if echo "$TELEGRAM_HEALTH" | grep -q '"ok":true'; then
    TELEGRAM_OK=true
    [ $attempt -gt 1 ] && log "STATUS: Bot API 시도 ${attempt}회차 성공 (일시 지연 복구)"
    break
  fi
  log "STATUS: Bot API 체크 실패 (시도 ${attempt}/3)"
  [ $attempt -lt 3 ] && sleep 5
done

if [ "$TELEGRAM_OK" = false ]; then
  if curl -s -m 5 --head https://www.google.com > /dev/null 2>&1; then
    CAUSE="서비스 장애 (인터넷 OK, Bot API만 실패)"
  else
    CAUSE="네트워크 장애 (인터넷 연결 실패)"
  fi
  log "ACTION: 3회 연속 Bot API 실패 → ${CAUSE} → 재시작"
  check_restart_loop
  send_telegram "⚠️ [ALERT type=bot_api_fail severity=critical attempts=3 cause=\"${CAUSE}\"] Bot API 헬스체크 3회 실패 → 재시작합니다..."
  tmux -S $TMUX_SOCKET kill-session -t $SESSION_NAME 2>/dev/null || true
  pkill -9 -f "claude.*--channels" 2>/dev/null || true
  pkill -9 -f "telegram.*start" 2>/dev/null || true
  pkill -9 -f "bun server.ts" 2>/dev/null || true
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
    log "ACTION: 텔레그램 플러그인 프로세스 비정상 상태(${PROC_STATE})"

    # Phase 3 🟡 자동 처리 시도 (bun만 재기동)
    ZOMBIE_HANDLER=__AUTO_HANDLERS_DIR__/zombie_bun_restart.sh
    if [ -x "$ZOMBIE_HANDLER" ]; then
      HANDLER_OUTPUT=$("$ZOMBIE_HANDLER" 2>&1)
      HANDLER_EXIT=$?
      log "AUTO: zombie_bun_restart exit=${HANDLER_EXIT}: ${HANDLER_OUTPUT}"
      if [ "$HANDLER_EXIT" -eq 0 ]; then
        send_telegram "🤖 [자동 처리 완료 type=zombie_bun_restart action=bun_kill] 좀비 bun(${PROC_STATE}) 재기동 성공"
        exit 0
      fi
      log "AUTO: 자동 처리 실패 → claude 전체 재시작 폴백"
    fi

    check_restart_loop
    send_telegram "⚠️ [ALERT type=plugin_dead severity=warning] 텔레그램 플러그인 ${PROC_STATE} 상태, 자동 처리 실패 → 전체 재시작"
    tmux -S $TMUX_SOCKET kill-session -t $SESSION_NAME 2>/dev/null || true
    pkill -9 -f "claude.*--channels" 2>/dev/null || true
    pkill -9 -f "telegram.*start" 2>/dev/null || true
    pkill -9 -f "bun server.ts" 2>/dev/null || true
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

# 오퍼 하트비트 체크 (Phase 3+ 보강, 2026-04-18)
# hang 조건: 파이프라인 active + 모든 독립 .done 존재 + ind tmux 세션 없음 + heartbeat stale
PIPELINE_ACTIVE=false
IND_AGENTS_EXIST=false
P_OUTPUT=""
if [ -f "$PIPELINE_STATE" ]; then
  CURRENT_STATUS=$(grep -o '"current_status"[[:space:]]*:[[:space:]]*"[^"]*"' "$PIPELINE_STATE" | grep -o '"[^"]*"$' | tr -d '"')
  [ "$CURRENT_STATUS" = "running" ] && PIPELINE_ACTIVE=true
  P_OUTPUT=$(grep -o '"output_file"[[:space:]]*:[[:space:]]*"[^"]*"' "$PIPELINE_STATE" | grep -o '"[^"]*"$' | tr -d '"')
fi
if tmux -S $TMUX_SOCKET ls 2>/dev/null | grep -q "^claude-ind-"; then
  IND_AGENTS_EXIST=true
fi

# 복수 output_file 지원 (쉼표 구분)
resolve_output_path() {
  local p="$1"
  p=$(echo "$p" | xargs)
  case "$p" in
    /*) echo "$p" ;;
    *)  echo "__AGENT_DIR__/$p" ;;
  esac
}

ALL_DONE=true
ANY_ERROR=false
ANY_OUTPUT_DEFINED=false
if [ -n "$P_OUTPUT" ]; then
  IFS=',' read -ra OUTPUT_LIST <<< "$P_OUTPUT"
  for out in "${OUTPUT_LIST[@]}"; do
    abs=$(resolve_output_path "$out")
    [ -z "$abs" ] && continue
    ANY_OUTPUT_DEFINED=true
    if [ -f "${abs}.error" ]; then
      ANY_ERROR=true
    elif [ ! -f "${abs}.done" ]; then
      ALL_DONE=false
    fi
  done
fi

if [ "$PIPELINE_ACTIVE" = true ] && [ "$ANY_OUTPUT_DEFINED" = true ] && [ "$ALL_DONE" = true ] && [ "$IND_AGENTS_EXIST" = false ] && [ -f "$OPERATOR_HEARTBEAT" ]; then
  LAST_BEAT=$(cat "$OPERATOR_HEARTBEAT" 2>/dev/null || echo "0")
  ELAPSED=$((NOW - LAST_BEAT))
  log "STATUS: 모든 독립 완료 + 파이프라인 running 유지 중, 오퍼 하트비트 ${ELAPSED}초 전"
  if [ "$ELAPSED" -gt "$OPERATOR_TIMEOUT" ]; then
    log "ACTION: 오퍼 hang 감지 (모든 독립 완료됐으나 오퍼 미처리, ${ELAPSED}초) → 강제 재시작"
    check_restart_loop
    send_telegram "⚠️ [ALERT type=heartbeat_hang severity=critical scope=operator elapsed=${ELAPSED}s] 모든 독립 완료됐으나 오퍼 미처리 ${ELAPSED}초 → 강제 재시작합니다..."
    tmux -S $TMUX_SOCKET kill-session -t $SESSION_NAME 2>/dev/null || true
    pkill -9 -f "claude.*--channels" 2>/dev/null || true
    pkill -9 -f "telegram.*start" 2>/dev/null || true
    pkill -9 -f "bun server.ts" 2>/dev/null || true
    sleep 2
    mkdir -p "$HEARTBEAT_DIR"
    date +%s > "$OPERATOR_HEARTBEAT"
    bash $START_SCRIPT
    sleep 5
    P_SUMMARY=$(get_pipeline_summary)
    send_telegram "✅ 오퍼 강제 재시작 완료! [${P_SUMMARY}]"
    exit 0
  fi
elif [ "$PIPELINE_ACTIVE" = true ] && [ "$IND_AGENTS_EXIST" = true ]; then
  log "STATUS: 파이프라인 활성, 독립 진행 중 (오퍼 대기 정상)"
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
      send_telegram "⚠️ [ALERT type=heartbeat_hang severity=warning scope=independent session=${IND_SESSION} elapsed=${ELAPSED}s] 독립에이전트 [${IND_SESSION}] ${ELAPSED}초간 무응답 → 강제 종료합니다"
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
    # 복수 output_file 지원 (쉼표 구분, 2026-04-18 fix ①)
    _ALL_DONE=true
    _ANY_ERROR=false
    _ERR_MSGS=""
    IFS=',' read -ra _OUT_LIST <<< "$P_OUTPUT"
    for _out in "${_OUT_LIST[@]}"; do
      _out=$(echo "$_out" | xargs)
      [ -z "$_out" ] && continue
      case "$_out" in
        /*) _abs="$_out" ;;
        *)  _abs="__AGENT_DIR__/$_out" ;;
      esac
      if [ -f "${_abs}.error" ]; then
        _ANY_ERROR=true
        _ERR_MSGS+="$(cat "${_abs}.error" 2>/dev/null); "
      elif [ ! -f "${_abs}.done" ]; then
        _ALL_DONE=false
      fi
    done

    NOTIFY_FLAG="/tmp/claude-watchdog-pipeline-notified"
    if [ "$_ANY_ERROR" = true ] && [ ! -f "$NOTIFY_FLAG" ]; then
      log "ACTION: 파이프라인 단계 [${P_STEP}] 실패(${_ERR_MSGS}), 오퍼 미인지 → 사용자 알림 + 상태 업데이트"
      sed -i 's/"current_status"[[:space:]]*:[[:space:]]*"running"/"current_status": "failed"/' "$PIPELINE_STATE"
      send_telegram "🔴 독립에이전트 [${P_AGENT}] 단계 '${P_STEP}' 실패! (${_ERR_MSGS}) 오퍼에게 메시지를 보내 상황을 확인해주세요."
      date +%s > "$NOTIFY_FLAG"
    elif [ "$_ALL_DONE" = true ] && [ ! -f "$NOTIFY_FLAG" ]; then
      log "ACTION: 파이프라인 단계 [${P_STEP}] 완료됨, 오퍼 미인지 → 사용자 알림 + 상태 업데이트"
      sed -i 's/"current_status"[[:space:]]*:[[:space:]]*"running"/"current_status": "done"/' "$PIPELINE_STATE"
      send_telegram "📋 독립에이전트 [${P_AGENT}] 단계 '${P_STEP}' 완료됨! 오퍼에게 메시지를 보내 다음 단계를 진행해주세요."
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
sed -i "s|__ENV_FILE__|$CHANNEL_DIR/.env|g" "$WATCHDOG_SCRIPT"
sed -i "s|__HEARTBEAT_DIR__|$HEARTBEAT_DIR|g" "$WATCHDOG_SCRIPT"
sed -i "s|__START_SCRIPT__|$START_SCRIPT|g" "$WATCHDOG_SCRIPT"
sed -i "s|__WATCHDOG_LOG__|$WATCHDOG_LOG|g" "$WATCHDOG_SCRIPT"
sed -i "s|__AGENT_DIR__|$AGENT_DIR|g" "$WATCHDOG_SCRIPT"
sed -i "s|__AUTO_HANDLERS_DIR__|$AUTO_HANDLERS_DIR|g" "$WATCHDOG_SCRIPT"

chmod 700 "$WATCHDOG_SCRIPT"  # 보안: 소유자만 읽기/실행 (BOT_TOKEN 관련 로직 포함, 2026-04-18)
add_version_marker "$WATCHDOG_SCRIPT"

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
# 사용법: ./run-independent-agent.sh <에이전트이름> <프롬프트파일> <출력파일> [작업디렉토리] [모델]
#   [모델] 생략 시 DEFAULT_MODEL(sonnet 4.6) 사용. 지정 시 해당 실행만 다른 모델로 동작, 다음 실행은 다시 기본값.

TMUX_SOCKET=__TMUX_SOCKET__
HEARTBEAT_DIR=__HEARTBEAT_DIR__
DEFAULT_WORKDIR=__WORKSPACE_DIR__
DEFAULT_MODEL="claude-sonnet-4-6"

AGENT_NAME=$1
PROMPT_FILE=$2
OUTPUT_FILE=$3
REQUESTED_WORKDIR=${4:-$DEFAULT_WORKDIR}
MODEL=${5:-$DEFAULT_MODEL}

# 2026-04-18 C 수정: WORK_DIR을 workspace로 강제 (플러그인 충돌 방지)
if [ "$REQUESTED_WORKDIR" != "$DEFAULT_WORKDIR" ] && [ "${REQUESTED_WORKDIR#$DEFAULT_WORKDIR/}" = "$REQUESTED_WORKDIR" ]; then
  echo "⚠️ WORK_DIR=$REQUESTED_WORKDIR 요청 무시. 독립에이전트는 workspace($DEFAULT_WORKDIR)에서 강제 실행 (플러그인 충돌 방지)"
fi
WORK_DIR="$DEFAULT_WORKDIR"

if [ -z "$AGENT_NAME" ] || [ -z "$PROMPT_FILE" ] || [ -z "$OUTPUT_FILE" ]; then
  echo "사용법: $0 <에이전트이름> <프롬프트파일> <출력파일> [작업디렉토리(무시됨, 항상 workspace)]"
  exit 1
fi

# Input validation (2026-04-18 보안 개선: shell injection 방지)
if ! echo "$AGENT_NAME" | grep -qE '^[a-zA-Z0-9_-]+$'; then
  echo "오류: 에이전트 이름은 영숫자·하이픈·언더스코어만 허용 (입력: $AGENT_NAME)"
  exit 1
fi
if [ ${#AGENT_NAME} -gt 64 ]; then
  echo "오류: 에이전트 이름이 너무 깁니다 (64자 이하)"
  exit 1
fi
for path_arg in "$PROMPT_FILE" "$OUTPUT_FILE" "$WORK_DIR"; do
  case "$path_arg" in
    *[\;\&\|\`\$\(\)\<\>]*)
      echo "오류: 경로에 shell 특수문자 사용 불가 ($path_arg)"
      exit 1
      ;;
  esac
done

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

claude -p "\$(cat $PROMPT_FILE)" --model $MODEL --dangerously-skip-permissions &
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

echo "독립에이전트 시작: $SESSION (작업디렉토리: $WORK_DIR, 모델: $MODEL)"
echo "완료 확인: ${OUTPUT_FILE}.done 또는 ${OUTPUT_FILE}.error"
IND_EOF

sed -i "s|__TMUX_SOCKET__|$TMUX_SOCKET|g" "$IND_SCRIPT"
sed -i "s|__HEARTBEAT_DIR__|$HEARTBEAT_DIR|g" "$IND_SCRIPT"
sed -i "s|__WORKSPACE_DIR__|$WORKSPACE_DIR|g" "$IND_SCRIPT"

chmod +x "$IND_SCRIPT"
add_version_marker "$IND_SCRIPT"

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

echo "" >> "$WORKSPACE_DIR/CLAUDE.md"
echo "<!-- Generated from claude-setup v${SETUP_VERSION} (${SETUP_DATE}) -->" >> "$WORKSPACE_DIR/CLAUDE.md"

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

### 음성 메시지 (Groq Whisper)
- 텔레그램 음성 메시지 → server.ts가 .oga 다운로드 → Groq Whisper API로 전송 → 텍스트 변환 → Claude에 전달
- API 키: ~/.claude/channels/telegram/.env의 GROQ_API_KEY
- 패치 위치: server.ts의 bot.on('message:voice') 핸들러 + transcribeVoice() 함수
- 모델: whisper-large-v3-turbo, 언어: ko
- 무료 한도: 하루 2,000건, 시간당 7,200초
- 주의: 플러그인 업데이트 시 패치 덮어씌워짐 → start.sh가 매 기동 시 voice-patch.py 자동 재적용 (§12 voice_patch_restore 🟢)

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

### 프로젝트 폴더 구조
- 프로젝트 작업은 $AGENT_DIR/{프로젝트명}/ 하위에서 관리
- 프로젝트 폴더 예: $AGENT_DIR/balmers/
  - roles/ → 프로젝트 전용 역할 파일
  - output-*.md → 결과 파일
- 작업폴더($AGENT_DIR/, $WORKSPACE_DIR/)는 시스템 고정, 프로젝트 폴더는 하위에 추가

### 역할 파일 참조 규칙
- 범용 역할: $WORKSPACE_DIR/roles/ (planner, writer, reviewer 등)
- 프로젝트 전용 역할: $AGENT_DIR/{프로젝트명}/roles/
- 참조 우선순위 (프로젝트 작업 시):
  1. 프로젝트 roles/에 해당 역할이 있으면 → 프로젝트 역할 사용
  2. 없으면 → workspace/roles/ 범용 역할 사용
- 프로젝트가 아닌 작업 → workspace/roles/ 범용만 사용
- 필요한 역할이 없으면 오퍼가 새 역할 파일을 생성한 후 사용

### 프롬프트 파일 작성 규칙
- 역할: 역할 파일 경로를 명시하여 참조 지시 (예: "$WORKSPACE_DIR/roles/planner.md를 읽고 역할을 따르세요")
- 작업 지시: 구체적인 작업 내용 (주제, 분량, 조건 등)
- 참조 파일: 이전 단계 결과물의 절대경로 (예: $AGENT_DIR/output-plan.md)
- 출력 파일: 결과를 저장할 절대경로 (예: $AGENT_DIR/output-implement.md)

### 스크립트 사용법
\`\`\`bash
$IND_SCRIPT <에이전트이름> <프롬프트파일> <출력파일> [작업디렉토리] [모델]
# 기본 작업디렉토리: $WORKSPACE_DIR/ (강제, 4번째 인수는 무시됨)
# 기본 모델: claude-sonnet-4-6 (5번째 인수 생략 시)
#   - 일회성 변경: 5번째 인수로 다른 모델 지정. 다음 실행은 다시 기본값.
#   - 예: claude-opus-4-7 / claude-haiku-4-5-20251001
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
1-1. start.sh의 \`--continue --fork-session\`으로 이전 대화 컨텍스트 자동 복원 (세션 .jsonl 기반). 재시작은 "기억상실"이 아니라 "컨텍스트 포크 복원"이 기본 동작.
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

병렬 복수 독립에이전트 실행 시:
- current_agent에 쉼표로 여러 세션 나열
- output_file에도 쉼표로 나열
- watchdog은 모든 .done이면 done 업데이트, 하나라도 .error면 failed 업데이트 (2026-04-18 ① 수정)
- hang 감지도 "모든 독립 완료 + 독립 세션 없음 + 오퍼 heartbeat stale"일 때만 발동 (오탐 방지, 2026-04-18 ③ 수정)

## 7. 스크립트 명세

스크립트 파일이 없으면 아래 명세에 따라 생성할 수 있다.

### 시작 스크립트 ($START_SCRIPT)
- 역할: 오퍼($SESSION_NAME) 시작
- 동작:
  1. 환경변수 설정 (BUN_INSTALL, PATH, LANG=C.UTF-8, LC_ALL=C.UTF-8)
  2. 기존 telegram 플러그인 프로세스 kill
  3. 커스텀 소켓($TMUX_SOCKET)으로 tmux -u 새 세션 생성 (UTF-8 강제)
  4. 세션 안에서 claude 실행 (--continue --fork-session --channels plugin:telegram, --dangerously-skip-permissions)
  5. tmux ls로 확인
- 주의: LANG/LC_ALL/tmux -u 없으면 이모티콘 포함 메시지에서 채널 멈춤 발생
- 주의: 프로세스 체크/종료용 pgrep/pkill 패턴은 리터럴이 아닌 regex(\`claude.*--channels\`)로 작성. claude 플래그가 중간에 끼어도 매칭되도록 함.

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

## 9. 세션 파일 관리

- 위치: ~/.claude/projects/-home-${USER}-${AGENT_NAME}/*.jsonl
- 포크 구조: \`--fork-session\`으로 재시작 시마다 새 세션 파일이 생성되고, 이전까지의 전체 대화 내용이 매 포크마다 새 파일에 복사됨 → 최신 파일 1개만으로 전체 대화 복원 가능
- 과거 포크 파일은 해당 시점까지의 완전한 스냅샷 (백업 역할)
- 자동 정리: 매일 03:00 cron이 mtime 30일 초과 .jsonl 삭제
  - cron 라인: \`0 3 * * * find ~/.claude/projects/-home-${USER}-${AGENT_NAME}/ -name '*.jsonl' -mtime +30 -print -delete >> ~/cleanup-sessions.log 2>&1\`
  - 삭제 로그: ~/cleanup-sessions.log
- 특정 세션을 영구 보존하고 싶으면 다른 경로로 복사하거나 \`touch\`로 mtime 갱신

### 예방 재시작 (메모리 누수 대응)
- 매일 03:00 cron으로 claude 프로세스 강제 종료 → watchdog이 1분 내 \`--continue --fork-session\`으로 자동 복구
- 실행 스크립트: \`~/claude-${AGENT_NAME}-preventive-restart.sh\` (echo 로그 + pkill)
- 로그: ~/claude-preventive-restart.log
- Claude Code의 알려진 누수 버그(GitHub Issues #18859, #21403 등)에 대응하는 업계 표준 "주기적 재시작" 패턴.
- Anthropic 공식 수정 출시 후 재검토

## 10. 응대 방식

### 기본 원칙
- 사용자는 떠오르는 질문을 **한 번에 묶어** 보내는 스타일을 선호할 수 있음. AI가 조직·정리 책임을 담당.
- 질문 받으면 **표면 답변 + 연관 후속 질문·대안·한계**까지 한 답변에 포함해 선제 제공.
- "질문을 나눠서 주세요" 식으로 사용자에게 부담 넘기지 말 것.
- 너무 멀리 가지 않기. 관련성 낮은 내용으로 노이즈 만들지 말 것 (적정선: 이어질 만한 2~3개 각도).

### 응답 길이 조절 (질문 난이도 기반)
- **단답·확인성 질문**: 1~3문장으로 마무리. 섹션·표·불릿 금지.
- **개념 설명·구현 제안**: 짧은 섹션 2~3개 + 소수 불릿. **기본 목표 분량**.
- **복잡한 설계·다중 옵션 비교**: 더 긴 구조화 응답(표 포함) 허용.
- **시스템 전체 설계·자가 복구·파이프라인 논의**: 문단으로 맥락을 충분히 풀어서 설명. 트리는 상세하게.
- 모든 답변에 "표 + 다중 섹션 + 메타 설명"을 기본 틀로 쓰지 말 것.
- "통합 답변"은 연관성이 분명할 때만. 억지로 각도를 넓혀 분량 부풀리지 말 것.
- 짧게 쓰려다 맥락이 끊기면 안 됨. 이해 가능성이 길이보다 우선.

### "바로 답변" 지시 처리
- 사용자가 "바로 답변" 또는 유사 지시 포함 시: **tool(Bash/Read/Grep/Glob/Web*) 전부 생략**.
- 사용 가능 정보: 학습 지식 + 자동 로드된 컨텍스트(CLAUDE.md, MEMORY.md 인덱스) + 이번 세션 과거 tool 결과.
- 적용 범위: 이미 논의된 내용 / 일반 학습 지식 / 학습 cutoff까지의 정보.
- 정보 부족 감지 시: **자동으로 tool 사용 금지**. 불완전 답변 + 한계 명시, 또는 사용자에게 tool 허용 요청.

### 방안 제시 시 범용성 표시
- 여러 방안을 제시하는 답변에는 각 방안의 **업계 범용성을 함께 표시**.
- 표기: ★★★ 업계 표준 / ★★ 흔함 / ★ 드묾 / ☆ 사용자 맞춤.

### "바로 답변" 시 답변 말미 품질 표시
- "바로 답변" 지시 시, 답변 본문 끝에 다음 형식으로 품질 메타데이터 첨부:
  \`\`\`
  ─ 답변 품질 ─
  • 확신도: 높음/중간/낮음
  • 근거: 학습지식/이번 대화/과거 세션 저장/추정
  • 외부 확인 권장: 불필요/선택/필수
  • 후속 옵션: ①그대로 사용 / ②tool 사용 허용 요청 / ③부분 확인
  \`\`\`

### CLAUDE.md 변경 시 연관 파일 동기화 (필수)
- CLAUDE.md 계열 파일 수정 시 **반드시 (1)현재 VM의 live 파일 + (2)setup 스크립트 내장 템플릿** 두 곳 모두 갱신.
- 오퍼 CLAUDE.md 수정:
  - Live: \$AGENT_DIR/CLAUDE.md
  - 템플릿: 자동 설정 스크립트의 CLAUDE_OP heredoc
- 독립에이전트 workspace CLAUDE.md 수정:
  - Live: \$WORKSPACE_DIR/CLAUDE.md
  - 템플릿: 자동 설정 스크립트의 CLAUDE_WS heredoc
- setup이 생성하는 다른 파일(start.sh, watchdog.sh, settings.json, 역할 파일 등)도 동일 원칙: Live + setup 템플릿 양쪽 모두 수정.
- 수정 완료 후 사용자에게 "Live + setup 템플릿 동기화 완료 (각 경로 명시)" 형태로 보고.

## 11. 메모리 관리

- MEMORY.md 줄 수를 상시 의식. **150줄 초과 시 사용자에게 정리 필요성 보고.**
- 새 메모리 저장 시점마다 현재 줄 수 확인하여 임계치 접근 체크.
- 통합·삭제는 반드시 사용자 승인 후 실행 (자동 삭제 금지).
- 삭제 전 해당 내용이 CLAUDE.md나 다른 메모리로 보존될 필요 없는지 확인.
- 통합 대상 우선순위: (1) 6개월 이상 된 일회성 사건 기록 (2) 같은 주제 중복 파일 (3) 완료된 프로젝트 관련 오래된 메모리.

## 12. 자동 실행 허용 목록 (Phase 3)

### 🟢 자동 실행 (승인 불필요, 사후 보고)
| type | 조건 | 실행 | 트리거 |
|─────|─────|─────|─────|
| voice_patch_restore | 패치 없음 + GROQ_API_KEY 존재 | voice-patch.py | start.sh |
| session_file_cleanup | .jsonl 30일+ | find -delete | cron 03:00 |
| preventive_restart | 매일 정기 | pkill claude | cron 03:00 |

### 🟡 조건부 자동
| type | 조건 | 실행 | 비자동 시 |
|─────|─────|─────|─────|
| zombie_bun_restart | bun 상태 Z/T | auto-handlers/zombie_bun_restart.sh | claude 전체 재시작 폴백 |
| tmp_cleanup | daily-review 실행 시점 | auto-handlers/tmp_cleanup.sh | 건너뜀 |
| memory_warn_auto | 새벽 02:00~06:00 KST + 사용률 ≥ 90% | pkill -9 claude (watchdog --continue 복구) | 그 외 → 경고만 (반자동) |

### 🔴 절대 승인 필수
- CLAUDE.md, MEMORY.md 편집
- memory/*.md 삭제·통합
- 스크립트 수정 (start.sh, watchdog.sh, voice-patch.py, auto-handlers/*, daily-review.sh, setup)
- settings.json, crontab 수정
- 세션 .jsonl 선택 삭제
- VM 리소스 변경
- 외부 API 키(.env) 수정
- 허용 목록 자체 변경

### 관리 원칙
- 신규 후보는 반자동 5회+ 안전 해결 이력 필요
- 오작동 시 즉시 강등
- 각 type별 대응 이력은 memory/alert_<type>.md에 누적

## 13. 알림 태그 포맷 및 일일 보고

### 알림 태그
\`\`\`
[ALERT type=<종류> severity=<info|warning|critical> ...추가필드]
<메시지>
\`\`\`

자동 처리는:
\`\`\`
🤖 [자동 처리 완료 type=<종류> action=<실행내용>]
<상세>
\`\`\`

### 주요 type
memory_warn, memory_warn_auto, restart_freq, bot_api_fail, oom_kill, plugin_dead, tmux_dead, claude_dead, zombie_bun_restart, heartbeat_hang, voice_patch_restore, session_file_cleanup, preventive_restart, tmp_cleanup, manual_approval

### 오퍼 응답 규칙
- [ALERT] 수신 시 태그 자동 파싱
- memory/alert_<type>.md Read로 과거 이력 확인
- critical·warning은 선제 대응 제안, info는 요약만
- 🤖 자동 처리 건은 확인만 (중복 응답 방지)

### 일일 보고 (매일 09:00 KST)
daily-review.sh가 cron 실행으로 다음 전송:
1. 어제 자동 처리 건수 (type별)
2. 허용 목록 현황
3. 승격 후보 (5회+ 이력)
4. 강등 후보 (이상 감지된 type)
5. 허용 목록 변경 이력
6. 시스템 상태 스냅샷

## 14. 모델 전환 명령 처리 (Phase 2)

### 독립에이전트 모델 (일회성 인수)
- run-independent-agent.sh 5번째 인수로 모델 ID 전달
- 기본값: DEFAULT_MODEL="claude-sonnet-4-6"
- 생략 시 기본값, 지정 시 해당 실행만, 다음은 다시 기본값

### 오퍼 모델 (영구/임시 분리)
- 영구: start.sh의 PERMANENT_MODEL 변수 수정 → 재시작 필요
- 임시: /tmp/claude-${AGENT_NAME}-model-override 파일에 모델 ID 기록 → start.sh가 읽고 즉시 삭제 → 1회 적용 후 자동 복귀
- 우선순위: 임시 > 영구 > 기본(플래그 없음)

### 텔레그램 명령 포맷 (오퍼 수동 해석)
- "독립 모델 sonnet으로" → 5번째 인수로 전달
- "오퍼 모델 임시 opus-4.6" → 오버라이드 파일 작성 후 kill
- "오퍼 모델 영구 opus-4.6" → start.sh 수정 후 kill
- "오퍼 모델 기본으로" → PERMANENT_MODEL="" 수정 후 kill

### 검증 원칙
- 새 모델 ID는 독립 테스트로 먼저 검증
- 검증 실패 시 오퍼 적용 금지 (watchdog 루프 위험)
- 공식 ID: claude-opus-4-7 / claude-opus-4-6 / claude-sonnet-4-6 / claude-haiku-4-5-20251001

### 무감 재시작 절차
1. 파일 수정(영구) 또는 오버라이드 작성(임시)
2. 텔로 "X초 후 전환" 사전 알림
3. pkill -9 -f "claude.*--channels"
4. watchdog 1분 내 복구 (--continue --fork-session)
5. 재기동 후 "전환 완료" 알림
CLAUDE_OP

echo "" >> "$AGENT_DIR/CLAUDE.md"
echo "<!-- Generated from claude-setup v${SETUP_VERSION} (${SETUP_DATE}) -->" >> "$AGENT_DIR/CLAUDE.md"

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
if [ -x "$START_SCRIPT" ] && grep -qE "claude.*--channels" "$START_SCRIPT"; then
  ok "시작 스크립트 정상"
  grep -q "LANG=C.UTF-8" "$START_SCRIPT" && ok "UTF-8 로캘 설정" || fail "LANG=C.UTF-8 미설정 (이모지 메시지 처리 실패 위험)"
  grep -q "tmux -u" "$START_SCRIPT" && ok "tmux UTF-8 플래그" || fail "tmux -u 미설정 (이모지 렌더링 실패 위험)"
  grep -q "\-\-continue --fork-session" "$START_SCRIPT" && ok "세션 복원 플래그(--continue --fork-session)" || fail "세션 복원 플래그 누락 (OOM 재시작 시 컨텍스트 손실)"
else
  fail "시작 스크립트 없음 또는 불완전"
fi

echo "[8/13] claude-${AGENT_NAME}-watchdog.sh..."
if [ -x "$WATCHDOG_SCRIPT" ]; then
  grep -q "has-session" "$WATCHDOG_SCRIPT" && ok "tmux 세션 체크" || fail "tmux 세션 체크 없음"
  grep -q 'pgrep -f "claude.*--channels"' "$WATCHDOG_SCRIPT" && ok "claude 프로세스 체크" || fail "claude 프로세스 체크 없음"
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
pgrep -f "claude.*--channels" > /dev/null 2>&1 && ok "claude 프로세스 실행 중" || info "claude 프로세스 없음"
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
    echo "  재설치: bash claude-setup-v2.7.sh"
    echo ""
  fi
else
  echo "  $FAIL개 항목에 문제가 있습니다."
  echo "  재설치: bash claude-setup-v2.7.sh"
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
  -d chat_id="$CHAT_ID" -d text="🎉 Claude Code 설정 완료! ($AGENT_NAME) v2.7" > /dev/null 2>&1
ok "테스트 메시지 전송 완료"

# crontab 등록
CRON_LINE="* * * * * /bin/bash $WATCHDOG_SCRIPT >> $WATCHDOG_LOG 2>&1"
SESSION_DIR="$HOME_DIR/.claude/projects/-home-${USER}-${AGENT_NAME}"
CLEANUP_LOG="$HOME_DIR/cleanup-sessions.log"
CLEANUP_LINE="0 3 * * * find $SESSION_DIR -name '*.jsonl' -mtime +30 -print -delete >> $CLEANUP_LOG 2>&1"
CRON_TMP=$(mktemp)
( crontab -l 2>/dev/null | grep -v "$WATCHDOG_SCRIPT" | grep -v "cleanup-sessions.log"; echo "$CRON_LINE"; echo "$CLEANUP_LINE" ) > "$CRON_TMP"
crontab "$CRON_TMP"
rm -f "$CRON_TMP"

if crontab -l 2>/dev/null | grep -q "$WATCHDOG_SCRIPT"; then
  ok "crontab 등록 완료 (매 1분 watchdog 실행)"
else
  fail "crontab 등록 실패"
fi

if crontab -l 2>/dev/null | grep -q "cleanup-sessions.log"; then
  ok "세션 정리 crontab 등록 완료 (매일 03:00, 30일 초과 .jsonl 삭제)"
else
  fail "세션 정리 crontab 등록 실패"
fi

# 예방 재시작 스크립트 + cron 등록 (Claude Code 메모리 누수 대응, 2026-04-18 수정)
# 이전: crontab 내부 echo+pkill 한 줄 (\$( ... ) 이스케이프 문제로 실제 실행 안 됨)
# 현재: 전용 스크립트로 분리 (안정성 확보)
PREVENT_SCRIPT="$HOME_DIR/claude-${AGENT_NAME}-preventive-restart.sh"
PREVENT_LOG="$HOME_DIR/claude-preventive-restart.log"
cat > "$PREVENT_SCRIPT" << PREVENT_EOF
#!/bin/bash
# 매일 03:00 예방 재시작 (Claude Code 메모리 누수 대응)
# claude kill 시 watchdog이 1분 내 --continue --fork-session으로 복구

echo "[\$(date -Iseconds)] 예방 재시작 실행" >> $PREVENT_LOG
pkill -9 -f "claude.*--channels" 2>/dev/null || true
PREVENT_EOF
chmod +x "$PREVENT_SCRIPT"
add_version_marker "$PREVENT_SCRIPT"

PREVENT_LINE="0 3 * * * /bin/bash $PREVENT_SCRIPT # preventive-restart"
CRON_TMP=$(mktemp)
( crontab -l 2>/dev/null | grep -v "preventive-restart"; echo "$PREVENT_LINE" ) > "$CRON_TMP"
crontab "$CRON_TMP"
rm -f "$CRON_TMP"

if crontab -l 2>/dev/null | grep -q "preventive-restart"; then
  ok "예방 재시작 crontab 등록 완료 (매일 03:00, 메모리 누수 대응)"
else
  fail "예방 재시작 crontab 등록 실패"
fi

# 일일 리뷰 cron 등록 (Phase 2+3, 2026-04-18)
DAILY_LINE="0 9 * * * /bin/bash $DAILY_REVIEW_SCRIPT >> $HOME_DIR/daily-review.log 2>&1 # daily-review"
CRON_TMP=$(mktemp)
( crontab -l 2>/dev/null | grep -v "daily-review"; echo "$DAILY_LINE" ) > "$CRON_TMP"
crontab "$CRON_TMP"
rm -f "$CRON_TMP"

if crontab -l 2>/dev/null | grep -q "daily-review"; then
  ok "일일 리뷰 crontab 등록 완료 (매일 09:00)"
else
  fail "일일 리뷰 crontab 등록 실패"
fi

# Log Rotation cron 등록 (2026-04-18 보안 감사 후 추가)
LOGROTATE_LINE="30 2 * * * /bin/bash $LOGROTATE_SCRIPT >> $HOME_DIR/logrotate.log 2>&1 # logrotate-claude"
CRON_TMP=$(mktemp)
( crontab -l 2>/dev/null | grep -v "logrotate-claude"; echo "$LOGROTATE_LINE" ) > "$CRON_TMP"
crontab "$CRON_TMP"
rm -f "$CRON_TMP"
if crontab -l 2>/dev/null | grep -q "logrotate-claude"; then
  ok "로그 회전 crontab 등록 완료 (매일 02:30)"
else
  fail "로그 회전 crontab 등록 실패"
fi

# ========================================
# 설치 결과 요약
# ========================================
echo ""
echo "========================================"
echo "  설치 완료! ✅ $PASS / ❌ $FAIL"
echo "========================================"

# ========================================
# 재배포 자동 감지: 운영 중인 claude가 있으면 pkill (v2.7.6)
# 신규 VM은 pkill 대상 없음 → 자동으로 건너뜀
# 기존 VM 재배포는 새 start.sh 즉시 적용 위해 pkill
# ========================================
if pgrep -f "claude.*--channels" > /dev/null 2>&1; then
  echo ""
  echo "운영 중인 claude 감지 → 재배포 모드"
  echo "  새 start.sh 즉시 적용을 위해 pkill 실행..."
  pkill -9 -f "claude.*--channels" 2>/dev/null || true
  echo "  ✓ pkill 완료. watchdog가 1분 내 새 환경으로 재기동합니다."
else
  echo ""
  echo "운영 중인 claude 없음 → 신규 설치 모드 (pkill 건너뜀)"
fi

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
