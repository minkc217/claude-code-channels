#!/bin/bash
# claude-agent1-start.sh를 v2.6.1(119 고정)로 교체하는 설치 스크립트
# 다른 VM에서 한 줄로 실행:
#   curl -fsSL https://raw.githubusercontent.com/minkc217/claude-code-channels/main/install-119-fix.sh | bash

set -e

REPO_URL="https://raw.githubusercontent.com/minkc217/claude-code-channels/main"
SOURCE_FILE="claude-agent1-start-v2.6.1.sh"
TARGET="/home/hsy/claude-agent1-start.sh"
BACKUP="${TARGET}.bak.$(date +%Y%m%d_%H%M%S)"

echo "========================================"
echo "  claude-agent1-start.sh 119 고정 패치"
echo "========================================"
echo ""

# 1. 119 버전 디스크 존재 확인 (없으면 npm으로 자동 설치 시도)
echo "[1/6] 119 버전 파일 확인..."
CLAUDE_119="/home/hsy/.local/share/claude/versions/2.1.119"
if [ ! -x "$CLAUDE_119" ]; then
  echo "  ⚠️ 119 없음 → npm으로 자동 설치 시도..."
  if ! command -v npm >/dev/null 2>&1; then
    echo "  ❌ npm 명령 없음. 수동 설치 필요. 패치 중단."
    exit 1
  fi
  if npm install -g @anthropic-ai/claude-code@2.1.119 2>&1 | tail -3; then
    echo "  ✓ npm install 완료"
  else
    echo "  ❌ npm install 실패. 네트워크/권한 확인 후 재시도. 패치 중단."
    exit 1
  fi
  if [ ! -x "$CLAUDE_119" ]; then
    echo "  ❌ npm install 후에도 $CLAUDE_119 없음. 패치 중단."
    exit 1
  fi
  echo "  ✓ 119 설치 완료"
else
  echo "  ✓ 119 버전 존재"
fi

# 2. 기존 start.sh 백업
echo "[2/6] 기존 start.sh 백업..."
if [ -f "$TARGET" ]; then
  cp "$TARGET" "$BACKUP"
  echo "  ✓ 백업: $BACKUP"
else
  echo "  ⚠️ 기존 파일 없음 (새로 생성)"
fi

# 3. 새 start.sh 다운로드
echo "[3/6] 새 start.sh 다운로드..."
if curl -fsSL "$REPO_URL/$SOURCE_FILE" -o "$TARGET"; then
  echo "  ✓ 다운로드 완료"
else
  echo "  ❌ 다운로드 실패"
  if [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$TARGET"
    echo "  ⚠️ 백업으로 복원함"
  fi
  exit 1
fi

# 4. 실행 권한
echo "[4/6] 실행 권한 부여..."
chmod +x "$TARGET"
echo "  ✓ chmod +x 완료"

# 5. 심링크를 119로 정리
echo "[5/6] 심링크 119로 정리..."
SYMLINK="/home/hsy/.local/bin/claude"
TARGET_119="/home/hsy/.local/share/claude/versions/2.1.119"
if [ -L "$SYMLINK" ] || [ ! -e "$SYMLINK" ]; then
  if ln -sfn "$TARGET_119" "$SYMLINK" 2>/dev/null; then
    echo "  ✓ 심링크 → 2.1.119"
  else
    echo "  ⚠️ 심링크 변경 실패 (권한? 운영엔 영향 없음)"
  fi
else
  echo "  ⚠️ $SYMLINK가 심링크가 아님 → 변경 건너뜀"
fi

# 6. claude 강제 종료 (재기동 트리거)
echo "[6/6] claude 재기동 트리거..."
pkill -9 -f "claude.*--channels" 2>/dev/null || true
echo "  ✓ pkill 실행"

echo ""
echo "========================================"
echo "  ✓ 설치 완료"
echo "========================================"
echo ""
echo "  watchdog가 1분 내 새 start.sh로 자동 재기동합니다."
echo "  텔레그램 봇이 응답하는지 확인해주세요."
echo ""
echo "  롤백 필요 시:"
echo "    cp $BACKUP $TARGET"
echo "    pkill -9 -f \"claude.*--channels\""
echo ""
