---
level: 3
mode: log
status: draft
last_verified: 2026-06-08
confidence: 0.7
owners: [송준서]
title: 홈 "모찌가 정리했어요" 보드 + agent action materialize 설계 탐색
description: 홈 심심함 해결을 위한 새 보드 아이디어가 "agent가 action tool 호출 → 텍스트+행위 동시 생성"이라는 제품 본체(action materialize) 설계로 번진 토론 로그. 코드 변경 없음(설계만). 홈 보드를 만들거나 백엔드 action tool/iOS 알림 실행부를 건드리기 전 읽어라. 미승인 — 분기·스코프 미정.
---

# 홈 "모찌가 정리했어요" 보드 + agent action materialize 설계 탐색 — 2026-06-08

> 코드/문서 변경 없음. **설계 토론만** 했다. CHANGELOG 미추가(결과 없음). 다음 사람이 architect 플랜부터 이어받으면 된다.

## 한 일

- 홈탭 현 구조 파악: 섹션 3개뿐 — ①"지금 확인해 주세요"(`needsReview`), ③"최근에 보낸 것들"(`recent`), ②"모찌가 정리하고 있어요"(`analyzing`, 접힘). 셋 다 **비면 사라지는 일시적 섹션** → 모찌가 일을 잘 할수록 홈이 비는 역설(= "심심함"의 근원).
- 새 섹션 "모찌가 정리했어요"(처리 결과 보드) 아이디어를 단순 UI 카피 → **agent action tool 아키텍처**까지 확장 탐색.
- 코드 근거 확인:
  - `actionCandidate`: iOS 분석 응답에서 **빈 채로 옴**(`MochiItemDTO+Analysis`가 `payload`만 매핑, DOMAIN §451). 클라 소비부는 `openURL`뿐 — `createReminder`/`createCalendarEvent` 실행 배선 없음.
  - **로컬 알림 자동 스케줄링 코드 0** (`UNUserNotificationCenter`는 권한 요청만, 실제 `UNNotificationRequest` 없음).
  - 백엔드 `app/modules/agent/`가 **이미 tool-calling agent loop**. `Tool` 베이스가 Gemini function-calling 스키마 자동생성(`tools.py:29`), `ToolName.CALENDAR_SYNC` enum 자리 있음(미등록). 현재 등록 tool은 `platformContext`/`webFetch`뿐 — "Arch2: LLM이 분석가다"라 분류·요약은 tool 아닌 `finalizeAnalysis` structured output(`registry.py:12`).
  - 문서 drift 발견: `PRODUCT.md §8.4` 본문(4-Intent 요약카드·"중요 제안"·이번 주 저장) ↔ `HomeFeature.swift:10` 주석("홈은 요약 피드가 **아니라** 자동성의 예외 처리")이 **서로 모순**.

## 결정 / 이유

- **새 보드 정체성 = "최근 처리 결과 보드"** (사용자 선택). recent 데이터 기반, intent별 1인칭 카피. 항상 차 있어 심심함 해결 + 미션 톤으로 입히면 자랑 로그가 아니라 안심 보드.
- **미션 원칙 못박음: "모찌가 한다고 말한 것은 실제로 해야 한다."** 카피와 실제 행위는 분리 불가. "알림 보내드릴게요"라고 띄우려면 실제 알림이 걸려 있어야 함 — 아니면 미션("필요한 기억은 떠오른다")의 정반대.
- **사용자 핵심 통찰: agent가 action tool을 호출하면 텍스트+action이 같은 추론에서 나와 일치가 구조적으로 보장**된다(거짓말의 한 축 제거). 인프라가 이미 있어 신규 아키텍처가 아닌 기존 agent 확장.
- 견적 정정: 앞서 "백엔드 맨땅 가정 3~4배"는 **과대평가**. 실제 = 백엔드 action tool 추가(중소·기존 확장) + iOS 실행 소비부(중·신규) + 홈 보드(소). 단 공유표면(백엔드 계약+iOS)이라 팀 합의·openapi 동기화 리드타임 선행.
- `DOMAIN §13` `mochi_action_candidates` materialize 게이트("active instance 안정 + 소비 코드 필요 판명")가 **이 보드로 충족** — design-ahead 살릴 시점.

## 다음 할 일

- architect 플랜 작성. 두 분기를 트레이드오프와 함께 정리:
  - **(A) action을 tool-call로** (agentic·유연) vs **(B) `finalizeAnalysis` 출력 + 결정적 `routed` materialize** (현 철학 일치·통제).
  - **(i) 서버 push(APNs)** vs **(ii) iOS 로컬 알림**(오프라인) — 어느 쪽이든 "실행 소비부" 신규 필요.
- 첫 수 제안: **서버 자체완결 action부터**(knowledge "정리해 뒀어요" = 임베딩/저장 서버서 끝, 거짓말 0). 알림류(디바이스 실행)는 실행부 붙은 뒤 켠다.
- 홈 보드는 카피를 **`reassuranceLine` 슬롯**으로 두기 → 지금은 클라가 "사실만" 채우고, LLM action 완성 후 백엔드 멘트로 승격(화면 무변경).
- 보드 카피 클라 템플릿 초안(승격 전 사실 한정): knowledge "찾기 쉽게 정리해 뒀어요" / schedule "캘린더에서 볼 수 있어요" / memo "기록으로 남겨뒀어요". todo·미래 약속("알림 보내드릴게요")은 실행부 전까지 보류.

## 막힌 것 / 사람 결정 필요

- **스코프 미정**: (가) 홈 보드를 "사실 카피"로 먼저 출시 + action materialize는 다음 트랙 vs (나) action 본체를 지금 스코프에 묶어 한 번에. → 사용자 결정 대기.
- 분기 **A/B**, **i/ii** 미정 (architect가 트레이드오프 제시 예정).
- **§8.4 본문 ↔ `HomeFeature` 주석 drift** 해소 방향 미정 — "홈은 요약 피드다(문서)"로 갈지 "예외 처리다(코드)"로 갈지. 새 보드는 사실상 전자 손을 들어줌. 구현 시 doc-guardian 거쳐 정리 필요.
- ③"최근에 보낸 것들" 처리: 새 보드가 같은 `recent`를 써 중복 → **③을 보드로 대체(승격)** 추천했으나 미확정(되돌리기 기능은 카드 탭→DetailView로 흡수).
