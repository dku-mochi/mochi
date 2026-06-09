---
experiment: rag-search
status: running
started: 2026-06-06
---

# rag-search — FINDINGS

> Semantic-gap 재현성 수정 후 최종 결과는 [`SEMANTIC_GAP_FINDINGS.md`](SEMANTIC_GAP_FINDINGS.md)를 기준으로 본다.

## 실험 범위 경계

| 실험 | 담당 |
|------|------|
| `agent-loop-image-eval` | Gemini 분석 품질 — 이미지 단독 입력의 intent·summary·tool |
| **`rag-search` (이 실험)** | 검색 품질 — 문서 전략·모델·차원·BM25/Vector/RRF |

`cases.json`은 입력만 정의하고, 검색 정답은 `gold/queries.json`에서만 정의한다.
검색 실패 원인은 `artifacts/analysis/{fp}.json`의 `summary`/`payload`/`entities`를 직접 확인해 판단한다.

> **장기 계획**: `agent-loop-image-eval`을 확장해 입력 유형별(image+memo/text/URL) 분석 품질도 커버하면
> `rag-search`는 그 결과를 참조하는 구조로 전환 가능하나, 현재 규모에서는 불필요하다.

## 실험 목적

"화장품" 쿼리 → "화장품 스크린샷 아이템"이 top-3 안에 들어오는가.
임베딩 모델·차원·문서 전략을 결정해 프로덕션 `EmbedTool` 구현에 반영한다.

## 파이프라인

```
data/cases.json (lab/data/screenshot 기준 46개 스크린샷, stable ID)
  → analyze.py        artifacts/analysis/{fp}.json
  → embed.py          artifacts/embeddings/{fp}/{model}@{dim}_{strategy}.json
  → eval_retrieval.py results/retrieval/{ts}.json
```

### 실행 (mochi-backend 디렉토리에서)

```bash
# Step 1
GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 \
GOOGLE_APPLICATION_CREDENTIALS="..." \
PYTHONPATH="...mochi-backend" \
uv run python "../lab/active/rag-search/analyze.py"

# Step 2
# Voyage 비교군까지 생성하려면 VOYAGE_API_KEY 도 필요하다.
uv run python "../lab/active/rag-search/embed.py"

# Step 3
uv run --group lab python "../lab/active/rag-search/eval_retrieval.py"
```

## 실험 설계

| 축 | 후보 |
|----|------|
| 임베딩 모델×차원 | text-multilingual-embedding-002@256/768, gemini-embedding-001@256/768/1536 |
| 문서 전략 | summary / summary+labels / summary+labels+payload / summary+labels+payload+entities / structured_fields |
| 검색 방식 | BM25 / Vector / RRF(BM25+Vector) |

평가 지표: HitRate@3, Recall@5, MRR, nDCG@5 — 쿼리 유형별(exact_keyword/semantic_paraphrase/intent_based/entity_based/colloquial) 분리

## 결론 (실험 완료 후 채울 것)

- **선택 모델×차원:**
- **선택 문서 전략:**
- **최적 검색 방식:**
- **avg nDCG@5:**
- **근거:**

## 결과 요약

<!-- eval_retrieval.py 실행 후 results/retrieval/*.json 기반으로 채우기 -->

| 레이블 | HitRate@3 | Recall@5 | MRR | nDCG@5 |
|--------|-----------|----------|-----|--------|
|        |           |          |     |        |

## 프로덕션 반영 체크리스트

- [ ] `EmbedTool.run()` 구현 — 선택 모델, Vertex AI 호출, 차원 설정
- [ ] `mochi_item_worker.py` — analyzed 직후 embedding 저장
- [ ] `postgres_index.py` — `naive_embed` → 실제 embedding 함수
- [ ] `.env` `EMBEDDING_DIM` 값 확인
- [ ] `EmbeddingRow.embedding Vector(N)` 차원 마이그레이션 (필요 시)

## Phase 2 여부

nDCG@5 < 0.7 이면 쿼리 LLM rewrite(확장) 실험 추가.

## 2026-06-10 Semantic Gap Keyword 평가

- retrieval result: `results/retrieval/20260610_025450_semantic_gap.json`
- gold: `gold/semantic_gap_queries.json` (21쿼리 × 25 expected_ids 쌍)
- 누수 검증: **[OK]** — `validate_semantic_gap.py --analysis-fp 044ec363` 통과

### Semantic Gap Keyword 정의

원문(summary/labels/payload/entities/ID)에 직접 등장하지 않지만, 해당 기록을 검색할 때
사용자가 입력할 가능성 있는 상위 개념·동의어 키워드.

예: `memo_접수내역기록`(니콘이미징코리아 A/S 접수) → query=`카메라`

총 21개 유형(딥러닝·다이어트·로맨스영화·대중교통·헬스·영양제·웨어러블·엔화·기본템·통신비·
사후세계·카메라·생일·자외선차단·세금·콘서트·버블티·취업·나들이·피부관리·생산성).

### BM25 완전 붕괴 — 핵심 발견

| 방식 | nDCG@5 | Hit@3 |
|------|--------|-------|
| BM25 | **0.021** | 0.000 |
| Vector (best Google) | **0.798** | 0.810 |
| RRF (BM25+Vector) | 0.252 | 0.333 |

> BM25는 쿼리 키워드가 원문에 없으면 점수를 줄 수 없어 nDCG@5=0.021로 붕괴한다.
> RRF는 BM25 컴포넌트에 끌려 Vector 단독보다 크게 낮다(0.798 → 0.252).
> **시맨틱 갭 쿼리 핸들링에 BM25/RRF는 적합하지 않으며, Vector 단독이 필수다.**

### Google 모델 결과 (상위 5)

| 레이블 | nDCG@5 | Hit@3 | MRR |
|--------|--------|-------|-----|
| `vec:gemini-embedding-001@768 × summary+labels+payload` | **0.798** | 0.810 | 0.773 |
| `vec:gemini-embedding-001@768 × summary+labels+payload+entities` | 0.793 | 0.810 | 0.793 |
| `vec:gemini-embedding-001@768 × summary` | 0.792 | 0.857 | 0.732 |
| `vec:gemini-embedding-001@1536 × summary+labels+payload+entities` | 0.790 | 0.810 | 0.769 |
| `vec:gemini-embedding-001@1536 × summary+labels+payload` | 0.788 | 0.905 | 0.738 |

### Voyage 모델 비교 — 미실행 (VOYAGE_API_KEY 없음)

`summary+labels` vs `summary+semantic_expansion` vs `summary+labels+semantic_expansion` 비교는
VOYAGE_API_KEY 설정 후 재실행 필요:

```bash
# mochi-backend 디렉토리에서
VOYAGE_API_KEY=<key> uv run --group lab python "../lab/active/rag-search/eval_retrieval.py" \
  --analysis-fp 044ec363 --gold semantic-gap --allow-partial
```

### 간접 추론

이전 표준 30쿼리 평가에서 `voyage-4-large@1024`의 `summary+labels+semantic_expansion`은:
- colloquial 유형: **+0.085** 개선
- exact_keyword 유형: -0.064 하락

Semantic gap 쿼리는 본질적으로 "원문에 없는 상위 개념 키워드"이므로 colloquial 개선 패턴과
동일한 맥락이다. Voyage + semantic_expansion 전략이 semantic gap에서도 개선 효과를 보일 가능성
이 높으나, 직접 검증은 VOYAGE_API_KEY 재설정 후 수행 권장.

### 프로덕션 추천

- **Vector 단독 필수** — BM25/RRF는 semantic gap에서 사용 불가 수준
- Voyage API 불가 환경에서 폴백이 필요하면 `gemini-embedding-001@768 × summary+labels+payload`(nDCG@5=0.798)
- semantic gap 처리가 핵심 요건이라면 semantic expansion 전략의 Voyage 비교 재실험 권장

---

## 2026-06-10 Semantic Expansion 실험

- retrieval result: `results/retrieval/20260610_021445.json`
- expansion artifact: `artifacts/expansion/044ec363.json`
- 추가 전략: `summary+semantic_expansion`, `summary+labels+semantic_expansion`
- expansion 생성: `expand.py` — Gemini `gemini-2.0-flash`, 항목당 3~5개, temperature=0

### 생성 방식

analysis artifact의 summary·labels·payload·entities를 Gemini에 입력하여
원문에 직접 등장하지 않는 상위 개념·동의어·관련 맥락 표현을 생성한다.
생성 결과는 Vector embedding 입력에만 추가하고, BM25 corpus에는 포함하지 않는다
(`embed.py`의 `bm25_doc_text` 필드로 분리).

### 기준선 vs 새 전략 비교 (`voyage-4-large@1024`)

| 쿼리 유형 | `summary+labels` (기준선) | `summary+labels+semantic_expansion` | Δ |
|-----------|--------------------------|--------------------------------------|---|
| colloquial | 0.569 | **0.654** | **+0.085** |
| intent_based | 0.924 | **0.935** | +0.011 |
| semantic_paraphrase | 0.945 | 0.941 | -0.004 |
| entity_based | 0.969 | 0.969 | 0.000 |
| exact_keyword | **0.993** | 0.929 | **-0.064** |
| **avg nDCG@5** | **0.925** | 0.909 | -0.016 |

### 해석

- colloquial 쿼리(구어체)는 **+0.085로 가장 큰 개선**. expansion이 원문에 없는 일상 표현을 보완해 semantic gap을 줄인 효과.
- intent_based도 미세 개선(+0.011). 상위 개념 보완이 의미 검색에 기여.
- exact_keyword가 -0.064로 가장 큰 하락. 확장 키워드가 벡터 공간에서 노이즈로 작용해 정확한 키워드 매칭 랭킹을 흐트러뜨린 것으로 보임.
- avg nDCG@5 기준으로 기준선보다 낮음(0.925 → 0.909). exact_keyword 하락 폭이 colloquial 개선 폭보다 크다.

### 적용 추천 여부

**현재 데이터셋 기준: 미채택.** 기존 `voyage-4-large@1024 × summary+labels`(nDCG@5=0.925) 유지.

단, colloquial 쿼리 개선이 실 사용자에게 중요하다면 재검토 여지가 있다:
- 사용자 실제 검색 로그가 쌓이면 쿼리 유형별 비중을 재가중해 평가 반복 권장.
- expansion 품질 향상(더 엄격한 필터 프롬프트, 모델 업그레이드) 후 재실험.

---

## 2026-06-10 512차원 추가 실험

- retrieval result: `results/retrieval/20260610_013007.json`
- 추가 조합: `voyage-4@512`, `voyage-4-large@512` × 5전략 = 10개

### voyage-4-large × summary+labels 차원별 비교

| 차원 | nDCG@5 | HitRate@3 | MRR |
|------|--------|-----------|-----|
| 1024 | **0.925** | 1.000 | 0.944 |
| 512  | 0.876  | 0.933     | 0.905 |
| 256  | 0.800  | 0.933     | 0.810 |

512는 256~1024 사이에 위치. **기존 결론(voyage-4-large@1024 × summary+labels) 변경 없음.**

---

## 2026-06-09 Voyage 포함 최종 결과

실행 결과:

- analysis fingerprint: `044ec363`
- retrieval result: `results/retrieval/20260609_030922.json`
- 입력 데이터: `lab/data/screenshot` 기준 46개
- Gold query: 30개
- 평가 조합: 45개

### 결론

- **선택 모델×차원:** `voyage-4-large@1024`
- **선택 문서 전략:** `summary+labels`
- **선택 검색 방식:** Vector 단독
- **avg nDCG@5:** `0.925`
- **근거:** 기존 1위였던 `text-multilingual-embedding-002@256 × structured_fields`의 `nDCG@5=0.899`보다 높고, `HitRate@3=1.000`, `MRR=0.944`로 상위 랭킹 품질도 가장 좋았다.

### 상위 결과

| Rank | Label | HitRate@3 | Recall@5 | MRR | nDCG@5 |
|------|-------|-----------|----------|-----|--------|
| 1 | `vec:voyage-4-large@1024 × summary+labels` | 1.000 | 0.943 | 0.944 | 0.925 |
| 2 | `vec:voyage-4-large@1024 × summary+labels+payload+entities` | 0.967 | 0.930 | 0.919 | 0.903 |
| 3 | `vec:voyage-4@1024 × summary+labels+payload` | 0.967 | 0.939 | 0.914 | 0.903 |
| 4 | `vec:voyage-4-large@1024 × structured_fields` | 0.967 | 0.930 | 0.925 | 0.902 |
| 5 | `vec:voyage-4-large@1024 × summary+labels+payload` | 0.967 | 0.930 | 0.919 | 0.902 |
| 6 | `vec:text-multilingual-embedding-002@256 × structured_fields` | 0.967 | 0.938 | 0.919 | 0.899 |

### 해석

- 현재 데이터셋에서는 Voyage 계열, 특히 `voyage-4-large@1024`가 가장 좋다.
- 문서 전략은 정보를 많이 넣는 `payload/entities`보다 `summary+labels`가 더 좋았다. 검색 문서는 과도하게 길게 만들기보다 핵심 요약과 intent label 정도로 압축하는 쪽이 유리해 보인다.
- BM25와 RRF는 이번 데이터셋에서 Vector 단독보다 낮았다. 현재는 Vector 단독을 우선 적용하고, 이후 실제 사용자 쿼리가 늘어난 뒤 hybrid/RRF 재평가가 맞다.
- 평가 중 일부 `voyage-4@1024` 조합은 Voyage API 429로 실패했지만, 최상위 결론은 `voyage-4-large@1024` 조합에서 나왔기 때문에 현재 추천에는 큰 영향이 없다.
