#!/usr/bin/env bash
# iOS TCA 레이어 경계 검사 (②티어 자동 게이트).
# 현재 ③ 문서/리뷰 의존이던 iOS 구조 규칙(App → Features → Cores, Features 끼리 직접 의존 금지)을
# grep 기반 ② 자동 검출로 격상.
#
# 사용: bash .claude/scripts/ios-boundaries.sh
# 출력: 위반 사례 리포트 + 위반 수 + 비어있으면 통과 메시지.
# exit code: 0 = 통과, 1 = 위반 존재.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

IOS_TARGETS="$REPO/mochi-ios/Targets"
if [[ ! -d "$IOS_TARGETS" ]]; then
  echo "ℹ️  $IOS_TARGETS 없음 — 검사 건너뜀."
  exit 0
fi

violations=0
echo "## iOS TCA 레이어 경계 검사 ($(date +%Y-%m-%d))"
echo
echo "**규칙** (docs/WORKFLOW.md §8): App → Features → Cores. Features 끼리 직접 import 금지 (\`RootFeature\` 만 조합). AppIntents 는 별도 extension 이 아니라 App 타겟 내부."
echo

# 1) Features/<X> 안에서 다른 Features/<Y> import 금지
#    grep "import Feature" 가 자기 자신을 포함하지 않는 경우만 위반.
echo "### 1) Features 간 직접 의존 검사"
if [[ -d "$IOS_TARGETS/Features" ]]; then
  feat_violations=0
  for feature_dir in "$IOS_TARGETS/Features"/Feature*; do
    [[ -d "$feature_dir" ]] || continue
    self=$(basename "$feature_dir")
    # 자기 자신 외의 Feature* import
    bad_lines=$(grep -rn "^import Feature" "$feature_dir" 2>/dev/null | grep -v "import $self" || true)
    if [[ -n "$bad_lines" ]]; then
      echo "- ❌ $self 가 다른 Feature 를 직접 import:"
      echo "$bad_lines" | sed 's|^|    |'
      feat_violations=$((feat_violations + 1))
      violations=$((violations + 1))
    fi
  done
  [[ "$feat_violations" -eq 0 ]] && echo "- ✅ Features 간 직접 의존 위반 없음."
else
  echo "- ℹ️  Features/ 디렉토리 없음."
fi
echo

# 2) Cores 가 Features 를 import 하면 위반 (역방향 의존)
echo "### 2) Cores → Features 역방향 의존 검사"
if [[ -d "$IOS_TARGETS/Cores" ]]; then
  reverse=$(grep -rn "^import Feature" "$IOS_TARGETS/Cores" 2>/dev/null || true)
  if [[ -n "$reverse" ]]; then
    echo "- ❌ Cores 에서 Features 를 import (구조 역행):"
    echo "$reverse" | sed 's|^|    |'
    violations=$((violations + $(echo "$reverse" | wc -l | tr -d ' ')))
  else
    echo "- ✅ Cores → Features 역방향 의존 없음."
  fi
else
  echo "- ℹ️  Cores/ 디렉토리 없음."
fi
echo

# 3) App/ 외부에 @main 이 있는지 (AppIntents 가 별도 extension 으로 새지 않았는지)
echo "### 3) @main 또는 AppIntent 의 위치 검사"
app_count=$(grep -rln "^@main" "$IOS_TARGETS/App" 2>/dev/null | wc -l | tr -d ' ')
elsewhere=$(grep -rln "^@main" "$IOS_TARGETS/Features" "$IOS_TARGETS/Cores" 2>/dev/null | wc -l | tr -d ' ')
echo "- App 내부 @main: $app_count 개. App 외부 @main: $elsewhere 개."
if [[ "$elsewhere" -gt 0 ]]; then
  echo "- ⚠️  App 외부에 @main 발견 — 의도된 추가 entry 인지 확인."
fi
echo

# 4) 요약
echo "### 요약"
if [[ "$violations" -gt 0 ]]; then
  echo "- ❌ 위반 총 $violations 건. /ship 전에 정리 권장."
  exit 1
fi
echo "- ✅ iOS TCA 레이어 경계 위반 없음."
exit 0
