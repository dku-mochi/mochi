---
level: 3
mode: design
status: draft
last_verified: 2026-06-16
confidence: 0.85
owners: [송준서]
title: 능동 회수 알림 — 정책 및 Agent 설계 (플래너 + 가드 + 발송)
description: 능동 회수 알림의 정책·동작 설계. "무엇을/언제/어떻게 보내나"(정본 planner 06-16 정제) + "누가 결정하나"(hook produces LLM 플래너 / cron decides 규칙가드) + "어떻게 발송하나"(서버 APNs push 단일, EventKit 무관). 보낸다/참는다 게이트("애매하면 안 보낸다"), 하드 가드, 신호·학습, 가장 큰 위험(저품질=정체성)이 본문. 알림 플래너·cron 워커·발송 빌더를 구현하기 전 읽어라. 데이터 모델은 schema.md, 화면 landing은 ux-ui.md, 구현 순서는 tech-plan.md.
---

# 능동 회수 알림 — 정책 및 Agent 설계 (2026-06-16)

> 정본 `2026-06-16-…-notification-planner`(언제/어떻게) 정제 + 발송 경로 결정. **데이터 모델은 `schema.md`, 화면 착지는 `ux-ui.md`, 구현은 `tech-plan.md`.** 미구현.

---

## 0. 한눈에

- **알림 = 알림 설계 Agent(tool-calling loop, 제안) + 규칙 집행가드(강제) 하이브리드.** "LLM이 다"도 "규칙이 다"도 아님.
- **메인 Agent → 알림 설계 Agent → cron** — 메인 분석 Agent가 "알림 필요"를 판정하면, 알림 설계 Agent(loop)가 tool로 계획을 짜고, cron이 발송 가드를 건다.
- **발송 = 서버 APNs push 단일.** EventKit 무관.
- **원칙: "애매하면 안 보낸다."** 가장 큰 위험은 스팸(빈도)이 아니라 저품질("모찌가 헛소리한다")로 인한 **정체성 손상**.

---

## 1. 무엇을 · 언제 (정본 planner §5)

| 축 | 누가 정하나 | 근거 |
|---|---|---|
| **무게**(알림 강도) | `todo`=규칙(D-1+days_until) / `schedule`=LLM 판정(heavy면 다단) / `importance`=보조 타이브레이커 | importance가 무게와 직교(실험①) |
| **시각**(몇 시) | 개인 활동 히스토그램(없으면 10–20시) | 추출: **6–10시 죽은시간** 회피 |
| **계획**(시점들·주기) | LLM 플래너 (마감없는 건 주기넛지, 마감은 상대시간) | 실험②③ |

**계획 형(`kind`)**: 지금 plan으로 만드는 건 3형 — `deadline`(마감 역산 다단) / `nudge`(마감없는 todo 주기넛지) / `spaced`(지식 정착). `recall`(맥락 회수)은 트랙 C에서 plan 없이 outbox로 직행(후보 생성/게이트 본체는 `tech-plan.md` §8 P7–P9, 범위 내). DSL·매핑은 `schema.md` §3.

**생성 eligibility (codex-3)**: hook은 **알림 가치 있는 신규/변경 intent만** plan 생성(과거·완료·추출실패 제외). 대량 import/재분석이 intent마다 plan을 찍지 않게 — cron은 `next_eligible_at` 도달분만 스캔.

## 2. 파이프라인 — 메인 Agent → 알림 설계 Agent → cron/worker

```
스크린샷 → 메인 분석 Agent (기존 AgentOrchestrator)
            : 분류 · mochi_item 저장 · 임베딩 · "알림 필요" 판정(needs_notification)
        → 알림 설계 Agent (신규, tool-calling loop — 알림 필요 기록만)
            : 강한 규칙 프롬프트 + 맥락 주입 + tool로 예약조회·수정·생성 → notification_plan
        → cron/worker
            : fire_at 도달분 발송 + 하드 가드(§4) → APNs
```

### 2.1 메인 분석 Agent
기존 `AgentOrchestrator`. 저장·임베딩 후 **"이 기록이 알림 가치 있나"를 판정**(needs_notification). 알림 필요로 명시된 기록만 알림 설계 Agent로 넘긴다.

### 2.2 알림 설계 Agent (tool-calling loop) ★
`AgentOrchestrator` 패턴 재사용. **단일 호출이 아니라 tool loop** — 예약 알림을 조회해 묶고, 기존 알림을 수정해 난사를 줄인 뒤 계획을 확정한다.

**맥락 주입(입력):** 현재 시각 / 최근 저장 기록 10 / **유사 저장 기록 10(임베딩)** / 예정 알림 10 / 과거 알림 10(클릭 *시각*만, **안 누름 ≠ negative**).

**tools:**
- `get_scheduled(date)` — 그날 예약 알림 조회. **일반 시간대 발송이면 필수 호출**(묶기·중복방지).
- `update_notification(id, entity)` — 기존 알림에 묶거나 시각 조율.
- `create_notification` / `create_recurring` — plan 생성(구조화 JSON 추출 가능, tool 왕복 없이도).

**강한 규칙(프롬프트, 기준+why — overfit 예시 금지):** 난사 금지가 최상위 / 시각=활동 히스토그램(없으면 10–20시, 마감 임박 예외) / 날짜=24h 내 긴급은 cap 무시·전날 무조건 1회·50일내 D-3/7/15/30·50일+ 10일 간격·중대+준비 긴 건 자주·하루 cap 3(되도록 2)·묶기 최우선.

> 맥락주입의 가치 = 비결정성 감소가 아니라 **"조율"**(죽은시간 회피·난사↓·묶기). lab `planner.py`는 tool 왕복을 맥락주입으로 **시뮬레이션**해 계획 품질만 검증 — 프로덕션은 실제 tool loop.

### 2.3 cron / worker (발송)
active plan 스캔 → "다음 occurrence" 계산(spaced는 **반응** 기준) → 하드 가드(§4) → `notification_outbox` lazy materialize → APNs 발송. 기존 outbox 폴링 패턴(`main.py` lifespan worker)을 시간축으로 확장한 경량 cron(분산 스케줄러 불필요).

## 3. 보낸다 / 참는다 게이트 ("애매하면 안 보낸다")

> **2026-06-17 갱신(트랙 C):** 트랙 C 의 보낸다/참는다는 점수 임계가 아니라 **LLM 선별 게이트**가 판정한다(코사인=후보 추림 바닥값). 결정적 가드(cap·야간·dismiss·dedup·owner 쿨다운·advisory lock)는 그대로 백스톱으로 남는다. 정본 `track-c-llm-gate-decision.md`. (A/B 는 본 절 그대로.)

발송은 화이트리스트가 아니라 **게이트 통과 + 애매하면 보류**.

**보낸다 (모두 충족):** push 권한 / 하루 cap 안 / theme cooldown 지남 / candidate age 적정 / 점수 임계 이상 / **preview에 구체 명사 1–2개**(generic 금지) / **landing 준비됨** / 같은 날 트랙 B 충돌 시 양보 안 함.

**참는다 (하나라도):** "저장한 거 다시 보세요" 수준 generic copy / 후보 약함 / 최근 직접 열어본 item / 이전에 dismiss됨 / 근거 item 약함 / landing 미준비.

> **landing readiness** = "누르면 정리된 화면이 준비돼 있어야 발송"(체류시간 직결). 알림과 landing은 한 쌍.

## 4. 하드 가드 (cron, 규칙)

하루 cap(예: 1건/주 3건) · 야간 무음 · **dismiss 영구 존중** · theme 7–14일 cooldown · **묶기**(같은 날) · **중요도 우선**(묶기·최소화가 중요한 걸 깎지 않게) · **트랙 B 충돌 양보**(같은 날 마감 푸시 있으면 회수는 후순위) · **stale/완료 재평가**.

## 5. 발송 경로 (결정 #3)

- **서버 APNs push 단일.** `SendRecallNotification` use case 신규(`SendAnalysisNotification` 형제), 기존 `HttpxAPNsClient`·`PushTokenRepository` 재사용. cron 워커가 진짜 신규(현재 시각 발송 0).
- **payload**: `mochiItemID`(기존 deep-link 재사용) + `sourceIntentID` + `routeType`(detail/list) + `recallEventID`(=`outbox.event_id`, 반응 추적) + `kind`(빌더 분기). `collapse_id`는 기존대로.
- **landing readiness 정의 강화 (codex-2)**: "서버에 item 있음"이 아니라 **"클라가 열 수 있는 route 있음"**. iOS 로컬 역매핑 실패 시 `recallEventID`로 **서버 landing payload fetch fallback**(빈 상세로 떨어지면 신뢰가 가장 빠르게 깨진다).
- **APNs 실패 분류 (codex-5)**: `410 Unregistered`/`BadDeviceToken` = 영구 → 토큰 무효화 + `dead_letter`/`skip_reason=no_valid_token`(재시도 안 함). `5xx`/timeout = transient → backoff 재시도.
- **반응 수집 신규 1개**: 앱이 탭 시 `opened(recallEventID)` 서버 보고 → `outbox.opened_at`. **인증 owner 기준 `(event_id, owner_id)` 조회 + `status='sent'`만 갱신 + first-write-wins 멱등 (codex-6)** — 남의 반응 조작·중복 탭으로 학습 꼬임 방지.

**사용자 도달 표면 #2 — EventKit 캘린더 미러**: **안 하기로 결정**(2026-06-16). 능동 회수는 EventKit에 따로 등록하지 않고, 앱↔시스템 캘린더 **양방향 동기화·생명주기 미러는 비범위**(복잡도 대비 가치 낮음). 기존 proposal 확정/캘린더 추가의 **일회성 EventKit 등록**(EKEvent/EKReminder 생성)은 별개로 그대로 살아있다 — '미러'(지속 양방향 동기화)와 '등록'(일회성)은 다르다.

**채팅 reminder(로컬 알림)**: 나중(클라 레벨 충분, 능동 회수 트랙과 분리).

## 6. 신호 / 학습

- **클릭 = 양성만.** "안 누름 ≠ 부정"(알림 보고 바로 행동한 경우 많음, 클릭 0을 페널티로 쓰지 않음).
- **부정 = 명시적 dismiss + lifecycle 완료(archived).**
- `item_access_log`의 "직접 열어봄"이 클릭보다 신뢰도 높은 양성.
- 반응 → 멘트·시각·간격 학습(반응 로그 콜드스타트라 notification 가동 후).

## 7. 가장 큰 위험과 통제

저품질("모찌가 헛소리한다") 한 번이면 신뢰가 깨진다. **dry-run 모드**(발송 0으로 튜닝) · 서버 **kill switch** · 발송 로그(`outbox`의 reason/score/copy/sent/opened/dismissed) · generic copy 금지 · landing 없는 푸시 금지 · LLM copy는 근거 item의 증거 있는 말만.

## 8. 미결 / 후속

- **임베딩/예약 타이밍 2버전**(planner §6) — 쉬운(분석 후 임베딩→push 에이전트) vs 세심한(생성시점 예약 결정→push 에이전트 분석). 구현 착수 시.
- **활동 히스토그램 산출** — `time_hint` 채우는 개인 활동시간 학습.
- **judge 채점 / 비결정성 재측정** — lab 후속(planner §7).
- **중요도 우선 가드 정밀화** — G5 기말고사 희생 방지(planner §7-2).
- **트랙 C 회수 본체 · 민감 캡처 필터** — A/B 다음 단계(범위 내), `tech-plan.md` §8 P7–P9.

## 9. 출처

- 정본: `journal/2026-06-16-proactive-recall-notification-planner.md` §3–5.
- 흡수: `journal/2026-06-15-proactive-recall-notification-decision.md`(보낸다/참는다 게이트·위험 통제) — 정본 보강, 충돌 없음.
- 결정: #3 발송 경로(서버 push 단일, EventKit 무관, 채팅 나중) — 2026-06-16 세션.
- 인프라: 백엔드 조사(`SendAnalysisNotification` payload·`apns_client.send(...collapse_id)`·Hexagonal use case·cron 발송 부재).
