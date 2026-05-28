---
description: 다음 세션(사람·AI)이 0부터 이어받을 수 있는 인수인계 문서를 만든다. codex 검증 결과 + 양 하위 repo git diff 요약을 포함한다.
argument-hint: [주제]
allowed-tools: Bash, Read, Write
---

# /handoff `$ARGUMENTS`

> 2달 짧고 굵은 프로젝트에서 3인이 매일 컨텍스트 스위치를 한다. handoff 가 부실하면 다음 세션이 30분 길을 잃는다 — 그 30분이 데모데이 전엔 치명적이다.

## 출력 위치

`journal/$(date +%Y-%m-%d)-$ARGUMENTS-handoff.md` (이미 있으면 이어 쓰기)

## 자동 수집 (사람 손 거치지 않고 채우는 영역)

### A. 양 하위 repo git diff 요약

```bash
git -C mochi-ios diff --stat
git -C mochi-ios diff --name-only
git -C mochi-backend diff --stat
git -C mochi-backend diff --name-only
```

→ 결과를 "변경된 파일" 섹션으로.

### B. codex 검증 결과 (있을 때)

이 세션에 `code-reviewer` 또는 `qa-validator` 가 codex 호출을 했다면 마지막 응답을 한 블록으로 인용. 통과/실패 여부 명시.

### C. 활성 front-matter 상태 변화

이 세션에 `last_verified`, `confidence`, `status` 가 갱신된 문서 목록. doc-guardian 의 후속 발견 거리.

## 사람이 채우는 영역 (대화에서 직접)

```
# <주제> — Handoff (<날짜>)
## 0. TL;DR (한 화면)
## 1. 대화 흐름 — 어떻게 여기까지 왔는가
## 2. 현재 코드 상태 (작동 가능 여부 + 변경된 파일 목록 — A 자동)
## 3. codex 검증 결과 (B 자동, 통과 여부와 P1 issue)
## 4. 결정 / trade-off (왜 이렇게 했는가)
## 5. 미완 결정 (사용자 선택 대기 중인 것)
## 6. 다음 단계 + 검증 기준
## 7. 컨텍스트 부채 (다음 세션이 먼저 봐야 할 docs/code)
```

## 핵심 원칙

- 추측 금지. 대화에서 실제 일어난 것만.
- "코드가 무엇을 하는지"(diff 가 말함) 가 아니라 "**왜 그렇게 됐고 무엇이 아직 안 정해졌는지**".
- 다음 세션이 처음 30분에 보는 첫 화면을 상상하며 쓴다.

## 발화 시점

- 미완 작업으로 세션을 끝낼 때 (필수)
- 큰 결정을 내린 직후 (권장)
- 사용자 또는 팀원이 컨텍스트 스위치를 명시 요청할 때
