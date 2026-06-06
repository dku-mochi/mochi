---
experiment: rag-search
status: running
started: 2026-06-06
---

# rag-search — FINDINGS

## 실험 목적

"화장품" 쿼리 → "화장품 스크린샷 아이템"이 top-3 안에 들어오는가.
임베딩 모델·차원·문서 전략을 결정해 프로덕션 `EmbedTool` 구현에 반영한다.

## 파이프라인

```
data/cases.json (18개 스크린샷, stable ID)
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
