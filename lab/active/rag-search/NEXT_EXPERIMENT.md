# 다음 실험: Category 기반 Hybrid Search

상태: 진행 예정

## 목표

문서 임베딩 입력에 `category`만 추가했을 때 Hybrid Search 검색 성능이 얼마나 개선되는지 확인한다.

목표 성능:

- Hybrid Search HitRate 약 80% 이상

## 실험 조건

- Query: `summary`만 보고 Gemini가 생성한 문서 필드 미포함 단일 키워드
- 문서 전략 기준선: 현재 5개 문서 전략의 최고 조합
- 신규 문서 전략: 기준선 문서에 `category`만 추가
- 검색 방식: Hybrid Search
- 비교 범위: Top-4, Top-5

## 평가 항목

- HitRate@4
- HitRate@5
- 기준선 대비 HitRate 증가량
- 기준선 대비 HitRate 증가율
- 기존 Vector 단독 대비 Hybrid Search 개선 여부

증가율 계산:

```text
증가율 = (category 적용 HitRate - 기준선 HitRate) / 기준선 HitRate
```

## Category 구성 원칙

- `건강`, `데이트`, `밥`, `여행`, `패션`처럼 사용자가 검색할 법한 상위 분류어를 사용한다.
- category는 문서마다 하나를 기본으로 한다.
- 동일 category에 속하는 문서들은 해당 category query의 다중 `expected_ids`로 묶는다.
- category query와 category 필드가 정확히 일치하므로 BM25 신호가 생기는 것을 의도한다.

## 진행 순서

1. 46개 문서에 category를 생성하거나 확정한다.
2. 동일 category 문서를 다중 `expected_ids`로 묶은 gold query를 생성한다.
3. category가 포함된 문서 임베딩과 BM25 corpus를 생성한다.
4. Vector 단독과 Hybrid Search를 비교한다.
5. Top-4와 Top-5 HitRate 및 증가율을 계산한다.
6. HitRate 80% 달성 여부와 최적 Hybrid 결합 방식을 기록한다.

## 주의사항

- 기존 field-gap 실험은 문서마다 하나의 expected ID만 사용하여 동일 category 문서가 서로 오답으로
  계산됐다. 다음 실험에서는 반드시 category 단위 다중 정답 평가를 사용한다.
- category가 query에 직접 포함되므로 이번 실험은 semantic-gap 검색이 아니라 category 기반 검색
  성능을 측정한다.
- Hybrid Search의 결합 방식과 가중치는 명시해서 비교한다. 현재 고정 RRF는 field-gap 실험에서
  Vector 성능을 낮췄으므로, 가중치 기반 결합도 함께 검토한다.
