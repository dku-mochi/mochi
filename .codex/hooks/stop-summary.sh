#!/usr/bin/env bash
# Stop hook — 세션 종료 직전 호출. 운영 위생 위반을 *알림* 한다 (차단 X).
# 검사 항목:
#   (1) .md 파일이 수정됐는데 CHANGELOG 갱신 안 됨 (오늘 날짜 항목 부재).
#   (2) 코드/docs 변경됐는데 양 하위 repo git status 가 안 잡힌 신규 디렉토리 있음.
# 출력: 사용자/모델에 stderr 로 한두 줄.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
today=$(date +%Y-%m-%d)

# 1) docs/ 의 .md 가 오늘 수정됐는지 (mtime 기준)
recent_docs=$(find "$REPO/docs" -maxdepth 2 -name "*.md" -newermt "$today 00:00:00" 2>/dev/null | grep -v CHANGELOG.md | head -3)

if [[ -n "$recent_docs" ]]; then
  # CHANGELOG 에 오늘 항목 있나
  if ! head -50 "$REPO/docs/CHANGELOG.md" 2>/dev/null | grep -q "^## $today"; then
    echo "⚠️  오늘($today) docs 변경이 있는데 CHANGELOG 에 항목 없음. CLAUDE.md §6 변경기록 규칙 — 작업 완료 전 한 줄 추가 권장." >&2
    echo "   수정된 docs:" >&2
    echo "$recent_docs" | sed 's|^|     - |' >&2
  fi
fi

# 2) AGENTS.md 가 CLAUDE.md 와 어긋났는지 빠른 sanity (둘 다 mtime 비교)
claude_ts=$(stat -f "%m" "$REPO/CLAUDE.md" 2>/dev/null || echo 0)
agents_ts=$(stat -f "%m" "$REPO/AGENTS.md" 2>/dev/null || echo 0)
if [[ "$claude_ts" -gt "$agents_ts" ]]; then
  diff_secs=$(( claude_ts - agents_ts ))
  if [[ "$diff_secs" -gt 300 ]]; then  # 5분 이상 차이
    echo "ℹ️  CLAUDE.md 가 AGENTS.md 보다 더 최근 — /sync-agents 로 미러 재생성 권장." >&2
  fi
fi

exit 0
