---
level: 1
mode: reference
status: active
last_verified: 2026-05-29
confidence: 0.9
owners: [송준서, 이용찬, 박세현]
description: 모든 Claude 세션의 진입점이자 작업 원칙(Think Before Coding / Simplicity First / Surgical Changes / Goal-Driven)·저장소 구성·문서 포인터·변경기록 규칙·하네스 구성의 단일 원천. 모든 작업 시작 전 반드시 읽어라. AGENTS.md 는 이 파일의 미러다.
---

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> 모찌(MOCHI) — Multimodal AI 기반 스크린샷·링크·기록 통합관리 에이전트
> 2026 SW중심대학 디지털 경진대회 / 팀 **세얼간이**

---

## 0. 저장소 구성

이 저장소는 두 개의 독립 프로젝트와 공유 설계 문서로 구성된다.

| 디렉터리 | 역할 | 진입점 |
| --- | --- | --- |
| `mochi-ios/` | iOS 클라이언트 (SwiftUI + TCA, Tuist) | `mochi-ios/README.md` |
| `mochi-backend/` | FastAPI 백엔드 (Modular Monolith + Hexagonal) | `mochi-backend/README.md` |
| `docs/` | 시스템 전체 설계 · 도메인 · 보안 · 제품 정의 | 아래 §5 참고 |
| `journal/` | 하루 작업 로그 · 세션 인수인계 (L3) | `journal/README.md` |
| `lab/` | 실험 · 벤치마크 (lab-experimenter 전용 write 영역) | — |
| `.claude/` | AI 하네스 — 서브에이전트 · 슬래시커맨드 · 권한 | 아래 §7 참고 |
| `archive/` | 폐기된 이전 설계 (참고용, 수정 금지) | — |

각 프로젝트의 빌드/테스트/실행 절차는 해당 README 를 기준으로 한다. 이 파일은 **반복하지 않는다.**

**3인 + AI 협업의 운영 매뉴얼은 [`docs/WORKFLOW.md`](docs/WORKFLOW.md) (L1) 가 단일 원천이다** — 정합성 통제 티어, 문서 레벨, 작업 루프, 공유표면, 브랜치 규칙. 협업·정합성에 관한 모든 결정은 거기서 본다 (§7).

---

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

구현 전에:
- 가정을 명시적으로 말한다. 불확실하면 묻는다.
- 해석이 여러 가지면 모두 제시한다. 조용히 하나를 고르지 않는다.
- 더 단순한 길이 있으면 말한다. 필요하면 반박한다.
- 모호하면 멈춘다. 무엇이 모호한지 짚고 묻는다.

특히 모찌는 **4-Intent 생명주기**와 **민감 캡처 처리**가 도메인의 본질이다. 이 두 축을 건드리는 변경은 반드시 `docs/DOMAIN_DESIGN.md` / `docs/PRIVACY_SENSITIVE_CAPTURE.md` 를 먼저 읽고 정합성을 확인한다.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- 요청되지 않은 기능 금지.
- 단일 호출 코드에 추상화 금지.
- 요청되지 않은 "유연성", "설정 가능성" 금지.
- 불가능한 시나리오에 대한 에러 핸들링 금지.
- 200 줄을 50 줄로 줄일 수 있으면 다시 쓴다.

"시니어가 보면 과설계라 할까?" 라고 자문한다. yes 이면 단순화한다.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

기존 코드를 수정할 때:
- 주변 코드·주석·포맷을 "개선"하지 않는다.
- 망가지지 않은 것을 리팩터링하지 않는다.
- 너라면 다르게 짤 만한 부분도 기존 스타일을 따른다.
- 관련 없는 dead code 는 **언급만 하고** 지우지 않는다.

네 변경이 만든 고아만 정리한다:
- 네 변경으로 인해 사용되지 않게 된 import / 변수 / 함수는 제거.
- 이전부터 있던 dead code 는 요청받지 않은 한 제거하지 않는다.

테스트: 변경된 모든 줄이 사용자의 요청까지 직접 추적 가능해야 한다.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

요청을 검증 가능한 목표로 바꾼다:
- "검증 추가" → "잘못된 입력에 대한 테스트를 쓰고, 그것을 통과시켜라"
- "버그 수정" → "버그를 재현하는 테스트를 쓰고, 그것을 통과시켜라"
- "X 리팩터" → "리팩터 전후 모두 테스트가 통과함을 보여라"

다단계 작업이면 간단한 계획을 먼저 말한다:

```
1. [단계] → 검증: [확인 방법]
2. [단계] → 검증: [확인 방법]
3. [단계] → 검증: [확인 방법]
```

iOS 쪽은 `tuist test`, 백엔드는 `make test` / `make lint` / `make typecheck` 가 항상 최종 검증이다.

**빌드 분담**:
- Claude 가 직접 실행: `tuist *` (build / test / generate), 백엔드 `make *`.
- 사용자가 직접 실행: `xcodebuild` 류 (시뮬레이터·실기기 부팅, archive, IPA). 결과가 필요하면 사용자에게 요청해 받는다.

---

## 5. 문서 포인터 (docs/)

아래 문서들은 **필요할 때 직접 읽는다.** 본 파일에 내용을 복제하지 않는다.

| 주제 | 문서 | 언제 읽는가 |
| --- | --- | --- |
| **docs/ path-first 길잡이 (L1 reference)** | [`docs/INDEX.md`](docs/INDEX.md) | 파일 열기 전 어떤 디렉토리를 읽고 어떤 디렉토리를 skip 할지 path 만으로 결정할 때 — 컨텍스트 절약 |
| **팀원 온보딩 · 하네스 입문 가이드 (L1 reference)** | [`docs/HARNESS_GUIDE.md`](docs/HARNESS_GUIDE.md) | 새 팀원 첫 진입, "왜 이렇게 일하나" 가 흔들릴 때 — `WORKFLOW.md`의 친절한 풀이 버전 |
| **팀 워크플로우 · 정합성 통제 (L1)** | [`docs/WORKFLOW.md`](docs/WORKFLOW.md) | 협업·브랜치·티어·문서레벨·공유표면·2달 단기 모드·메타데이터 컨벤션 — 작업 시작 전 |
| 시스템 전체 아키텍처 (iOS ↔ Backend) | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | 두 프로젝트에 걸친 변경, 데이터 흐름·계약 수정 시 |
| 도메인 모델 · DB 스키마 · 4-Intent 상태머신 | [`docs/DOMAIN_DESIGN.md`](docs/DOMAIN_DESIGN.md) | Intent / lifecycle / 테이블 / 마이그레이션 변경 시 |
| 민감 캡처 보호 설계 (on-device 감지, 마스킹) | [`docs/PRIVACY_SENSITIVE_CAPTURE.md`](docs/PRIVACY_SENSITIVE_CAPTURE.md) | 캡처 ingestion · 업로드 · 저장 경로 변경 시 |
| 제품 정의 · 사용자 문제 · 컨셉 | [`docs/PRODUCT.md`](docs/PRODUCT.md) | UX · 핵심 기능 의사결정이 흔들릴 때 |
| 외부 설정 · 비밀값 체크리스트 (Apple/Google) | [`docs/TODO.md`](docs/TODO.md) | 인증 · 외부 통합 작업 시 |
| 변경 이력 | [`docs/CHANGELOG.md`](docs/CHANGELOG.md) | 모든 변경의 종착지 (§6 참고) |

하루 작업 로그·인수인계:
- [`journal/`](journal/) — 어제 흐름 이어받기, 컨텍스트 스위치 직후 첫 30분에 읽기

프로젝트 로컬 문서:
- [`mochi-ios/README.md`](mochi-ios/README.md) — iOS 빌드·모듈 구조·App Group·Tuist
- [`mochi-backend/README.md`](mochi-backend/README.md) — 백엔드 빌드·헥사고날 규칙·Idempotency·SSRF 가드

---

## 6. 변경 기록 규칙 (필수)

코드든 문서든 의미 있는 변경이 있을 때마다 다음 두 가지를 반드시 한다.

1. **해당 docs 문서를 동기화한다.**
   - 도메인/스키마 변경 → `docs/DOMAIN_DESIGN.md` 갱신
   - 시스템 토폴로지·API 계약 변경 → `docs/ARCHITECTURE.md` 갱신
   - 민감정보 처리 흐름 변경 → `docs/PRIVACY_SENSITIVE_CAPTURE.md` 갱신
   - 외부 설정 추가 → `docs/TODO.md` 체크리스트 추가
   - **정합성 폭포**: 상위 레벨(L1/L2) 문서를 바꾸면 하위(L3)·양 README·`openapi.json` 까지 따라 맞춘다 (레벨 정의는 `docs/WORKFLOW.md` §2).
   - 문서와 코드가 어긋난 채로 끝내지 않는다. 동기화가 불가능하면 사용자에게 보고하고 멈춘다.

2. **`docs/CHANGELOG.md` 맨 위에 한 줄 추가한다.**
   - 포맷: `## YYYY-MM-DD — <범위>` 헤더 아래 변경 사항 bullet.
   - 범위는 `ios` / `backend` / `docs` / `infra` 중 하나 이상.
   - "왜" 가 자명하지 않으면 한 줄 이유를 덧붙인다.
   - 예시:
     ```
     ## 2026-05-23 — backend
     - WebFetch SSRF 가드에 multicast IP 차단 추가 (DNS rebinding 우회 방지)
     ```

이 두 단계는 작업의 일부다. 누락은 미완성으로 간주한다.

---

## 7. 하네스 — 서브에이전트 · 워크플로우 · 정합성 통제

3인 + AI 협업의 정합성을 지키는 운영 체계다. **상세 규칙은 [`docs/WORKFLOW.md`](docs/WORKFLOW.md) 가 단일 원천**이며, 여기엔 부모 Claude 가 항상 지킬 핵심만 둔다.

**서브에이전트 (기본 read-only, 코드 수정은 부모 Claude 만):**
- `architect` — 설계·플랜 (read-only)
- `code-reviewer` — diff 리뷰, codex 위임 (수정 없음)
- `qa-validator` — 테스트·동작검증, codex 보강 (수정 없음)
- `doc-guardian` — 작업 *전* 문서 정합성·모순·모호성 스캔 (read-only)
- `lab-experimenter` — **유일하게 write 가능, `lab/` 한정**

**Hooks (`.claude/hooks/`, 대부분 ②티어 강제력 — 마지막 1개만 ③ 넛지):**
- `session-start.sh` — 경진대회 제출 D-day + 활성 known-drift + 직전 journal 의 "다음 할 일" 1줄
- `pre-bash.sh` — 위험 Bash 패턴 차단 (force-push, reset --hard, rm -rf /, .env 직접 출력)
- `pre-edit-scope.sh` — `lab-experimenter` 의 Edit/Write 를 `lab/` 안으로 제한 (payload `agent_type` 로 판별, fail-open 이라 부모 Claude 는 자유). lab 경계를 ③(프롬프트)에서 ②(기계 강제)로 승격.
- `post-edit-md.sh` — `.md` Edit/Write 직후 front-matter 7필드 누락 알림
- `stop-summary.sh` — 세션 종료 직전 CHANGELOG 누락 + CLAUDE↔AGENTS mtime drift 알림
- `pre-commit-reminder.sh` — **③ 넛지(차단 아님)**. `git commit` 직전 부모 Claude 컨텍스트에 "review/qa 거쳤나? 사소하면 스킵 OK" 리마인더 주입(`additionalContext`). review/qa *필요 여부*는 판단 영역이라 ②로 강제하지 않고 가시성만 높인다. lint/typecheck 는 `ship-precheck.sh` §6 담당(여기 중복 안 둠). 근거: 직전 세션이 review/qa 게이트를 조용히 건너뜀(journal §8.1(C)).
- `settings.json` permissions.deny — `Read/Edit/Write(**/.env)` 등 비밀파일 차단

**자동 채점 스크립트 (`.claude/scripts/`):** — `.sh` 모두 git mode 100755 executable, `lib/*.py` 는 정적 import 모듈이라 100644.
- `audit.sh <l1|l2|l3|all>` — 시간 강등 + 코드 식별자 grep 강등 + STOP 후보. 모노레포·macOS/Linux 이식.
- `ship-precheck.sh <ios|backend|docs|all>` — `/ship` 자동 사전 체크 **7단계** (audit / CHANGELOG / 미러 mtime / iOS 경계 / OpenAPI drift / **백엔드 lint+typecheck** / git status). 게이트 무결성 보장(exit code 명시).
- `ios-boundaries.sh` — TCA 레이어 위반 자동 검출 (Features 간 import / Cores 역방향 / @main 위치).
- `openapi-check.sh` (+ `lib/extract_paths.py`) — OpenAPI ↔ iOS 클라이언트 drift 자동 검사 (path-parameter 정규화 양방향). 정식 swift-openapi-generator 배선까지의 fallback ② 게이트.

**표준 작업 루프:**
```
업무지시 → doc-guardian(모순/모호성 체크, 모호하면 STOP)
        → architect(플랜) → 부모(코드 수정)
        → code-reviewer(→codex) → qa-validator(→codex) → 반복
완료 → 문서+정합성 폭포 동기화 → /ship → 커밋 → (PR)
```

**정합성 통제 티어** (⓪ > ① > ② > ③): 갈라질 수 있는 결정은 가장 싼 통제에 둔다. 기계로 막을 수 있는 것을 ③(문서)에 두지 않는다.
- ⓪ 불가능: API 계약 = `mochi-backend/openapi.json` 단일원천 (**목표 상태** — iOS 는 `swift-openapi-runtime` 의존성만 있고 generator 미설정, 현재는 수기 `URLSessionMochiAPIClient` 라 drift 위험. ⓪ 로 끌어올리려면 generator 배선 필요)
- ① 포매터 / ② 린터·타입체커·백엔드 경계테스트 / ③ 문서 + 서브에이전트 (iOS 레이어 규칙은 자동검출 없어 현재 ③)

**슬래시커맨드:** `/daily` `/handoff` `/ship` `/sync-agents` `/codify` `/sprint-end` `/audit`
- `/sprint-end <식별자>` — 2주 sprint 마감 의식 (W2/W4/W6/submission). done/expired → `docs/archive/<식별자>/` 이관 + 다음 sprint 목표 1줄 + scope-cut 강제.
- `/audit <범위>` — 지정 영역 정합성·신선도 감사. `last_verified` 시간 강등 + 코드 식별자 grep 강등. 알림만, 차단 X (cascade paralysis 회피).
- 새 갈라짐이 발견되면 `/codify` 로 적절한 티어에 굳힌다 (규칙도 Simplicity First — 추측성 규칙 금지).

**codex:** QA·리뷰의 검증 엔진. codex 가 읽는 규칙은 `AGENTS.md`(= 이 파일의 미러, `/sync-agents` 로 생성).

---

**These guidelines are working if:** diff 에 불필요한 변경이 줄고, 과설계로 인한 재작성이 줄고, 명확화 질문이 실수 이후가 아니라 구현 이전에 나온다.
