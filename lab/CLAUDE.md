# lab — 실험·벤치마크

모찌의 프로토타입·벤치마크 영역. 프로덕션(`mochi-ios/`, `mochi-backend/`)과 분리된 검증 공간이다.

## 구조

- `active/` — 진행 중인 실험
  - `agent-loop-image-eval/` — **이미지 agent loop eval** (2026-06-05~). 로컬 스크린샷을 GCS 없이 Gemini에 직접 전달해 agent loop 전체를 검증. 평가 항목: 툴 호출 여부·기대 intent 일치·LLM-as-judge summary 점수. 데이터는 `lab/data/screenshot/intent_N/`에 배치 (gitignore). 결과는 `results/YYYYMMDD_HHMMSS.json`. 파일명 컨벤션: `설명_intent1_intent2.PNG` (끝 토큰이 기대 intent). `FINDINGS.md`에 결론·프로덕션 반영 메모 기록.
  - `agent-loop-live/` — **agent loop 라이브 통합 테스트** (text/URL end-to-end). DB 없이 FakeGateway로 실행.

- `archive/` — 종료된 실험 (보관용, 경로가 stale 할 수 있음 — 재실행 시 `data/` 경로 확인 필요)
  - `extraction-strategy/` — **추출 형식 비교** (2026-05-29, 종료). A(자유형)·B(구조화)·C(하이브리드) × flash-lite·flash 비교. 결론: **C + flash-lite** → `system_prompts.py` 반영.
  - `youtube-enrich/` — **유튜브 메타 추출 실험** (2026-05-29, 종료). 자막·멀티모달 제외, 메타(oEmbed + watch page) 1차 경로 확정. 결론: 메타만으로 충분 → `PlatformContextTool` 반영.
  - `intent-schema-decision/` — **intent 스키마 결정** (2026-06-04, 종료). score_flat vs intent_instances 비교. 결론: `intent_instances + needs_review + review_options` → 빅뱅 반영.
  - `intent-classification/` — **백탭 이미지 의도분류 프롬프트 튜닝** (2026-05-25~27, 종료). v3~v6 프롬프트 튜닝. 결론: v6 → `system_prompts.py` 초기 버전 출처.

- `data/` — 공유 입력 (**gitignore** — 개인 스크린샷·데이터셋은 git 미추적, 별도 공유)
  - `screenshot/intent_N/` — 이미지 eval용 스크린샷 (파일명: `설명_intent.PNG`)
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
```

각 실험 폴더의 스크립트 docstring 에 세부 실행법·옵션이 있다.
