#!/usr/bin/env bash
# /ship 의 *자동 사전 체크 엔진* — 명령 문서 절차의 일부를 실제 실행.
# 사용: bash .claude/scripts/ship-precheck.sh [ios|backend|docs|all]
# 출력: 통과/실패 체크리스트 + 머지 전 사람 확인 항목.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCOPE="${1:-all}"
today=$(date +%Y-%m-%d)

pass=0; fail=0; warn=0
mark_pass() { echo "  ✅ $1"; pass=$((pass+1)); }
mark_fail() { echo "  ❌ $1"; fail=$((fail+1)); }
mark_warn() { echo "  ⚠️  $1"; warn=$((warn+1)); }

echo "## /ship-precheck ($SCOPE) — $today"
echo

# 1) audit 자동 점검 — exit code 명시적 처리 (실패 삼키지 않음, 게이트 무결성)
echo "### 1) docs 정합성 (audit.sh)"
audit_out=$(bash "$REPO/.claude/scripts/audit.sh" all 2>&1)
audit_rc=$?
if [[ "$audit_rc" -ne 0 ]]; then
  mark_fail "audit.sh 가 exit $audit_rc 로 실패. 게이트 신뢰 불가 — 통과 표시하지 않는다."
  echo "    --- audit.sh 출력 시작 ---"
  echo "$audit_out" | sed 's|^|    |'
  echo "    --- audit.sh 출력 끝 ---"
else
  stop_items=$(echo "$audit_out" | awk '/^## STOP 후보/{f=1; next} /^## /{f=0} f && /^- /{print}')
  drift_items=$(echo "$audit_out" | awk '/^## known-drift/{f=1; next} /^## /{f=0} f && /^- /{print}')

  if echo "$stop_items" | grep -q "front-matter 누락"; then
    mark_fail "docs/journal 중 front-matter 누락 파일이 있음 (audit STOP 섹션)."
  fi
  # STOP 후보를 *등재된 known-drift* vs *신규* 로 구분.
  # 등재 기준 — (a) audit 의 drift_items 에 같은 파일이 있고, (b) CHANGELOG 에 'known-drift' 토큰이 있다.
  stop_low_conf=$(echo "$stop_items" | grep "confidence .* < 0.3" || true)
  if [[ -n "$stop_low_conf" ]]; then
    new_drift=0
    changelog_has_token=0
    grep -q "known-drift" "$REPO/docs/CHANGELOG.md" 2>/dev/null && changelog_has_token=1
    # here-doc 제거 — read-only 환경에서 임시파일 실패 회피. process substitution 도 임시파일 의존이라 회피.
    # 대신 stop_low_conf 를 줄 단위로 직접 순회 (printf + IFS 변경).
    saved_ifs=$IFS
    IFS=$'\n'
    for line in $stop_low_conf; do
      [[ -n "$line" ]] || continue
      doc=$(printf '%s' "$line" | sed -E 's|^- ([^ ]+) .*|\1|')
      if printf '%s' "$drift_items" | grep -q "^- $doc"; then
        if [[ "$changelog_has_token" -eq 1 ]]; then
          :  # 등재된 known-drift
        else
          new_drift=$((new_drift + 1))
        fi
      else
        new_drift=$((new_drift + 1))
      fi
    done
    IFS=$saved_ifs
    if [[ "$new_drift" -gt 0 ]]; then
      mark_fail "신규 STOP 후보 $new_drift 건 — CHANGELOG 등재 known-drift 가 아님. 결정 후 머지."
    else
      # 등재 known-drift 의 미해결 일수 알림 (경고 피로 완화: 7일↑ 미결이면 "결정 압박" 라벨)
      drift_age_days=""
      first_drift_date=$(grep -B2 "known-drift" "$REPO/docs/CHANGELOG.md" 2>/dev/null | grep -oE "## [0-9]{4}-[0-9]{2}-[0-9]{2}" | head -1 | awk '{print $2}')
      if [[ -n "$first_drift_date" ]]; then
        # to_epoch — Linux/macOS portable
        dts=$(date -j -f "%Y-%m-%d" "$first_drift_date" "+%s" 2>/dev/null || date -d "$first_drift_date" "+%s" 2>/dev/null || echo 0)
        if [[ "$dts" -gt 0 ]]; then
          drift_age_days=$(( ( $(date "+%s") - dts ) / 86400 ))
        fi
      fi
      if [[ -n "$drift_age_days" && "$drift_age_days" -gt 7 ]]; then
        mark_warn "등재 known-drift 미결 ${drift_age_days}일째 — 결정 압박. /sprint-end 또는 명시 결정 권장."
      else
        mark_warn "confidence < 0.3 STOP 은 모두 CHANGELOG 등재 known-drift — 추적 중."
      fi
    fi
  fi
  if [[ -z "$stop_items" && -z "$drift_items" ]]; then
    mark_pass "audit 통과 (STOP 후보·신규 drift 없음)."
  elif [[ -z "$stop_items" ]]; then
    drift_n=$(echo "$drift_items" | grep -c '^- ' || true)
    mark_pass "audit STOP 후보 없음. known-drift ${drift_n}건은 활성 추적 중."
  fi
fi
echo

# 2) CHANGELOG 오늘 항목 존재 검사
echo "### 2) CHANGELOG"
if head -50 "$REPO/docs/CHANGELOG.md" 2>/dev/null | grep -q "^## $today"; then
  mark_pass "CHANGELOG 에 오늘 항목 있음."
else
  mark_fail "오늘($today) docs/code 변경이 있다면 CHANGELOG 한 줄 추가 필요 (CLAUDE.md §6)."
fi
echo

# 3) AGENTS.md 미러 동기화
echo "### 3) AGENTS.md 미러"
claude_ts=$(stat -f "%m" "$REPO/CLAUDE.md" 2>/dev/null || stat -c "%Y" "$REPO/CLAUDE.md" 2>/dev/null || echo 0)
agents_ts=$(stat -f "%m" "$REPO/AGENTS.md" 2>/dev/null || stat -c "%Y" "$REPO/AGENTS.md" 2>/dev/null || echo 0)
if [[ "$claude_ts" -gt "$agents_ts" ]]; then
  diff_secs=$(( claude_ts - agents_ts ))
  if [[ "$diff_secs" -gt 300 ]]; then
    mark_warn "CLAUDE.md 가 AGENTS.md 보다 새로움 — /sync-agents 실행 권장."
  else
    mark_pass "CLAUDE.md / AGENTS.md mtime 차이 5분 이내."
  fi
else
  mark_pass "AGENTS.md 가 CLAUDE.md 이후 갱신됨."
fi
echo

# 4) iOS 구조 경계 검사 (TCA 레이어 규칙)
if [[ "$SCOPE" == "ios" ]] || [[ "$SCOPE" == "all" ]]; then
  echo "### 4) iOS 구조 경계 (ios-boundaries.sh)"
  ios_out=$(bash "$REPO/.claude/scripts/ios-boundaries.sh" 2>&1)
  ios_rc=$?
  if [[ "$ios_rc" -ne 0 ]]; then
    mark_fail "iOS 레이어 규칙 위반 — ios-boundaries.sh 출력 확인."
    echo "$ios_out" | grep -E "^- ❌" | sed 's|^|    |'
  else
    mark_pass "iOS TCA 레이어 경계 위반 없음."
  fi
  echo
fi

# 5) OpenAPI ↔ iOS 클라이언트 drift — generator 미배선의 fallback ② 게이트
if [[ "$SCOPE" == "ios" ]] || [[ "$SCOPE" == "backend" ]] || [[ "$SCOPE" == "all" ]]; then
  echo "### 5) OpenAPI ↔ iOS 클라이언트 drift (openapi-check.sh)"
  api_out=$(bash "$REPO/.claude/scripts/openapi-check.sh" 2>&1)
  api_rc=$?
  case "$api_rc" in
    0)
      mark_pass "OpenAPI ↔ iOS 클라이언트 정합 (drift 0)."
      ;;
    1)
      # drift 발견. 등재 known-drift 면 warn, 신규면 fail.
      if grep -q "openapi-drift" "$REPO/docs/CHANGELOG.md" 2>/dev/null; then
        mark_warn "OpenAPI drift 발견 — CHANGELOG 등재 known-drift (openapi-drift). 추적 중."
      else
        mark_fail "OpenAPI drift 발견 — CHANGELOG 미등재. 결정 후 머지 (openapi-check.sh 출력 확인)."
        echo "$api_out" | grep -E "^- /api" | sed 's|^|    |'
      fi
      ;;
    *)
      # exit 3/4/5 = extract 실패 / 입력 손상 / 환경 오류 — 절대 통과 표시 X
      mark_fail "openapi-check.sh 가 exit $api_rc — 게이트 신뢰 불가. 출력 확인."
      echo "$api_out" | sed 's|^|    |'
      ;;
  esac
  echo
fi

# 6) 백엔드 정적 검사 (make lint / typecheck) — 빠른 게이트만 자동 포함
if [[ "$SCOPE" == "backend" ]] || [[ "$SCOPE" == "all" ]]; then
  echo "### 6) 백엔드 정적 검사 (make lint / typecheck)"
  if [[ -f "$REPO/mochi-backend/Makefile" ]]; then
    # Makefile 의 lint/typecheck 타겟이 있는지 확인
    if grep -qE '^(lint|typecheck):' "$REPO/mochi-backend/Makefile" 2>/dev/null; then
      # 환경 의존성 (venv, ruff/mypy 설치) 때문에 *시도* 만 하고 실패 시 skip 알림.
      lint_out=$(cd "$REPO/mochi-backend" && make lint 2>&1) ; lint_rc=$?
      type_out=$(cd "$REPO/mochi-backend" && make typecheck 2>&1) ; type_rc=$?
      if [[ "$lint_rc" -eq 0 ]] && [[ "$type_rc" -eq 0 ]]; then
        mark_pass "백엔드 lint + typecheck 통과."
      elif [[ "$lint_rc" -ne 0 ]] || [[ "$type_rc" -ne 0 ]]; then
        # 환경 미설정(uv/venv 없음) vs 실제 위반 구분
        # 환경 이슈 vs 실제 위반 구분 — 패턴 확장 (uv cache 권한, Permission denied, venv 미생성 등 모두 환경).
        if echo "$lint_out$type_out" | grep -qE "command not found|No module|not found|Permission denied|uv cache|Cache directory|virtualenv|pyproject"; then
          mark_warn "백엔드 lint/typecheck 환경 이슈 — \`cd mochi-backend && make install\` 후 재실행 권장."
        else
          mark_fail "백엔드 lint 또는 typecheck 실제 위반 — 출력 확인."
          echo "$lint_out$type_out" | tail -5 | sed 's|^|    |'
        fi
      fi
    else
      mark_warn "mochi-backend/Makefile 에 lint/typecheck 타겟 부재."
    fi
  else
    mark_warn "mochi-backend/Makefile 부재 — 백엔드 정적 검사 건너뜀."
  fi
  echo
fi

# 7) git status — 모노레포 통합 후엔 루트 한 번만, 통합 전엔 하위 각각
echo "### 7) git status"
if [[ -d "$REPO/.git" ]]; then
  # 모노레포 통합 완료
  changes=$(git -C "$REPO" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$changes" -gt 0 ]]; then
    mark_warn "루트 작업트리 변경 $changes 개 — code-reviewer + codex review 통과 확인."
  else
    mark_pass "루트 git 작업트리 clean. (모노레포 통합 완료)"
  fi
else
  # 통합 전 폴백 (가능성: 사용자가 .git 일시 제거 등)
  for sub in mochi-ios mochi-backend; do
    if [[ -d "$REPO/$sub/.git" ]]; then
      changes=$(git -C "$REPO/$sub" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
      [[ "$changes" -gt 0 ]] && mark_warn "$sub 변경 $changes 개." || mark_pass "$sub clean."
    else
      mark_warn "$sub 도 git repo 아님 — 루트 git 통합 필요."
    fi
  done
fi
echo

# 5) 요약
echo "### 요약"
echo "- ✅ pass: $pass"
echo "- ⚠️  warn: $warn"
echo "- ❌ fail: $fail"
echo
if [[ "$fail" -gt 0 ]]; then
  echo "🚫 머지 전 ❌ 항목 해결 필요."
  exit 1
fi
echo "📦 자동 사전 체크 통과. 다음은 사람 결정 영역: 실제 make test/tuist test 실행, code-reviewer/qa-validator 호출, /ship 본문 §1~§11 (commands/ship.md) 점검."
exit 0
