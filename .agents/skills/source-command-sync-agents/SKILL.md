---
name: "source-command-sync-agents"
description: "AGENTS.md(canonical)에서 AGENTS.md(Codex용 미러)를 재생성한다"
---

# source-command-sync-agents

Use this skill when the user asks to run the migrated source command `sync-agents`.

## Command Template

`AGENTS.md` 가 단일 원천이다. `AGENTS.md` 는 codex 가 읽는 얇은 미러로, AGENTS.md 와 어긋나면 안 된다.

1. `AGENTS.md` 를 읽는다.
2. `AGENTS.md` 를 다음 구조로 재생성한다:
   - 헤더(codex 대상 명시) + 프로젝트 한 줄 소개
   - "**작업 원칙·문서 포인터·변경기록 규칙은 모두 `AGENTS.md` 를 단일 원천으로 따른다**" 는 명시 (원칙 본문을 복제하지 않는다)
   - **Codex 고유 역할** 섹션만 추가로 둔다:
     - codex 는 모찌의 **검증자**다 — `code-reviewer`/`qa-validator` 서브에이전트가 `codex review` / `codex exec` 로 호출한다.
     - 리뷰 시 AGENTS.md 의 원칙(Simplicity·Surgical)과 `docs/WORKFLOW.md` 의 티어 정합성을 기준으로 본다.
     - 도메인 불변식(4-Intent lifecycle, Idempotency, ownership, SSRF 가드)을 깨는 변경을 P1 으로 잡는다.
3. AGENTS.md 의 핵심 규칙이 AGENTS.md 와 의미상 일치하는지 확인한다. 복제가 아니라 포인터 + codex 역할만 담겼는지 검증한다.
