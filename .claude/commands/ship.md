---
description: 머지/PR 전 최종 체크리스트 — 테스트·린트·타입·계약·문서 정합성을 한 번에 검증
argument-hint: ios | backend | docs
allowed-tools: Bash, Read, Grep, Glob, Edit
---

`$ARGUMENTS` 범위의 변경을 머지/커밋하기 전 마지막 게이트. 하나라도 실패하면 **미완**이며, 통과할 때까지 고친다.

## 0. 자동 사전 체크 (반드시 먼저)

```bash
bash .claude/scripts/ship-precheck.sh $ARGUMENTS
```

스크립트가 자동으로 한다 — audit 정합성, CHANGELOG 오늘 항목 검사, CLAUDE↔AGENTS 미러 mtime, 하위 repo git status. 통과/실패 마크업 출력. ❌ 가 있으면 멈추고 고친다.

> 이 스크립트는 `/ship` 전용이 아니다 — 부모 Claude 는 작업 루프 중간 어디서든 `bash .claude/scripts/ship-precheck.sh <범위>` 로 자율 호출할 수 있다 (`docs/WORKFLOW.md` §5.2).

## backend 인 경우 (`mochi-backend/` 에서)
1. `make lint` — ruff 통과
2. `make typecheck` — mypy strict 통과
3. `make test` — pytest 통과 (모듈 경계 테스트 `test_module_boundaries.py` 포함)
4. API 변경이 있었으면 `make openapi` → `git diff openapi.json` 로 계약 변화 확인 (계약 티어 단일원천)

## ios 인 경우 (`mochi-ios/` 에서)
1. `tuist test` — TestStore 테스트 통과
2. `xcodebuild`/시뮬레이터 빌드가 필요하면 **직접 돌리지 말고 사용자에게 요청**

## 공통 — 문서 정합성 (모든 범위)
5. 도메인/스키마 변경 → `docs/DOMAIN_DESIGN.md` 동기화
6. 토폴로지/API 계약 변경 → `docs/ARCHITECTURE.md` 동기화
7. 민감정보 흐름 변경 → `docs/PRIVACY_SENSITIVE_CAPTURE.md` 동기화
8. **정합성 폭포**: L2 를 바꿨다면 양 README·이번주 plan(L3)까지 일치하는지 doc-guardian 으로 확인
9. `docs/CHANGELOG.md` 맨 위에 `## <날짜> — <범위>` 항목 추가 (§6)

## 마지막
10. 변경된 모든 줄이 사용자 요청까지 추적 가능한지(Surgical) 확인.
11. 머지 전 `code-reviewer`(→codex) 리뷰를 거쳤는지 확인.
