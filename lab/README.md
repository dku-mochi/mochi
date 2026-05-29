# lab — 실험·벤치마크

모찌의 프로토타입·벤치마크 영역. 프로덕션(`mochi-ios/`, `mochi-backend/`)과 분리된 검증 공간이다.

## 구조

- `active/` — 진행 중·현행 실험
  - `extraction-strategy/` — **채팅용 추출 전략 실험** (2026-05-29~). 스크린샷·메모에서 사실/의견/정보를 얼마나·어떤 형태로 뽑을지. A(자유형)·B(구조화)·C(하이브리드) × flash-lite·flash 비교. 잠정 결론: **C + flash-lite**. 리포트는 폴더 내 `*_report.md`.
- `archive/` — 종료된 실험 (보관용, 경로가 stale 할 수 있음 — 재실행 시 `data/` 경로 확인 필요)
  - `intent-classification/` — 백탭 이미지 의도분류 프롬프트 튜닝 (2026-05-25~27, v3~v6). 프로덕션 `VertexAIGeminiClassifier` 의 v6 프롬프트가 여기서 나왔다. (`SCREENSHOT_DIR` 가 옛 경로라 그대로는 안 돌아감 — 보관 목적.)
- `data/` — 공유 입력 (**gitignore** — 개인 스크린샷·데이터셋은 git 미추적, 별도 공유)
  - `screenshot/` — 테스트 스크린샷
  - `text_memos.json` — 텍스트 메모 데이터셋 (gold label `[구체적 의도, 4-intent]` + reminder_kind)
- `agent_loop_live_test.py` — agent orchestrator 라이브 통합 테스트 (text/URL end-to-end)

## 실행 (공통)

ADC + `GOOGLE_CLOUD_PROJECT` 필요. `mochi-backend` 의 uv 환경에서 돌린다:

```bash
GOOGLE_CLOUD_PROJECT=<proj> \
  uv run --directory mochi-backend \
  python lab/active/extraction-strategy/extraction_strategy_bench.py --mode both
```

각 실험 폴더의 스크립트 docstring 에 세부 실행법·옵션이 있다.
