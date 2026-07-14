---
level: 3
mode: design
status: draft
last_verified: 2026-06-16
confidence: 0.85
owners: [송준서]
title: 능동 회수 알림 — 발송 스키마 (notification_plan + notification_outbox + stages DSL)
description: 능동 회수 알림의 발송 데이터 모델 확정 골격. 정본 2저널(2026-06-16-proactive-recall-notification-planner / 2026-06-15-proactive-recall-ux-decision) + codex 적대검증(10이슈 중 7 ACCEPT·3 PARTIAL, 과설계 3건 거부)을 반영한 2테이블 + JSONB DSL. "생성 분리(notification_plan) / 발송 통합(notification_outbox)" 원칙. 알림 발송 테이블·마이그레이션·cron 워커·발송 빌더를 구현하기 전 읽어라. 미구현 — 설계 골격. 트랙 A/B/C 모두 범위(A/B=plan 경유, C=plan 없이 outbox 직행). 민감 캡처는 트랙 C 발송 시점 필터로 처리(sensitivity 전체 구현 비의존). 출처·왜는 §5·§8.
---

# 능동 회수 알림 — 발송 스키마 (2026-06-16)

> **정본** = `2026-06-16-…-notification-planner`(알림 "언제/어떻게") + `2026-06-15-…-ux-decision`(화면). 본 문서는 그 둘에서 비어 있던 **"알림 plan을 어디에 저장하나"**를 확정한 산출물 + codex 적대검증 반영. **미구현 — 설계 골격.** 트랙 A(지식 spaced)·B(마감 역산)·C(관련·맥락 회수) 모두 범위. A/B는 plan 경유(시각 트리거), C는 plan 없이 `notification_outbox` 직행(이벤트 트리거, `kind=recall`). 민감 캡처 게이트는 트랙 C 발송 시점 필터(후보 제외·본문 마스킹)로 처리 — `sensitivity_level` 전체 구현 비의존.

---

## 0. 한눈에

- **생성 분리 / 발송 통합.** 트랙 A/B는 시각 트리거(미리 박음), 트랙 C는 이벤트 트리거(이벤트가 부름)라 성격이 반대 → 생성 테이블은 트랙별, 발송 큐는 하나.
- **알림 설계 Agent(tool loop) → `notification_plan`** (tool로 예약조회·묶기 후 계획 전체를 `stages`에 = 1 row). 메인 Agent가 "알림 필요" 판정한 기록만. 상세 `notification-agent.md` §2.
- **cron decides → `notification_outbox`** (다음 1발을 lazy materialize, 규칙 가드, APNs 발송, 반응 추적).
- 기존 `mochi_item_outbox` 패턴(BigInteger PK, `FOR UPDATE SKIP LOCKED`, 5초 폴링, lifespan asyncio worker)을 시간축으로 확장.

```
hook produces  → notification_plan 1 row (stages = 계획 전체)
cron decides   → ① active plan 스캔 → "지금 발송할 다음 occurrence" 계산
                 ② 규칙 가드(cap·야간·dismiss·중요도우선·묶기·트랙B양보)
                 ③ 통과분만 notification_outbox 에 lazy materialize
                 ④ fire_at 도달분 클레임 → apns_client.send → sent/opened/dismissed 추적
                 ⑤ 반응 보고 plan 재평가(필요시 superseded_by 교체)
```

---

## 1. `notification_plan` (계획)

```text
notification_plan
  id                UUID PK (uuid4)
  owner_id          UUID FK users(id) CASCADE, index
  source_intent_id  UUID FK intent_instances(id) CASCADE, index
  source_item_id    UUID FK mochi_items(id) CASCADE, nullable      -- 조회/딥링크 편의
  plan_kind         String(16)            -- deadline_backoff | recurring_nudge | spaced
  dsl_version       String(16)            -- stages DSL 버전(마이그레이션 안전)
  stages            JSONB                 -- §3 DSL (계획 전체)
  status            String(16) 'active'   index  -- active | superseded | done | cancelled
  cancelled_at      DateTime(tz) nullable -- 영구 dismiss 시각
  cancel_reason     String(32) nullable   -- user_dismiss | intent_archived | superseded
  generated_model   String(64)            -- 재현성(어느 LLM/프롬프트가 짰나)
  next_eligible_at  DateTime(tz) nullable -- cron이 "지금 평가할 plan"만 스캔(전체 active 스캔 회피)
  superseded_by     UUID nullable FK notification_plan(id)  -- 재평가 교체 포인터
  created_at        DateTime(tz)  default now()
  updated_at        DateTime(tz)  default now()

  INDEX (owner_id, status)
  INDEX (status, next_eligible_at)         -- 대량 import/재분석 시 plan 폭증 대비 cron 스캔(codex-3)
```

- **생성 eligibility (codex-3)**: 분석 후단 hook은 **알림 가치 있는 신규/변경 intent만** plan 생성(과거·완료·추출실패 제외 — planner §3 전처리 가드). 대량 import/재분석 시 intent마다 plan을 만들지 않는다. cron은 `next_eligible_at <= now`인 plan만 스캔.

- `status` 의미: `done`=모든 stage 발송 완료 / `superseded`=재평가로 새 plan 대체 / `cancelled`=영구 dismiss·intent archived.
- **anchor 값은 캐시하지 않는다.** `stages`가 심볼(`deadline`)로 참조 → cron이 발송 때 `intent_instances.payload`를 최신 조회. 사용자가 마감을 수정하면 자동 추종.
- intent_instances는 soft-delete(`lifecycle_kind=archived`) 전제라 CASCADE가 실삭제를 거의 안 탐. 완료는 `cancel_reason=intent_archived`로 명시 종료.

## 2. `notification_outbox` (발송 + 반응)

```text
notification_outbox
  id              BigInteger PK autoincrement      -- mochi_item_outbox 패턴(클레임 순서)
  event_id        UUID (uuid4)                     -- 멱등/추적
  plan_id         UUID FK notification_plan(id) SET NULL, nullable  -- 삭제돼도 발송 이력 보존 / 트랙C 직행 NULL
  stage_seq       Integer nullable                 -- plan stages 의 몇 번째 단계
  occurrence_seq  Integer nullable                 -- 그 단계의 N번째 발생(반복/spaced identity)
  owner_id        UUID, index                      -- 삽입 시 plan.owner_id 복사(불변식)
  source_item_id    UUID FK mochi_items(id) SET NULL, nullable      -- 딥링크
  source_intent_id  UUID FK intent_instances(id) SET NULL, nullable -- 딥링크 + cooldown 조회 키
  kind            String(16), index   -- deadline | nudge | spaced | recall (push 빌더 분기)
  fire_at         DateTime(tz), index -- 발송 예정(=배달 시각, identity 아님)
  expires_at      DateTime(tz) nullable  -- 지나서 미발송이면 stale skip(마감 지난 알림 방지)
  title           String
  body            String                 -- 문구 snapshot(생성시점 고정 — plan 바뀌어도 보낸 건 불변)
  collapse_id     String nullable        -- apns_client.send 가 이미 지원
  status          String(16) 'pending', index  -- pending | sent | deferred | skipped | dead_letter
  skip_reason     String nullable        -- [deferred 재시도] cap | night | yielded_to_b  /  [terminal] superseded | cancelled | stale | dismissed_cooldown | bundled | no_valid_token | preference_off(전역 회수 선호 off, users.notify_recall_enabled=false, 0028)  (cancelled=plan 취소: intent_archived·user stop. superseded=재평가 교체와 구별)
  next_retry_at   DateTime(tz) nullable  -- deferred occurrence 재평가 시각(D-1이 cap에 영구 소실 안 되게, codex-4)
  attempts        Integer 0
  locked_until    DateTime(tz) nullable
  last_error      String nullable
  sent_at         DateTime(tz) nullable
  opened_at       DateTime(tz) nullable   -- 클릭=양성(정본 신호)
  dismissed_at    DateTime(tz) nullable   -- 명시적 부정
  created_at      DateTime(tz)  default now()
  updated_at      DateTime(tz)  default now()

  INDEX  (status, fire_at)                          -- cron 클레임 핵심
  UNIQUE (plan_id, stage_seq, occurrence_seq) WHERE plan_id IS NOT NULL  -- fire_at은 가드로 바뀌니 identity 불가
```

- **`recall_log` 흡수**: `sent_at`/`opened_at`/`dismissed_at` 이 이벤트 로그 역할. outbox는 "발송 확정분"이라 candidate와 안 섞임 → 별도 로그 테이블 불필요.
- cap·cooldown·theme suppress 는 전부 이 테이블 쿼리로 해결(별도 suppression 테이블 X).

---

## 3. `stages` JSONB DSL

trigger 3종(relative / recurring / spaced) + 시각·문구·무게. LLM 플래너가 생성하므로 삽입 전 **Pydantic 검증 필수**(malformed/adversarial 방지).

```jsonc
{
  "dsl_version": "1",                // plan.dsl_version 과 일치
  "seq": 1,                          // outbox.stage_seq 와 매칭
  "trigger": {
    "type": "relative",              // relative | recurring | spaced
    // [relative] 고정 기준점 대비 오프셋
    "anchor": "event_date",          // closed enum: { deadline, event_date, saved_at } — plan_kind 와 정합 강제
    "offset": "-P7D",                // ISO-8601 duration: -P15D, -PT2H, +P3D
    // [recurring] 마감 없는 주기 넛지
    "interval_days": 3,
    "max_occurrences": 2,
    "until_anchor": null,            // deadline 등에서 종료, null=무한
    // [spaced] 지식 정착(반응 시 다음 칸 전진)
    "schedule_days": [3, 7, 18, 45]
  },
  "time_hint": "19:00",              // 활동 히스토그램 반영. null → cron 기본 윈도우(10~20시, 6~10시 회피)
  "content_template": "{title} 마감 {offset_human} 남았어요",  // 증거 명사 슬롯
  "importance_hint": "heavy"         // heavy | light | null → 중요도 우선 가드 입력
}
```

**3패턴이 모두 표현됨** (recall은 plan 없이 트랙 C에서 outbox로 직행):

| 케이스 | plan_kind | stages 요지 |
|---|---|---|
| 토익 시험(heavy) | `deadline_backoff` | anchor=event_date, `-P15D / -P7D / -P3D / -P1D` 4 stage |
| 과제(light, 상대시간) | `deadline_backoff` | anchor=deadline, `-PT2H` 1 stage |
| 엄마 전화(마감없음) | `recurring_nudge` | `interval_days:3, max_occurrences:2` |
| RAG 자료(지식) | `spaced` | `schedule_days:[3,7,18,45]` (반응으로 전진) |

**`plan_kind`(3종) ↔ `outbox.kind`(4종) 매핑 (doc-guardian M-2):**

| plan_kind | → outbox.kind | 비고 |
|---|---|---|
| `deadline_backoff` | `deadline` | 마감 역산 다단 |
| `recurring_nudge` | `nudge` | 마감없는 주기 |
| `spaced` | `spaced` | 지식 정착 |
| (plan 없음) | `recall` | 트랙 C 직행(`plan_id NULL`) — 후보 생성/게이트는 `tech-plan.md` §8(P7–P9, 범위 내) |

> **타임존 (codex-1)**: MVP는 **단일 KST 전제**. cap·야간·상대시간 판정은 **owner의 KST local date 기준**으로 계산. 글로벌 확장 시 `plan.timezone`(IANA) + `outbox.fire_local_date`를 추가(지금은 컬럼 보류 — 과설계 회피).

**lazy 동작**: cron이 active plan을 스캔 → trigger + 마지막 occurrence의 **반응**(spaced는 sent_at 아님)으로 "다음 occurrence" 계산 → 가드 통과분만 outbox 1 row materialize. `recurring`/`spaced`의 다음 발은 직전 반응을 보고 계산되므로 미리 못 박는 게 정당.

---

## 4. 스키마가 아닌 불변식 (쿼리/로직 — 구현 시 강제)

codex 검증으로 도출. 스키마는 이미 받치고, 아래는 코드 레벨 규약:

1. **spaced 전진 = 반응 기준.** 다음 칸은 마지막 occurrence의 `opened_at`/`dismissed_at` 으로 판단(`MAX(sent_at)` 아님). dismiss=소멸, 양성=다음 간격. **예외(2026-06-21)**: 예정 탭 veto("이번 회차만 건너뛰기")로 `skip_reason='user_veto'` 된 칸은 opened 없이도 다음 칸으로 전진하되, 전진 base 를 그 칸의 `fire_at` 으로 쓴다(opened 경로와 격리 — "다음 회차는 예정대로"). 정본 동작 `recall_occurrence.next_spaced_occurrence`, 표시·scope 는 `ux-ui.md` §4 / `DOMAIN_DESIGN.md` §5.2.
2. **plan 교체 race 차단.** sender 클레임 쿼리는 `JOIN notification_plan ON status='active'` 필수. supersede 트랜잭션에서 기존 pending outbox를 `skipped(superseded)` 마킹(같은 트랜잭션).
3. **owner 일관성.** 삽입 시 `outbox.owner_id := plan.owner_id` 복사 + 테스트(composite FK는 과설계라 안 씀, §6).
4. **dismiss cooldown은 plan 경계를 넘는다.** `source_intent_id` 기준 outbox 조회로 판정(plan이 교체돼도 dismiss 이력 추종).
5. **하루 cap·중요도 우선은 per-owner 직렬화.** advisory lock으로 두 워커 동시 카운트 방지(인덱스 최적화는 규모 커질 때).

---

## 5. 정본 요구 → 필드 매핑 (왜 이 필드들인가)

| 정본 요구 | 받치는 필드 |
|---|---|
| 무게(heavy/light) → 중요도 우선 가드 | `stages[].importance_hint` |
| 다단/주기/상대시간/spaced | `stages[].trigger`(3 type) + `occurrence_seq` |
| 시각(활동 히스토그램, 6–10시 회피) | `stages[].time_hint` + cron 최종조정 |
| cap·야간·양보 미발송 사유 | `outbox.skip_reason` |
| 신호(클릭=양성/dismiss=부정/안누름≠부정) | `outbox.opened_at`/`dismissed_at` (NULL 무페널티) |
| "그만 물어봐" 영구 | `plan.status='cancelled'` + `cancelled_at`/`cancel_reason` |
| 알림 누르면 어느 상세로(딥링크) | `outbox.source_item_id`/`source_intent_id` |
| cron 지연 시 마감 지난 알림 안 보냄 | `outbox.expires_at` |
| 중복 발송 방지(가드로 fire_at 흔들려도) | `UNIQUE(plan_id, stage_seq, occurrence_seq)` |
| LLM JSONB 안전 | `dsl_version` + Pydantic 검증 |
| plan 삭제 시 발송 이력 보존 | `outbox.plan_id` SET NULL |

## 6. codex 검증에서 **거부한** 과설계 (기록)

"지금 필요 없는 일반화"라 적용 안 함 — 정본 요구가 아직 강제하지 않음:

- **composite FK `(id, owner_id)`** (#2): owner 누출은 코드버그 가정 → 삽입 불변식+테스트로 충분.
- **per-owner quota 테이블** (#8): outbox 카운트로 충분, 2테이블 원칙 유지.
- **`bundle_id`/`bundle_rank`** (#9): 진짜 묶기는 콜드스타트 후속 → 지금은 `skip_reason='bundled'` 값만.

## 7. 미결 (다음 결정)

- ✅ **발송 빌더** — 결정됨: 서버 APNs push 단일, `SendRecallNotification`(기존 형제) + payload `mochiItemID`/`recallEventID`/`kind`. 상세 `notification-agent.md` §5.
- ✅ **알림 → landing 화면 매핑** — 결정됨: 카디널리티가 화면 결정(단건→상세 직행), kind는 상세 섹션. 상세 `ux-ui.md` §4.
- **활동 히스토그램 산출 로직** — `time_hint` 채우는 개인 활동시간 학습(별도, `notification-agent.md` §8).
- **임베딩/예약 타이밍 2버전** — planner §6, 구현 착수 시 선택.
- **트랙 C 회수 본체** — recall_candidates 후보 생성/ANN/dedup + 발송 적격 게이트 → outbox 합류구. 범위 내(A/B 다음 단계), 상세 `tech-plan.md` §8(P7–P9).
- **민감 캡처 게이트** — 트랙 C 발송 적격 게이트에 포함(민감 항목 후보 제외·본문 마스킹·channel allowlist). `sensitivity_level` 전체 구현 비의존.

## 8. 출처

- 정본: `journal/2026-06-16-proactive-recall-notification-planner.md` §5(확정 설계)·§6(임베딩 타이밍) / `journal/2026-06-15-proactive-recall-ux-decision.md` §4(회수 3단)·§5(landing).
- 흡수: `journal/2026-06-15-proactive-recall-tech-design.md` §1(인프라 사실)·§7(DDL 스케치) — 본 문서가 `scheduled_recall`/`recall_candidates`/`recall_log` 3안을 plan+outbox 2테이블로 재배치.
- 검증: codex(GPT, read-only) 적대검증 10이슈 → 7 ACCEPT·3 PARTIAL, 과설계 3 거부(§6).
- 백엔드 컨벤션: PK=UUID(`PgUUIDColumn`), status=String(16), outbox=BigInteger+event_id, Alembic, `apns_client.send(...collapse_id)`, `app/main.py` lifespan worker.
