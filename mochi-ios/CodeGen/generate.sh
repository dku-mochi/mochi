#!/usr/bin/env bash
# CoreNetworking 의 OpenAPI 생성 클라이언트(Client.swift / Types.swift)를 재생성한다.
#
# 단일 계약 흐름:
#   백엔드 코드(source) → `make openapi`(생성 + iOS 동기화) → 이 스크립트(Swift 클라 생성)
#
# 선행: 백엔드에서 `make openapi` 를 돌려 CoreNetworking/openapi.json 을 최신화한 상태.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET="$HERE/../Targets/Cores/CoreNetworking"
cd "$HERE"
swift run swift-openapi-generator generate \
  "$NET/openapi.json" \
  --config "$NET/openapi-generator-config.yaml" \
  --output-directory "$NET/Sources/Generated"
echo "→ 재생성 완료: $NET/Sources/Generated/{Client,Types}.swift"
echo "  (변경되면 git diff 확인 후 커밋 — 생성물은 no-diff 게이트 대상)"
