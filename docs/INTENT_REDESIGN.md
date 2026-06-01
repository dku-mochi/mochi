---
level: 2
mode: reference
status: draft
last_verified: 2026-06-02
confidence: 0.8
owners: [송준서, 이용찬, 박세현]
description: Intent 데이터 모델 재설계 제안(미구현). 현재 4필드 파생 중복을 flat intents 리스트로, primary/secondary 위계 폐기, fallback=memo 정책. 2026-06-02 송준서·Claude 설계 토론 기록. intent 스키마·agent 파이프라인·프롬프트를 손대기 전 반드시 읽어라.
---

# Intent 데이터 모델 재설계 — 설계 노트

> **상태: 제안 / 미구현.** 2026-06-02 설계 토론(송준서 ↔ Claude) 기록.
> intent 스키마 · agent 오케스트레이터 · 프롬프트 · iOS DTO 를 **손대기 전 필독.**
> 지금 당장 스키마를 바꾸는 작업은 아니다 — **방향만 합의**했고, 실제 구현 시점/범위는 팀이 정한다.

---

## 0. TL;DR

- **문제**: 지금 intent 를 4개 필드로 나눠 저장하는데, 그중 3개가 1개에서 파생되는 **중복**이다. 이미 동기화 버그를 냈다.
- **방향**: 원천을 **flat `intents` 리스트 1개**로 통일. 대표(primary)·집계는 *저장하지 말고 계산*. primary/secondary 위계 폐기.
- **정책**: `active = applicability ≥ τ 인 intent들` → 비면 **`memo` 하나로 fallback** → 사용자 확인은 `needs_review` 별도 플래그.
- **핵심**: 저장 구조와 결정 정책을 **분리**하면 "복수 intent 라서 fallback 이 복잡하다"는 문제가 사라진다.

---

## 1. 배경 — 무엇을 정하려 했나

2026-06-01 회의에서 **"데이터·인텐트 관계 1:N"**(하나의 `MochiItem` 이 여러 intent 를 가질 수 있다)을 결정했다. 예: **회의록 캡처 한 장이 일정 + 할 일 + 지식 + 기록을 동시에** 담을 수 있다.

그래서 던진 질문: *현재 코드 구조로 1:N 이 충분한가? 정규화(join 테이블)가 나은가? 아니면 다른 형태인가?*

---

## 2. 현재 구조 (as-built, 2026-06-02 기준)

`mochi_items` 단일 테이블에 intent 가 **4개 컬럼**으로 들어있다 (migration 0005·0008):

| 필드 | 타입 | 의미 | 출처 |
|---|---|---|---|
| `intent` | `varchar(32)` | 대표 의도 1개 | `argmax(candidates.applicability)` |
| `secondary_intents` | `varchar(32)[]` | 대표 뺀 보조 의도들 | `distinct(candidates.intent) − intent` |
| `intent_applicability` | `jsonb` | `{intent: 강도 0~1}` 맵 | candidates 를 intent별 max 집계 |
| `intent_candidates` | `jsonb` | `[{label, intent, applicability, reasoning}]` | **LLM 원천 출력** |

### 문제 — 4중 파생 중복

```
intent_candidates   ← 진짜 원천 (LLM 출력)
   ├─ intent               = argmax(applicability)
   ├─ secondary_intents    = 나머지 distinct intents
   └─ intent_applicability = intent별 max 집계
```

세 필드는 전부 `intent_candidates` 하나에서 계산되는 **파생값**이다. 같은 정보를 4가지 모양으로 중복 저장 → **갱신 이상(update anomaly)**: candidates 가 바뀌면 4개를 다 동기화해야 하고, 하나라도 빠지면 불일치.

**이미 터진 버그 (CHANGELOG 근거):**
- *"intent_applicability 를 candidates 전체로 풍부화 (구 `{primary:confidence}` 버그 수정)"*
- *"동기 분류가 confidence 를 안 채워 iOS 에 0.0 이 박힘"*

→ 둘 다 이 4중 중복의 동기화 실패다. "필드 의존성이 강하다"는 직관은 설계 부채가 맞다.

> 참고: 코드의 `intent_confidence` 는 사실상 `max(applicability)` 다. confidence 와 applicability 는 **별개의 두 축이 아니라 같은 값**이다.

---

## 3. 송준서의 문제의식 (이 토론에서 정해진 관점)

1. **세 필드(`intent_candidates`/`secondary_intents`/`intent_applicability`)는 의존성이 너무 강하다.** → §2 의 파생 중복으로 확인됨.
2. **primary/secondary 위계를 쓰지 말자.** 대표 1개 + 서브 N개가 아니라, **복수 intent 를 동등하게 저장**한다. LLM 이 동등하게 본 의도를 argmax 로 줄 세우는 건 정보 손실 + 자의적 tie-breaking 이다.
3. **걱정은 정확도와 fallback 정책의 복잡성이다.** 예: Agent 가 3개 intent 를 예상했는데 **모든 applicability 가 아주 낮은** 경우 어떻게 처리하나? 1:N 이면 intent 마다 fallback 을 따로 생각해야 해서 정책이 복잡해질 것 같다 — 명쾌한 규칙이 필요하다.
4. Agent 파이프라인·프롬프트 수정이 따라온다는 건 인지하고 있다.
5. **"지금 코드는 임시로 짠 것인데 이게 이상적인 설계인가?"** (솔직한 평가 요청)

---

## 4. 합의된 방향 (결정)

### 4.1 저장 — flat 리스트 하나

```
intents: [ {intent: schedule, applicability: 0.8},
           {intent: todo,     applicability: 0.7},
           {intent: memo,     applicability: 0.6} ]
```

- **원천은 `intents` 리스트 1개.** primary/secondary 위계 없음, 동등.
- 대표가 UI 에 필요하면 → **저장하지 말고 `max()` 로 계산.**
- `confidence` = `max(applicability)`, 역시 파생(저장 안 함).
- → 4개 필드 → 1개 리스트. §2 의 중복·동기화 버그가 구조적으로 사라진다.

### 4.2 결정 정책 — 규칙 3개 + 직교 플래그

저장과 **분리한다.** 정책은 이게 전부다:

```
1) active      = { i ∈ intents : i.applicability ≥ τ }     # 임계값 넘는 의도들 (복수 가능)
2) if active 비면  active = { memo }                        # 분류 실패 → 기록으로 안전 보존
3) needs_review = max(i.applicability) < τ_review           # 저장·active 와 직교한 별도 boolean
```

- **`memo` fallback 이 핵심이고 우연이 아니다.** memo 는 "맥락 보존·영구 보관"(PRODUCT.md §5)이고, **미션("놓치기 쉬운 순간은 쉽게 남기고, 필요한 기억은 쉽게 떠오른다")과 정확히 정합**한다. 분류를 못 해도 일단 안 잃는다.
- **`needs_review`("헷갈려요")는 저장과 직교**한다. "memo 로 보관" + "사용자에게 확인 요청"이 동시에 성립.

### 4.3 §3.3 걱정에 대한 명쾌한 답

*"3개 intent 예상했는데 전부 낮음"* 케이스를 규칙에 넣으면:
- 전부 `< τ` → active 비어 있음 → **`memo` 로 저장**
- `max(applicability)` 도 낮음 → **`needs_review = true` → "헷갈려요" 카드**
- 결과: **memo 로 보관 + 사용자 확인 요청.** 끝. 추가 정책 불필요.

→ 복수 intent 여도 fallback 은 복잡해지지 않는다. "intent 마다 fallback"으로 보면 복잡하지만, **"active 집합이 비면 memo"라는 집합 규칙 하나**로 보면 복수든 단수든 동일하다.

---

## 5. 현재 코드는 이상적인 설계인가 — 솔직한 평가

**아니다. 동작하는 합리적 임시방편이지 이상적이진 않다.**

- 부채 1: 4중 파생 중복(§2) — 이미 동기화 버그를 냈고 또 낼 구조.
- 부채 2: primary/secondary 위계가 LLM 의 동등 판단을 왜곡.
- 부채 3: `confidence` = `max(applicability)` 인데 이름이 둘이라 별개 개념처럼 보임.

**이상적 방향 = §4** (flat `intents` 원천 1개 + 계산 파생 + memo fallback + 직교 review 플래그). 이러면 세 부채가 한 번에 정리되고, 저장은 단순해지고 정책은 규칙 3개로 명시된다.

**결론: 지금 코드 유지보다 §4 로 가는 게 맞다.** 초기에 잡는 게 나중에 4중 중복을 여러 군데서 동기화하는 것보다 싸다.

---

## 6. 영향 범위 (개발 착수 시 건드릴 곳)

정합성 폭포(상위 → 하위) 순서로:

| 레이어 | 작업 |
|---|---|
| **DB** | migration: 4필드 → `intents`(jsonb) + `needs_review`(bool). 기존 row 데이터 이행. |
| **Agent** | orchestrator: candidates → `intents` 형태로. **프롬프트 출력 스키마** 변경(applicability 포함 flat 리스트). |
| **정책 코드** | §4.2 규칙 3개를 한곳(예: `lifecycle_policy` 인접)에 명시. τ/τ_review 주입. |
| **iOS** | `MochiItemDTO`, Realm schemaVersion, "헷갈려요/복수 의도" 표시 로직(현 `isUncertain`/`isMultiIntent` 재배선). |
| **문서/계약** | `DOMAIN_DESIGN.md`(ERD/DDL), `openapi.json`, 양 README — L1/L2 폭포 필수. |

---

## 7. 개발 전 팀이 정할 것 (미해결)

- **τ, τ_review 값** → 감으로 정하지 말고 **실험**(박세현 eval dataset, 회의 안건 §9 threshold sweep: 0.6/0.7/0.8/0.9)으로 결정.
- **복수 intent UI 표현** — 홈 카드·검색 필터에서 "여러 의도"를 어떻게 보여줄지(대표 1개 강조? 칩 N개?).
- **실행 단위 materialize** — active intent 마다 typed 테이블(todos/calendar_events 등)을 만들지(별도 작업, §2 의 1:N 과 다른 축).
- `intent_candidates` 의 `label`/`reasoning` 을 새 `intents` 에 유지할지(디버깅·설명 가치 vs 슬림).
- **구현 시점** — 지금 vs 통합 sprint(6/19~). 스키마 owner(이용찬)와 조율.

---

## 8. 범위 밖 / 재론 안 함

- **지금 스키마 수정 안 함.** 이 문서는 방향 합의 + 핸드오프용.
- 정규화 join 테이블(별도 intent 테이블) 안은 **2026-05-30 폐기** — 재론하지 않는다. intent 는 값 4개 고정 enum 이라 join 의 이득이 적고, 항상 함께 읽힌다.

---

## 부록 — 토론 Q&A 흐름

| # | Claude 질문 | 송준서 답 |
|---|---|---|
| 1 | "1:N"의 정확한 의미? | 하나의 mochi item 이 여러 intent 를 도출 가능. 대표/서브가 아니라 **복수 동등**. |
| 2 | 지금 구조로 충분? Join 정규화? | (테이블 설명 요청 후) 세 필드 **의존성이 강하다**. flat 복수 저장으로 가자. |
| 3 | 모든 intent confidence 가 낮으면? | 정책이 복잡해질 것 같다 — **명쾌한 해결책 필요**. → §4.3 으로 정리. |
| 4 | 지금 코드가 이상적인가? | (궁금함) → "임시방편, §4 가 이상적"으로 합의. |
| 5 | 초기에 잡을까? | **맞다, 초기에 잡는 게 훨씬 낫다.** |
