---
description: 지정 영역의 문서 정합성·신선도 감사 — confidence 자동 채점 + last_verified 갱신
argument-hint: l1 | l2 | l3 | all
allowed-tools: Bash, Read, Grep, Glob, Edit
---

# /audit `$ARGUMENTS`

> 자동 채점 없는 메타데이터는 곧 장식이 된다 (codex 자문 Q6 의 핵심 경고). 이 명령이 그 자동화 절반을 부담한다. **실제 실행 엔진은 `.claude/scripts/audit.sh`** (bash) — 이 명령 문서는 사용 가이드.

## 실제 실행

```bash
bash .claude/scripts/audit.sh <l1|l2|l3|all>
```

스크립트가 자동으로 한다:
- 각 대상 파일의 `last_verified`, `confidence`, `level`, `mode` 추출
- 시간 기반 강등 (L1 60일, L2 30일, L3 14일 임계)
- L2 committed 문서에 대한 코드 식별자 grep 강등 (예: DOMAIN_DESIGN 의 `mochi_item` ↔ 코드)
- front-matter 누락 또는 `confidence < 0.3` 을 STOP 후보로 표시
- 마크다운 리포트로 stdout 출력

대상 범위:
- `l1` — `docs/WORKFLOW.md`, `docs/PRODUCT.md`, `docs/HARNESS_GUIDE.md`, `docs/INDEX.md`
- `l2` — `docs/ARCHITECTURE.md`, `docs/DOMAIN_DESIGN.md`, `docs/PRIVACY_SENSITIVE_CAPTURE.md` (`l2/aspirational/` 는 제외 — 별도 의식인 `/sprint-end` 가 처리)
- `l3` — `docs/TODO.md`, `docs/CHANGELOG.md`, `journal/*.md`
- `all` — 위 셋 모두

## 절차

### 1. front-matter 추출

각 대상 파일의 `last_verified`, `confidence`, `status` 를 수집.

### 2. 시간 기반 강등 (자동)

- L1: `last_verified` 가 60일↑ → confidence -0.1
- L2: `last_verified` 가 30일↑ → confidence -0.1
- L3: `last_verified` 가 14일↑ → confidence -0.2

강등 결과를 *제안*만 한다. 부모 Claude 가 사용자 확인 후 갱신.

### 3. grep 기반 정합성 강등 (자동)

- L2 committed 문서에 등장하는 핵심 식별자(엔티티/필드/모듈명)를 추출.
- 동일 식별자가 코드(`mochi-backend/app/**`, `mochi-ios/Targets/**`) 에 *존재하지 않으면* confidence -0.3.
- 예: `DOMAIN_DESIGN.md` 가 `mochi_item` 을 다루는데 코드엔 `mochi_item` 0건 / `capture` 다수 → known-drift confirm.

### 4. STOP 여부

confidence 가 0.3 미만으로 떨어진 문서는 *작업 시작 전 사람 결정 필요* 항목으로 표시. doc-guardian 의 알림 목록에 자동 포함.

### 5. 리포트

```
## /audit $ARGUMENTS 리포트 (YYYY-MM-DD)
| 파일 | 현재 confidence | 제안 | 강등 사유 |
|---|---|---|---|
...
## 사람 결정 필요 (confidence < 0.3)
- ...
## known-drift 신규 발견
- ...
```

## 발화 시점

- L1: 권장 없음 (2달 안에 의미 없음). 마감 직전 한 번.
- L2: **매 sprint 끝(`W2`/`W4`/`W6`/submission)** — `/sprint-end` 가 자동 호출.
- L3: 매주 (월요일 작업 시작 전 또는 `/daily` 의 일부로).

## 왜 강제하지 않나

cascade paralysis 회피(codex 자문 Q2). 강등은 *알림*이지 차단이 아니다. 강제 STOP 은 "문서 ↔ 코드 식별자 0건" 같은 *논리적 모순* 에만.
