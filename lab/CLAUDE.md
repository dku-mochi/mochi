# lab — 실험·벤치마크

모찌의 프로토타입·벤치마크 영역. 프로덕션(`mochi-ios/`, `mochi-backend/`)과 분리된 검증 공간이다.

## 구조

- `active/` — 진행 중·현행 실험
  - `extraction-strategy/` — **채팅용 추출 전략 실험** (2026-05-29~). 스크린샷·메모에서 사실/의견/정보를 얼마나·어떤 형태로 뽑을지. A(자유형)·B(구조화)·C(하이브리드) × flash-lite·flash 비교. 잠정 결론: **C + flash-lite**. 리포트는 폴더 내 `*_report.md`.
  - `agent-loop-image-eval/` — **이미지 agent loop eval** (2026-06-05~). 로컬 스크린샷을 GCS 없이 Gemini에 직접 전달해 agent loop 전체를 검증. 평가 항목: 툴 호출 여부·기대 intent 일치·LLM-as-judge summary 점수. 데이터는 `lab/data/screenshot/intent_N/`에 배치 (gitignore). 결과는 `results/YYYYMMDD_HHMMSS.json`. 파일명 컨벤션: `설명_intent1_intent2.PNG` (끝 토큰이 기대 intent). `FINDINGS.md`에 결론·프로덕션 반영 메모 기록.
  - `youtube-enrich/` — **유튜브 메타 추출 실험** (2026-05-29~). 북극성: "사용자가 직접 할 일을 최대한 줄인다". URL→메타(oEmbed 무키 + watch page 전체설명·길이·자막유무)만으로 intent 분류·요약이 되는가 = 사용자 fallback 회피율. 사전조사 결론으로 **멀티모달(영상 토큰화 비용폭발·프리뷰 의존)·자막(클라우드 IP 차단·공식 captions 본인영상만) 제외**, 메타를 1차 경로로. 잠정: 식별 가능한 영상은 메타로 충분(비용 ~$0.0001/건, 무키·공식·지속가능), 진짜 fallback 은 *제목조차 모호한 극소수*(ablation 으로 판정기가 false 도 정확히 가림을 확인). `youtube_enrich_bench.py`(URL→메타 벤치) + `ablation_sufficiency.py`(판정기 민감도) + `image_context_bench.py`(**URL 없는 스크린샷** 2단계: 비전 맥락추출 + 부족시 URL 복원). 리포트는 폴더 내 `*_report.md`.
    - **image_context 결과**(실제 스샷 8장): 비전만으로 맥락 충분 7/8(88%), 비전 단서로 무키검색 videoId 복원 8/8(정확도 채널고려 6/8). 핵심 — *비전 충분 ↔ 복원 정확이 같은 뿌리(화면에 제목·채널 단서 유무)*. 진짜 fallback(1/8)은 영상 전체화면 등 식별 메타가 화면에 없는 경우로, 비전·복원이 동시에 실패(비전이 self-report). URL 복원은 비전 실패를 구제하는 게 아니라 "단서를 읽은 뒤 더 풍부한 메타"용 보강.
- `archive/` — 종료된 실험 (보관용, 경로가 stale 할 수 있음 — 재실행 시 `data/` 경로 확인 필요)
  - `intent-classification/` — 백탭 이미지 의도분류 프롬프트 튜닝 (2026-05-25~27, v3~v6). 프로덕션 `VertexAIGeminiClassifier` 의 v6 프롬프트가 여기서 나왔다. (`SCREENSHOT_DIR` 가 옛 경로라 그대로는 안 돌아감 — 보관 목적.)
- `data/` — 공유 입력 (**gitignore** — 개인 스크린샷·데이터셋은 git 미추적, 별도 공유)
  - `screenshot/` — 테스트 스크린샷
  - `text_memos.json` — 텍스트 메모 데이터셋 (gold label `[구체적 의도, 4-intent]` + reminder_kind)
  - `agent-loop-live/` — **agent loop 라이브 통합 테스트** (text/URL end-to-end). DB 없이 FakeGateway로 실행.

## 실행 (공통)

ADC + `GOOGLE_CLOUD_PROJECT` 필요. `mochi-backend` 의 uv 환경에서 돌린다:

```bash
GOOGLE_CLOUD_PROJECT=<proj> \
  uv run --directory mochi-backend \
  python lab/active/extraction-strategy/extraction_strategy_bench.py --mode both
```

각 실험 폴더의 스크립트 docstring 에 세부 실행법·옵션이 있다.
