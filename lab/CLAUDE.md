# lab — 실험·벤치마크

모찌의 프로토타입·벤치마크 영역. 프로덕션(`mochi-ios/`, `mochi-backend/`)과 분리된 검증 공간이다.

## 구조

- `active/` — 진행 중인 실험
  - `agent-loop-image-eval/` — **이미지 agent loop eval** (2026-06-05~). 로컬 스크린샷을 GCS 없이 Gemini에 직접 전달해 이미지 단독 입력의 agent loop 분석 품질을 검증. 평가 항목: Gold Intent vs 예측 Intent(Recall/Precision/Exact), 사람이 파일명에 적은 실제 저장 의도 ↔ Agent 분석 결과 의미 정합성(LLM Judge), contradiction/skip/error. 데이터는 `lab/data/screenshot/` 한 폴더에 배치한다(gitignore). 파일명 컨벤션: `<intent...>_<actual_intention>.<ext>` — 앞쪽의 연속된 `schedule|todo|knowledge|memo` 토큰이 Gold Intent, 이후가 실제 저장 의도. 결과는 `results/YYYYMMDD_HHMMSS.json`이며 `FINDINGS.md`에 요약이 자동 추가된다.
  - `agent-loop-live/` — **agent loop 라이브 통합 테스트** (text/URL end-to-end). DB 없이 FakeGateway로 실행.
  - `shopping-product-link/` — **쇼핑 캡처 → 구매 링크** (2026-06-13~). exp1: 캡처에서 상품을 검색어 수준으로 식별 가능한지 (flash-lite vs 3.5-flash + LLM judge), exp2: 상품명으로 커머스 "검색된 상태" URL(쿠팡/네이버) 도달성. 결론·반영 스케치는 `FINDINGS.md`.
  - `rag-search/` — **RAG 검색 실험** (2026-06-06~). `lab/data/screenshot` 기반 케이스를 Gemini Agent로 분석한 뒤, 분석 결과를 여러 문서 전략·임베딩 모델·차원으로 임베딩하고 BM25/Vector/RRF 검색 품질을 평가한다. `data/cases.json`은 입력만, `gold/queries.json`은 사람이 정의한 검색어와 기대 결과만 담는다. 분석/임베딩/검색 결과 artifact는 gitignore.

- `archive/` — 종료된 실험 (보관용, 경로가 stale 할 수 있음 — 재실행 시 `data/` 경로 확인 필요)
  - `extraction-strategy/` — **추출 형식 비교** (2026-05-29, 종료). A(자유형)·B(구조화)·C(하이브리드) × flash-lite·flash 비교. 결론: **C + flash-lite** → `system_prompts.py` 반영.
  - `youtube-enrich/` — **유튜브 메타 추출 실험** (2026-05-29, 종료). 자막·멀티모달 제외, 메타(oEmbed + watch page) 1차 경로 확정. 결론: 메타만으로 충분 → `PlatformContextTool` 반영.
  - `intent-schema-decision/` — **intent 스키마 결정** (2026-06-04, 종료). score_flat vs intent_instances 비교. 결론: `intent_instances + needs_review + review_options` → 빅뱅 반영.
  - `intent-classification/` — **백탭 이미지 의도분류 프롬프트 튜닝** (2026-05-25~27, 종료). v3~v6 프롬프트 튜닝. 결론: v6 → `system_prompts.py` 초기 버전 출처.

- `data/` — 공유 입력 (**gitignore** — 개인 스크린샷·데이터셋은 git 미추적, 별도 공유)
  - `screenshot/` — 이미지 eval·RAG 검색 실험용 스크린샷 (파일명: `<intent...>_<actual_intention>.<ext>`)
  - `text_memos.json` — 텍스트 메모 데이터셋 (gold label)

## 실행 (공통)

ADC + `GOOGLE_CLOUD_PROJECT` 필요. `mochi-backend` 의 uv 환경에서 돌린다:

```bash
# 이미지 eval
GOOGLE_CLOUD_PROJECT=<proj> uv run --directory mochi-backend \
  python lab/active/agent-loop-image-eval/eval.py

# text/URL 라이브 테스트
GOOGLE_CLOUD_PROJECT=<proj> uv run --directory mochi-backend \
  python lab/active/agent-loop-live/agent_loop_live_test.py

# RAG 검색 실험
GOOGLE_CLOUD_PROJECT=<proj> uv run --directory mochi-backend \
  python ../lab/active/rag-search/analyze.py

uv run --directory mochi-backend \
  python ../lab/active/rag-search/embed.py

uv run --directory mochi-backend --group lab \
  python ../lab/active/rag-search/eval_retrieval.py
```

각 실험 폴더의 스크립트 docstring 에 세부 실행법·옵션이 있다.
