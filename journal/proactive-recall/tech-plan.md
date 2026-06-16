---
level: 3
mode: design
status: draft
last_verified: 2026-06-16
confidence: 0.8
owners: [송준서]
title: 능동 회수 알림 — 테크니컬 구현 플랜 (선결·단계·검증)
description: 능동 회수 알림(트랙 A/B/C)의 구현 순서·선결 의존성·검증 기준. schema.md(2테이블+DSL)·notification-agent.md(정책)·ux-ui.md(화면)를 코드로 내릴 때의 단계 분할. P1 마이그레이션 → P2 LLM 플래너(hook) → P3 cron 워커+가드 → P4 발송 빌더 → P5 반응 수집 → P6 iOS landing+응답 (A/B) → P7–P9 트랙 C(후보 생성·게이트+민감 필터·발송 합류). 진짜 별도 트랙(채팅 reminder)은 §8 — EventKit 양방향 미러는 안 함(2026-06-16). 구현 착수 전 읽어라. 정합 폭포(DOMAIN_DESIGN·CHANGELOG)는 구현 시점에.
---

# 능동 회수 알림 — 테크니컬 구현 플랜 (2026-06-16)

> `schema.md`(데이터) + `notification-agent.md`(정책) + `ux-ui.md`(화면)를 코드로 내리는 순서. **트랙 A/B/C 전체** (A/B=P1–P6, C=P7–P9). **2026-06-16 구현 완료** (A/B·C 모두 — make 406 passed + iOS tuist build/test).

---

## 0. 범위

- **트랙 A/B/C 모두 범위.** A(지식 spaced)·B(마감 역산)는 시각 트리거 → `notification_plan` 경유(P1–P6). C(관련·맥락 회수)는 이벤트 트리거 → plan 없이 `notification_outbox` 직행(`kind=recall`, P7–P9, §8). 생성 경로만 다를 뿐 같은 발송 파이프라인.
- **민감 캡처는 트랙 C의 인질이 아니다.** 스크린샷 회수의 민감 노출은 `sensitivity_level` 도메인 전체 구현을 기다리지 않고, 회수 후보 생성/발송 시점의 **필터**(민감 항목 후보 제외·본문 마스킹·channel allowlist)로 국소 처리(P8).
- **안 함(2026-06-16 결정)**: EventKit 양방향 미러 동기화 — 앱↔시스템 캘린더 생명주기 미러는 비범위(일회성 등록과 다름, §8).
- **제외(진짜 별도 트랙 §8)**: 채팅 reminder 승격.

## 1. 선결 의존성

- ✅ 백엔드 인프라 대부분 존재(`APNsClient`·`PushTokenRepository`·outbox 패턴·lifespan worker). 새 인프라 의존성은 없음.
- `entities (owner_id, kind, value)` 인덱스는 트랙 C 후보 생성(P7)에 쓴다 — A/B(P1–P6) 단계엔 불필요, 트랙 C 착수 시 추가.
- **민감 스크린샷은 `sensitivity_level` 구현의 인질이 아니다.** 트랙 C가 스크린샷을 회수해도 민감 노출은 회수 후보/발송 시점 필터(P8: 후보 제외·본문 마스킹·channel allowlist)로 처리 — 도메인 전체 구현을 선결로 두지 않는다. 트랙 A/B는 소스가 마감·일정·지식이라 이 가드 영향이 더 적다.
- **전제: 단일 KST 타임존**(codex-1). 모든 시각 판정은 owner KST local date 기준.

## 2. 구현 단계

```
P1  스키마 + 마이그레이션        → 검증: alembic upgrade/downgrade 왕복, 2테이블 생성
P2  LLM 플래너 (hook produces)   → 검증: 저장/분석 후 notification_plan 1 row, stages Pydantic 통과
P3  cron 워커 + 하드 가드         → 검증: active plan → 다음 occurrence → outbox materialize, 가드 skip 동작
P4  발송 빌더 (SendRecallNotification) → 검증: fire_at 도달분 클레임 → APNs 발송(dry-run 먼저)
P5  반응 수집 엔드포인트          → 검증: opened/dismissed 보고 → outbox 컬럼 갱신
P6  iOS landing + proposal 응답   → 검증: 알림 탭 → kind별 상세 섹션, 응답 → lifecycle/학습 반영
─ 트랙 C (A/B 발송 파이프라인 P4–P6 재사용) ─
P7  회수 후보 생성                 → 검증: recall_candidates ANN/dedup → 적격 후보 목록
P8  발송 적격 게이트 + 민감 필터    → 검증: 민감 항목 후보 제외/본문 마스킹, 점수 임계 skip
P9  발송 합류(outbox 직행)         → 검증: kind=recall outbox(plan_id NULL) → P4–P6 경로 재사용
```

## 3. P1 — 스키마 / 마이그레이션

- Alembic 신규 revision(현재 max 0022 → 0023). `notification_plan` + `notification_outbox` 2테이블(`schema.md` §1–2).
- 컨벤션: plan PK=UUID(`PgUUIDColumn`), outbox PK=BigInteger+event_id, status=String(16), DateTime(tz). upgrade/downgrade 대칭.
- `stages` Pydantic 모델(`dsl_version` 검증, anchor closed enum) — 삽입 전 검증.

## 4. P2 — 알림 설계 Agent (메인 Agent 판정 → tool loop)

- **메인 분석 Agent**(`AgentOrchestrator`)가 저장·임베딩 후 `needs_notification` 판정 → **알림 필요 기록만** 알림 설계 Agent 호출(best-effort 격리, 실패해도 분석 롤백 안 함).
- **알림 설계 Agent = `AgentOrchestrator` 패턴 + notification tools** (단일 호출 아님, `notification-agent.md` §2.2).
  - **선결**: notification tools 정의·등록 — `get_scheduled(date)`=outbox 조회, `update_notification`/`create*`=plan·outbox 작성. `Tool` 베이스 + `ToolName` enum(기존 `tools.py`/`registry.py` 패턴).
- 입력 맥락: 최근10 / 유사10(임베딩) / 예정10 / 과거10 + 활동 히스토그램. 강한 규칙 프롬프트(overfit 예시 금지, 기준+why).
- 출력: `notification_plan`(plan_kind + stages). 무게: `todo`=규칙 / `schedule`=LLM.
- **생성 eligibility (codex-3)**: 알림 가치 있는 신규/변경 intent만. 대량 import/재분석은 dry-run/선별로 plan 폭증 방지. `next_eligible_at` 세팅.
- 임베딩/예약 타이밍 2버전(planner §6) 선택은 여기서(메인 Agent가 needs_notification 판정 = 세심한 버전에 가까움).

## 5. P3 — cron 워커 + 가드

- `main.py` lifespan에 경량 cron worker 추가(기존 `MochiItemWorker` 패턴, `run_forever` + 폴링).
- 루프: `next_eligible_at` 도달 plan 스캔 → 다음 occurrence 계산(spaced는 **반응** 기준, `MAX(sent_at)` 아님) → 하드 가드(`notification-agent.md` §4) → outbox lazy materialize.
- **skip 재배치 (codex-4)**: cap/night/yielded로 skip된 occurrence는 `deferred` + `next_retry_at`(재평가 가능). `stale/dismissed/superseded/no_valid_token`만 terminal. D-1 마감이 cap에 영구 소실되지 않게 — 단 `expires_at` 전까지만 재배치.
- **불변식**(`schema.md` §4): sender 클레임은 `JOIN plan ON status='active'`, supersede 트랜잭션에서 기존 pending skip, owner_id 복사, cooldown은 `source_intent_id` 기준, cap은 per-owner advisory lock, 모든 날짜 판정은 KST local date.

## 6. P4–P5 — 발송 + 반응

- **P4**: `SendRecallNotification` use case(`SendAnalysisNotification` 형제). payload `mochiItemID`+`sourceIntentID`+`routeType`+`recallEventID`+`kind`. `HttpxAPNsClient`·`PushTokenRepository` 재사용. **dry-run 모드 먼저**(발송 0으로 threshold 튜닝). **APNs 응답 분류 (codex-5)**: 410/BadDeviceToken→토큰 무효화+terminal, 5xx/timeout→backoff retry.
- **P5**: 반응 수집 엔드포인트(`opened(recallEventID)` / `dismissed`) → `outbox.opened_at`/`dismissed_at`. presentation router 신규. **인증 owner `(event_id, owner_id)` 조회 + `status='sent'`만 + first-write-wins 멱등 (codex-6)**.

## 7. P6 — iOS

- 알림 탭 → 기존 `openDetailFromNotification` 재사용 + `routeType`/`kind`별 상세 섹션 분기(`ux-ui.md` §4–5). **로컬 역매핑 실패 시 `recallEventID`로 서버 landing fetch fallback (codex-2)** — 빈 상세 금지.
- proposal 카드 응답(`ProposalCardView`) → 서버 반응 보고 + lifecycle. **primary=목적수행, 피드백=보조** (codex-8). 액션 scope 1:1(codex-7).
- 홈 회수 "한 칸"(`HomeFeature` 새 섹션, `ux-ui.md` §6).
- **접근성 (codex-9)**: 이유 칩 VoiceOver 라벨, 홈 preview Dynamic Type 2줄, 상세 액션 세로 스택 전환(`ux-ui.md` §5a).

## 8. 트랙 C (구현 완료, P7–P9) + 안 함 / 별도 트랙

**트랙 C 회수 본체 — 구현 완료 (2026-06-16, P7–P9).** 범위 내 트랙 C는 **1:1 단건 맥락 회수**(임베딩 ANN)다 — 주제 묶음(entity bundling)은 **비범위**(콜드스타트 후속, `journal/2026-06-15-track-c-bundling-validation.md`).
- **P7 후보 생성** (`notifications/application/generate_recall_candidates.py` + `infrastructure/recall_candidate_repository.py`) — 새 item(B) 분석 done 후 worker 가 best-effort 로 `_generate_recall_candidates` 호출(P2 플래너 형제, 독립 세션·격리). `recall_context_provider._similar` 와 동일 pgvector cosine ANN 으로 유사 과거 기록 조회 → 최고점(A)을 회수 앵커(`source_item_id=A`). **`entities (owner_id, kind, value)` 인덱스는 불필요** — 1:1 임베딩 ANN 은 entity 집계를 안 쓴다(인덱스 선행은 entity 묶음=비범위용이었음, 이 절이 정정).
- **P8 발송 적격 게이트** — 점수 임계(`recall_candidate_min_score`)·재스팸 dedup(`recent_recall_exists`)·dismiss cooldown(`source_intent_id` 기준, `check_dismiss_cooldown` 재사용)·generic copy 금지(근거 명사 확보 시만). 야간/cap/트랙B 양보는 `recall_guards` 재사용하되 **생성 시점에 fire_at 미루기**로 표현(트랙 C 는 plan 없어 worker deferred 회생을 못 타므로 pending 의 future fire_at 으로). **민감 필터는 넣지 않는다(2026-06-16 결정)** — 회수 본문은 원본 OCR 이 아니라 추상화된 LLM 요약이라 A/B 와 동일한 ungated 논리(`PRIVACY_SENSITIVE_CAPTURE.md` §9). no-op pluggable stub 도 speculative 라 두지 않음(Simplicity First). `sensitivity_level` 실구현 시 회수 use case 에 발송 게이트로 끼운다.
- **P9 발송 합류** — plan 없이 `notification_outbox` 직행(`kind=recall, plan_id NULL`). 발송 패스 클레임이 이미 `plan_id IS NULL OR active plan` 이라 recall 행을 클레임·발송(worker 수정 불필요였음). 발송·반응·landing 은 A/B 파이프라인(P4–P6) 재사용. 본문 = 결정적 템플릿(근거 명사, 비단정 "다시 볼까요?" 톤 — 비교/의도단정 아님).
- **피드/landing 합류** — `GetRecallFeed` 가 active spaced(A) + 최근 recall outbox(C) 를 합류, `related` 를 landing/feed 시점 ANN 재실행으로 채움(`RelatedItem{item_id,title,oneline}` 객체). iOS 관련 카드 탭 → 항목 상세.
- 검증: `make lint/typecheck/test`(406 passed) + iOS `tuist build/test`. dry-run 기본 True(threshold 튜닝 후 flip).

**안 함 (2026-06-16 결정):**
- **EventKit 양방향 미러 동기화** — 앱↔시스템 캘린더 생명주기 미러는 비범위(복잡도 대비 가치 낮음). 일회성 등록(proposal 확정/캘린더 추가의 EKEvent/EKReminder)은 별개로 유지. ※ known-drift "캘린더 탭 반영"(날짜·메모 확정이 캘린더 탭에 안 보임)은 **앱 내부 데이터 반영 버그**(EventKit 미러와 무관, 별개)로 그쪽에서 처리.

**진짜 별도 트랙:**
- **채팅 reminder 서버 승격** — 클라 레벨 충분, 나중.

## 9. 정합 폭포 (구현 착수 시)

- `docs/DOMAIN_DESIGN.md` — notification_plan/outbox 신규 테이블 + intent lifecycle 연동(완료→cancelled).
- `docs/CHANGELOG.md` — 구현 단계마다 한 줄.
- committed `docs/PROPOSAL_PROACTIVE_RECALL.md` §5/§7(푸시 정책) — 재프레이밍(push가 미션상 정합, "누르고 싶은 질"로 통제).
- `mochi-backend/openapi.json` — 반응 수집·푸시토큰 외 신규 엔드포인트(P5).

## 10. 출처

- 흡수: `journal/2026-06-15-proactive-recall-tech-design.md`(인프라 사실·구현 단계·개발 디테일).
- 결정: schema.md / notification-agent.md / ux-ui.md (본 폴더).
