---
level: 3
mode: log
status: archived
last_verified: 2026-05-29
confidence: 1.0
owners: [송준서, 이용찬, 박세현]
description: docs/archive/ — 분기 마감되거나 superseded 된 문서가 들어오는 곳. AI 는 기본 skip. 과거 추적이 명시 필요할 때만 path 를 명시해 읽는다.
---

# docs/archive/ — Skip by default

이 디렉토리의 모든 파일은 **현재 유효하지 않은 상태로 보존된 기록물**이다.

## AI 동작 규칙

- doc-guardian / architect / code-reviewer / qa-validator — **읽지 않는다.**
- 부모 Claude — 사용자가 명시 요청한 경우에만 읽는다 (예: "1분기 결정 흔적 보여줘").
- `confidence` 채점 / 정합성 폭포 / known-drift 스캔 — **대상 외.**

## 들어오는 경로

- `/sprint-end` 가 `status: done` 또는 `expires` 만료 항목을 일괄 이동.
- 사용자가 명시적으로 superseded 선언 시 수동 mv.

## 들어오면 안 되는 것

- 현재 결정 대기 중인 known-drift — 그건 `CHANGELOG.md` 의 활성 영역에 남긴다.
- aspirational 이지만 미실현 — 그건 `docs/aspirational/` 의 `target_milestone` 만료 처리.

## 루트 `archive/` 와 구분

루트의 `archive/` 는 *프로젝트 초기 폐기된 설계 자료* (예: `archive/기획서GPT.txt`, 옛 ARCHITECTURE/DOMAIN_DESIGN). `docs/archive/` 는 *모찌 docs/ 의 분기 마감물*. 둘 다 skip 대상이지만 출처가 다르다.
