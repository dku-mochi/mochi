---
level: 3
mode: log
status: active
last_verified: 2026-06-04
confidence: 0.9
owners: [송준서]
title: intent 스키마 빅뱅 — instance 단위 lifecycle + 별도 테이블 (설계 확정 핸드오프)
description: intent 저장을 mochi_items 5컬럼 파생중복 → 별도 intent_instances 테이블 + instance 단위 lifecycle + boolean 저장으로 빅뱅 교체하는 결정. 대표(representative)·점수(applicability/confidence/threshold) 폐기. architect+codex 만장일치, 코드 0줄(설계 확정·미구현). 다음 세션이 plan 모드로 이어받을 때 읽어라 — 통합 프롬프트·가드레일 3개·미결 기본값·왜 이렇게 정했는지 근거 전부 여기.
---

# intent 스키마 빅뱅 재설계 — Handoff (2026-06-04)

> **상태: 설계 확정 · 코드 0줄 변경.** 이 세션은 *결정과 핸드오프만* 했다. 다음 세션이 plan 모드로 이어받아 구현한다 — §5 통합 프롬프트를 그대로 복붙하면 된다.
> 두 독립 리뷰(architect + codex)가 모든 축에서 합의했고 사용자 직관과도 일치한다. **재론 말고 이어서 구현하라.**

---

## 0. TL;DR (한 화면 요약)

- **무엇:** intent 저장을 `mochi_items` 5컬럼 파생중복 → **별도 `intent_instances` 테이블(1급 행)** 으로 빅뱅 교체. 점수(applicability/confidence/threshold) 폐기하고 **boolean 저장**(저장돼 있으면 곧 active). 대표(representative) 개념 폐기. lifecycle 을 item → **intent instance 단위**로.
- **왜 빅뱅:** 06-02 설계(`INTENT_REDESIGN`, applicability + threshold τ)를 06-04 실험(`FINDINGS`)이 뒤집었다 — boolean instance 방식이 intent F1 **0.809 → 0.935** 로 이김. 그 결과 `DOMAIN_DESIGN §4.4` 의 핵심 엔진(점수·threshold·argmax)이 통째로 폐기됐다.
- **저장구조 결정:** 별도 테이블(정규화). **architect + codex 만장일치.** 근거 §3.3.
- **포기한 것:** "iOS 0줄 무중단(API projection)". instance 단위 lifecycle 때문에 API 응답 구조 자체가 바뀌어 성립 불가 → iOS 단수 intent 전제를 재배선한다.
- **다음:** plan 모드로 미결 2개 닫고 → 구현 → `/goal` 로 문서·마이그레이션·lint 수렴 → (선택) dynamic workflow 로 iOS 화면 병렬검증.

---

## 1. 대화 흐름 — 어떻게 여기까지 왔는가

1. **06-02 `INTENT_REDESIGN.md` (L2, adopting):** intent 4컬럼 파생중복 문제 → flat `intents:[{intent, applicability}]` 리스트 1개 + threshold τ 로 active 판정 + `representative=argmax(applicability)`. iOS 는 API projection 으로 0줄. → `DOMAIN_DESIGN §4.4` 가 이걸 committed 타겟으로 보유(0009 예정).
2. **06-04 `FINDINGS.md` (실험):** τ/applicability 방식(`score_flat`)이 실험에서 졌다(intent F1 0.809, count acc 0.667). `intent_instances`(boolean) + `needs_review`(LLM holistic boolean) + `review_options`(미확정 후보)가 이김(F1 0.935 / 0.907). payload 는 자유 object 가 아니라 **공통 optional typed fields**(title/date/time/deadline/person/topic/url/note) 명시 필요. → §4.4 의 **핵심 엔진(점수·threshold·argmax)이 통째로 폐기**.
3. **이 세션 (06-04):**
   - 사용자가 *"대표 intent 가 폐기됐는데 왜 architect 가 대표를 다루나"* 지적. 확인 결과 **§4.4 는 저장 위계(primary/secondary)만 폐기하고, 계산 대표(`representative`) + "복수여도 UI엔 대표만"(§4.4 line 661) 은 iOS 0줄 유지를 위해 남겨둔 절충**이었다. → **representative 까지 폐기** 결정.
   - lifecycle 단위 논의. 사용자: *"아이템이 완료가 아니라, 아이템에서 파생된 그 TODO 가 완료."* → **instance 단위 lifecycle 확정.** (한 캡처에서 나온 TODO_A 완료 / TODO_B active / Schedule_C 만료가 서로 독립.)
   - 저장구조 **A(jsonb 배열 내장) vs B(별도 테이블)** → architect + codex 에 독립 자문 → **둘 다 B**. 사용자 직관도 B.

---

## 2. 현재 코드 상태 (이어받기 기준점)

- **코드 변경 0.** 이 세션은 결정 + 핸드오프만.
- **as-built (alembic 0001~0008):** `mochi_items` 단일 테이블에 intent **5컬럼** —
  `intent`(argmax 대표) / `secondary_intents` / `intent_applicability`(jsonb) / `intent_candidates`(jsonb, LLM 원천) / `confidence`(= max applicability).
  lifecycle 은 **item 단위** (`mochi_items.lifecycle_archive_reason` 등 / iOS `RealmMochiItem.lifecycleStateRawValue`).
- **`DOMAIN_DESIGN §4.4`** 는 아직 실험 *이전* 타겟(flat intents + applicability + threshold). → **재작성 대상.**
- **현재 동작:** ingest → Gemini 분석 → `apply_analysis` 가 5컬럼+entities 적재. iOS 는 단수 `intent` + `confidence<0.6` client-derive 로 "헷갈려요" 표시.

---

## 3. 결정 / trade-off

### 3.1 확정 방향 (재론 금지)
- intent **복수 동등**. 위계(primary/secondary)·**대표(representative, argmax 계산값) 폐기**. 같은 type **다중 허용**(한 캡처에서 TODO 여러 개, Schedule 여러 개).
- **boolean 저장:** applicability/confidence/threshold 점수 폐기. instance 가 저장돼 있으면 곧 active.
- `needs_review`(LLM boolean) + `review_options`(미확정 후보) 도입.
- **lifecycle(완료/만료 + archive_reason)은 intent instance 단위.**
- **iOS "0줄 무중단" 포기** (§3.5).

### 3.2 저장구조 = 별도 `intent_instances` 테이블 + 왜 배열이 아닌가

intent instance 를 `mochi_items` 안 jsonb 배열이 아니라 **별도 `intent_instances` 테이블(1급 행)** 으로 저장.
각 행 = PK · FK(`mochi_item_id`) · `owner_id` · `intent_type` · `payload`(jsonb typed: title/date/time/deadline/person/topic/url/note) · `label` · `reasoning` · lifecycle 컬럼.

**왜 jsonb 배열(A)이 아닌가** — instance 단위 lifecycle 은 본질적으로 "특정 TODO 1개만 완료" 같은 **행 단위 부분 업데이트**다. jsonb 배열에 넣으면:
1. 배열 통째 read-modify-write → **이번에 없애려는 그 5컬럼 동기화 lost-update 버그를 jsonb 안에 재발명.**
2. 같은 type 다중이라 **"N 번째 todo"를 가리킬 안정적 ID 부재** (배열 인덱스는 재정렬·동시성에 깨짐).
3. "미완 todo 만 / 만료 schedule 만" 조회가 전부 **json path 쿼리** → 앱단 펼침·재정렬.

행으로 두면 instance 가 PK 를 갖고 기존 lifecycle 패턴(`update_lifecycle(instance_id, ...)`)을 그대로 승계한다.

### 3.3 두 독립 리뷰 종합 (왜 신뢰할 수 있나)

architect 와 codex 에게 **같은 질문을 독립적으로** 던졌고, 모든 축에서 수렴했다:

| 쟁점 | architect | codex | 합의 |
|---|---|---|---|
| A vs B | **B** | **B** | ✅ + 사용자 직관도 B |
| A 의 치명상 | 부분쓰기(TODO 1개 완료) = 옛 lost-update 버그 재발명 | 같은 type 다중에서 "두 번째 todo" 가리킬 ID 가 배열엔 없음 | ✅ 같은 급소 |
| lifecycle 처리 | mochi_items 엔 "처리상태"만, 의미 lifecycle 은 instance 로 | `mochi_items.lifecycle` 을 "분석 파이프라인 상태"로 축소 | ✅ 동일 |
| review_options | instance 와 별개 축 | instance 아님 — 섞으면 "저장되면 active" 원칙 깨짐 | ✅ 동일 |
| 정규화 범위 | intent_instances 만, typed 파생은 나중 | todos/calendar 까지 만들면 과하다 | ✅ 동일 |

codex 가 누가 시키지도 않았는데 architect 의 미결 2개(review_options 분리 · lifecycle 의미 분리)를 독립적으로 같은 급소로 짚었다 — 강한 신호.

### 3.4 가드레일 3개 (안 지키면 이 설계가 무너짐)
1. **lifecycle 의미 2분할.** `mochi_items` 의 lifecycle 은 "분석 파이프라인 상태"(ingested/analyzing/failed)로 축소. "완료/만료/decay" 의미 lifecycle 은 `intent_instances` 로 이동. `DOMAIN_DESIGN §7` 상태머신을 이 둘로 재작성. (item 상태와 instance 상태가 한 이름에 섞이면 다시 혼란.)
2. **`review_options` 를 `intent_instances` 에 섞지 마라.** 후보는 instance 가 아니다 — 섞으면 "저장된 instance = active" 원칙이 깨진다. 기본: `needs_review` 는 `mochi_items` boolean 컬럼, `review_options` 는 API projection 으로 시작(DB 영속은 "미확정 후보를 나중에 다시 보는 UX" 가 실제 필요해질 때 컬럼 승격).
3. **정규화를 여기서 멈춰라.** 지금 만드는 건 `intent_instances` **한 테이블뿐**. `DOMAIN_DESIGN §13` 의 todos/calendar_events 등 typed 파생 테이블은 만들지 않는다. (lifecycle 가진 최소 실행단위만 행으로 승격, 그 이상은 과설계.)

### 3.5 포기 항목: iOS 0줄 무중단
§4.4 는 "API 응답을 stable projection 으로 두면 iOS 0줄" 을 약속했으나, 그건 **record-level lifecycle 가정 위**에서다. instance 단위 lifecycle 은 `MochiItemResponse` 구조 자체(단수 `lifecycleKind` → instance별)를 바꿔야 하므로 **무중단이 성립하지 않는다** (A 를 골라도 동일하게 깨짐 — 원인은 저장형태가 아니라 instance lifecycle). 이번 빅뱅은 iOS 도 함께 고친다.

iOS 재배선 대상(단수 intent / per-record lifecycle 의존):
`MochiItem.intent`(루트 속성), `RecentMochiCard`, `DetailView` 의 `intent==.schedule/.todo` 분기, `MochiCalendar` 의 `representativeIntent`, `IntentBadge`, `RealmMochiItemRepository`(`listActiveTodos`/`listAmbiguous`/`listAnalyzing`). `confidence<0.6` 헷갈려요 → `needsReview` 직접 읽기로 **오히려 단순해짐**.

---

## 4. 미완 결정 (사람 선택 대기 — plan 에서 닫음)

architect/codex 가 추천 기본값을 줬다. plan 에서 **재확인만** 하면 된다.

- **(가장 큰 것) §7 상태머신 2분할의 정확한 형태** — `mochi_items` 에 남길 "처리상태" 와 `intent_instances` 의 "의미상태"의 상태/전이/archive_reason 표. 가드레일 1 기준 재작성. *이게 §7 재작성의 본체.*
- **`review_options` 영속 위치** — 기본 API projection. (DB 컬럼 승격은 UX 필요 시.)
- **재분석 reconcile** — 기본 "재분석 = 해당 item 의 instance 전량 delete-reinsert"(데이터 없으니 단순). 사용자 완료상태 보존은 후속 sprint. ⚠️ 실데이터 쌓이기 전에만 안전한 단순화 — prod 전 재검토 표시.
- **iOS 0줄 포기 확인** — 사용자 수용함(§3.5). 별도 액션 불필요.

---

## 5. 다음 단계 + 검증 기준

### 5.1 통합 프롬프트 (새 세션에 그대로 복붙)

```
# intent 스키마 빅뱅 재설계 — 구현 지시 (plan 모드로 시작)

설계는 두 독립 리뷰(architect + codex)가 합의해 확정됨. plan 은 미결만 닫고 빠르게 통과시킨다.

## 확정 방향 (재론 금지)
- intent 복수 동등. 위계(primary/secondary)·대표(representative, argmax 계산값) 폐기.
  같은 type 다중 허용(한 캡처에서 TODO 여러 개, Schedule 여러 개).
- boolean 저장: applicability/confidence/threshold 점수 폐기. instance 가 저장돼 있으면 곧 active.
- needs_review(LLM boolean) + review_options(미확정 후보) 도입.
- lifecycle(완료/만료 + archive_reason)은 mochi_item 단위가 아니라 intent instance 단위.
- iOS "0줄 무중단(API projection 만 바꾸면 iOS 안 고침)" 포기. 복수 intent 를 UI 까지
  관철하려 iOS 단수 intent 전제를 재배선한다.

## 저장구조 (확정 — 되돌리지 말 것)
intent instance 를 mochi_items 안 jsonb 배열이 아니라 별도 `intent_instances` 테이블(1급 행)로
저장한다. 각 행 = PK · FK(mochi_item_id) · owner_id · intent_type · payload(jsonb typed:
title/date/time/deadline/person/topic/url/note) · label · reasoning · lifecycle 컬럼.

왜 jsonb 배열이 아닌가 ("배열이 더 단순"이라며 되돌리는 것 방지):
instance 단위 lifecycle 은 본질적으로 "특정 TODO 1개만 완료" 같은 행 단위 부분 업데이트다.
jsonb 배열에 넣으면 — (1) 배열 통째 read-modify-write → 이번에 없애려는 그 5컬럼 동기화
lost-update 버그를 재발명, (2) 같은 type 다중이라 "N 번째 todo"를 가리킬 안정적 ID 부재,
(3) "미완 todo 만 / 만료 schedule 만" 조회가 전부 json path 쿼리. 행으로 두면 instance 가
PK 를 갖고 기존 lifecycle 패턴(update_lifecycle)을 그대로 승계한다.

## 가드레일 (안 지키면 이 설계가 무너짐)
1. lifecycle 의미 2분할. mochi_items 의 lifecycle 은 "분석 파이프라인 상태"
   (ingested/analyzing/failed)로 축소. "완료/만료/decay" 의미 lifecycle 은 intent_instances 로
   이동. DOMAIN_DESIGN §7 상태머신을 이 둘로 재작성.
2. review_options 를 intent_instances 에 섞지 마라. 후보는 instance 가 아니다 — 섞으면
   "저장된 instance = active" 원칙이 깨진다. 기본: needs_review 는 mochi_items boolean 컬럼,
   review_options 는 API projection 으로 시작(DB 영속은 "미확정 후보를 나중에 다시 보는 UX"가
   실제 필요해질 때 컬럼 승격).
3. 정규화를 여기서 멈춰라. 지금 만드는 건 intent_instances 한 테이블뿐. DOMAIN_DESIGN §13 의
   todos/calendar_events 등 typed 파생 테이블은 만들지 않는다. (lifecycle 가진 최소 실행단위만
   행으로 승격, 그 이상은 과설계)

## plan 에서 닫을 미결 (추천 기본값 — 재확인만)
- §7 상태머신 2분할의 정확한 상태/전이 표 (가드레일 1 기준). 이게 §7 재작성의 본체.
- 재분석 reconcile: 기본 "재분석 = 해당 item 의 instance 전량 delete-reinsert"(데이터 없으니 단순).
  사용자 완료상태 보존은 후속 sprint.

## 제약
- L1/L2 문서 교체 허용. DOMAIN_DESIGN §4.4/§7/§13 재작성 OK.
- prod 아님, 실데이터 폐기 허용. migration 0009 = intent_instances 신규 + mochi_items 옛 5컬럼
  (intent / secondary_intents / intent_applicability / intent_candidates / confidence) DROP,
  backfill 없음. iOS Realm schemaVersion bump + deleteRealmIfMigrationNeeded(기존 로컬 데이터
  폐기, 서버 재동기).
- 정합성 폭포: DOMAIN_DESIGN → ARCHITECTURE → openapi.json → 양 README →
  iOS swift-openapi-generator → CHANGELOG.

## 작업 순서
1. doc-guardian: DOMAIN_DESIGN §4.4 ↔ INTENT_REDESIGN ↔ FINDINGS 모순 스캔.
2. architect: 위 확정 위에서 plan (미결 2개 + 0009 DDL + Realm 재모델 + §7 상태머신).
3. 구현(부모) → code-review → qa.
4. 완료 수렴 = /goal "DOMAIN_DESIGN·ARCHITECTURE·openapi.json 동기 + 0009 마이그레이션
   + make lint && make typecheck 통과".
5. (선택) dynamic workflow: iOS 화면별 새 instance 스키마 소비 병렬 검증.

## 참조 경로
- 백엔드: mochi_items/infrastructure/orm.py, repository.py(apply_analysis · list_active_todos_with_entities),
  intents/domain/lifecycle_policy.py, mochi_items/presentation/schemas.py
- iOS: CorePersistence/{RealmObjects,RealmStoreFactory,RealmMochiItemMapper,RealmMochiItemRepository}.swift,
  CoreDomain/{LifecycleState,MochiItemAnalysis}.swift
- 근거: lab/active/intent-schema-decision/FINDINGS.md, docs/INTENT_REDESIGN.md
```

### 5.2 작업 순서 요약
`plan(설계 미결 2개 닫기) → 구현 → code-review → qa → /goal(문서·마이그·lint 자동수렴) → (선택) workflow(iOS 병렬검증)`
- plan 은 설계가 이미 굳어 **짧게 통과**가 목표. goal/workflow 는 설계 확정 *후* 효과가 나므로 지금 던지지 않는다.

### 5.3 검증 기준 (goal 종료점이 될 객관 조건)
1. 한 캡처에서 파생된 TODO_A 만 완료했을 때 TODO_B·다른 intent lifecycle 불변 — 테스트 통과.
2. "owner 의 미완 todo 만" 조회가 instance 행에서 동작, 한 캡처가 todo+schedule 동시 보유 시 두 목록 모두 등장 — 테스트 통과.
3. LLM 출력(배열) → 행 분해 적재 round-trip 무손실 — 테스트 통과.
4. `0009` 적용 후 옛 5컬럼 DROP + 새 구조만, backfill 없이 통과.
5. iOS Realm schemaVersion bump 후 `tuist test` 통과, instance lifecycle 소비 화면 재배선.
6. 백엔드 `make lint && make typecheck` 통과.
