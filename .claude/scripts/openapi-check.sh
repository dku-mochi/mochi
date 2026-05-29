#!/usr/bin/env bash
# OpenAPI ↔ iOS 클라이언트 drift 자동 검사 (②티어 fallback 게이트).
# 정식 swift-openapi-generator 가 배선되기 전까지 *수기* 클라이언트가 명세를 따르고 있는지 자동 확인.
# 사용: bash .claude/scripts/openapi-check.sh
# 출력: 양방향 drift (openapi.json 에 있는데 iOS 에 없음 / iOS 에 있는데 openapi.json 에 없음).
# exit code: 0 = drift 없음, 1 = drift 발견.
#
# 왜 필요한가: API 계약은 모찌의 가장 중요한 공유 표면(WORKFLOW.md §3). ⓪ 가 한쪽만 닫혀
# (백엔드 make openapi 만) iOS 는 수기. 이 갭이 데모 직전 폭발의 단골 원인.
# 이 스크립트가 generator 배선까지의 *fallback 게이트* 다.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

SPEC="$REPO/mochi-backend/openapi.json"
# iOS 클라이언트는 한 파일이 아니다 — 도메인 API(MochiAPIClient)와 인증 API(AuthAPIClient)가 분리돼 있어
# 둘 다 스캔해야 auth/users endpoint 가 위양성 drift 로 잡히지 않는다.
CLIENTS=(
  "$REPO/mochi-ios/Targets/Cores/CoreNetworking/Sources/URLSessionMochiAPIClient.swift"
  "$REPO/mochi-ios/Targets/Cores/CoreAuth/Sources/AuthAPIClient.swift"
)

# 부재 시 안내 후 통과 (생성/이동 가능성)
if [[ ! -f "$SPEC" ]]; then
  echo "ℹ️  $SPEC 없음 — 검사 건너뜀."
  exit 0
fi
existing_clients=()
for c in "${CLIENTS[@]}"; do
  [[ -f "$c" ]] && existing_clients+=("$c")
done
if [[ "${#existing_clients[@]}" -eq 0 ]]; then
  echo "ℹ️  클라이언트 파일 없음 — 검사 건너뜀."
  exit 0
fi

# path 추출 — 별도 파일로 분리(heredoc 제거, read-only sandbox 호환).
# extract_paths.py 가 stdout 으로 SPEC/CLIENT 두 섹션 출력. 실패하면 명시적 에러로 중단.
PY_LIB="$SCRIPT_DIR/lib/extract_paths.py"
if [[ ! -f "$PY_LIB" ]]; then
  echo "❌ $PY_LIB 없음 — 환경 오류." >&2
  exit 3
fi
extract_paths=$(python3 "$PY_LIB" "$SPEC" "${existing_clients[@]}")
extract_rc=$?
if [[ "$extract_rc" -ne 0 ]]; then
  echo "❌ extract_paths.py 가 exit $extract_rc 로 실패 — 게이트 신뢰 불가." >&2
  exit "$extract_rc"
fi

spec_norm=$(printf '%s\n' "$extract_paths" | awk '/^SPEC:/{f=1; next} /^CLIENT:/{f=0} f')
client_norm=$(printf '%s\n' "$extract_paths" | awk '/^CLIENT:/{f=1; next} f')

# Sanity — 둘 다 0 이면 추출이 망가졌을 가능성 (조용한 실패 차단)
spec_count=$(printf '%s\n' "$spec_norm" | grep -c '^/' || true)
client_count=$(printf '%s\n' "$client_norm" | grep -c '^/' || true)
if [[ "$spec_count" -eq 0 && "$client_count" -eq 0 ]]; then
  echo "❌ spec/client 모두 path 0 개 추출 — extract_paths.py 또는 입력 파일 손상 가능성. 통과 표시 안 함." >&2
  exit 5
fi

# 4) drift 비교
spec_only=$(comm -23 <(printf '%s\n' "$spec_norm") <(printf '%s\n' "$client_norm"))
client_only=$(comm -13 <(printf '%s\n' "$spec_norm") <(printf '%s\n' "$client_norm"))

echo "## OpenAPI ↔ iOS 클라이언트 drift 검사 ($(date +%Y-%m-%d))"
echo
echo "- 명세 path 수: $spec_count"
echo "- 클라이언트 path 수: $client_count"
echo

drift_count=0

if [[ -n "$spec_only" ]]; then
  echo "### 명세에는 있는데 클라이언트가 안 부르는 endpoint (백엔드가 노출했으나 iOS 미구현)"
  echo "$spec_only" | sed 's|^|- |'
  echo
  drift_count=$((drift_count + $(echo "$spec_only" | grep -c '^/' || true)))
fi

if [[ -n "$client_only" ]]; then
  echo "### 클라이언트는 부르는데 명세에 없는 endpoint (iOS 가 미정의 API 호출 — 위험)"
  echo "$client_only" | sed 's|^|- |'
  echo
  drift_count=$((drift_count + $(echo "$client_only" | grep -c '^/' || true)))
fi

if [[ "$drift_count" -eq 0 ]]; then
  echo "✅ openapi.json 과 iOS 클라이언트 endpoint 정합 (drift 0)."
  exit 0
fi

echo "❌ drift 총 $drift_count 건. 결정 필요:"
echo "  (a) 명세에 누락된 endpoint 면 백엔드 presentation 에 추가 후 \`make openapi\` 재생성."
echo "  (b) iOS 가 잘못 부르는 거면 클라이언트 수정."
echo "  (c) 의도된 미정의(예: 외부 서비스 prefix 같음)면 CHANGELOG 에 known-drift 등재."
exit 1
