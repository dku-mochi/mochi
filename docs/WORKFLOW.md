---
level: 1
mode: committed
status: active
last_verified: 2026-05-29
confidence: 0.9
owners: [송준서, 이용찬, 박세현]
title: 팀 워크플로우 · 정합성 통제
description: 3인 + AI 협업의 운영 매뉴얼. 갈라질 수 있는 모든 것을 티어로 통제하고, 작업 루프·문서레벨·브랜치·공유표면·세션 라이프사이클·2달 단기 모드 규칙의 단일 원천. 모든 작업 시작 전 필독.
---

# WORKFLOW — 팀 운영 매뉴얼 (L1)

> 모찌(MOCHI) — 3인이 AI로 코드를 짜며 빠르게 협업한다. 이 문서의 목표는 **사람마다·AI마다 갈라질 수 있는 모든 결정을 통제**해서 충돌과 모호함이 안 생기게 하는 것이다.
>
> 이 문서는 **L1(불변 기반)** 이다. 바꾸려면 팀 합의가 필요하다. (AI는 사람 명시 승인 없이 수정하지 않는다.)

---

## 0. 핵심 사상 — 열거하지 말고 시스템으로

규칙을 500개 미리 적으면 아무도 안 읽고 금방 낡는다. 대신 두 기둥으로 굴린다:

- **기둥 A — 라우팅**: 갈라질 수 있는 어떤 결정이든 **가장 싼 통제 티어**로 보낸다 (§1).
- **기둥 B — 학습 루프**: 미리 다 못 적으니, 갈라짐이 *발견될 때마다* `/codify` 로 규칙으로 굳힌다 (§6).

규칙도 Simplicity First 를 따른다. 최소 시드로 시작하고, 갈라짐이 생길 때만 추가한다. 추측성 규칙 금지.

---

## 1. 정합성 통제 티어 (⓪ > ① > ② > ③)

모든 "갈라질 수 있는 결정" 을 종류별로 가장 싼 통제에 박는다. **기계로 막을 수 있는 것을 ③(문서)에 두지 않는다** — 가장 흔한 실수다.

| 티어 | 원리 | 갈라질 확률 | 모찌에서의 구현 |
|---|---|---|---|
| **⓪ 불가능하게** | 단일 원천에서 생성 | 0% | 디자인 토큰 = `DesignSystem` 모듈. **API 계약은 목표 상태** — `mochi-backend/openapi.json` 을 단일원천으로 iOS 생성하려 하나, 현재 iOS 는 `swift-openapi-runtime` 의존성만 있고 generator 미설정 + 수기 `URLSessionMochiAPIClient` 라 실제론 ③(drift 위험). generator 배선 시 ⓪ 승격. |
| **① 자동 결정** | 포매터 | ~0% | `ruff format` (py) · SwiftLint autocorrect/swiftformat (swift) |
| **② 자동 검출** | 린터·타입체커·경계테스트·훅 | ~0% | `ruff check`(E,F,I,B,UP,**N**,SIM,ASYNC) · `mypy --strict` · `tests/unit/test_module_boundaries.py` · `.swiftlint.yml` · `.claude/hooks/`(pre-bash, **pre-edit-scope**=lab 경계) |
| **③ AI 판단** | 문서 + 서브에이전트 | ~80% | 이 문서의 네이밍 사전(§7)·파일위치 맵(§8) + `code-reviewer`/`doc-guardian` |

③(AI가 문서 따르기)는 ~80%만 맞으므로, **검증 게이트**(§5 의 `/ship`·code-reviewer·qa-validator·CI)가 새는 20%를 잡는다.

---

## 2. 문서 레벨 + 정합성 폭포

각 문서는 **안정도** 레벨을 갖는다 (front-matter `level:`). 안정 레벨일수록 수정 보호가 강하고, 어느 레벨을 바꾸든 **정합성이 아래로 흐른다.**

| 레벨 | 성격 | 문서 | 수정 규칙 |
|---|---|---|---|
| **L1** 불변 기반 | 문제·팀·워크플로우 | `WORKFLOW.md`(이 문서), `PRODUCT.md` | 팀 합의 + 사람 명시 승인 |
| **L2** 바뀌면 골치 | 도메인·아키텍처·인프라·민감캡처 | `DOMAIN_DESIGN.md`, `ARCHITECTURE.md`, `PRIVACY_SENSITIVE_CAPTURE.md`, `gcp-architecture.html` | 수정 시 L3·양 README 재검토 강제 |
| **L3** 자주 바뀜 | 주간플랜·아이디어·로그 | `TODO.md`, `journal/*`, `lab/*` | 자유 |

**폭포 예시 (반드시 따라 바꿔야 함):**
- DB 스키마 변경(L2 `DOMAIN_DESIGN`) → 백엔드 코드·iOS 코드·양 README·이번주 plan(L3) 동기화
- 해결할 문제 변경(L1 `PRODUCT`) → 도메인 모델(L2) → 서버·iOS·plan(L3) 연쇄

작업 시작 전 `doc-guardian` 서브에이전트가 이 폭포를 스캔해 모순/모호성을 먼저 잡는다 (§4).

---

## 3. 공유 표면 (고충돌 구역) ⚠️

기능을 수직 분담(한 사람이 자기 기능의 iOS+백엔드 다)하면 대부분 서로 다른 파일을 만져 충돌이 거의 없다. 충돌은 **오직 이 공유 표면에서만** 난다. 여기를 건드리면 **멈추고 팀에 공유**한다:

1. **API 계약** — `mochi-backend/openapi.json` (그리고 그것을 만드는 presentation 스키마)
2. **DB 스키마 / 마이그레이션** — `alembic/versions/*`, ORM
3. **공유 Core 모듈** — 백엔드 `app/shared/`·`app/core/`, iOS `Cores/*` (특히 `CoreDomain`, `CoreNetworking`)
4. **라우팅 / 네비게이션** — 백엔드 `app/api.py`, iOS `RootFeature`
5. **디자인 토큰** — iOS `DesignSystem`
6. **4-Intent lifecycle 정책** — `lifecycle_policy.py` ↔ `CoreDomain.LifecyclePolicy` (양쪽 동일 불변식)

→ **주간 contract-first 킥오프**(§9)에서 이 표면들의 변경을 먼저 합의한다.

---

## 4. 작업 루프 (Flow A / B)

부모 Claude 가 오케스트레이터다. 서브에이전트는 분석·평가·QA 전담(읽기), **코드 수정은 부모만**. `lab-experimenter` 만 예외(`lab/` 한정 쓰기).

```
Flow A — 구현 루프
업무 지시
  → [doc-guardian]  문서·코드 정독 + 모순/모호성 체크 (모호하면 STOP, 사람에게 질문)
  → [architect]     검증 가능한 플랜 작성 (공유표면 닿는지 경고)
  → [부모 Claude]   코드 수정
  → [code-reviewer] 리뷰 (→ codex review)
  → [qa-validator]  QA (make test / tuist test, → codex exec)
  → 통과까지 반복

Flow B — 완료
개발 완료
  → [부모 + doc-guardian]  문서 수정 + 정합성 폭포 동기화
  → /ship <범위>           최종 게이트
  → 커밋 (Conventional Commits)
  → (remote 붙으면) PR
```

---

## 5. 서브에이전트 + codex

> **왜 에이전트 팀이 아니라 "서브에이전트 + 슬래시커맨드 + hooks"인가** — harness 메타스킬의 기본형(에이전트 팀 `TeamCreate`/`SendMessage` + 오케스트레이터 스킬 + 커맨드 금지)에서 *의도적으로* 변형한 결정이다. 흔들리지 않도록 근거를 남긴다:
> - **서브에이전트(팀 아님)**: 모찌의 작업 루프는 부모 Claude 단일 오케스트레이터로 충분하다. 팀 통신(`SendMessage`) 오버헤드가 이득보다 크다. 서브에이전트는 read-only 분석·검증 전담, **코드 수정은 부모만** → 책임 단일화·감사 추적 단순화.
> - **슬래시커맨드 사용(스킬 대신)**: `/ship` `/daily` `/sprint-end` 등은 자동 흐름이 아니라 **사람이 트리거하는 결정점("의식")**이다. 사람 결정점에는 커맨드가 자연스럽다. 단, 검증 *로직*은 `.claude/scripts/`에 두어 부모가 자율 재사용할 수 있게 한다 (§5.2).
> - **hooks/scripts(②티어)**: harness 기본형에 없는 강제력이다. 기계로 막을 수 있는 갈라짐은 ③(문서)이 아니라 hook/script 로 올린다 (§1 원칙의 직접 구현).

| 에이전트 | 권한 | 역할 |
|---|---|---|
| `architect` | read-only | 설계·플랜 |
| `code-reviewer` | read + Bash, 수정 없음 | diff 리뷰, **codex 위임** |
| `qa-validator` | read + Bash, 수정 없음 | 테스트·동작검증, codex 보강 |
| `doc-guardian` | read-only | 작업 전 문서 정합성 스캔 |
| `lab-experimenter` | **write (lab/ 한정 — `pre-edit-scope.sh` 훅이 ②로 강제)** | 실험·벤치 |
| 부모 Claude | write (ios/backend) | 코드 수정 주체 |

**codex** 는 QA·리뷰의 검증 엔진이다 (`brew/npm 설치, ChatGPT 인증 완료`). `code-reviewer`/`qa-validator` 가 `codex review` · `codex exec` 로 호출한다. codex 가 직접 읽는 규칙은 `AGENTS.md`(= CLAUDE.md 미러)에 있다.

### 5.1 서브에이전트 출력 공통 규약

서브에이전트마다 출력 포맷이 제각각이면 부모가 매번 재해석해야 한다. 모든 서브에이전트는 다음을 지킨다:

- **첫 줄은 한 줄 판정**: `## VERDICT: <PASS|FAIL|STOP|OK|BLOCKED> — <핵심 한 줄>`. 부모가 결과를 재해석 없이 분기(다음 단계 진행 / 사람에게 질문 / 수정 루프)할 수 있게 한다.
  - `architect` → `OK`(플랜 준비됨) / `STOP`(모호성·결정 필요)
  - `doc-guardian` → `OK`(정합) / `STOP`(논리적 모순·사람 결정 필요)
  - `code-reviewer` → `PASS`(P1 없음) / `FAIL`(must-fix 있음)
  - `qa-validator` → `PASS` / `FAIL`
  - `lab-experimenter` → `OK`(실험 완료, lab/ 한정) / `BLOCKED`(프로덕션 변경 필요 — 부모가 실행)
- **위치 인용은 `상대경로:줄`** 형식으로 통일한다 (예: `mochi-backend/app/modules/mochi_items/application/ingest.py:42`). 부모가 바로 점프할 수 있다.
- **codex 위임 결과는 codex 결론을 먼저**, 그 다음 자기 판단을 적는다.

### 5.2 검증 스크립트 자율 호출

`.claude/scripts/` 의 게이트(`ship-precheck.sh`, `audit.sh`, `openapi-check.sh`, `ios-boundaries.sh`)는 `/ship`·`/audit` 커맨드(사람 트리거)에만 묶이지 않는다. **부모 Claude 는 Flow A/B 중간 어디서든** `bash .claude/scripts/ship-precheck.sh <scope>` 등을 자율 호출해 정합성을 빠르게 확인할 수 있다 — 커맨드는 사람용 진입점, 스크립트는 부모용 재사용 엔진이다.

---

## 6. 자기성장 루프 — `/codify`

규칙은 시간이 지날수록 저절로 촘촘해진다:

```
갈라짐 발견 (리뷰/충돌/"왜 이렇게 짰어?")
   → /codify "<갈라진 결정>"
   → 가장 싼 티어 판단 (§1)
       기계화 가능 → 린터/포매터/생성기 규칙으로
       판단 영역   → 이 문서 §7/§8 에 한 줄
   → CHANGELOG 에 codify: 한 줄
   → 3명의 AI 전부 다음 작업부터 자동 상속
```

---

## 7. 네이밍 사전 (③ 판단 — 시드, `/codify` 로 성장)

기계 린터(②)가 잡는 것(case 규칙 등)은 여기 적지 않는다. **의미적 선택**만 적는다.

**백엔드 (Python)** — ruff `N`(pep8-naming) 이 case 는 강제.
- 유스케이스 클래스: 동사+명사 (`IngestCapture`, `HybridSearch`, `OverrideCaptureIntent`).
- 포트(Protocol): 역할 명사 (`MochiItemRepository`, `RetrievalIndex`, `LLMClient`).
- 조회 함수: `queries.py` 에 모음. (TBD: `get_` vs `fetch_` 통일 — 첫 충돌 시 `/codify`)

**iOS (Swift)** — `.swiftlint.yml` 이 case 강제. `id, ok, x, y` 는 짧은 이름 허용.
- TCA: `<X>Feature`(Reducer) + `<X>View`. 도메인 모델은 `CoreDomain`.
- 계약 모델은 손으로 만들지 않는다 — `openapi.json` 생성 클라이언트 사용 (⓪).

---

## 8. 파일 위치 맵 (구조 티어 — 백엔드는 ② 경계테스트 강제, iOS 는 ③ 문서/리뷰)

**백엔드 헥사고날** (`app/modules/<module>/`):
| 종류 | 위치 |
|---|---|
| 순수 도메인(프레임워크 import 금지) | `domain/` |
| 유스케이스 | `application/` |
| 포트(Protocol) | `domain/ports.py` |
| ORM·외부 어댑터 구현 | `infrastructure/` |
| FastAPI 라우터 + Pydantic API 스키마 | `presentation/` |
| 모듈 간 공통(Intent, ID) | `app/shared/` |
| cross-cutting(config, db, security…) | `app/core/` |

규칙: 다른 모듈은 그 모듈의 `domain/`·`application/`·`shared`·`core` 만 import 가능. `infrastructure/`·`presentation/` 비노출. `domain/` 은 sqlalchemy/fastapi/httpx/google import 금지. → `tests/unit/test_module_boundaries.py` 가 강제.

**iOS TCA** (`Targets/`):
| 종류 | 위치 |
|---|---|
| 앱 셸·@main·AppIntents | `App/` |
| 화면 기능(Reducer+View) | `Features/Feature<X>/` |
| 도메인·영속·네트워킹·디자인 등 | `Cores/Core<X>/` |
| 공유시트 | `ShareExtension/` |

규칙: `App → Features → Cores`. Features 끼리 직접 의존 금지(`RootFeature` 가 조합). AppIntents 는 별도 extension 아니라 App 타겟 내부.

> iOS 구조 규칙은 **`.claude/scripts/ios-boundaries.sh` 가 ② 자동 검출**한다 (Features 간 직접 import 금지 / Cores → Features 역방향 금지 / @main 위치). `/ship` precheck 가 자동 호출 (`ship-precheck.sh` §4). 더 깊은 검사(Tuist graph dump 분석)는 백로그.

---

## 9. 협업 리듬

**주간 (월요일 킥오프 — contract-first):**
1. 이번 주 각자 맡을 기능 분담 (예: 알림 / 게시판 / 검색).
2. 각 기능의 **API 계약을 먼저 합의**한다 — 구현 전에 백엔드 `presentation/` 스키마·route 를 추가하고 `make openapi` 로 `openapi.json` 을 재생성한다. (`openapi.json` 은 손으로 고치지 않는다 — presentation 에서 생성된다.) 3명의 AI가 같은 `openapi.json` 을 보고 짠다.
3. 건드릴 **공유표면**(§3) 공유.
4. 그 다음 각자 AI로 구현 시작.

**하루:**
- 시작: `git pull` → 최신 `journal/` + `CHANGELOG` 훑기.
- 작업: feature 브랜치, 작은 커밋, Flow A 루프.
- 종료: 미완이면 `/handoff`, `/daily` 로 로그, `/ship`, `CHANGELOG` 한 줄.

---

## 10. 브랜치 · 커밋 (모노레포 통합 완료)

> **루트 모노레포 git 통합 완료** (2026-05-29). 하위 `.git` 제거 후 루트 단일 git 으로 합침. 이제 `.claude/`, `docs/`, `journal/` 의 변경이 모두 추적된다. PR 가 붙기 전엔 `/ship` + code-reviewer 로 PR 리뷰를 대체한다.

- **트렁크 기반**: `main` + 짧은 feature 브랜치.
- **브랜치명**: `feat|fix|docs|chore/<area>-<짧은설명>` — area ∈ `ios` `be` `docs` `infra`. 예: `feat/be-notifications`, `fix/ios-backtap-crash`.
- **커밋**: Conventional Commits. `type(scope): 요약` — 예: `feat(auth): Apple/Google Sign-In`. (기존 히스토리가 이미 이 형식)
- **1 PR = 1 논리 변경.** codex 셀프리뷰 → 팀원 1 리뷰.
- `git push` 는 자동 허용하지 않음(항상 확인). force-push 금지 (`.claude/hooks/pre-bash.sh` 가 차단).

---

## 11. 2달 단기 모드 — sprint cadence + 마감 보호

> 모찌는 **8주 짧고 굵은 프로젝트**다(경진대회 산출물 제출 2026-07-15, `docs/.deadline`). 분기·반기 cadence 는 발생하지 않으므로 그 의식을 폐기하고 **2주 sprint × 4회** 로 압축한다.

### 11.1 Sprint 식별자

| 식별자 | 의미 | 발화 |
|---|---|---|
| `W2` | 시작 후 2주 | `/sprint-end W2` |
| `W4` | 시작 후 4주 | `/sprint-end W4` |
| `W6` | 시작 후 6주 (데모 직전) | `/sprint-end W6` |
| `submission` | 제출 직전 최종 정리 | `/sprint-end submission` |
| `post-submission` | 제출 후 살릴 작업 | aspirational L2 의 `target_milestone` 값 |

### 11.2 cadence

- **매 세션**: SessionStart hook 이 D-day · known-drift · 직전 journal 의 "다음 할 일" 출력.
- **매일**: `/daily` 로 journal, `/handoff` 로 다음 세션 인수인계.
- **매주(권장)**: `/audit l3` 로 stale 항목 강등.
- **매 2주(필수)**: `/sprint-end <식별자>` — done/expired 이관 + 다음 sprint 목표 1줄 + scope-cut 강제 + CHANGELOG 한 줄.
- 분기/반기 cadence — **없음**.

### 11.3 함정 회피 (codex 자문 기반)

- **cascade paralysis**: 정합성 폭포는 *알림*이지 차단이 아니다. `confidence < 0.7` 은 doc-guardian 의 우선 flag, STOP 은 *논리적 모순* 에만.
- **scope creep**: aspirational L2 는 반드시 `target_milestone`. 없으면 `/sprint-end` 가 cut 후보로 표시.
- **장식 메타데이터**: `last_verified`/`confidence` 는 `/audit` 와 `/ship` 이 자동 갱신 (사람 수동 갱신은 보조).

---

## 12. 메타데이터 컨벤션 (front-matter)

> 모든 docs 와 `journal/*.md`, `mochi-{ios,backend}/README.md`, `CLAUDE.md`, `AGENTS.md` 가 같은 7필드 시드를 따른다. `description` 은 **AI 트리거** — "언제 이 문서를 읽어야 하는가" 를 imperative 로.

### 12.1 필수 7필드

> `.claude/scripts/audit.sh` 와 `.claude/hooks/post-edit-md.sh` 가 검사하는 *전체 시드* 다. 7필드 모두 박혀야 자동 채점 대상이 되고, 누락 시 알림.

```yaml
---
level: 1                       # 1|2|3 — 변화율 축 (L0 폐기, 단기 모드)
mode: committed                # committed | aspirational | reference | log
status: active                 # active | done | superseded | archived
last_verified: 2026-05-29      # ISO date — 마지막 정합 확인일
confidence: 0.7                # 0.1~0.9 — 현재 신뢰도 (코드 정합·시간 강등 반영)
owners: [송준서, 이용찬, 박세현]  # 팀 공동물은 셋 다, 개인 작성물은 한 명
description: <언제 읽어야 하는가 + 무엇이 들어있는가 — imperative, pushy>
---
```

### 12.2 mode 의미

| mode | 의미 | 검증 게이트 |
|---|---|---|
| `committed` | 코드와 정합돼야 함 | `/ship`, code-reviewer, qa-validator 대상 |
| `aspirational` | 목표/희망 상태 | 검증 외. **반드시 `target_milestone` 필요** |
| `reference` | 정보 카탈로그·온보딩 | 검증 외 |
| `log` | append-only 시간 기록 | 검증 외 |

### 12.3 description 작성 규칙 (AI-friendly)

- imperative + "When to read" 트리거. 예: "*다음 중 하나라도 손대기 전 읽어라 — A, B, C*"
- "pushy" 권장 — undertrigger 방지. AI 가 의심 시 펴게 한다.
- 한 줄. 길어지면 본문에서 풀어라.

### 12.4 owners 컨벤션

- 팀 공동 운영물: `[송준서, 이용찬, 박세현]` 셋 다.
- 개인 작성물: 작성자 한 명.
- 책임 분담이 있으면 첫 번째가 primary.

---
