---
level: 3
mode: log
status: archived
last_verified: 2026-05-25
confidence: 1.0
owners: [송준서, 이용찬, 박세현]
description: 백탭 캡쳐의 4-Intent 분류 벤치마크와 latency 실험 결과(2026-05-25). Intent 분류·LLM 프롬프트·이미지 전처리 의사결정의 근거가 필요할 때 읽어라. 실험 raw 는 lab/ 에.
---

# 모찌 백탭 캡쳐 — LLM 의도 분류 / latency 실험 보고서

> 작성일: 2026-05-25
> 범위: 백탭 silent + push notification UX 설계의 데이터 토대
> 산출물: `lab/` (스크립트 + 결과 JSON), 본 문서, `docs/CHANGELOG.md` 2026-05-25 docs 항목

## TL;DR

- **Gemini 3.1 Flash Lite (Vertex AI) + v6 prompt + fhd_jpeg_q60 압축** 이 모찌 백탭 캡쳐의 4-Intent 분류 + use case 후보 생성 task 의 production 권장 조합.
- **Latency p50 ~2.8s**, 페이로드 ~85KB (원본 PNG 대비 13배 축소).
- **사용자가 한 캡쳐에 여러 의도를 동시에 갖는 게 default 패턴** — 13/13 multi-intent. UX 는 single-tap 으로 보이되 모델은 multi 로 사고하게.
- 분기 신호 (`dominant_single` / `likely_multi` / `ambiguous_fallback`) 는 **LLM 출력이 아니라 서버 코드가 applicability 점수로 derive**.

## 1. 왜 이 실험을 했는가

2026-05-25 의 백탭 흐름은 `ShowsSnippetView` 카드에 "캡쳐/메모" 두 버튼이었음. 사용자 (기획자) 와 토론 중 다음 문제가 떠올랐음:

- snippet 카드의 dismiss 가 iOS 17 에서 자동 안 됨 ("완료" 강제 탭 필요)
- "캡쳐 vs 메모" 두 버튼이 사용자 의도 spectrum 의 거친 진입점
- 사용자 의도가 정말 두 가지 (캡쳐/메모) 뿐인가? 아니면 모찌의 4-Intent (schedule/todo/knowledge/memo) 차원으로 자동 분류가 가능한가?
- 메모 단독 surface 는 백탭이 아니라 Siri/위젯이 더 자연스럽지 않은가?

이 결정의 토대로 실측이 필요한 가설들:
1. **LLM 이 스크린샷을 hint 없이 분류 시 정확도 / latency?**
2. **사용자 의도가 본질적으로 모호한 케이스의 비율?**
3. **이미지 압축이 latency 에 미치는 영향?**
4. **multi-intent 가 흔한가, 단일 intent 가 default 인가?**

`lab/screenshot/` 의 사용자 본인 캡쳐 13장 (일부는 파일명이 ground truth) 으로 측정.

## 2. 실험 진화 — v1 → v6

| version | 핵심 변경 | 결과 |
| --- | --- | --- |
| **v1** (`intent_latency_bench.py`) | LLM 이 4-Intent 직접 분류 + self-confidence | latency p50 2.94s. confidence 가 8/8 모두 0.85+ — 가짜 자신감. 모호 케이스 자동 catch 불가. |
| **v2** (`intent_use_case_bench.py` 초기) | "4-Intent 직접 분류 → use case 후보 3개 생성" reframe. 예시 라벨 14개. | 라벨 quality 좋아짐. 단, 후보가 좁게 해석되어 시스템적 표현 ("후속 작업") 자주 등장. |
| **v3** | 예시 라벨 제거, 원리 기반 설명 | 라벨 자연스러움 ↑ ("대화 박제" 등 신조어 등장). p50 2.94s 회복. |
| **v4** | CO-STAR + skill-creator 가이드 적용. WHY 명시, 모찌 도메인 context 추가. | 시나리오 다양성 ↑, 모호 정직성 ↑ (likelihood 0.4 영역 첫 등장). 단 p50 4.11s (+40%). |
| **v4 + jpeg_q60** | 이미지 전처리 (1920px resize + JPEG q60) 결합 | latency p50 3.13s 회복. payload 13배 축소. |
| **v5** | "스크린샷 찍기" → "기록 행위" framing reframe. multi-intent 허용 (독립 likelihood, 합≠1.0). | p50 2.87s (variance ↓). multi-intent 12/13. 사용자가 든 마우스 예시 ("나중에 구매" + "가격 비교") 둘 다 후보로 잡힘. |
| **v6** (codex 권장 반영) | `likelihood` → `applicability` rename. boolean flag 제거, 서버 코드가 후처리. JSON 예시 prompt 안에 명시. "기록/참고" 규칙 자가 모순 정리. | p50 2.82s. applicability 분포 더 정직 (top 0.85-0.95). boolean 100% 일관성. multi-intent 13/13. |

전체 진화 양상: **시스템 분류 task → 사용자 의도 시나리오 펼치기 task → multi-intent 와 정직한 점수 분포**.

## 3. 이미지 전처리 (resize × compression) 실험

`intent_preprocess_bench.py` — 같은 v3 prompt 에 5 variant 적용:

| variant | p50 | mean | bytes | 안정성 |
| --- | --- | --- | --- | --- |
| original | 3075ms | 3439ms | 1151KB | 기준 |
| fhd_png | 3745ms | 4632ms | 476KB | 6/8 — PNG re-encode 가 의외로 느림 |
| fhd_jpeg_q85 | 3170ms | 3643ms | 129KB | 6/8 |
| **fhd_jpeg_q60** | **2757ms** | **2859ms** | **85KB** | **6/8** |
| hd_jpeg_q70 | 2967ms | 3630ms | 57KB | 5/8 (너무 작으면 quality 영향) |

가장 두드러진 결과: **JPEG q=60 + 1920px** 가 sweet spot. 원본 대비 latency 약간 ↓ + bytes 13배 축소. quality 손실은 본질적 모호 케이스 (사용자가 직접 모호하다 짚은 영역) 외 신호 없음.

5.8MB → 113KB 가 가능한 큰 이미지 (IMG_8477) 의 경우 latency 5.5s → 2.7s 로 50% 감소.

## 4. 핵심 데이터 발견

### 4.1 LLM 의 self-confidence 는 모호 케이스 탐지에 부적합

v1: 8/8 모두 confidence ≥ 0.85. 사용자에게 "확신이 낮을 때만 fallback" 같은 흐름 구현 불가.

v4 부터 `likelihood` (v6: `applicability`) 분산이 도입되며 본질적 모호 영역 (likelihood 0.4) 이 출력에 등장. 이게 모찌 알림 fallback UX 의 정직한 trigger.

### 4.2 multi-intent 가 default 패턴

| version | likely_multi_intent | dominant_single | ambiguous_fallback |
| --- | --- | --- | --- |
| v5 | 12/13 | 0/13 | 1/13 |
| v6 (서버 후처리) | 13/13 | 0/13 | 0/13 |

**13장 전부 multi-intent** (threshold: 2 이상의 후보가 applicability ≥ 0.5). 사용자가 본인 예시로 든 마우스 캡쳐 (구매 고민 + 가격 비교), 이뻐서 구매고민중 기록 (구매 + 기록), 아키텍쳐 참고 (학습 + 설계 적용) 모두 후보 셋에 multi 의도 잡힘.

**도메인 함의**: 현재 `docs/DOMAIN_DESIGN.md` 의 4-Intent 가 single-valued (mochi_item 1건당 1 intent). multi-intent UX 를 본격 도입하려면:
- 옵션 A: 한 capture → 여러 mochi_item 으로 derive (multi-row)
- 옵션 B: capture 의 primary_intent + secondary_intents[] metadata
- 옵션 C: single 유지하되 user 가 알림에서 가장 강한 1개 고른 후 모찌 앱 안에서 multi-tag 보강 (도메인 변경 없음 — 가장 가벼움)

본 실험에서는 도메인 영향은 *고려하지 않고* (사용자 지시) UX/프롬프트 차원만 검증. 실제 구현 시 위 옵션 중 결정 필요.

### 4.3 라벨 vocabulary 의 specific-bias 잔존

v4 부터 LLM 의 시스템적 표현 ("저장", "기록", "처리") 회피는 잘 작동. 다만 v6 의 "사용자 의도가 진짜 일반어면 그 단어를 써라" 규칙도 LLM 의 specific-bias 를 완전히 못 풀음 — 아키텍쳐 = "참고" (사용자 의도) 가 LLM 에서는 "기술 학습" 으로 specific 화됨. few-shot 예시 추가 (v7?) 또는 calibration 데이터로 풀어야 할 영역.

### 4.4 codex consult 결과 (`/tmp/codex-mochi-v5-response.txt`)

codex 가 v5 단계에서 받은 second opinion. 핵심 5개:

1. **framing reframe ("스크린샷"→"기록 행위") 효과 인정**. 메커니즘: 질문 축이 "이게 뭐야" → "왜 남겼나" 로 바뀜.
2. **likelihood 는 실제 확률 아님**. `applicability` 또는 `intent_score` rename 권장. *v6 반영 완료*.
3. **boolean flag 는 코드 후처리로** — threshold 정의라 LLM 이 판단할 이유 없음. *v6 반영 완료*.
4. blind spot: schema 명시 약함 / 후보 3개 고정의 가짜 후보 위험 / "기록" 규칙 자가 모순 / negative instruction 많음 → few-shot 효과적 / 입력 컨텍스트 (OCR, 앱명) 부재. *v6 에 schema 예시 + 자가 모순 정리 반영. few-shot / OCR 등은 미반영*.
5. **multi-intent 도메인 sound, UX 는 default single 처럼**. 기본 = top-1 큰 제안, multi-score 높을 때만 multi-select 강조. "모델 multi + UI progressive disclosure".

## 5. Production 권장 spec

### 5.1 iOS 클라이언트

```swift
// 백탭 → 스크린샷 캡쳐 후 전처리
let maxEdge: CGFloat = 1920
let jpegQuality: CGFloat = 0.60

let resized = screenshot.scaledToFit(maxEdge: maxEdge)
let payload = resized.jpegData(compressionQuality: jpegQuality)
// 평균 ~85KB
```

본문 사진 (영구 저장) 과 분석 전송 (Gemini 호출용) 의 quality 를 *분리*해도 좋음 — 보관 = q85, 분석 = q60. 결정은 모찌의 캡쳐 영구 저장 정책에 따라.

### 5.2 백엔드 호출

```
Model: gemini-3.1-flash-lite (Vertex AI)
location: global
prompt: v6 SYSTEM_PROMPT (lab/intent_use_case_bench.py 참조)
temperature: 0.3
max_output_tokens: 1024
thinking_config: thinking_budget=0 (minimal)
response_mime_type: application/json
response_schema: lab/intent_use_case_bench.py 의 RESPONSE_SCHEMA
```

응답 latency p50 ~2.8s, max ~6.6s (variance 큰 편 — variance 안정성은 다회 측정 필요).

### 5.3 서버 후처리 — 분기 신호 derive

`lab/intent_v6_compressed_bench.py` 의 `derive_flags()` 참고. 현재 threshold:

```python
dominant_single_intent = top.applicability >= 0.7 AND all others <= 0.3
likely_multi_intent     = count(c.applicability >= 0.5) >= 2
# 둘 다 false 면 ambiguous_fallback
```

**Threshold 는 가이드라인이고 production data 로 calibration 필요**. 현재 13장 표본에서는 dominant 0건, multi 13건, fallback 0건. 사용자 실 선택 로그가 모이면 ROC 기반 calibration.

### 5.4 알림 UX (codex + 사용자 통찰)

```
[기본 - top-1 강조]
🐹 모찌에 저장 — "구매 고민" 으로 둘까요?
[저장]  [다른 의도 보기]
                ↓ (펼침)
                ☑ 구매 고민 (선택됨)
                ☐ 가격 비교
                ☐ 위시리스트 공유
                ☐ 다른 의도 (자유 입력)

분기:
- dominant_single: 단순 confirmation 알림 (저장됨 토스트)
- likely_multi:     기본 알림 + 펼침 시 multi-select 강조
- ambiguous_fallback: 후보 3개 노출, top-1 가 small selected
```

iOS push notification action 한도 (4개) 안에 후보 3개 + "다른 의도" 가 들어감.

## 6. 미해결 / 다음 단계

| # | 작업 | 비고 |
| --- | --- | --- |
| 1 | 사용자 정답 라벨링 받기 → cover rate (top-1 / top-3 / multi-cover) 정량 산출 | 사용자 5분, 신뢰도 검증 |
| 2 | variance 검증 — v6 + jpeg_q60 을 같은 13장 × 3회 반복 | 9분, latency 분포 안정성 확인 |
| 3 | threshold 튜닝 실험 — dominant/multi threshold 변종 적용 (LLM 재호출 불필요, 코드만) | 1분 |
| 4 | few-shot 예시 추가한 v7 — 아키텍쳐 "참고" 같은 일반어 의도 cover 시도 | 30분, latency trade-off |
| 5 | **도메인 모델 결정** — multi-intent 를 모찌 도메인에서 어떻게 표현할지 (옵션 A/B/C, §4.2) | 큰 결정, 별도 토론 |
| 6 | **iOS 측 구현 plan + handoff** — `CaptureScreenshotIntent` 또는 백엔드 업로드 단계에 resize/compress 적용, 알림 흐름, multi-select UI | 본 실험의 자연스러운 후속 |
| 7 | **백엔드 측 endpoint** — Gemini 호출 + threshold 후처리 + 4-Intent 매핑 결과 저장. `app/modules/captures/application/` 에 use case 적합 | iOS 구현과 짝 |
| 8 | OCR / 앱명 / 시간 등 입력 컨텍스트 추가 — codex blind spot #5 | 정확도 ↑ 가능. 우선순위 낮음. |
| 9 | LLM 분류 정확도 사후 calibration — 사용자 실제 선택 로그로 prompt 보강 + threshold 튜닝 | production 진입 후 |

## 7. 파일 인덱스 (`lab/`)

### 스크립트
- `intent_latency_bench.py` — v1: 4-Intent 직접 분류 baseline
- `intent_use_case_bench.py` — v2-v6: use case 후보 생성 (SYSTEM_PROMPT 는 현재 v6 버전)
- `intent_preprocess_bench.py` — 이미지 전처리 5 variant × 8장 = 40 호출
- `intent_v4_compressed_bench.py` — v4 + fhd_jpeg_q60 결합 (11장)
- `intent_v5_compressed_bench.py` — v5 + fhd_jpeg_q60 (13장)
- `intent_v6_compressed_bench.py` — **v6 + fhd_jpeg_q60 + 서버 boolean derive (production candidate)**

### 결과 JSON
- `intent_latency_results.json` (v1)
- `intent_use_case_results.json` (v2)
- `intent_use_case_results_v3.json`
- `intent_use_case_results_v4.json`
- `intent_v4_compressed_results.json`
- `intent_use_case_results_v5.json`
- `intent_v5_compressed_results.json`
- `intent_preprocess_results.json`
- `intent_v6_compressed_results.json` ← **production 권장 spec 검증 결과**

### 외부 자료
- `/tmp/codex-mochi-v5-prompt.md` — codex 에 보낸 prompt
- `/tmp/codex-mochi-v5-response.txt` — codex 응답

### 입력
- `lab/screenshot/` — 사용자 본인 캡쳐 13장. 새 3장 (마우스/아키텍쳐/이뻐서) 과 다음 2장 (공부 관련) 은 파일명에 ground truth 의도가 명시되어 cover rate 검증에 유용.

## 8. 제약 / 정직성

- **n=13, single run** — variance 검증 미흡. p50/p99 의 안정성은 다회 측정 필요.
- **사용자 본인 표본** — 본인 사용 패턴에 편향됨. 다른 사용자 페르소나 cover 안 됨.
- **사용자 정답 라벨링 미수집** — top-1 / top-3 적중률 정량 미산출. 파일명 기반 추정 정도.
- **OCR 등 입력 컨텍스트 미포함** — 이미지만 입력. 백엔드에서 OCR / 앱명 / 시간 등 보강하면 정확도 ↑ 가능 (codex 권장).
- **threshold 는 calibration 전 가이드라인** — 실 사용자 선택 로그로 튜닝 필요.
- **도메인 변경 영향은 본 실험 범위 밖** — multi-intent 의 도메인 표현 (옵션 A/B/C) 은 별도 결정.

## 9. 본 실험의 자산 가치

본 실험이 후속 작업에 제공하는 검증된 토대:

1. **Gemini 3.1 Flash Lite 가 이 task 에 적합** — latency p50 ~2.8s 로 알림 UX 에 충분.
2. **이미지 압축 spec 확정** — 1920px + JPEG q60. payload 13배 축소.
3. **multi-intent 가 default 패턴** — UX 설계의 가장 큰 의사결정 입력.
4. **분기 신호는 서버 코드 후처리** — LLM 부담 ↓ + 일관성 ↑.
5. **codex 의 5개 권장사항** — v6 prompt 에 3개 반영, 나머지 (few-shot, OCR) 는 후속 작업 단서.
6. **production 권장 spec 패키지** — `intent_v6_compressed_bench.py` + `intent_use_case_bench.py:SYSTEM_PROMPT` 가 그대로 백엔드 호출 코드의 reference.
