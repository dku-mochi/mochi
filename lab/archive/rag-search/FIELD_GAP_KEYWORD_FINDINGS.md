# Summary 기반 단일 키워드 검색 실험 결과

실험일: 2026-06-10

## 실험 목적

Gemini가 문서의 `summary`만 보고 문서에 직접 포함되지 않은 상위 맥락의 단일 키워드를
생성했을 때, 어떤 임베딩 모델·차원·문서 전략·검색 방식이 기대 문서를 잘 찾는지 비교한다.

예시:

```text
식단 구성 참고 → 다이어트
나중에 방문할 장소 → 나들이
구매할 옷 참고 → 패션
상하이 방문 정보 → 관광
```

## 실험 구성

- Analysis fingerprint: `044ec363`
- 평가 문서 및 쿼리: 46개
- 쿼리 생성 입력: Gemini 분석 결과의 `summary`만 사용
- 쿼리 형식: 공백과 문장부호가 없는 단일 키워드 한 단어
- 쿼리 생성 모델: `gemini-3.1-flash-lite`
- 평가 임베딩 조합: 55개
- 평가 지표: HitRate@3, Recall@5, MRR, nDCG@5
- 결과 파일: `results/field-gap/20260610_035424.json`

생성된 쿼리가 기대 문서의 `{summary, intent, title, topic, organization, note}`에 직접
포함되지 않았는지 검증했으며, 46개 모두 통과했다.

## 핵심 결과

### 최고 단일 조합

| 검색 방식 | 모델 | 차원 | 문서 전략 | HitRate@3 | nDCG@5 |
|---|---|---:|---|---:|---:|
| Vector | `gemini-embedding-001` | 1536 | `summary+labels+payload+entities` | 0.717 | **0.651** |
| Vector | `voyage-4-large` | 1024 | `summary+labels` | 0.717 | 0.644 |
| Vector | `gemini-embedding-001` | 1536 | `structured_fields` | 0.739 | 0.643 |
| Vector | `voyage-4-large` | 1024 | `structured_fields` | 0.696 | 0.643 |

절대 최고점은 `gemini-embedding-001@1536 + summary+labels+payload+entities + Vector`다.
다만 2위와 nDCG@5 차이는 `0.007`로 작다.

### 모델 안정성

각 모델의 모든 차원·문서 전략에 대한 Vector nDCG@5 평균이다.

| 모델 | 평균 nDCG@5 | 최고 nDCG@5 |
|---|---:|---:|
| `voyage-4-large` | **0.620** | 0.644 |
| `gemini-embedding-001` | 0.580 | **0.651** |
| `voyage-4` | 0.561 | 0.585 |
| `text-multilingual-embedding-002` | 0.543 | 0.593 |

`gemini-embedding-001`은 최고점이 가장 높지만 256차원 성능 저하가 커 평균이 낮다.
`voyage-4-large`는 모든 차원과 전략에서 상대적으로 안정적이다.

### 모델 내부 차원 비교

| 모델 | 추천 차원 | 해당 차원 평균 nDCG@5 |
|---|---:|---:|
| `gemini-embedding-001` | 1536 | 0.635 |
| `text-multilingual-embedding-002` | 768 | 0.569 |
| `voyage-4-large` | 1024 | 0.633 |
| `voyage-4` | 256 | 0.569 |

차원은 모델마다 표현 방식이 다르므로 서로 다른 모델 사이에서 숫자만 직접 비교하면 안 된다.

### 문서 전략 안정성

각 전략의 모든 모델·차원에 대한 Vector nDCG@5 평균이다.

| 문서 전략 | 평균 nDCG@5 | 최고 nDCG@5 |
|---|---:|---:|
| `structured_fields` | **0.584** | 0.643 |
| `summary+labels+payload+entities` | 0.581 | **0.651** |
| `summary+labels` | 0.581 | 0.644 |
| `summary+labels+payload` | 0.580 | 0.633 |
| `summary` | 0.568 | 0.638 |

전략 간 평균 차이는 작다. 최고 성능은 모든 정보를 합친 전략이지만,
전반적인 안정성은 `structured_fields`가 근소하게 가장 높았다.

### 검색 방식 비교

| 검색 방식 | 평균 nDCG@5 | 최고 nDCG@5 |
|---|---:|---:|
| Vector | **0.579** | **0.651** |
| RRF | 0.247 | 0.300 |
| BM25 | 0.058 | 0.064 |

이번 쿼리는 의도적으로 문서 필드에 없는 키워드이므로 BM25가 거의 작동하지 않는다.
BM25 결과를 함께 결합한 RRF도 Vector 순위를 크게 훼손했다. 이 조건에서는 Vector 단독이 적합하다.

## 결론

- 최고 성능 우선: `gemini-embedding-001@1536 + summary+labels+payload+entities + Vector`
- 안정성과 단순성 우선: `voyage-4-large@1024 + structured_fields + Vector`
- 더 작은 문서 표현 우선: `voyage-4-large@1024 + summary+labels + Vector`
- field-gap 단일 키워드 검색에서는 BM25와 현재 방식의 RRF를 사용하지 않는 편이 낫다.

## 평가 한계

46개 쿼리 중 고유 키워드는 33개다. `패션`, `문화생활`, `나들이`, `화장품`처럼 같은
키워드가 여러 문서에 연결됐지만, 현재 평가는 각 쿼리 생성 원본 문서 하나만 정답으로 본다.
따라서 동일 키워드의 관련 문서가 상위에 나와도 오답으로 계산되어 실제 사용자 체감보다 점수가
낮을 수 있다.

다음 실험에서는 동일 키워드를 공유하는 문서들을 다중 `expected_ids`로 묶은 평가를 함께 실행해,
특정 문서를 찾는 능력과 관련 문서 묶음을 찾는 능력을 분리해서 판단하는 것이 좋다.
