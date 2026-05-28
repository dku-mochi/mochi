#!/usr/bin/env bash
# SessionStart hook — 세션 시작 시 작업 컨텍스트를 한 화면에 압축해 보여준다.
# 출력은 모두 Claude 컨텍스트에 들어가므로 짧게 유지한다.

set -euo pipefail

# 스크립트 위치 기준 REPO 자동 추론 (이식성: 절대경로 하드코딩 회피)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
DEADLINE_FILE="$REPO/docs/.deadline"

# 경진대회 제출 마감 카운트다운 (마감일 파일 있을 때만)
if [[ -f "$DEADLINE_FILE" ]]; then
  deadline=$(head -1 "$DEADLINE_FILE" | tr -d '[:space:]')
  if [[ -n "$deadline" ]]; then
    deadline_ts=$(date -j -f "%Y-%m-%d" "$deadline" "+%s" 2>/dev/null || echo "")
    now_ts=$(date "+%s")
    if [[ -n "$deadline_ts" ]]; then
      days=$(( (deadline_ts - now_ts) / 86400 ))
      echo "🏁 경진대회 제출까지: D-${days} ($deadline)"
    fi
  fi
fi

# 활성 known-drift 한 줄 (CHANGELOG 의 'known-drift' 마커가 있는 가장 최근 줄)
drift=$(grep -m1 "known-drift" "$REPO/docs/CHANGELOG.md" 2>/dev/null | head -c 200 || true)
if [[ -n "$drift" ]]; then
  echo "⚠️  활성 known-drift: $drift"
fi

# 가장 최근 journal 의 '다음 할 일' 1줄 (있으면)
latest_journal=$(ls -t "$REPO/journal/"*.md 2>/dev/null | grep -v README.md | head -1 || true)
if [[ -n "$latest_journal" ]]; then
  next=$(grep -A1 "다음 할 일\|## 다음\|## Next" "$latest_journal" 2>/dev/null | tail -1 | head -c 200 || true)
  if [[ -n "$next" ]]; then
    echo "📝 이어받기 ($(basename "$latest_journal")): $next"
  fi
fi

exit 0
