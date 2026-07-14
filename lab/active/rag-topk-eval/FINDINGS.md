---
experiment: rag-topk-eval
status: done
started: 2026-07-14
last_verified: 2026-07-14
---

# rag-topk-eval — FINDINGS

`rag-rerank-eval`(391 items, @10 천장)의 한계 (a)(b)(c) 후속 — **4V 증강 코퍼스 1,045 아이템에서
TOP_K 8 vs 25 를 처음 실측**해 "TOP_K=25 방침 상향"(CHANGELOG 2026-07-09)의 근거 공백을 메웠다.

## 결론 먼저

1. **TOP_K=25 상향은 실측으로 정당하다.** 프로덕션 채팅 형상(파이프라인 C)에서 recall@8 0.800 →
   recall@25 0.958 (**+15.8pt**, 감사 라벨). 이득의 원천은 L-tier(정답 8~13개 컬렉션 질의):
   0.627 → 0.896 (**+26.9pt**). 설계 라벨 민감도 런에서도 동일 방향(0.530 → 0.857, +32.8pt).
2. **TOP_K=8 은 컬렉션 질의에서 구조적 천장이었다.** 정답 n>8 이면 recall@8 의 수학적 상한이
   8/n — L-tier 이론 상한이 0.892(감사)/0.839(설계)라 랭킹이 완벽해도 8 슬롯으로는 못 담는다.
   실측(0.627)은 상한보다도 낮아 슬롯 부족 + 딥랭크(9~25위 정답) 손실이 겹쳐 있었다.
3. **@15 → @25 한계효용도 살아 있다** — 전체 +3.5pt, L-tier +8.0pt(설계 라벨 +11.9pt).
   @25 에서 후보 recall(rrf_top50 0.952) 부근까지 포화 — **다음 병목은 K 가 아니라
   RERANK_CANDIDATES=50** (더 올리려면 후보 폭 확장이 지렛대).
4. S-tier(정답 1~3)는 @8 에서 이미 0.875~1.0 — TOP_K 는 정밀 회상에 무영향. 상향의 비용
   (컨텍스트 토큰)은 컬렉션 질의가 있을 때만 대가를 지불한다.
5. BM25 rescue 는 이번에도 1건 — 이 분포에선 hybrid 의 recall 기여가 여전히 근사 0
   (rag-rerank-eval 결론 재확인).
6. **세 라벨 변형(감사/pool 보정/dup-그룹)이 전부 같은 결론** — codex P1-1(감사 범위 밖
   cross-batch 정답) pooling 보정 후 C @8 0.807 → @25 0.966(+15.9pt), L-tier +28.8pt 로
   오히려 강화. 재저장 dup 이중가중을 제거한 그룹 채점도 동형(@8 0.807 → @25 0.972).

## 4V 코퍼스 (data/stats.json)

| 축 | 실측 |
|---|---|
| Volume | 1,045 items (answer 270 / hard_neg 216 / filler 559) · 쿼리 50 (S12 / M22 / L16) |
| Variety | 페르소나 6 (123~215) × 도메인 12+ × 타입 screenshot 648 / memo 236 / link 161 × 문체 혼합 · hard_neg 는 배치별 의미거리 설계(config.py hard_neg_note) |
| Velocity | captured_at 6개월(2026-01~07) 최근 편중(6월 250) · 배치 수집 창 · 재저장 근사중복 17 · occurs 296 |
| Veracity | ①결정적: id 유일·role 수 일치·unexpected near-dup **0** ②독립 감사: 생성 flash-lite ≠ 검증 **gemini-3.5-flash** 전수 qrels 감사 — demote 43 / promote 21 (audit_report.json) |

감사 소견: promote 는 대부분 정당(생성기가 hard_neg 스펙을 어기고 사실상 정답을 만든 케이스를
judge 가 회수 — 예 S06 "맥북 M4 Pro 16인치 상세 스펙"), demote 일부는 문언적 과협소 해석 여지
(L07 "노트북 비교"에서 개별 후보 기록 제외). 그래서 **양 라벨셋 모두로 측정**해 결론의 강건성을
확보했다 — 방향·크기 모두 일치.

## 측정 (voyage-4-large@1024 · rerank-2.5 · K∈{8,10,15,25})

파이프라인: A Vector→TopK / B Vec50→rerank→TopK / C Vec60+BM25 60→RRF50→rerank→TopK(채팅 형상).

### 감사 라벨 (results/eval.json — 1차 기준)

| pipe | R@8 | R@10 | R@15 | R@25 | MRR | nDCG@25 |
|---|---|---|---|---|---|---|
| A | 0.8511 | 0.8902 | 0.9314 | 0.9574 | 0.865 | 0.850 |
| B | 0.7985 | 0.8763 | 0.9243 | 0.9513 | 0.824 | 0.821 |
| **C** | **0.8003** | **0.8848** | **0.9236** | **0.9582** | 0.827 | 0.826 |

C 티어별: S 0.875→1.0→1.0→1.0 · M 0.886→0.927→0.961→0.981 · **L 0.627→0.741→0.816→0.896**.
후보 recall: vec_top50 0.964 · rrf_top50 0.952 · BM25 rescue 1.

### 설계 라벨 (results/eval_designed.json — 민감도)

C 전체 0.785→0.831→0.888→0.937 · **L 0.530→0.622→0.738→0.857**. 동일 결론.

### codex 리뷰 → 보정 런 (results/eval_poolfix.json)

`codex exec`(read-only·medium) 리뷰 결과 P0 없음, P1 4·P2 5·P3 1. 실측 타당성을 위협하는
P1-1(qrels 감사가 해당 배치만 봐서 filler/타배치의 진짜 정답이 miss 로 채점될 위험)은
**retrieval-pooled 보정**으로 해소 — A/B/C top-25 합집합의 무라벨 1,272개를 독립 judge 로
전수 판정(추가 정답 92개, 31개 쿼리), 저장 랭킹을 재채점:

| 라벨 | C @8 | C @10 | C @15 | C @25 | L @8 | L @25 |
|---|---|---|---|---|---|---|
| 감사(1차) | 0.8003 | 0.8848 | 0.9236 | 0.9582 | 0.627 | 0.8955 |
| **pool 보정** | 0.8069 | 0.8717 | 0.9289 | **0.9661** | 0.6243 | **0.9127** |
| pool+dup그룹 | 0.8069 | 0.8749 | 0.9322 | 0.9718 | — | — |

나머지 반영: 임베딩 캐시 내용해시 키(P1-2)·gold_audited 세대 스탬프 검증+부재 시 에러(P1-3/4)·
MRR@25 깊이 통일(P2, **이후 런부터** — 본 문서 1차 표의 MRR 은 A=25/B·C=50 혼합 깊이라 참고치)·
`hash()` → crc32 시드(P2)·stale 샤드 가드(P2). 생성 자체(temperature 1.0)는 비재현 —
**샤드가 동결 산출물**이며 회귀 기준은 corpus sha256(audit_meta.json). dup 이중가중(P2)은
의도된 "저장 레코드 회수" 의미론(expected 의 6.5%)이고 그룹 채점 변형으로 영향 없음을 실측.

### 관찰 (부차)

- 이 코퍼스에선 raw Vector(A)가 @8 에서 C 보다 소폭 높다 — 다정답 컬렉션 질의의 macro-recall
  평균에서 reranker 가 꼬리 정답 일부를 hard_neg 아래로 내리는 비용. 단일정답 정밀도(R@1~3)가
  승부처였던 rag-rerank-eval 과 지표 축이 다르니 **reranker 무용으로 읽지 말 것**(전 실험이
  R@1 +2.8배를 실측). 후속 재현 시 R@1/R@3 병기 권장.

## 재현

```bash
# mochi-backend 디렉토리에서 (ADC + GOOGLE_CLOUD_PROJECT + VOYAGE_API_KEY in .env)
set -a; source .env; set +a
uv run --group lab python ../lab/active/rag-topk-eval/gen_corpus.py            # 68 배치(flash-lite)
uv run --group lab python ../lab/active/rag-topk-eval/build_corpus.py          # 병합+결정적 검증
uv run --group lab python ../lab/active/rag-topk-eval/verify_qrels.py          # 독립 감사(3.5-flash)
uv run --group lab python ../lab/active/rag-topk-eval/run_eval.py              # 감사 라벨 측정
uv run --group lab python ../lab/active/rag-topk-eval/run_eval.py --gold designed  # 민감도
uv run --group lab python ../lab/active/rag-topk-eval/audit_pool.py               # pool 보정 재채점
```

생성 경위: 68 배치 중 65 성공 → S03/S05/S06 3개는 "정답 1개" 스펙을 flash-lite 가 초과 생성해
3회 실패 → `--only` 교정 재시도(스펙 위반 사유를 프롬프트에 명시)로 2차에 성공.
