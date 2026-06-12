---
description: 2주 sprint 마감 — done/expired 항목 archive 이관 + 다음 sprint 목표 1줄 + scope-cut 결정 강제
argument-hint: [sprint 식별자 e.g. W2 | W4 | W6 | submission]
allowed-tools: Bash, Read, Grep, Glob, Edit, Write
---

# /sprint-end `$ARGUMENTS`

> 2달 짧고 굵은 프로젝트라 분기/반기 cadence 는 없다. 대신 **2주 sprint 의 4회 발화**(`W2`, `W4`, `W6`, `submission`)가 자연 리듬이다. 이 명령은 한 sprint 의 끝을 *명시적으로 닫는 의식*이다. OKR 의 "분기 closure" 를 단기 압축한 형태.

## 절차

### 1. done/expired 일괄 청소

- `docs/aspirational/**/*.md` — `target_milestone == $ARGUMENTS` 이고 미실현이면 사용자에게 cut 여부 확인. 확인 시 `docs/archive/$ARGUMENTS/` 로 mv 후 front-matter `status: superseded` 로 갱신.
- `docs/TODO.md` — `[x]` 또는 `~~취소~~` 항목을 한 묶음으로 추출해 `journal/$(date +%Y-%m-%d)-$ARGUMENTS-closure.md` 에 옮긴다.
- `journal/*.md` — 14일 이상 미수정 + 후속 결정 없는 항목은 `journal/archive/$ARGUMENTS/` 로 mv.

### 2. 정합성 폭포 부채 정리

- 활성 `confidence < 0.5` 문서 목록 작성.
- known-drift 중 sprint 안에서 결정 가능한 것 추출 → 사용자에게 결정 요청.
- 미결정 known-drift 는 그대로 두되 마감일 기록.

### 3. 다음 sprint 목표 1줄

`docs/TODO.md` 맨 위에 다음 형식으로 한 줄:
```
## 다음 sprint: <식별자> — <목표 1문장 + 검증 기준>
```
- 목표는 `docs/PRODUCT.md` MVP 우선순위(P0/P1) 중 *하나*. 다 못 한다. (데모 시나리오 상세는 `docs/UX_SPEC.md` §5)
- 검증 기준은 "데모 시연 가능 = X 화면이 Y 동작" 으로 구체적.

### 4. scope-cut 결정 강제

사용자에게 다음을 묻는다:
- "이번 sprint 안 끝난 것 중, 다음 sprint 로 미룰 것 / 데모데이 후로 미룰 것 / 폐기 — 각 1~3개 골라달라."
- 결정을 `journal/$(date +%Y-%m-%d)-$ARGUMENTS-closure.md` 에 기록.

### 5. CHANGELOG 한 줄

`docs/CHANGELOG.md` 맨 위에 추가:
```
## YYYY-MM-DD — sprint-end ($ARGUMENTS)
- 마감: <한 줄>
- archive: <항목 수>
- cut: <항목 수>
- 다음 sprint: <식별자> · <목표>
```

## 통과 기준 (이 5단계 모두 완료 시에만 sprint 닫힘)

- archive 이관 완료
- 다음 sprint 목표 1줄 박힘
- scope-cut 기록됨
- CHANGELOG 항목 있음

## 왜 이렇게 무거운가

데모데이 임박할수록 scope creep 이 모찌의 가장 큰 적이다. 매 sprint 끝마다 "**모두 다 못 한다**" 를 사람이 명시적으로 인정하지 않으면 마감 직전에 모든 게 fire 가 된다. 의식의 무게가 그 인정을 강제하는 장치다.
