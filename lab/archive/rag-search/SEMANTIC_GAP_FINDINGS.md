# Semantic Gap 검색 실험 결과

실험일: 2026-06-10

## 실험 목적

기록의 원문과 기존 분석 결과에는 직접 포함되지 않았지만, 사용자가 검색할 가능성이 높은
연관 키워드로 검색했을 때 semantic expansion이 검색 성능을 개선하는지 확인한다.

예시:

```text
식단 기록 → 다이어트
교통비 지원 기록 → 대중교통
카메라 수리 접수 기록 → 카메라
공차 할인 기록 → 버블티
```

`semantic-gap` 쿼리는 문장형 검색어가 아니라 한 단어 또는 짧은 명사구 형태의 키워드다.
각 키워드는 기대 문서의 다음 필드에 직접 포함되지 않는지 검증했다.

- 원본 입력과 사용자 메모
- 파일명과 ID
- Gemini summary
- intent labels
- payload
- entities

Semantic expansion 결과는 누수 검사 대상에서 제외했다.

## 실험 구성

- Analysis fingerprint: `044ec363`
- 평가 기록: 46개
- Semantic-gap 키워드 쿼리: 21개
- 기대 문서 연결: 25쌍
- 임베딩 조합: 77개
- Expansion 생성 모델: `gemini-3.1-flash-lite`
- Expansion 생성 리전: `global`
- 평가 지표: HitRate@3, Recall@5, MRR, nDCG@5

## 재현성 문제 및 수정

최초 실행에서는 실패한 백그라운드 `expand.py` 프로세스가 정상 expansion artifact를 빈 결과로
덮어쓰는 문제가 발견됐다. 또한 embedding 캐시가 analysis hash만 검사하여 이전 expansion으로
생성한 벡터를 재사용할 수 있었다.

다음과 같이 수정했다.

- `expand.py`에 동시 실행 잠금과 원자적 파일 저장 추가
- expansion 모델, 리전, 프롬프트 기반 config hash 추가
- expansion 46개가 모두 존재하지 않으면 `embed.py` 즉시 중단
- embedding artifact에 expansion hash를 기록하고 변경 시 재생성
- 존재하지 않는 expected ID가 있으면 누수 검증 실패 처리

검증 결과:

- `py_compile`: 통과
- `ruff check`: 통과
- 누수 검증: 21개 쿼리 × 25개 기대 문서 연결 모두 통과
- Semantic expansion: 46개 생성 완료
- Embedding artifact: 77개 조합 생성 완료
- 재실행 시 expansion 46개와 embedding 77개 모두 정상적으로 캐시 사용

## Semantic Gap 평가 결과

결과 파일:
`results/retrieval/20260610_030744_semantic_gap.json`

### Voyage-4-large@1024 비교

| 문서 전략 | HitRate@3 | Recall@5 | MRR | nDCG@5 | 기준선 대비 |
|---|---:|---:|---:|---:|---:|
| `summary+labels` | 0.905 | 0.937 | 0.850 | 0.862 | 기준선 |
| `summary+semantic_expansion` | 1.000 | 1.000 | 0.889 | 0.920 | +0.058 |
| `summary+labels+semantic_expansion` | 1.000 | 1.000 | 0.889 | 0.920 | +0.058 |

Expansion을 적용했을 때 21개 semantic-gap 키워드 모두 기대 문서가 Top-3 안에 포함됐다.

### 기대 문서 최고 순위 분포

| 기대 문서 최고 순위 | `summary+labels` | `summary+semantic_expansion` |
|---|---:|---:|
| 1위 | 16개 | 17개 |
| 2위 | 3개 | 2개 |
| 3위 | 0개 | 2개 |
| 4위 | 0개 | 0개 |
| 5위 | 1개 | 0개 |
| Top-5 밖 | 1개 | 0개 |

### 순위가 개선된 키워드

| 검색 키워드 | 기존 순위 | Expansion 적용 순위 |
|---|---:|---:|
| `대중교통` | Top-5 밖 | 3위 |
| `카메라` | 2위 | 1위 |
| `버블티` | 5위 | 3위 |

### Semantic Gap 전용 최고 조합

```text
gemini-embedding-001@1536 × summary+semantic_expansion

1위: 18개
2위: 2개
3위: 1개
Top-5 밖: 0개
nDCG@5: 0.930
```

Semantic-gap 키워드만 평가하면 `gemini-embedding-001@1536`이 가장 좋은 결과를 보였다.

## 기존 일반 쿼리 평가 결과

결과 파일:
`results/retrieval/20260610_030849.json`

| 문서 전략 (`voyage-4-large@1024`) | nDCG@5 | 기준선 대비 |
|---|---:|---:|
| `summary+labels` | 0.925 | 기준선 |
| `summary+labels+semantic_expansion` | 0.909 | -0.016 |

쿼리 유형별 주요 변화:

| 쿼리 유형 | `summary+labels` | Expansion 적용 | 변화 |
|---|---:|---:|---:|
| colloquial | 0.569 | 0.654 | +0.085 |
| intent_based | 0.924 | 0.935 | +0.011 |
| semantic_paraphrase | 0.945 | 0.941 | -0.004 |
| entity_based | 0.969 | 0.969 | 0.000 |
| exact_keyword | 0.993 | 0.929 | -0.064 |

Expansion은 구어체와 원문에 없는 연관 키워드 검색에는 효과적이지만, 정확한 키워드 검색에서는
관련 표현이 노이즈로 작용하여 순위 품질이 낮아졌다.

## 결론

Semantic expansion은 원문에 없는 연관 키워드 검색에서 명확한 개선 효과가 있다.

하지만 모든 기록의 기본 임베딩에 expansion을 항상 포함하면 exact keyword 검색 성능이 하락하여
전체 평균 검색 품질이 낮아진다.

현재 권장 설정:

```text
기본 검색 인덱스:
voyage-4-large@1024 × summary+labels

Semantic-gap 전용 후보:
gemini-embedding-001@1536 × summary+semantic_expansion
```

프로덕션에는 기존 `summary+labels`를 기본 검색 인덱스로 유지하는 것이 적절하다.
후속 실험에서는 semantic-gap 성격의 쿼리를 판별하여 expansion 인덱스를 선택하거나,
기본 Vector 결과와 expansion Vector 결과를 별도로 결합하는 방식을 비교해야 한다.
