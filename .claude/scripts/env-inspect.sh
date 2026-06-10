#!/usr/bin/env bash
# .env 파일의 키 목록·값 존재 여부만 출력한다 — 값 자체는 절대 출력하지 않는다.
# AI 가 "이 키가 설정돼 있나?" 를 확인하는 유일한 허용 경로 (pre-bash.sh 가 그 외 .env 읽기를 차단).
#
# 사용: env-inspect.sh <path/to/.env> [...]
#       인자 없으면 repo 의 흔한 위치(mochi-backend/.env 등)를 자동 탐색.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

declare -a FILES=()
if [[ $# -gt 0 ]]; then
  FILES=("$@")
else
  for f in "$REPO"/mochi-backend/.env "$REPO"/mochi-backend/.env.local "$REPO"/mochi-ios/.env "$REPO"/.env; do
    [[ -f "$f" ]] && FILES+=("$f")
  done
fi

[[ ${#FILES[@]} -eq 0 ]] && { echo "(.env 파일 없음)"; exit 0; }

for f in "${FILES[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "## $f — 파일 없음"
    continue
  fi
  echo "## $f"
  # KEY=value 행만 파싱. 값은 길이만 보고한다.
  awk -F= '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^[A-Za-z_][A-Za-z0-9_]*=/ {
      key=$1
      val=substr($0, length(key)+2)
      # 따옴표 제거 후 길이
      gsub(/^["'\'']|["'\'']$/, "", val)
      if (length(val) == 0) printf "  %-40s (empty)\n", key
      else                  printf "  %-40s (set, %d chars)\n", key, length(val)
    }
  ' "$f"
done
