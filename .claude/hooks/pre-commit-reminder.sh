#!/usr/bin/env bash
# PreToolUse hook for Bash — git commit 직전 review/qa 리마인더 (차단 X, ③ 판단 넛지).
# 입력: stdin JSON ({tool_input: {command}}).
# 출력: git commit 패턴이면 hookSpecificOutput.additionalContext 로 부모 Claude 에게만
#       리마인더 주입(permissionDecision=allow → 커밋은 그대로 진행). 아니면 침묵 exit 0.
#
# 왜 강제(exit 2)가 아닌가: code-reviewer/qa-validator "필요 여부" 는 판단 영역이다
# (사소한 오타·문구·디자인 변경엔 불필요). 기계가 그 판단을 대신할 수 없으므로 ②로
# 강제하지 않고, 커밋 결정 지점에서 의식하도록 ③ 가시성만 높인다. lint/typecheck 는
# 별도 — ship-precheck.sh §6 가 검사한다(여기 중복 안 둠).
#
# 근거: journal/2026-05-29-mochi-item-rename.md §8.1(C) — 직전 세션이 review/qa 게이트를
# 조용히 건너뜀. lint/typecheck 는 인라인으로 돌렸으므로(§3) 그건 강제 대상이 아니다.

set -euo pipefail

input=$(cat)

cmd=$(echo "$input" | python3 -c "import sys, json; print(json.load(sys.stdin).get('tool_input', {}).get('command', ''))" 2>/dev/null || echo "")

[[ -z "$cmd" ]] && exit 0

# git commit 패턴만 매칭. commit-tree/commit-graph 오탐 방지(뒤에 공백/끝 경계).
# git commit / git commit -m / git -C <path> commit / git -c k=v commit / --git-dir / && 체인 포함.
if ! echo "$cmd" | grep -qE '(^|[^a-zA-Z])git([[:space:]]+(-[cC]|--git-dir)[[:space:]=][^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)'; then
  exit 0
fi

# permissionDecision 은 의도적으로 출력하지 않는다 — "allow" 를 주면 매칭된 Bash 호출
# *전체* 가 권한 프롬프트 없이 자동 승인되어(compound 명령 포함) ③ 넛지가 ②/권한 영역으로
# 새 나간다. additionalContext 만 주면 정상 권한 흐름은 유지되고 컨텍스트만 부모에게 주입된다.
# python3 가 죽어도(read-only 환경의 heredoc temp-file 실패 등) hook-error 노이즈 대신 침묵 통과.
python3 <<'PY' 2>/dev/null || exit 0
import json

msg = (
    "커밋 직전 점검(차단 아님 — 판단해서 진행): "
    "원칙적으로 Flow A 루프상 code-reviewer → qa-validator 를 거친 변경이어야 한다. "
    "다만 사소한 변경(오타·주석·문구·간단 디자인 조정 등)이라 스스로 판단되면 게이트를 생략하고 리소스를 아껴라. "
    "또한 의미 있는 변경이면 docs 정합 폭포 + CHANGELOG 한 줄(CLAUDE.md §6) 동기화를 확인했는지 본다."
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "additionalContext": msg,
    }
}, ensure_ascii=False))
PY
