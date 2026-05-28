---
level: 3
mode: log
status: active
last_verified: 2026-05-29
confidence: 1.0
owners: [송준서, 이용찬, 박세현]
title: journal — 하루 작업 로그 · 인수인계
description: 날짜별 작업 로그와 세션 인수인계의 단일 원천. 다음 중 하나라도 해당하면 읽어라 — 어제/그저께 흐름 이어받기, 컨텍스트 스위치 직후 첫 30분, 다른 팀원의 어제 결정 확인. 과정은 여기 · 결과 요약은 docs/CHANGELOG.md · `/sprint-end` 가 분기 단위 archive 이관.
---

# journal/ — 하루 작업 로그 · 인수인계 (L3)

날짜별 작업 과정·결정·인수인계를 남긴다. **과정**은 여기, **결과 요약**은 `docs/CHANGELOG.md`.

## 파일 이름
- 작업 로그: `YYYY-MM-DD-<주제>.md` → `/daily` 로 생성
- 인수인계: `YYYY-MM-DD-<주제>-handoff.md` → `/handoff` 로 생성

## 작업 로그 템플릿 (`/daily`)
```markdown
# <주제> — <YYYY-MM-DD>

## 한 일
- 

## 결정 / 이유
- 

## 다음 할 일
- 

## 막힌 것 / 사람 결정 필요
- 
```

## 인수인계 템플릿 (`/handoff`)
```markdown
# <주제> — Handoff (<YYYY-MM-DD>)

## 0. TL;DR (한 화면 요약)
## 1. 대화 흐름 — 어떻게 여기까지 왔는가
## 2. 현재 코드 상태 (작동 가능 여부 + 변경 파일)
## 3. 결정 / trade-off
## 4. 미완 결정 (사람 선택 대기)
## 5. 다음 단계 + 검증 기준
```

## 원칙
- 다음 사람(또는 AI)이 **0 부터 이어받을 수 있을 만큼**만. 코드가 무엇을 하는지(diff 가 말함)가 아니라 **왜·무엇이 미정인지**.
- 추측 금지. 실제 일어난 것만.
