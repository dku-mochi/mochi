---
level: 2
mode: aspirational
status: active
last_verified: 2026-05-29
confidence: 0.7
owners: [송준서, 이용찬, 박세현]
target_milestone: post-submission
description: API 계약의 ⓪ 승격을 위한 iOS OpenAPI generator 배선 계획. iOS 클라이언트 자동 생성을 시작/이어받을 때 읽어라. 현재는 aspirational — 제출 후 작업으로 미뤘다. submission 직전엔 cut 후보, post-submission 에 재개.
---

# FUTURE — iOS OpenAPI Generator 배선

> **현재 상태**: 모찌 백엔드의 `openapi.json` 은 단일 원천이고 `make openapi` 로 재생성된다(⓪). 그러나 iOS 쪽은 `swift-openapi-runtime` 의존성만 있고 generator 미설정. 클라이언트는 손으로 만든 `URLSessionMochiAPIClient` 가 사용 중(③). 결과적으로 API 계약 ⓪ 가 한쪽만 닫혀 있어 drift 위험.

## 왜 지금 안 만들었나

- 경진대회 산출물 제출 마감(2026-07-15)까지 시간이 짧다. generator 배선은 Tuist 통합·Codegen 단계·CI 통합까지 1주 이상 소요 추정.
- 현재 수기 클라이언트로 핵심 기능(인증·캡처·검색) 데모 가능. drift 는 doc-guardian + code-reviewer 의 ③ 검증으로 *부분* 흡수 중.
- post-submission 작업으로 미뤄도 데모 시연에는 무영향. 단 *제출 후 운영* 단계엔 필수.

## 목표 상태

1. `mochi-ios/openapi-generator-config.yaml` 작성 — `swift-openapi-generator` 의 Tuist Plugin 또는 SwiftPM plugin 배선.
2. `mochi-ios/Targets/Cores/CoreNetworking/Generated/` 신설 — Codegen 결과 자동 생성, 손으로 안 만짐.
3. `mochi-backend/openapi.json` 변경 → `tuist generate` 또는 build phase 가 자동 재생성.
4. 기존 `URLSessionMochiAPIClient` 를 점진 폐기 — 생성된 client 가 같은 endpoint 를 cover 하면 deprecate.

## 검증 게이트 (배선 후)

- `.claude/scripts/audit.sh` 의 `COMMITTED_RULES` 에 "iOS Generated/ 에 openapi.json 의 path 들이 모두 cover" 검사 추가.
- `make openapi` 후 `tuist generate` 가 항상 따라붙는 hook 또는 CI.

## 함정

- swift-openapi-generator 가 SwiftUI/TCA 모델과 잘 안 맞는 케이스 가능 — 어댑터 레이어 별도.
- Generated 코드가 형식 변경에 민감 — `openapi.json` 변경 시 항상 양쪽 rebuild.

## 다음 발화 시점

- `/sprint-end submission` 직전 — cut 후보로 확인.
- `post-submission` 첫 sprint — 우선순위로 격상.

## 관련 출처

- swift-openapi-generator (Apple) — Tuist Plugin: 외부 검색 필요.
- 모찌 백엔드의 `openapi.json` 단일원천 패턴 — `mochi-backend/Makefile` 의 `openapi` 타겟.
