---
level: 3
mode: log
status: active
last_verified: 2026-06-07
confidence: 0.7
owners: [박세현]
description: agent-loop 이미지 평가 구조 개편과 첫 실험 결과의 세션 핸드오프. 이미지 분석 평가 실험을 이어받을 때 읽어라.
title: "agent-loop-image-eval 평가 구조 개편 + 첫 실험 실행 + 결과 분석"
date: 2026-06-07
branch: lab/local-image-eval
status: in-progress
scope: lab
---

# agent-loop-image-eval 개편 + 첫 실험 결과 분석 — Handoff (2026-06-07)

## 0. TL;DR (한 화면)

- `eval.py` 전면 개편 완료 — 평가 축이 "이미지↔summary" → "사람의 저장 의도↔Agent 분석"으로 변경
- 파일명 파싱 규칙 변경: `__` 구분자 → 앞쪽 연속 valid intent 토큰 자동 분리 (`_` 단일)
- 데이터 경로 변경: `intent_N/` 서브폴더 → `screenshot/` 직접 스캔
- 34건 첫 실험 실행 완료. **핵심 발견: Recall 낮음(0.27)은 agent 문제가 아니라 gold label 문제**
- eval 완료 시 `FINDINGS.md` 자동 업데이트 추가
- 다음 세션 최우선 결정: gold label 재라벨링 vs 지표 해석 기준 조정

---

## 1. 대화 흐름

1. **handoff 점검** (세션 시작) — 어제 세션3 handoff 작성
2. **eval.py 평가 구조 개편** — 사용자가 새 평가 구조 전달:
   - `parse_gold`: 파일명에서 gold intent + 실제 저장 의도 파싱
   - `judge_intention_alignment`: 이미지 judge 제거, 텍스트 의미 정합성으로 교체
   - Recall / Precision / Exact match 지표 추가
   - `predicted_analysis` 결과 JSON 저장
3. **버그 수정 라운드** (code-reviewer 피드백):
   - `called_finalize` 항상 false → 제거
   - JudgeResult Pydantic + `response_schema` 타입 강제
   - `contradiction_rate` 분모 — judge 실패(None) 케이스 제외
   - skip 파일 → `skipped_cases` + `summary.skipped` 기록
   - 중복 intent · 빈 의도 · 폴더-개수 불일치 차단
4. **데이터 경로·파싱 변경** — `screenshot/` 에 파일이 있고 `intent_N/` 폴더는 없음 확인. `__` → 단일 `_` 앞부분 토큰 파싱으로 변경. 파일명 dry-run으로 전체 OK 확인.
5. **첫 실험 실행** — 34건 전체 실행 (10건만 하려다 이미 돌고 있었음)
6. **FINDINGS.md 자동 업데이트** 추가 — 기존엔 JSON만 저장, eval 끝나면 결과 요약 자동 append
7. **결과 분석** — `memo` recall 0% 집중 논의 → V7 프롬프트 정의 읽어보니 gold label 문제

---

## 2. 현재 코드 상태

**브랜치: `lab/local-image-eval` (`2e0b0e0`, origin 동기)**

**이번 세션 커밋:**
```
2e0b0e0  feat(lab): eval 완료 시 FINDINGS.md 자동 업데이트 + 첫 실험 결과 기록
6e8b9ef  refactor(lab): eval 데이터 경로 + 파싱 규칙 변경
952d43d  feat(lab): agent-loop-image-eval 평가 구조 개편
```

**변경 파일:**
```
lab/active/agent-loop-image-eval/eval.py      ← 전면 개편
lab/active/agent-loop-image-eval/FINDINGS.md  ← 첫 실험 결과 자동 추가됨
```

**미커밋 (untracked):**
```
lab/active/agent-loop-image-eval/results/     ← gitignore 대상, 실험 결과 JSON
lab/active/rag-search/TEAM_LEAD_BRIEF.md      ← 어제부터 미커밋 상태
```

**작동 가능 여부:** eval 실행 정상. ruff 전체 통과.

---

## 3. codex 검증 결과

이 세션 code-reviewer / qa-validator 호출 없음. 사용자가 직접 피드백 제공 (P1 1개, P2 4개).

적용된 수정:
- P1: `called_finalize` 항상 false → `tool_eval`에서 제거 + docstring 수정
- P2: JudgeResult Pydantic + `response_schema`
- P2: `contradiction_rate` 분모 None 제외
- P2: `predicted_analysis` 결과에 저장
- P2: gold label 검증 강화 (중복·빈 의도·폴더 불일치)
- P2: skip 파일 결과 JSON 기록
- nit: `analysis_applied` 제거

---

## 4. 결정 / trade-off

| 결정 | 이유 |
|------|------|
| `__` → 단일 `_` 파싱 | 기존 파일명 형식과 호환. 앞쪽 연속 valid intent 토큰을 gold로 수집 |
| `intent_N/` → `screenshot/` flat | 이미 flat으로 파일이 들어와 있었음. intent_count는 `len(expected_intents)`에서 파생 |
| FINDINGS.md 자동 append | eval 끝에 수동으로 문서 쓰는 것을 없앰 |
| gold label 재라벨링 여부 → 미결 | 이번 세션에서 결론 내지 않음 (아래 §5) |

---

## 5. 미완 결정

**[가장 중요] gold label 재라벨링 여부**

현재 `memo` gold 파일 21건 중 18건이 recall 0.0. 이유는 Agent 오류가 아니라 정의 불일치:

- **사람의 gold label 기준**: "나중에 보려고 저장한 것 = memo"
- **V7 프롬프트 정의**: `memo`는 schedule/todo/knowledge 셋 어디에도 안 들어가는 정서적·일회적 기록

Agent가 `memo_나중에가보려고.png`를 `knowledge`로 분류하는 것은 프롬프트 기준으론 맞습니다.

**선택지:**

A. **gold label 재라벨링** — `memo_나중에가보려고.png` → `knowledge_나중에가보려고.png` 등으로 변경. Recall이 실제 agent 품질을 반영하게 됨.

B. **지표 해석 기준 조정** — gold label은 그대로 두고, Recall 대신 Alignment Score(3.81/5)를 주 지표로. "사람의 의도를 Agent가 이해했는가"가 더 핵심 질문이면 이쪽.

C. **혼합** — `memo_나중에*` 류는 재라벨링, 명확히 메모성인 것만 `memo`로 유지.

---

## 6. 다음 단계 + 검증 기준

### 즉시 할 것

1. **gold label 재라벨링 결정** (§5) — 다음 eval 의미 있는 Recall 산출을 위해 먼저 결정 필요

2. **오류 파일 2건 교체/삭제**
   - `memo_사고싶다.PNG` — 이미지 손상 (incorrect header check)
   - `memo_저장해두고나중에봐야지.PNG` — 이미지 손상

3. **`schedule` → `[]` 케이스 판단**
   - `schedule_공차할인날짜시간.jpeg`, `schedule_todo_친구공연장장소와시간.jpeg`
   - Agent가 "과거 이벤트"로 판단해 아무 intent도 안 냄
   - lab 데이터가 과거 날짜 스크린샷이라 발생. 수용할지, 데이터 교체할지 결정 필요

4. **재실험** — gold label 정리 후 재실행해서 Recall 재측정

### 검증 기준

- gold label 재라벨링 후 Recall ≥ 0.6 이면 Agent 분류 품질 양호 판정
- Alignment Score 3.5 이상 유지 확인

---

## 7. 컨텍스트 부채 (다음 세션이 먼저 봐야 할 것)

| 파일 | 왜 봐야 하는가 |
|------|---------------|
| `mochi-backend/app/modules/agent/prompts/system_prompts.py` | V7 `ACTIVE_PROMPT` — 4-Intent 정의 원문. gold label 재라벨링 기준 |
| `lab/active/agent-loop-image-eval/FINDINGS.md` | 첫 실험 결과 전체 + low-recall / low-judge 케이스 목록 |
| `lab/data/screenshot/` | 현재 파일 34장 목록. 재라벨링·교체 대상 파악 |

**V7 memo 정의 요약 (재라벨링 기준):**
> memo = 위 셋(schedule/todo/knowledge)에 안 들어가는 정서적·일회적 기록, 또는 대상이 불분명한 안전 보관

**실행 명령 (mochi-backend 디렉토리에서):**
```powershell
$env:GOOGLE_CLOUD_PROJECT="axial-device-460408-i9"
$env:GOOGLE_APPLICATION_CREDENTIALS="C:/Users/dhapr/Downloads/mochi/mochi-gemini-team.json"
$env:PYTHONPATH="C:/Users/dhapr/OneDrive/바탕 화면/git/mochi/mochi-backend"
uv run python "../lab/active/agent-loop-image-eval/eval.py"
```
