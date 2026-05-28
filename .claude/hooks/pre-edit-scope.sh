#!/usr/bin/env bash
# PreToolUse hook for Edit|Write — lab-experimenter 의 쓰기를 lab/ 안으로 제한 (②티어).
# 입력: stdin 에 JSON ({agent_type, cwd, tool_name, tool_input: {file_path}}).
# 출력: exit 2 면 차단(메시지는 stderr), exit 0 이면 통과.
#
# 설계: fail-open. agent_type 이 "lab-experimenter" 가 아니면(부모 Claude·타 에이전트는
# 빈 값) 무조건 통과한다 — 부모의 정상 편집은 절대 막지 않는다. lab-experimenter 가
# lab/ 밖을 쓰려 할 때만 막는다. payload 필드는 실측으로 확인됨(2026-05-29).

set -euo pipefail

input=$(cat)

read -r agent_type target cwd <<EOF
$(echo "$input" | python3 -c "
import sys, json
d = json.load(sys.stdin)
ti = d.get('tool_input', {})
path = ti.get('file_path') or ti.get('path') or ''
print(d.get('agent_type', ''), path, d.get('cwd', ''))
" 2>/dev/null || echo "  ")
EOF

# lab-experimenter 가 아니면 제약 없음 (부모 Claude 포함)
[[ "$agent_type" != "lab-experimenter" ]] && exit 0
# 경로를 못 읽으면 막지 않는다 (오탐으로 작업 중단시키지 않음)
[[ -z "$target" || -z "$cwd" ]] && exit 0

# 절대경로로 정규화 후 cwd/lab/ 하위인지 검사 ('..' 우회는 normpath 가 무력화)
allowed=$(python3 -c "
import os, sys
target, cwd = sys.argv[1], sys.argv[2]
t = target if os.path.isabs(target) else os.path.join(cwd, target)
t = os.path.normpath(t)
lab = os.path.normpath(os.path.join(cwd, 'lab')) + os.sep
print('1' if t.startswith(lab) else '0')
" "$target" "$cwd" 2>/dev/null || echo "1")

if [[ "$allowed" != "1" ]]; then
  echo "🚫 차단: lab-experimenter 는 lab/ 밖을 쓸 수 없다." >&2
  echo "   대상: $target" >&2
  echo "   프로덕션 변경이 필요하면 직접 고치지 말고, 결과·근거와 함께 부모 Claude 에게 보고해라." >&2
  exit 2
fi

exit 0
