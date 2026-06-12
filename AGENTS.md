---
level: 1
mode: reference
status: active
last_verified: 2026-06-10
confidence: 0.9
owners: [송준서, 이용찬, 박세현]
description: codex CLI 가 모찌 저장소에서 작업할 때 읽는 진입점. CLAUDE.md 의 미러이며 codex 고유 검증자 역할만 추가로 담는다. 직접 손대지 말고 CLAUDE.md 를 고친 뒤 /sync-agents 로 재생성한다.
---

# AGENTS.md

This file provides guidance to Codex when working in this repository.

> 모찌(MOCHI) — Multimodal AI 기반 스크린샷·링크·기록 통합관리 에이전트
> 2026 SW중심대학 디지털 경진대회 / 팀 **세얼간이**

---

## 단일 원천: `CLAUDE.md`

작업 원칙(Think Before Coding · Simplicity First · Surgical Changes · Goal-Driven),
저장소 구성, 문서 포인터, 변경 기록 규칙(§6), 하네스 구성(§7)은 모두 **[`CLAUDE.md`](CLAUDE.md) 를 단일 원천으로 따른다.**
여기에 그 내용을 복제하지 않는다. 협업·정합성·메타데이터·2달 단기 모드 규칙은 [`docs/WORKFLOW.md`](docs/WORKFLOW.md) 가 기준이다.

> 이 파일은 `/sync-agents` 로 `CLAUDE.md` 에서 재생성되는 미러다. 직접 손대지 말고 `CLAUDE.md` 를 고친 뒤 동기화한다.

## docs 읽기 룰 (codex 가 작업 시작 시 따를 것)

- `docs/INDEX.md` 가 path-first 길잡이 — 어떤 디렉토리를 읽고 어떤 디렉토리를 skip 할지 path 만으로 결정.
- `docs/archive/**`, `docs/aspirational/**`, 루트 `archive/**` — **default skip**. 명시 요청 시만 읽는다.
- `docs/*.md` 의 front-matter `mode`:
  - `committed` 만 코드 정합 검증 대상 (P1).
  - `aspirational` 은 검증 외 (단, `target_milestone` 만료 시 강등 후보).
  - `reference` / `log` 는 정보·기록.
- 모든 docs 의 `description` 은 "언제 읽어야 하는가" 트리거. 그 트리거가 작업과 맞으면 읽어라.

---

## Codex 고유 역할 — 검증 엔진

Codex 는 모찌의 **검증자**다. Claude 의 `code-reviewer` / `qa-validator` 서브에이전트가
`codex review` · `codex exec` 로 너를 호출한다. 검증 시 다음을 기준으로 본다.

**리뷰 기준 (CLAUDE.md 원칙 + `docs/WORKFLOW.md` 티어 정합성):**
- **Surgical** — 요청과 무관한 변경/리팩터/포맷 변경이 섞였는가
- **Simplicity** — 과설계·불필요한 추상화·일어날 수 없는 에러 핸들링
- **티어 정합성** — 네이밍 사전(어휘)·레이어 위치(구조)·**API 계약(⓪: `mochi-backend/openapi.json` 단일원천. iOS 는 거기서 생성. 생성물 `Generated/*.swift` 가 openapi.json 과 stale 하지 않은지 = `ship-precheck §5`)**
- **문서 소유 경계** — `docs` 에 스키마/DDL 복제 누수(참조 아닌 복제), 정본 외 문서가 컬럼 재정의 (`docs/WORKFLOW.md` §2.1 참조-비복제)

**P1(must-fix) 으로 잡을 도메인 불변식:**
- 4-Intent lifecycle 전이가 `lifecycle_policy.py`(백엔드) ↔ `CoreDomain.LifecyclePolicy`(iOS) 양쪽에서 일치
- Idempotency-Key 재요청이 중복 캡처를 만들지 않음
- `MochiItemRepository` 의 `owner_id` 강제 (cross-tenant 누설 차단)
- WebFetch SSRF 가드 (사설/링크로컬/메타데이터/multicast IP 차단, redirect hop 마다 재검증)
- 민감 캡처 보호 경로(on-device 감지·마스킹·최소전송) 우회 없음

**검증 명령:** 백엔드 `make test` / `make lint` / `make typecheck`, iOS `tuist test`.
`xcodebuild` 류(시뮬레이터·실기기·archive)는 직접 실행하지 않고 사용자에게 요청한다.

## 모노레포 git 컨텍스트 (통합 완료)

**루트 모노레포 git 통합 완료** (2026-05-29). `mochi-ios/.git`, `mochi-backend/.git` 제거 후 루트 단일 git 으로 합쳤다. `.claude/`, `docs/`, `journal/` 등 운영 파일이 이제 모두 버전 관리된다.

`codex review` / `codex exec` 는 **루트에서 한 번에** 실행하면 된다:

```bash
codex exec "이 작업트리 변경을 리뷰해줘. 기준: CLAUDE.md 원칙 + WORKFLOW 티어. P1/P2/nit 로."
```

양 하위 `mochi-{ios,backend}/AGENTS.md` symlink 는 호환성 + codex 가 하위에서 실행되는 경우 안전망으로 유지.

## 2달 단기 모드

경진대회 산출물 제출 마감 = `docs/.deadline` (현재 2026-07-15). 2주 sprint × 4회로 의식을 압축. 자세한 cadence·scope-cut 규칙은 `docs/WORKFLOW.md` §11.
