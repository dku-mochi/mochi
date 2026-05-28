---
level: 1
mode: reference
status: active
last_verified: 2026-05-29
confidence: 0.9
owners: [송준서, 이용찬, 박세현]
description: 모찌 docs/ 의 path-first 길잡이. AI 가 파일을 열기 전 어떤 디렉토리를 읽고 어떤 디렉토리를 skip 할지 path 만 보고 결정하도록 한 줄로 안내. 새 문서가 생기면 여기 한 줄 추가.
---

# docs/ INDEX — path-first 길잡이

> 목적: **파일을 열기 전에 path 만으로 "지금 읽을 가치가 있는가" 를 판단**한다. 컨텍스트 윈도우는 비싸고, 안 읽어도 될 걸 안 읽는 것이 첫 번째 절약이다.

## 디렉토리 의미 (load/skip 기준)

| 경로 | 의미 | AI 가 언제 읽나 |
|---|---|---|
| `docs/WORKFLOW.md` | L1 운영 매뉴얼 (단일 원천) | **모든 작업 시작 전** — 티어·폭포·공유표면 확인 |
| `docs/PRODUCT.md` | L1 제품 정의 | UX·핵심 기능 결정 시 |
| `docs/HARNESS_GUIDE.md` | L1 reference — 친절한 입문서 | 새 팀원/세션이 합류했을 때만 |
| `docs/ARCHITECTURE.md` | L2 committed — 시스템 토폴로지·API 계약 | 두 프로젝트에 걸친 변경 시 |
| `docs/DOMAIN_DESIGN.md` | L2 committed — 도메인·DB·4-Intent | 도메인/마이그레이션 변경 시 |
| `docs/PRIVACY_SENSITIVE_CAPTURE.md` | L2 committed — 민감 캡처 보호 | 캡처 ingestion/저장 경로 변경 시 |
| `docs/l2/aspirational/` | L2 aspirational — *목표 상태* (검증 대상 외) | **default skip**. 명시 요청 시만. |
| `docs/TODO.md` | L3 — 외부 설정·비밀 체크리스트 | 인증/외부 통합 작업 시 |
| `docs/CHANGELOG.md` | L3 log — 변경 이력 (append-only) | 최근 변경 맥락 확인 시 |
| `docs/archive/` | 분기 마감되거나 superseded | **default skip**. 과거 추적이 명시 필요할 때만. |
| `docs/gcp-architecture.html` | L2 reference — 인프라 다이어그램 | 인프라 관련 작업 시 |
| `journal/*.md` | L3 log — 하루 작업 로그·인수인계 | 어제/그저께 흐름 이어받을 때 |
| `lab/*.py`, `lab/*.json` | L3 실험 — 벤치·프로토타입 | 비슷한 실험 결과가 필요할 때 |
| `archive/` (루트) | 폐기된 이전 설계 | **read 금지 / skip** — `docs/ARCHITECTURE.md` 가 정본 |

## 두 축

- **level (변화율)**: L1(다년) → L2(분기/년) → L3(주/일). 빠른 층은 느린 층을 침범하지 않는다.
- **mode (종류)**: `committed`(코드 정합 검증 대상) / `aspirational`(목표·미래, 검증 외, **반드시 `target_milestone` 필요**) / `reference`(정보) / `log`(시간 기록).

→ `level × mode` 매트릭스의 자세한 규칙은 `docs/WORKFLOW.md` §2.

## 새 문서를 추가할 때

1. front-matter 6개 필드 채우기: `level`, `mode`, `status`, `last_verified`, `confidence`, `description`.
2. `description` 은 "**언제 이 문서를 읽어야 하는가**" 를 한 줄로. AI 트리거 조건이다.
3. 이 INDEX 에 한 줄 추가.
4. 적절한 디렉토리에 둔다 (현재는 path 기반 분리가 lite — `l2/aspirational/` 만 분리, 나머지는 front-matter 의 `mode` 로 판정).
