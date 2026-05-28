---
level: 3
mode: log
status: archived
last_verified: 2026-05-27
confidence: 1.0
owners: [송준서, 이용찬, 박세현]
description: 하네스 v1 초기 구축 세션(2026-05-27) 의 결정·이유·다음 할 일 기록. 하네스가 왜 이렇게 설계됐는지 흔적이 필요할 때 읽어라. v2(2026-05-29) 갱신 내역은 docs/CHANGELOG.md 참고.
---

# AI-native 협업 하네스 구축 — 2026-05-27

## 한 일
- 폴더 구조·git 상태 점검: 루트는 git 아님, `mochi-ios`/`mochi-backend` 는 각각 로컬 git(remote 없음).
- codex CLI 설치(npm `@openai/codex` 0.134.0) — ChatGPT 인증 이미 완료. `codex review` / `codex exec` 사용 가능 확인.
- `.claude/` 하네스 신설:
  - `settings.json` — 권한 allowlist(make/tuist/uv/ruff/pytest/codex/git, push 제외)
  - agents: `architect`·`code-reviewer`·`qa-validator`·`doc-guardian`(read-only) + `lab-experimenter`(lab/ 한정 write)
  - commands: `/daily`·`/handoff`·`/ship`·`/sync-agents`·`/codify`
- `docs/WORKFLOW.md`(L1) 신설 — 티어 정책(⓪①②③)·문서레벨·공유표면·작업루프·네이밍사전·파일위치맵·협업리듬·브랜치규칙.
- `journal/` 승격 + 템플릿. `_workspace/`의 handoff 2개 이동.

## 결정 / 이유
- 서브에이전트는 기본 read-only(분석/평가/QA), 코드 수정은 부모 Claude 만 — 사용자 경험칙.
- QA·리뷰는 codex 에 위임 — codex 가 그 작업에 강함.
- 규칙은 최소 시드 + `/codify` 학습 루프로 성장 (Simplicity First, 추측성 규칙 금지).
- 컨벤션 시드는 추측이 아니라 실제 코드/설정 스캔에서 추출.

## 다음 할 일
- CLAUDE.md 갱신(서브에이전트·문서레벨·워크플로우·티어·contract-first) + AGENTS.md 미러 재생성.
- 양 README 의 `openapi.yaml` → `openapi.json` drift 수정.
- CHANGELOG 항목 추가.

## 막힌 것 / 사람 결정 필요
- **git 모노레포 통합 + GitHub remote 는 팀 상의 대기 중.** 그 전까지 `.claude/`·`docs/WORKFLOW.md`·`journal/` 등 루트 파일은 버전관리 밖이라 팀원이 git 으로 못 받아감 — 결국 모노레포 결정 필요.
