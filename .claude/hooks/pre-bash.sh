#!/usr/bin/env bash
# PreToolUse hook for Bash — 위험 패턴 차단.
# 입력: stdin 에 JSON ({tool_name, tool_input: {command}}).
# 출력: exit 2 면 차단(메시지는 stderr), exit 0 이면 통과.
#
# 차단 대상 — settings.json 의 deny 패턴과 보완: 정규식이라 deny 가 못 잡는 변형까지 잡는다.
# 차단보다 보호가 목적이므로 표현은 짧고 명확하게.

set -euo pipefail

input=$(cat)

# jq 없는 환경 대응: grep 으로 command 추출
cmd=$(echo "$input" | python3 -c "import sys, json; print(json.load(sys.stdin).get('tool_input', {}).get('command', ''))" 2>/dev/null || echo "")

if [[ -z "$cmd" ]]; then
  exit 0
fi

block() {
  echo "🚫 차단: $1" >&2
  echo "   원인: $2" >&2
  echo "   필요하면 명시적으로 우회 절차를 사용자에게 확인받아라." >&2
  exit 2
}

# 1) force push / 강제 변경 — 작업 유실 위험
echo "$cmd" | grep -qE '(^|[^a-zA-Z])(git[[:space:]]+push[[:space:]]+(-f|--force))' && \
  block "git force push" "원격 히스토리 덮어쓰기 — 팀원 작업이 사라질 수 있다."

echo "$cmd" | grep -qE 'git[[:space:]]+reset[[:space:]]+--hard' && \
  block "git reset --hard" "untracked 변경 영구 삭제 위험."

# 2) 광범위 rm — 복구 불가. 정확한 시스템 경로만 차단 (사용자 프로젝트 내부 절대경로는 통과).
echo "$cmd" | grep -qE '(^|[[:space:]])rm[[:space:]]+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)[[:space:]]+/[[:space:]]*$' && \
  block "rm -rf /" "루트 자체 삭제."
echo "$cmd" | grep -qE '(^|[[:space:]])rm[[:space:]]+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)[[:space:]]+/(etc|usr|var|bin|sbin|System|Library|Applications|home|root)(/|$|[[:space:]])' && \
  block "rm -rf <시스템 디렉토리>" "시스템 디렉토리 광범위 삭제."

# 3) .env 류 직접 출력 — 비밀 누출 가능.
#    키 목록·값 존재 여부는 .claude/scripts/env-inspect.sh 가 유일한 허용 경로(값은 출력 안 함).
if ! echo "$cmd" | grep -q 'env-inspect\.sh'; then
  echo "$cmd" | grep -qE '(cat|less|more|head|tail|cp|grep|rg|ugrep|sed|awk|sort|uniq|nl|strings|xxd|od|base64|python3?|ruby|perl|node)[[:space:]]+[^|;&]*\.env(\.|[[:space:]]|$)' && \
    block ".env 직접 읽기" "비밀값을 모델 컨텍스트에 노출하지 마라. 키 목록·값 존재 여부는 'bash .claude/scripts/env-inspect.sh' 사용. 값이 정말 필요하면 사용자 승인."
fi

exit 0
