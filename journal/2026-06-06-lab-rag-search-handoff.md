---
title: "lab 구조 정비 + 환경 연동 확인 + RAG 검색 실험 방향 설정"
date: 2026-06-06
branch: lab/local-image-eval
status: in-progress
scope: lab, backend
---

# lab 구조 정비 + 환경 연동 확인 + RAG 검색 실험 방향 설정 — Handoff (2026-06-06)

## 0. TL;DR (한 화면)

- `lab/local-image-eval` 브랜치로 전환, lab 구조를 `data/screenshot/intent_N/` 포함 최종안으로 정비
- `agent-loop-live` 테스트 3케이스(text×2, url×1) 모두 통과 → Gemini + 백엔드 연동 정상 확인
- Windows 환경 셋업 보정 커밋(`tzdata` + `stat` 호환) 푸시 완료
- 다음 실험 방향 확정: **RAG 검색 + 채팅 탭** — 텍스트 임베딩 기반, 이미지 임베딩 ㄴㄴ, LLM-as-judge 평가 포함
- 현재 `search` 모듈은 `naive_embed`(zero vector) fallback 상태 — 실제 Gemini 임베딩 미연결

---

## 1. 대화 흐름 — 어떻게 여기까지 왔는가

1. **lab 구조 리뷰** — `develop` 브랜치의 현재 lab 구조 확인. `active/` 3개, `archive/` 1개, 루트에 떠도는 `agent_loop_live_test.py`.
2. **새 구조 제안·검토** — `data/screenshot/intent_N/` (N = 기대 intent 개수), `active/CHANGES.md` 위치 질문, 루트 파일 처리 논의.
3. **`lab/local-image-eval` 브랜치 전환** — 원격 브랜치가 이미 proposed보다 앞서 있었음 (intent-schema-decision 등 이미 archive 이관, agent-loop-live 폴더화).
4. **data 디렉터리 재구성** — 기존 18장 한글명 파일 → `data/legacy/`, `data/screenshot/intent_1~4/` 빈 폴더 생성, `__MACOSX` 찌꺼기 삭제. (gitignore 영역이라 커밋 없음)
5. **agent-loop-live 테스트 실행** — PYTHONPATH + PYTHONIOENCODING 환경변수 조합으로 Windows에서 성공. 3케이스 모두 pass.
6. **어제 미커밋 변경 발굴·커밋·푸시** — `tzdata` Windows 의존성, `stat` 호환, `alembic.ini` 주석 영문화.
7. **다음 방향 논의** — RAG 검색+채팅 실험, SSE 관찰 도구, LLM-as-judge 방향 합의 → handoff 요청.

---

## 2. 현재 코드 상태

**현재 브랜치: `lab/local-image-eval`** (develop 3커밋 앞)

### 변경된 파일 (이 브랜치 전체, develop 대비)

```
lab/CLAUDE.md                                ← 신규 (lab 전용 가이드)
lab/active/agent-loop-image-eval/eval.py     ← 신규 (이미지 eval 메인)
lab/active/agent-loop-image-eval/lab_gemini_client.py ← 신규
lab/active/agent-loop-image-eval/FINDINGS.md ← 신규
lab/active/agent-loop-live/agent_loop_live_test.py    ← 이동+정리 (루트→폴더)
lab/active/agent-loop-live/FINDINGS.md       ← 신규
lab/archive/{extraction-strategy,intent-schema-decision,youtube-enrich}/ ← active→archive 이관
lab/archive/intent-classification/results/   ← results/ 서브폴더 분리
.claude/hooks/stop-summary.sh                ← stat Linux/macOS 호환
mochi-backend/pyproject.toml                 ← tzdata Windows 의존성 추가
mochi-backend/uv.lock                        ← 잠금파일 갱신
mochi-backend/alembic.ini                    ← 주석 영문화
```

**작동 가능 여부:** agent-loop-live 3케이스 통과, DB 없이 FakeGateway로 실행. 이미지 eval(`agent-loop-image-eval`)은 `data/screenshot/intent_N/`에 이미지 없어 아직 실행 불가.

---

## 3. codex 검증 결과

이 세션에서 code-reviewer / qa-validator 호출 없음.

agent-loop-live 테스트 결과 (수동 실행):

| 케이스 | 입력 | intent | needs_review | 판정 |
|--------|------|--------|--------------|------|
| text | 운영체제 과제 마감 (23:59) | schedule | false | ✅ |
| text + memo | LangChain ReAct + "발표 준비 참고" | knowledge | false | ✅ |
| url | ko.wikipedia.org/wiki/대규모_언어_모델 | knowledge | false | ✅ (WebFetch 툴 호출 확인) |

---

## 4. 결정 / trade-off

| 결정 | 이유 |
|------|------|
| `intent_N` = 기대 intent **개수** (1~4), 타입 아님 | eval.py 로직이 폴더명을 개수 힌트로 사용, 파일명 끝에 intent 타입 토큰 붙임 |
| 기존 18장 한글명 파일 → `legacy/` 보존 | 재명명 없이 보존, 새 실험엔 올바른 명명규칙(`설명_intent.PNG`)으로 새 파일 사용 |
| Windows tzdata 의존성 조건부 추가 | macOS/Linux는 시스템 tzdata 있어 불필요, Windows만 타겟 |
| 이미지 임베딩 ㄴㄴ | 비용·복잡도 대비 효과 불확실, 텍스트 임베딩(summary+entities)으로 먼저 검증 |

---

## 5. 미완 결정

1. **`active/CHANGES.md` 추가 여부** — lab 전체 실험 변경 로그를 `lab/` 루트에 둘지, 각 실험 `FINDINGS.md`로 충분한지 아직 결정 안 됨.
2. **RAG 실험 이름/폴더** — `active/rag-search/`? `active/search-chat/`? 아직 미정.
3. **SSE 관찰 도구 범위** — 백엔드 API의 스트리밍 엔드포인트를 새로 만들지, 아니면 lab 테스트 레벨에서 이벤트를 프린트하는 수준인지.

---

## 6. 다음 단계 + 검증 기준

### 즉시 할 것

1. **새 lab 실험 폴더 생성** `lab/active/rag-search/`
   - `eval.py` — 쿼리 셋 → 벡터 서치 → LLM-as-judge 점수
   - 검증: "화장품" 쿼리 → "올리브영 숏츠 영상" 관련 아이템 top-3 안에 들어오는가

2. **임베딩 연결** — `naive_embed`(zero vector) → 실제 `text-embedding-005` 연결
   - 파일: `mochi-backend/app/modules/search/infrastructure/postgres_index.py`
   - `EmbeddingTool` (이미 `tools/embedding.py` 있음) 재사용 여부 확인

3. **무엇을 임베딩할지 결정** — `summary`만? `summary + entities + label`을 concat? 실험으로 비교
   - 핵심 가설: "올리브영 숏츠 영상"의 summary가 "화장품"과 코사인 유사도가 높아야 함

4. **SSE 관찰 도구** — `agent-loop-live` 수준에서 tool call 이벤트를 실시간 프린트하는 래퍼 먼저

### 검증 기준

- 쿼리 "화장품" → 저장된 뷰티 관련 아이템이 top-5 안에 포함
- LLM judge 점수 ≥ 3.5 / 5.0 (정답 아이템 vs 쿼리 관련성)
- BM25 단독 vs 벡터 단독 vs hybrid(RRF) 비교표 작성

---

## 7. 컨텍스트 부채 (다음 세션이 먼저 봐야 할 것)

| 파일 | 왜 봐야 하는가 |
|------|---------------|
| `mochi-backend/app/modules/search/infrastructure/postgres_index.py` | `naive_embed` fallback 위치, 실제 임베딩 wire 포인트 |
| `mochi-backend/app/modules/agent/infrastructure/tools/embedding.py` | 기존 EmbeddingTool — 재사용 가능한지 확인 |
| `mochi-backend/app/modules/search/presentation/router.py` | `_ExtractiveSynthesizer` fallback 상태, SSE 추가 시 교체 지점 |
| `lab/active/agent-loop-image-eval/eval.py` | LLM-as-judge 패턴 — rag-search eval에 그대로 빌릴 수 있음 |
| `lab/CLAUDE.md` | 실험 실행 명령 컨벤션, data 배치 규칙 |

**실행 명령 (다음 세션 바로 확인용):**
```bash
# agent-loop-live (연동 확인)
cd mochi-backend
GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 \
GOOGLE_APPLICATION_CREDENTIALS="C:/Users/dhapr/Downloads/mochi/mochi-gemini-team.json" \
PYTHONPATH="C:/Users/dhapr/OneDrive/바탕 화면/git/mochi/mochi-backend" \
PYTHONIOENCODING=utf-8 \
uv run python "C:/Users/dhapr/OneDrive/바탕 화면/git/mochi/lab/active/agent-loop-live/agent_loop_live_test.py"
```
