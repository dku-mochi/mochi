---
level: 3
mode: log
status: concluded
last_verified: 2026-05-29
confidence: 0.9
owners: [송준서]
description: 스크린샷·메모 추출 전략 실험 결론. 추출 형식(A/B/C) × 모델(flash/flash-lite) 비교. 프롬프트 설계 시 참고.
---

# FINDINGS — extraction-strategy

## 결론

**C(하이브리드) + flash-lite** 채택.

이미지·텍스트 모두 전략 간 intent 정확도 차이는 미미(88~92%)하나,
C가 비용·간결성에서 우위를 가지며 flash-lite 로도 flash 와 동일한 정확도를 낸다.

---

## 실험 개요

- **기간**: 2026-05-29
- **모델**: gemini-3.1-flash, gemini-3.1-flash-lite
- **데이터**: 스크린샷 22장 + 텍스트 메모 40건 (gold label 포함)
- **전략**:
  - A (자유형): 자유로운 bullet 나열
  - B (구조화): facts / opinions / key_info / entities 섹션 분리
  - C (하이브리드): `fact` / `info` / `opinion` 태그 prefix bullet

---

## 핵심 수치

### 텍스트 메모 (gold label 대비 정확도)

| 모델 | 전략 | intent 정확도 | 비용($/건) |
|---|---|---|---|
| flash | A | 90% | 0.00052 |
| flash | B | 88% | 0.00066 |
| flash | C | 88% | 0.00051 |
| **flash-lite** | **A** | **92%** | **0.00012** |
| **flash-lite** | **B** | **92%** | **0.00017** |
| **flash-lite** | **C** | **92%** | **0.00014** |

### 스크린샷 (이미지)

| 모델 | 전략 | 평균 항목수 | tok_out | 비용($/건) |
|---|---|---|---|---|
| flash | A | 6.3 | 247 | 0.00118 |
| flash | B | 11.6 | 393 | 0.00160 |
| flash | C | 4.9 | 270 | 0.00126 |
| flash-lite | A | 5.2 | 190 | 0.00026 |
| flash-lite | B | 9.3 | 295 | 0.00032 |
| **flash-lite** | **C** | **4.3** | **230** | **0.00029** |

---

## 전략별 특성

- **A (자유형)**: 간결하지만 구조 없어 파싱 어려움. intent 정확도는 오히려 가장 높음(텍스트 기준).
- **B (구조화)**: 항목수·토큰이 가장 많음. 세부 정보 풍부하나 비용 부담.
- **C (하이브리드)**: A의 간결함 + B의 타입 힌트. 항목수 적고 비용 낮으면서 정확도 동급.

---

## 프로덕션 반영

`system_prompts.py` 의 추출 프롬프트 설계에 C 형식(`fact`/`info`/`opinion` 태그) 적용.
모델은 비용 대비 정확도가 동등한 **flash-lite** 사용.

---

## 미해결 / 후속

- 이미지 케이스는 gold label 없어 intent 정확도 자동 측정 불가 — `agent-loop-image-eval` 에서 지속 검증.
- B 전략의 entities 구조화가 downstream 검색에 유리할 수 있음 — 추후 검색 품질 실험 시 재검토.
