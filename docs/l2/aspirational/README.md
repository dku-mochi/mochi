---
level: 2
mode: aspirational
status: active
last_verified: 2026-05-29
confidence: 0.9
owners: [송준서, 이용찬, 박세현]
description: L2 aspirational 영역 안내. 이 디렉토리의 문서는 "지금 코드와 정합돼야 하는 약속" 이 아니라 "도달하고 싶은 상태" 다. 모든 파일은 `target_milestone` 을 가져야 하며, 만료되면 강등/폐기.
---

# L2 aspirational — 목표 상태 영역

> 이 디렉토리는 **검증 대상이 아니다.** 여기 들어있는 문서는 코드와의 정합성 게이트(/ship, codex review, qa-validator) 가 통과 요건으로 삼지 않는다.

## 들어가야 할 것

- "iOS OpenAPI generator 배선 → ⓪ 승격" 같은 구조 목표
- "민감 캡처 on-device 마스킹 v2" 같은 미래 기능 설계
- 데모데이 *후* 작업으로 미루기로 한 모든 것

## 들어가면 안 되는 것

- 지금 코드가 의존하는 도메인 모델 → `docs/DOMAIN_DESIGN.md`
- 지금 운영 중인 토폴로지 → `docs/ARCHITECTURE.md`
- 지금 강제 중인 작업 룰 → `docs/WORKFLOW.md`

## 모든 파일 필수 규칙

1. front-matter 의 `mode: aspirational`.
2. **`target_milestone` 필수** — `W2 | W4 | W6 | post-submission` 중 하나. 만료 시 `/sprint-end` 가 자동 강등 후보로 표시.
3. 첫 줄에 "왜 지금 안 만들었나" 한 줄 — 우선순위 결정 흔적.

## 왜 분리하나 (Pace Layering + K8s "Beta forever" 회피)

같은 디렉토리에 committed 와 aspirational 이 섞이면 doc-guardian 이 둘 모두를 "코드 정합성 검증 대상" 으로 다룬다. → 잘못된 STOP → cascade paralysis. 그래서 path 만으로 분리한다.

K8s 가 2020 년 "Moving Forward From Beta" 정책으로 만료 없는 Beta 를 강제 승격/폐기로 처리한 사고를 모찌 docs 에도 적용 — `target_milestone` 없는 aspirational 은 `/sprint-end` 가 cut 한다.

## 현재 들어있는 문서

(아직 없음 — 첫 후보는 iOS OpenAPI generator 배선 도큐먼트)
