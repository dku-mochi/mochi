---
experiment: rag-search
status: running
started: 2026-06-06
---

# rag-search — FINDINGS

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
