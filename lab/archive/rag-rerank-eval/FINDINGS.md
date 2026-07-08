---
experiment: rag-rerank-eval
status: done
started: 2026-06-12
last_verified: 2026-07-09
---

# rag-rerank-eval — FINDINGS

검색 파이프라인 A/B/C 성능 비교. 임베딩 설정(모델·차원·input)은 **고정**하고
reranker / hybrid 추가가 Recall@10 을 실제로 개선하는지 측정.

## 2026-07-09 재실행 — voyage-4-large 정정 (⚠️ 우선 읽기)

**배경.** 본 실험의 "고정 조건" 임베딩 모델이 `voyage-3-large` 로 들어갔으나, 모델 선정
실험(`lab/archive/rag-search`)의 결론은 `voyage-4-large@1024`(nDCG@5 0.925, 전 후보 1위)였다.
`voyage-3-large` 는 잘못 들어간 값이라 프로덕션까지 그대로 반영돼 있었다 → `voyage-4-large` 로 정정.

**재실행.** 동일 코퍼스(391)·gold(24)·리랭커로 임베딩만 `voyage-4-large@1024` 로 바꿔 재측정.
voyage-3-large 비교값은 아래 표에 기록. voyage-3-large 문서 임베딩 캐시(`artifacts/doc_emb_voyage-3-large@1024.json`)가 남아 있어 `run_eval.py` 의 `EMB_MODEL` 만 되돌리면 재현된다.

| 파이프라인 | 지표 | voyage-4-large | voyage-3-large | Δ |
|---|---|---|---|---|
| A (Vector) | R@1 | 0.1181 | 0.1528 | -0.035 |
| A (Vector) | R@3 | 0.5868 | 0.4757 | **+0.111** |
| A (Vector) | R@5 | 0.7812 | 0.8160 | -0.035 |
| A (Vector) | MRR | 0.5108 | 0.5604 | -0.050 |
| **B/rerank-2.5** | R@1 | **0.4271** | **0.4271** | **0.000** |
| **B/rerank-2.5** | R@3 | **0.8715** | **0.8715** | **0.000** |
| **B/rerank-2.5** | R@5 | **0.9688** | **0.9688** | **0.000** |
| **B/rerank-2.5** | MRR | **0.8819** | **0.8819** | **0.000** |
| C/rerank-2.5 | 전 지표 | (B 와 동일) | (B 와 동일) | 0.000 |

**결론.**
1. **프로덕션 파이프라인(Vector+rerank-2.5)에서 두 모델은 완전 동일** — 무회귀. 두 모델 모두
   정답을 vec_top50 후보에 100% 넣고(candidate recall 100%), rerank-2.5 가 동일하게 재정렬해
   raw 임베딩 순위 차이를 흡수한다. **교체는 안전.**
2. raw Vector 단독(A)에선 혼재 — voyage-4-large 가 R@3 은 +0.111 우세, R@1/R@5/MRR 은 소폭 열세.
   이 합성 코퍼스는 @10 천장이라 A 단계 미세차는 최종 품질에 영향 없음(리랭커가 동일화).
3. voyage-4-large 채택 근거는 이 실험이 아니라 **실데이터 모델 선정(`rag-search`, nDCG@5 0.925)** 이며,
   본 재실행은 "리랭크 파이프라인에서 회귀가 없다" 는 안전성 확인이다.

## 고정 조건 (사용자 결정)

| 항목 | 값 |
|------|-----|
| 임베딩 모델 | `voyage-4-large` (2026-07-09 정정 — 원 실행은 잘못 들어간 `voyage-3-large`, 위 §정정 참조) |
| 차원 | 1024 |
| 임베딩 input | `summary + labels` (doc=`RETRIEVAL_DOCUMENT`/`input_type=document`, query=`query`) |
| Reranker 비교군 | `rerank-2.5`, `rerank-2.5-lite` |
| BM25 | char bi-gram 토크나이저 (한국어 조사 영향 최소화), k1=1.5 b=0.75 |
| RRF | k=60, recall 통합용 (최종 순위는 reranker) |

## 코퍼스 · 평가셋

- 코퍼스 **391개** — 6 카테고리(뷰티/모빌리티/주거/여행·F&B/전자기기/라이프) 서브에이전트 생성.
  role 분포: answer 49 / hard_neg 100 / filler 242.
  hard negative 3종: ①같은 카테고리 비정답 ②동일 키워드 다른 대상(예: "보조금" 전기차 vs 청년월세) ③의미 유사 다른 조건.
- gold 쿼리 **24개** (짧은 키워드) — 다중정답 19(Recall@10) + 단일정답 5(Hit@10).
- 데이터: `data/corpus.json`, `data/gold.json`. 결과: `results/eval.json`.

## 파이프라인

| | 구성 |
|---|---|
| A | Vector → Top10 |
| B | Vector Top50 → Reranker → Top10 |
| C | Vector Top60 + BM25 Top60 → RRF Top50 → Reranker → Top10 |

## 결과

### Recall@10 (사용자 1차 지표)

| 파이프라인 | Recall@10 | Hit@10 |
|---|---|---|
| A (Vector) | 0.9896 | 1.0000 |
| **B / rerank-2.5** | **1.0000** | 1.0000 |
| B / rerank-2.5-lite | 0.9896 | 1.0000 |
| **C / rerank-2.5** | **1.0000** | 1.0000 |
| C / rerank-2.5-lite | 0.9896 | 1.0000 |

→ **Recall@10 은 전 파이프라인이 0.99~1.0 (천장 효과).** voyage-4-large 가 391개 코퍼스에서
정답을 거의 다 top10 안에 넣어, @10 만으로는 파이프라인 변별이 안 된다.

### 더 엄격한 지표 (천장 아래 실차이)

| 파이프라인 | R@1 | R@3 | R@5 | R@10 | MRR |
|---|---|---|---|---|---|
| A (Vector) | 0.153 | 0.476 | 0.816 | 0.990 | 0.560 |
| **B / rerank-2.5** | **0.427** | **0.872** | 0.969 | 1.000 | **0.882** |
| B / rerank-2.5-lite | 0.375 | 0.833 | 0.938 | 0.990 | 0.808 |
| C / rerank-2.5 | 0.427 | 0.872 | 0.969 | 1.000 | 0.882 |
| C / rerank-2.5-lite | 0.375 | 0.833 | 0.938 | 0.990 | 0.808 |

### 후보단계 진단

- 정답 49개 중 **vec_top50 포함 100%**, rrf_top50 포함 100%.
- **BM25 rescue 0건** — vector top60이 이미 모든 정답을 포함해 BM25가 추가로 건진 정답 없음.

## 결론

1. **Vector 단독 → Vector+Reranker: 큰 개선.**
   Recall@10 은 천장이라 +0.01 에 불과하지만, 상위 순위 품질은 극적 —
   R@1 0.15→0.43 (**+2.8배**), R@3 0.48→0.87, MRR 0.56→0.88.
   reranker 가 vector 가 4~9위에 두던 정답을 1~3위로 끌어올린다(분석1: 거의 모든 쿼리에서 순위 상승,
   '화장품' a_004 는 A top10 밖 → B 8위로 Recall@10 자체도 개선).

2. **Vector+Reranker → Hybrid+Reranker: 이 셋업에선 Recall@10 개선 없음 (B == C).**
   - 원인: vector 후보 recall 이 이미 100% → BM25 가 보탤 정답이 없음(rescue 0건).
   - BM25 는 키워드만 겹치는 **노이즈를 후보에 추가**했고(분석4: '적금'에 6건, '향수' 5건 등),
     reranker 가 그 노이즈를 최종 top10 에서 전부 걸러냄 → **무해하지만 무익**.
   - 부작용: '화장품' a_004 는 RRF 후보 12위였으나 `rerank-2.5-lite` 가 top10 밖으로 탈락(분석5).
     강한 reranker(`rerank-2.5`)는 8위로 유지.

3. **Reranker 모델: `rerank-2.5` > `rerank-2.5-lite`** (R@1 0.43 vs 0.38, MRR 0.88 vs 0.81).
   lite 는 비용·지연이 낮지만 어려운 케이스에서 정답을 놓친다.

### 최종 답 (사용자 질문)

> **"Hybrid + Reranker 가 Vector + Reranker 보다 실제로 Recall@10 을 개선하는가?"**
> → **이 코퍼스·쿼리셋에서는 아니오 (동일).** vector recall 이 이미 천장이라 BM25 의 recall 기여가 0.
> BM25 의 가치는 *임베딩이 약한 쿼리*(고유명사 오타·영문·신조어·코드성 키워드)나 *훨씬 큰/모호한 코퍼스*에서
> 나타나는데, 현재 합성셋은 그 조건을 만들지 못했다.

## 한계 · 다음 단계

- **@10 천장**으로 Recall@10 변별력이 없다. 실차이는 R@1/R@3/MRR 에서만 보인다.
- Hybrid 의 진짜 효과를 보려면 천장을 깨야 함 — (a) 임베딩이 약한 쿼리(오타·영문 모델명·희귀 고유명사),
  (b) 정답과 hard negative 의 의미 거리를 더 좁힘, (c) 코퍼스 1000+ 확장.
- 프로덕션 반영 관점: **Vector + `rerank-2.5`** 가 비용 대비 최적. Hybrid 는 현 데이터분포에선 보류,
  키워드성 쿼리 비중이 높아지면 재평가.

## 프로덕션 반영 (2026-06-12, 2026-07-09 모델 정정)

> **2026-07-09**: 임베딩 모델을 `voyage-3-large` → `voyage-4-large` 로 정정(위 §정정). input·차원·리랭커는 불변.
> 프로덕션 재색인은 `scripts/backfill_embeddings.py`(model_version `voyage-4-large@1024`)로 백필.

확정값(voyage-4-large@1024 · input=summary+labels · rerank-2.5)이 `mochi-backend` 에 반영됨:
- `app/shared/voyage.py` (클라이언트 + `build_embedding_text`), 마이그레이션 0018(768→1024)
- 검색탭 `POST /search`: 기존 BM25+RRF **유지** + rerank-2.5 — 검색탭은 짧은 키워드·고유명사
  질의 분포라 BM25 가 보험(본 실험이 "무해함"을 검증, rescue 는 그 분포에서 재평가).
- 채팅 `search_items`: 키워드(ILIKE) + vector 병합 → rerank-2.5. chat 프롬프트 v7
  (어휘 변주 재검색 지시 제거 — retrieval 이 흡수).
상세: `docs/CHANGELOG.md` 2026-06-12 backend 항목, `docs/ARCHITECTURE.md` §3.4 자연어 검색.

## 재현

```bash
# mochi-backend 디렉토리에서 (VOYAGE_API_KEY in .env)
set -a; source .env; set +a
python ../lab/active/rag-rerank-eval/build_corpus.py     # 코퍼스 병합 + gold
uv run --group lab python ../lab/active/rag-rerank-eval/run_eval.py   # 임베딩(캐시)+평가
python ../lab/active/rag-rerank-eval/analyze.py          # 엄격지표 재집계 + 5개 분석
```
