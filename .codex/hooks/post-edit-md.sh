#!/usr/bin/env bash
# PostToolUse hook — .md 파일을 Edit/Write 한 직후 호출.
# 목적: front-matter 7필드가 누락된 채로 새 .md 가 들어가는 걸 *알림* 만 한다 (차단 X — cascade paralysis 회피).
# 입력: stdin JSON ({tool_name, tool_input: {file_path, ...}})
# 출력: stderr 로 경고. exit 0 항상 (알림만).

set -uo pipefail

input=$(cat)
fp=$(echo "$input" | python3 -c "import sys, json; print(json.load(sys.stdin).get('tool_input', {}).get('file_path', ''))" 2>/dev/null || echo "")

# .md 만 검사
[[ "$fp" == *.md ]] || exit 0
# archive/, lab/, 외부 경로는 검사 외
case "$fp" in
  */archive/*|*/lab/*|*/.claude/commands/*|*/.claude/agents/*|*/.claude/scripts/*|*/.claude/hooks/*) exit 0 ;;
esac
[[ -f "$fp" ]] || exit 0

# front-matter 추출 (첫 --- 와 두 번째 --- 사이)
fm=$(awk '/^---$/{c++; next} c==1{print} c==2{exit}' "$fp" 2>/dev/null || true)
if [[ -z "$fm" ]]; then
  echo "⚠️  $fp 에 front-matter 없음 — level/mode/status/last_verified/confidence/owners/description 7필드 시드를 권장 (docs/WORKFLOW.md §12.1)." >&2
  exit 0
fi

# 필수 필드 검사
missing=()
for key in level mode status last_verified confidence owners description; do
  echo "$fm" | grep -qE "^${key}:" || missing+=("$key")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "⚠️  $fp front-matter 누락 필드: ${missing[*]} (docs/WORKFLOW.md §12 참고)." >&2
fi

# description 길이 sanity (너무 짧으면 트리거가 약함)
desc=$(echo "$fm" | awk '/^description:/{sub(/^description:[[:space:]]*/,""); print; exit}')
if [[ -n "$desc" && "${#desc}" -lt 30 ]]; then
  echo "ℹ️  $fp description 이 너무 짧다(${#desc}자). 'When to read' 트리거를 imperative 로 강화 권장." >&2
fi

exit 0
