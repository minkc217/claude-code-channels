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

# 1. 119 버전 디스크 존재 확인 (없으면 패치 무용)
echo "[1/5] 119 버전 파일 확인..."
if [ ! -x "/home/hsy/.local/share/claude/versions/2.1.119" ]; then
  echo "  ❌ /home/hsy/.local/share/claude/versions/2.1.119 없음"
  echo "  먼저 119 버전이 디스크에 있어야 합니다. 패치 중단."
  exit 1
fi
echo "  ✓ 119 버전 존재"

# 2. 기존 start.sh 백업
echo "[2/5] 기존 start.sh 백업..."
if [ -f "$TARGET" ]; then
  cp "$TARGET" "$BACKUP"
  echo "  ✓ 백업: $BACKUP"
else
  echo "  ⚠️ 기존 파일 없음 (새로 생성)"
fi

# 3. 새 start.sh 다운로드
echo "[3/5] 새 start.sh 다운로드..."
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
echo "[4/5] 실행 권한 부여..."
chmod +x "$TARGET"
echo "  ✓ chmod +x 완료"

# 5. claude 강제 종료 (재기동 트리거)
echo "[5/5] claude 재기동 트리거..."
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
