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

---

# RAG 검색 파이프라인 구현 + 실험 범위 정리 — Handoff (2026-06-06, 세션 2)

## 0. TL;DR (한 화면)

- `lab/active/rag-search/` 파이프라인 완성 — analyze → embed → eval 3단계, 캐시 정합성 완비
- 실험 범위 명확히 분리: `rag-search` = retrieval 품질만, `agent-loop-image-eval` = 분석 품질
- `cases.json`에서 `expected_*` 필드 전부 제거, `retrieval_diagnostic` 코드 삭제
- Windows 한글 출력 오류 수정 (`sys.stdout.reconfigure`), `PYTHONIOENCODING` 불필요
- 커밋 3개 푸시 완료 (`lab/local-image-eval` 브랜치, `ea3c2d5`)
- **아직 파이프라인을 실제로 실행하지 않았다** — `analyze.py` 한 번도 안 돌림

---

## 1. 대화 흐름

1. **`eval_retrieval.py` 해시 검증 완성** — 이전 세션에서 미완이던 P1/P2 적용:
   - P1: embedding hash를 embedding끼리만 비교 → **현재 analysis artifact hash와 직접 비교**로 교체
   - P2: 예상 25개 조합 누락 시 기본 중단, `--allow-partial`로만 계속 허용
2. **자동 선택 로직 수정** — embedding 디렉터리 mtime 기준 → **analysis artifact mtime 기준**으로 변경. 대응 embedding 없으면 즉시 중단.
3. **Windows UnicodeEncodeError 수정** — `—`, `←`, `✗` 출력 시 cp949 크래시. 3개 스크립트 모두 `sys.stdout.reconfigure(encoding="utf-8")` 추가, docstring에서 `PYTHONIOENCODING=utf-8` 제거.
4. **1차 커밋·푸시** (`28af8f5`)
5. **실험 범위 분리 논의** — `rag-search`에 `expected_intents/topics/entities`와 `retrieval_diagnostic`이 있어 `agent-loop-image-eval`과 책임이 겹침을 확인.
6. **`cases.json` 정리** — 3개 expected 필드 전부 제거, 순수 입력 정의만 유지.
7. **`analyze.py` 정리** — `_topic_in_output`, `retrieval_diagnostic` 계산 블록, `pass_rate` 전부 삭제 (~50줄).
8. **`FINDINGS.md` scope 섹션** — 현재 구현 기준으로 경계 표 수정 (과거엔 agent-loop-image-eval이 topic/entity도 담당한다고 과장했었음).
9. **2차, 3차 커밋·푸시** (`dc35ce3`, `ea3c2d5`)
10. **이미지 라벨링 컨벤션 설명** — `설명_intent1_intent2.PNG`, intent 4종 (`todo/schedule/knowledge/memo`)

---

## 2. 현재 코드 상태

**브랜치: `lab/local-image-eval` (`ea3c2d5`, origin 동기)**

### 이번 세션 변경 파일

```
lab/active/rag-search/                       ← 신규 (전체)
  _lab_utils.py                              ← MODELS, STRATEGY_NAMES, analysis_hash, expected_embed_names 단일 원천
  analyze.py                                 ← 이미지→Gemini→artifact. expected_* / diagnostic 없음
  embed.py                                   ← 25개 조합 임베딩 생성·캐시
  eval_retrieval.py                          ← BM25/Vector/RRF 평가. analysis hash 비교, --allow-partial
  data/cases.json                            ← 18케이스, 입력 정의만
  gold/queries.json                          ← 14쿼리, 검색 정답
  dataset.synthetic.json                     ← 스모크 테스트용 합성 데이터 (보관)
  FINDINGS.md                                ← 실험 설계·범위 경계·결론 템플릿
lab/active/agent-loop-image-eval/eval.py     ← import 정렬 수정 (ruff I001)
mochi-backend/pyproject.toml                 ← lab 그룹: rank-bm25, numpy 추가
mochi-backend/uv.lock                        ← 갱신
.gitignore                                   ← artifacts/, results/ gitignore 추가
```

**작동 가능 여부:** 코드 완성, ruff 전체 통과. 실제 이미지 분석은 아직 미실행.

---

## 3. codex 검증 결과

이 세션 code-reviewer / qa-validator 호출 없음.

---

## 4. 결정 / trade-off

| 결정 | 이유 |
|------|------|
| `cases.json`에서 expected_* 제거 | `rag-search`는 retrieval 품질만 담당. 분석 정답은 `agent-loop-image-eval` 영역 |
| `retrieval_diagnostic` 전체 삭제 | 현재 규모(18케이스)에서 자동 실패원인 분류는 복잡도만 추가. 사람이 artifact 직접 확인으로 충분 |
| 누락 조합 기본 중단 (`--allow-partial` 옵션) | 25개 미만이면 leaderboard가 불완전 — 실험 결론을 왜곡할 수 있어 기본 fail-fast |
| 자동 선택을 analysis artifact mtime 기준으로 | embedding mtime은 과거 실험을 새 분석인 것처럼 오해하게 만들 수 있음 |
| `sys.stdout.reconfigure` (환경변수 아님) | 실행 명령마다 `PYTHONIOENCODING=utf-8` 붙이는 것보다 코드 내 처리가 더 안정적 |

---

## 5. 미완 결정

없음 — 파이프라인 구현은 완료. **실험 실행이 아직 안 됐을 뿐.**

---

## 6. 다음 단계 + 검증 기준

### 즉시 할 것

1. **`analyze.py` 실행** — 18개 이미지 Gemini 분석 → `artifacts/analysis/{fp}.json` 생성
2. **`embed.py` 실행** — 25개 조합 임베딩 생성 (Vertex AI 호출, 시간 소요 예상)
3. **`eval_retrieval.py` 실행** — BM25/Vector/RRF 평가 → `results/retrieval/*.json`
4. **`FINDINGS.md` 결론 섹션 채우기** — 최적 모델·차원·전략 결정

### 실행 명령 (mochi-backend 디렉토리에서)

```bash
# Step 1 — 분석
GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 \
GOOGLE_APPLICATION_CREDENTIALS="C:/Users/dhapr/Downloads/mochi/mochi-gemini-team.json" \
PYTHONPATH="C:/Users/dhapr/OneDrive/바탕 화면/git/mochi/mochi-backend" \
uv run python "../lab/active/rag-search/analyze.py"

# Step 2 — 임베딩
GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 \
GOOGLE_APPLICATION_CREDENTIALS="C:/Users/dhapr/Downloads/mochi/mochi-gemini-team.json" \
uv run python "../lab/active/rag-search/embed.py"

# Step 3 — 평가
GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 \
GOOGLE_APPLICATION_CREDENTIALS="C:/Users/dhapr/Downloads/mochi/mochi-gemini-team.json" \
uv run --group lab python "../lab/active/rag-search/eval_retrieval.py"
```

### 검증 기준

- `"화장품"` 쿼리 → `cosmetics-buy-1`, `cosmetics-buy-2` 두 아이템이 top-3 안에 포함
- 25개 조합 전부 평가 완료 (누락 없음)
- nDCG@5 기준 최적 조합 선택 → `FINDINGS.md` 결론 섹션 채우기

---

## 7. 컨텍스트 부채 (다음 세션이 먼저 봐야 할 것)

| 파일 | 왜 봐야 하는가 |
|------|---------------|
| `lab/active/rag-search/FINDINGS.md` | 실험 범위·설계·결론 템플릿 — 실행 전 한 번 확인 |
| `lab/active/rag-search/data/cases.json` | 18케이스 이미지 파일명 — `lab/data/legacy/`의 실제 파일과 매칭되는지 확인 필요 |
| `lab/active/rag-search/gold/queries.json` | 14쿼리 정답 셋 — 실험 결과 해석 기준 |
| `mochi-backend/app/modules/agent/infrastructure/tools/embedding.py` | 프로덕션 EmbedTool — 실험 결과 반영 시 수정 포인트 |

---

# RAG 실험 환경 최종 점검 + TEAM_LEAD_BRIEF 작성 — Handoff (2026-06-06, 세션 3)

## 0. TL;DR (한 화면)

- 세션 시작 직후 handoff 점검 요청 → 세션 자체 작업 없음
- **미커밋 파일 1개 발견**: `lab/active/rag-search/TEAM_LEAD_BRIEF.md` (untracked)
  - 팀 리드용 실험 환경 요약 — 목적·흐름·디렉터리·실행법·결과 활용 설명
- 실험 파이프라인 실행은 **아직 0번도 실행하지 않음** (세션 2 이월)

---

## 1. 대화 흐름

1. `handoff` 슬래시커맨드 실행 → 현재 브랜치 상태·미커밋 파일·git diff 자동 수집
2. 세션 2 handoff가 이미 완전히 작성되어 있음 확인
3. 미커밋 `TEAM_LEAD_BRIEF.md` 발견 → 이번 세션 유일한 신규 아티팩트

---

## 2. 현재 코드 상태

**브랜치: `lab/local-image-eval` (`d41e5a9`, origin 동기)**

### 미커밋 파일 (git status: untracked)

```
lab/active/rag-search/TEAM_LEAD_BRIEF.md   ← 팀 리드용 실험 요약 문서
```

**작동 가능 여부:** 파이프라인 코드 완성 상태. 이미지 분석·임베딩·평가 모두 미실행.

---

## 3. codex 검증 결과

이 세션 code-reviewer / qa-validator 호출 없음.

---

## 4. 결정 / trade-off

없음 — 이번 세션은 handoff 점검만 수행.

---

## 5. 미완 결정

세션 2에서 이월된 항목 그대로:
1. **파이프라인 실행** — `analyze.py` → `embed.py` → `eval_retrieval.py` 한 번도 안 돌림
2. **`TEAM_LEAD_BRIEF.md` 커밋 여부** — untracked 상태, 커밋할지 결정 필요

---

## 6. 다음 단계 + 검증 기준

세션 2 §6과 동일. 즉시 할 것:

1. **`TEAM_LEAD_BRIEF.md` 커밋** (선택)
2. **`analyze.py` 실행** — 18개 이미지 Gemini 분석
3. **`embed.py` 실행** — 25개 조합 임베딩
4. **`eval_retrieval.py` 실행** — BM25/Vector/RRF 평가
5. **`FINDINGS.md` 결론 채우기**

실행 명령은 세션 2 §6 참고.

### 검증 기준

- `"화장품"` 쿼리 → `cosmetics-buy-1`, `cosmetics-buy-2` top-3 안에 포함
- 25개 조합 전부 평가 완료
- nDCG@5 기준 최적 조합 → `FINDINGS.md` 결론 채우기

---

## 7. 컨텍스트 부채

세션 2 §7과 동일. 추가 항목:

| 파일 | 왜 봐야 하는가 |
|------|---------------|
| `lab/active/rag-search/TEAM_LEAD_BRIEF.md` | 팀 리드용 실험 개요 — 커밋 전 내용 확인 |
