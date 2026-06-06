---
level: 3
mode: log
status: active
last_verified: 2026-06-05
confidence: 1.0
owners: []
description: text/URL 입력으로 agent loop end-to-end 를 라이브 검증. DB 없이 FakeGateway 로 실행. 실행 중 발견한 이슈·동작 확인 사항을 여기에 기록.
---

# FINDINGS — agent-loop-live

## 개요

`agent_loop_live_test.py` 를 돌리며 발견한 동작 확인·이슈·개선사항을 기록한다.
이미지 입력 검증은 `agent-loop-image-eval/` 에서 담당한다.

## 실행

```bash
GOOGLE_CLOUD_PROJECT=<proj> uv run --directory mochi-backend \
  python lab/active/agent-loop-live/agent_loop_live_test.py

# 특정 URL 단건 테스트
GOOGLE_CLOUD_PROJECT=<proj> uv run --directory mochi-backend \
  python lab/active/agent-loop-live/agent_loop_live_test.py https://...
```

## 변경 이력

| 날짜 | 내용 |
|---|---|
| 2026-06-05 | `VertexAIGeminiClassifier` import 제거 (클래스 삭제됨), `ProfileWindowItem` import 추가 |

## 발견사항

<!-- 실행하며 이슈·확인사항 기록 -->
