#!/usr/bin/env bash
# /audit 의 *실제 동작 스크립트* — 명령 문서가 아니라 코드.
# 사용: bash .claude/scripts/audit.sh [l1|l2|l3|all]
# 출력: 시간 강등 제안 + grep 정합성 강등 제안 + STOP 후보 (confidence < 0.3).
#
# 왜 bash 인가: 모찌의 ②티어 강제력은 도구 차원이어야 한다. 명령 문서에만 있으면
# AI 가 "잘 따라줄 것" 에 의존하게 되고, 그건 자동 채점이 아니라 장식이다.
#
# 이식성: macOS / Linux 둘 다 동작. date 와 stat 의 platform 분기 처리.
# 의존성: bash 4+, awk, grep, find. (`bc` 제거 — awk 산술로 대체)

set -uo pipefail

# 스크립트 위치 기준 repo 루트 추정 (hardcoded path 제거)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"

SCOPE="${1:-all}"
TODAY_TS=$(date "+%s")

# date portable: ISO date string → epoch seconds
to_epoch() {
  local d=$1
  if date -j -f "%Y-%m-%d" "$d" "+%s" 2>/dev/null; then return; fi   # macOS
  if date -d "$d" "+%s" 2>/dev/null; then return; fi                  # Linux
  echo 0
}

# 대상 파일 결정
declare -a TARGETS
case "$SCOPE" in
  l1)  TARGETS=("$REPO/docs/WORKFLOW.md" "$REPO/docs/PRODUCT.md" "$REPO/docs/HARNESS_GUIDE.md" "$REPO/docs/INDEX.md") ;;
  l2)  TARGETS=("$REPO/docs/ARCHITECTURE.md" "$REPO/docs/DOMAIN_DESIGN.md" "$REPO/docs/PRIVACY_SENSITIVE_CAPTURE.md") ;;
  l3)  TARGETS=("$REPO/docs/TODO.md" "$REPO/docs/CHANGELOG.md" "$REPO"/journal/*.md) ;;
  all) TARGETS=(
         "$REPO/docs/WORKFLOW.md" "$REPO/docs/PRODUCT.md" "$REPO/docs/HARNESS_GUIDE.md" "$REPO/docs/INDEX.md"
         "$REPO/docs/ARCHITECTURE.md" "$REPO/docs/DOMAIN_DESIGN.md" "$REPO/docs/PRIVACY_SENSITIVE_CAPTURE.md"
         "$REPO/docs/TODO.md" "$REPO/docs/CHANGELOG.md"
         "$REPO"/journal/*.md
       ) ;;
  *) echo "사용: $0 [l1|l2|l3|all]" >&2; exit 1 ;;
esac

extract_field() {
  local file=$1 key=$2
  awk -v k="^${key}:" '
    /^---$/ { fm=!fm; next }
    fm && $0 ~ k { sub(k"[[:space:]]*","",$0); gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit }
  ' "$file"
}

stale_days_for() {
  case "$1" in 1) echo 60 ;; 2) echo 30 ;; 3) echo 14 ;; *) echo 60 ;; esac
}

# float subtraction without bc — awk
fsub() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", a-b}'; }
flt()  { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }   # exit 0 = true

echo "## /audit $SCOPE 리포트 ($(date +%Y-%m-%d))"
echo
echo "| 파일 | level | 현재 conf | 제안 conf | 강등 사유 |"
echo "|---|---|---|---|---|"

declare -a STOP_LIST=()
declare -a DRIFT_LIST=()

# L2 committed 코드 정합 검사 규칙 — 확장 가능한 매핑.
# 형식: "<docs 식별자>|<grep 패턴>|<코드 search root>|<강등량>|<드리프트 메시지>"
declare -a COMMITTED_RULES=(
  "docs/DOMAIN_DESIGN.md|mochi_item|mochi-backend/app mochi-ios/Targets|0.3|문서 'mochi_item' 코드 0건 (known-drift confirm)"
  "docs/DOMAIN_DESIGN.md|LifecyclePolicy|mochi-backend/app mochi-ios/Targets|0.2|LifecyclePolicy 양쪽 정합 grep 실패"
  "docs/DOMAIN_DESIGN.md|IngestCapture|mochi-backend/app|0.2|IngestCapture 유스케이스 누락 가능성"
  "docs/PRIVACY_SENSITIVE_CAPTURE.md|ssrf|mochi-backend/app|0.2|SSRF 가드 식별자가 코드에 안 보임"
  "docs/PRIVACY_SENSITIVE_CAPTURE.md|on_device_detection|mochi-ios/Targets|0.2|on-device 민감 감지가 iOS 코드에 안 보임"
  "docs/ARCHITECTURE.md|Idempotency-Key|mochi-backend/app|0.2|Idempotency-Key 처리가 코드에 안 보임"
  "docs/ARCHITECTURE.md|CaptureRepository|mochi-backend/app mochi-ios/Targets|0.2|CaptureRepository 포트가 코드에 안 보임"
  "docs/ARCHITECTURE.md|WebFetch|mochi-backend/app|0.2|WebFetch 어댑터가 코드에 안 보임"
)

apply_grep_rule() {
  local rel="$1"
  local pattern="$2"
  local roots="$3"   # space-separated
  # 문서 안에 그 패턴이 있나
  if ! grep -qi "$pattern" "$REPO/$rel" 2>/dev/null; then return 1; fi
  # 코드 root 들에서 같은 패턴 검색
  local hits=0
  for r in $roots; do
    [[ -d "$REPO/$r" ]] || continue
    local n
    n=$(grep -rEi "$pattern" "$REPO/$r" 2>/dev/null | wc -l | tr -d ' ')
    hits=$((hits + n))
  done
  [[ "$hits" -eq 0 ]] && return 0 || return 1
}

for f in "${TARGETS[@]}"; do
  [[ -f "$f" ]] || continue

  rel="${f#$REPO/}"
  level=$(extract_field "$f" "level")
  conf=$(extract_field "$f" "confidence")
  lv=$(extract_field "$f" "last_verified")
  mode=$(extract_field "$f" "mode")
  owners=$(extract_field "$f" "owners")
  desc=$(extract_field "$f" "description")

  # front-matter 누락 — owners/description 까지 7필드 검사
  if [[ -z "$level" || -z "$conf" || -z "$lv" || -z "$mode" || -z "$owners" || -z "$desc" ]]; then
    miss=""
    [[ -z "$level" ]]   && miss+="level "
    [[ -z "$mode" ]]    && miss+="mode "
    [[ -z "$lv" ]]      && miss+="last_verified "
    [[ -z "$conf" ]]    && miss+="confidence "
    [[ -z "$owners" ]]  && miss+="owners "
    [[ -z "$desc" ]]    && miss+="description "
    echo "| $rel | ${level:-?} | ${conf:-?} | ? | front-matter 누락: $miss |"
    STOP_LIST+=("$rel — front-matter 누락 ($miss)")
    continue
  fi

  # 시간 강등
  lv_ts=$(to_epoch "$lv")
  if [[ "$lv_ts" -gt 0 ]]; then
    age_days=$(( (TODAY_TS - lv_ts) / 86400 ))
    stale=$(stale_days_for "$level")
    time_drop=0
    if [[ "$age_days" -gt "$stale" ]]; then
      if [[ "$level" == "3" ]]; then time_drop="0.2"; else time_drop="0.1"; fi
    fi
  else
    age_days="?"; time_drop=0
  fi

  # grep 강등 (L2 committed 만, 매핑 규칙 적용)
  grep_drop=0; drift_note=""
  if [[ "$level" == "2" && "$mode" == "committed" ]]; then
    for rule in "${COMMITTED_RULES[@]}"; do
      # here-string `<<<` 제거 — read-only 환경에서 temp file 만드는 호환 문제.
      # awk 로 필드 파싱 (subshell 안전, 순수 stdout).
      r_file=$(printf '%s' "$rule" | awk -F'|' '{print $1}')
      r_pat=$(printf  '%s' "$rule" | awk -F'|' '{print $2}')
      r_roots=$(printf '%s' "$rule" | awk -F'|' '{print $3}')
      r_drop=$(printf '%s' "$rule" | awk -F'|' '{print $4}')
      r_msg=$(printf  '%s' "$rule" | awk -F'|' '{print $5}')
      [[ "$r_file" == "$rel" ]] || continue
      if apply_grep_rule "$rel" "$r_pat" "$r_roots"; then
        grep_drop=$(awk -v a="$grep_drop" -v b="$r_drop" 'BEGIN{s=a+b; if(s>0.5) s=0.5; printf "%.2f", s}')
        drift_note="${drift_note}${drift_note:+; }${r_msg}"
        DRIFT_LIST+=("$rel — $r_msg")
      fi
    done
  fi

  proposed=$(fsub "$conf" "$(awk -v t="$time_drop" -v g="$grep_drop" 'BEGIN{printf "%.2f", t+g}')")
  reason=""
  if [[ "$time_drop" != "0" ]]; then reason="시간 강등(age=${age_days}d > ${stale}d)"; fi
  if [[ -n "$drift_note" ]]; then reason="${reason}${reason:+; }${drift_note}"; fi
  [[ -z "$reason" ]] && reason="-"

  echo "| $rel | $level | $conf | $proposed | $reason |"

  if flt "$proposed" "0.3"; then
    STOP_LIST+=("$rel — 제안 confidence $proposed < 0.3")
  fi
done

echo
if [[ ${#STOP_LIST[@]} -gt 0 ]]; then
  echo "## STOP 후보 (사람 결정 필요 — confidence < 0.3 또는 front-matter 누락)"
  for s in "${STOP_LIST[@]}"; do echo "- $s"; done
  echo
fi
if [[ ${#DRIFT_LIST[@]} -gt 0 ]]; then
  echo "## known-drift 신규/재확인"
  for d in "${DRIFT_LIST[@]}"; do echo "- $d"; done
  echo
fi

echo "## 비고"
echo "- 이 리포트는 *제안*이다. 부모 Claude 가 사용자 확인 후 front-matter 를 갱신한다."
echo "- 강등은 알림이지 차단이 아니다 (cascade paralysis 회피)."
echo "- STOP 은 'front-matter 누락' 또는 'confidence < 0.3' 에만 적용."
echo "- 검사 규칙은 \$REPO/.claude/scripts/audit.sh 의 COMMITTED_RULES 배열에서 확장."
