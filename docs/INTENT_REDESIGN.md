---
level: 2
mode: reference
status: adopting
last_verified: 2026-06-04
confidence: 0.9
owners: [송준서, 이용찬, 박세현]
description: Intent 데이터 모델 재설계 — `intent_instances` 리스트(per-instance `applicable: bool` + `payload`) + top-level `needs_review` boolean, LLM single truth source. v2(2026-06-03 채팅 합의)로 boolean 모델 확정, v1 의 float/threshold 모델은 폐기. **채택됨(adopting)**: DOMAIN_DESIGN.md §4.4 가 committed 타겟으로 보유(코드는 migration 0009 로 이행 예정). 이 문서는 그 근거·토론 기록. intent 스키마·agent 파이프라인·프롬프트를 손대기 전 반드시 읽어라.
---

# Intent 데이터 모델 재설계 — 설계 노트

> **상태: 채택됨(adopting) / 코드 미구현.** 2026-06-02 설계 토론(송준서 ↔ Claude) 기록 + **2026-06-03 v2 채팅 합의**(boolean + single truth source — §4 본문 반영).
> 2026-06-03: 이 방향이 [`DOMAIN_DESIGN.md`](DOMAIN_DESIGN.md) **§4.4 Intent 모델**에 committed 타겟으로 편입됨 — 거기가 정본 스펙, 이 문서는 **근거·토론 기록**이다.
> intent 스키마 · agent 오케스트레이터 · 프롬프트 · iOS DTO 를 **손대기 전 필독.**
> 코드는 아직 4컬럼 상태 — migration `0009`(원천 도입) → `0011`(4컬럼 DROP)로 이행한다.

---

## 0. TL;DR

- **문제**: 지금 intent 를 4개 필드로 나눠 저장하는데, 그중 3개가 1개에서 파생되는 **중복**이다. 이미 동기화 버그를 냈다.
- **방향**: 원천을 **`intent_instances` 리스트 1개**(per-instance `applicable: bool` + `payload`)로 통일. 같은 type 의 multi instance 가능(회의록 → todo 두 개 + schedule 한 개). 위계 폐기.
- **정책**: `active = filter(applicable=true)` → 비면 **`memo` 하나로 fallback** → 사용자 확인은 `needs_review` boolean (**LLM 출력**).
- **핵심**: LLM 출력 = single truth source. 임계값 없음, derived 없음. 컨트롤 surface 는 *프롬프트 정확도 하나*.

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

> **v2 (2026-06-03 송준서·박세현 채팅 합의):** boolean + single truth source. v1 의 float `applicability` + `τ`/`τ_review` threshold 모델은 폐기.
> 동기: 두 가지 컨트롤 surface(LLM 분포 정확도 + 임계값 튜닝)를 **하나**(LLM boolean 정확도)로 줄여 dev velocity 확보. `intent_instances` 가 instance 단위라 typed 테이블로 직접 매핑되는 부수효과까지.

### 4.1 저장 — `intent_instances` 리스트

```jsonc
intent_instances: [
  {
    "intent_type": "schedule",         // 4-Intent enum: schedule|todo|knowledge|memo
    "applicable":  true,               // boolean — 이 instance 를 저장할지 (LLM 결정)
    "payload": {                       // intent_type 별 typed 필드
      "title": "디자인팀 리뷰 미팅",
      "date":  "2026-06-07",
      "time":  "14:00"
    }
  },
  // 같은 intent_type 의 multi instance 도 가능 — 회의록 한 장 → todo 두 개 등
]
```

- **원천 = `intent_instances` 리스트 1개.** 위계 없음(primary/secondary 폐기). 동일 type 의 instance 중복 OK.
- **per-instance `applicable: bool`** — *이 의도를 저장할지* 의 LLM 자기판단(박세현·송준서 채팅 의미 확정).
- **payload typed 필드**가 instance 안에 직접 들어감 → typed 테이블(`todos`, `calendar_events`)로 *직접* 매핑되는 실행 단위.
- 대표·집계·`confidence` 등 파생값은 **저장 안 함, read 시 계산**(projection — `DOMAIN_DESIGN.md §4.4`).

### 4.2 결정 정책 — boolean 규칙 3개 (single truth source)

저장과 **분리한다.** 정책은 이게 전부다:

```
1) active_instances = intent_instances.filter(applicable = true)   # boolean filter
2) if active_instances 비면 → memo fallback instance 추가            # 분류 실패 → 안전 보존
3) if needs_review (top-level, LLM 출력) → passive "헷갈려요" 카드   # 사용자 직교 플래그
```

- **임계값 없음.** `τ`·`τ_review` 폐기. active 판정은 `applicable == true`, review 판정은 `needs_review == true`.
- **`needs_review` 는 LLM top-level 출력.** *사용자에게 되물을지* 의 LLM 자기판단(채팅 의미 확정). derived 계산이나 안전망 override 없음 — **single truth source 원칙**(송준서: *"트루소스를 하나로 맞추는게 나을듯"*).
- **`memo` fallback** 그대로 — active 비면 memo instance 자동 추가. 미션(*"놓치기 쉬운 순간은 쉽게 남기고, 필요한 기억은 쉽게 떠오른다"*) 정합. 분류 못 해도 안 잃는다.

> §3.3 우려 (LLM self-confidence 모호 탐지 부적합) 는 **known risk 로 수용한다.** 정확도 컨트롤은 *프롬프트 엔지니어링 + eval* 로. derived override 안전망(이전 Claude 제안)은 truth source 다중화를 막기 위해 폐기. 의도된 단순성.

### 4.3 사례별 작동

**케이스 A — 단일 의도 확신**
```
needs_review: false
intent_instances: [
  { intent_type: schedule, applicable: true, payload: {...} }
]
```
→ schedule 1 개 저장. 사용자 안 물음.

**케이스 B — multi instance 확신 (같은 type 도 가능)**
```
needs_review: false
intent_instances: [
  { intent_type: todo,     applicable: true, payload: {title: "기획안 초안 작성"} },
  { intent_type: todo,     applicable: true, payload: {title: "디자인팀에 공유"} },
  { intent_type: schedule, applicable: true, payload: {...} }
]
```
→ 3 개 instance 자동 저장 → typed 테이블 행(`todos` 2 개 + `calendar_events` 1 개). 사용자 안 물음. UI 는 대표 1 개 + 작은 chip 들.

**케이스 C — LLM 이 헷갈림**
```
needs_review: true
intent_instances: [ ... LLM 추정, applicable 도 LLM 판단 ... ]
```
→ active 비면 memo fallback. **passive "헷갈려요" 카드** (single-confirm 1-tap, advanced 옵션으로 다른 의도 추가 숨김). 답해도 좋고 무시해도 됨.

→ **1:N 데이터 ≠ 1:N 사용자 질의 UX.** Multi 는 모찌가 자신 있게 판단했을 때만 자동 저장(케이스 B 만, 사용자 개입 X). 사용자에게 묻는 케이스 C 는 LLM 도 multi 라고 확신하지 않은 상태라 단일 확인으로 충분. 자세한 사례 풀이: [`../journal/2026-06-03-intent-fallback-clarification.md`](../journal/2026-06-03-intent-fallback-clarification.md).

---

## 5. 현재 코드는 이상적인 설계인가 — 솔직한 평가

**아니다. 동작하는 합리적 임시방편이지 이상적이진 않다.**

- 부채 1: 4중 파생 중복(§2) — 이미 동기화 버그를 냈고 또 낼 구조.
- 부채 2: primary/secondary 위계가 LLM 의 동등 판단을 왜곡.
- 부채 3: `confidence` = `max(applicability)` 인데 이름이 둘이라 별개 개념처럼 보임.

**이상적 방향 = §4** (`intent_instances` 원천 1개 + boolean `applicable`/`needs_review` + memo fallback + payload typed). 이러면 세 부채가 한 번에 정리되고, 저장은 단순해지고 정책은 규칙 3개로 명시되며, **컨트롤 surface 가 LLM boolean 정확도 하나로 축소**된다.

**결론: 지금 코드 유지보다 §4 로 가는 게 맞다.** 초기에 잡는 게 나중에 4중 중복을 여러 군데서 동기화하는 것보다 싸다.

---

## 6. 영향 범위 (개발 착수 시 건드릴 곳)

정합성 폭포(상위 → 하위) 순서로:

| 레이어 | 작업 |
|---|---|
| **DB** | migration: 4컬럼 + `confidence` → `intent_instances`(jsonb) + `needs_review`(bool). 기존 row 데이터 이행. |
| **Agent** | orchestrator: candidates → `intent_instances` 형태로. **프롬프트 출력 스키마** 변경 — top-level `needs_review` + per-instance `{intent_type, applicable, payload}`. LLM 이 자기판단 boolean 두 개 출력. |
| **정책 코드** | §4.2 규칙 3개를 한곳(예: `lifecycle_policy` 인접)에 명시. **boolean filter 만**, threshold 주입 없음. |
| **iOS** | `MochiItemDTO`, Realm schemaVersion, "헷갈려요/복수 의도" 표시 로직(현 `isUncertain`/`isMultiIntent` 재배선). 헷갈려요 = `needs_review` 직접 사용, client-derive(`confidence < 0.6`) 폐기. |
| **문서/계약** | `DOMAIN_DESIGN.md §4.4`(이미 정합 — 본 PR), `openapi.json`, 양 README — L1/L2 폭포 필수. |

---

## 7. 개발 전 팀이 정할 것 (미해결)

- **프롬프트 + eval 정밀도** (박세현) — `applicable` 정확도 + `needs_review` 정확도 두 축. **threshold sweep 폐기.** LLM 자기판단의 false-negative/false-positive 측정·튜닝.
- **payload schema 정의** — `intent_type` 별 typed 필드 합의(`todo: {title}`, `schedule: {title, date, time}`, `knowledge: {?}`, `memo: {text}`). agent 프롬프트와 typed 테이블이 같은 schema 를 따라야 함.
- **복수 intent UI 표현** — 홈 카드·검색 필터에서 "여러 의도"를 어떻게 보여줄지(대표 1개 강조 + 작은 chip N개 — 사례 풀이 journal §Q2 노선).
- **실행 단위 materialize** — `intent_instances` 마다 typed 테이블(todos/calendar_events 등) 1행을 만들지(별도 작업).
- `intent_candidates` 의 `label`/`reasoning` 을 새 `intent_instances` 에 유지할지(디버깅·설명 가치 vs 슬림 — `payload` 가 typed 라 reasoning 따로 둘 가치 재검토).
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
