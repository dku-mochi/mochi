---
experiment: rag-search
status: running
started: 2026-06-06
---

# rag-search — FINDINGS

## 실험 범위 경계

| 실험 | 현재 담당 |
|------|-----------|
| `agent-loop-image-eval` | 이미지 단독 입력의 Gemini intent·summary·tool 품질 |
| **`rag-search` (이 실험)** | 임베딩·검색 품질 + retrieval 실패 진단용 topic/entity 존재 여부 |

> **장기 계획**: `agent-loop-image-eval`을 `agent-loop-input-eval`로 확장해 image+memo / text / URL 등
> 입력 유형별 topic·entity recall도 담당하게 되면, `rag-search`의 `retrieval_diagnostic`은
> 그 결과를 참조하는 구조로 전환한다.

`analyze.py`가 출력하는 `retrieval_diagnostic.avg_intent_recall` 등은 **검색 실패 원인 추적용 진단 메타데이터**다.
분석 품질 결론을 내리거나 leaderboard 지표로 사용하지 않는다.

```
검색 실패
├─ diagnostic에 기대 topic 없음 → upstream 분석 문제 (agent-loop 영역)
└─ diagnostic에 topic 있음      → embedding/retrieval 문제 (이 실험 영역)
```

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
