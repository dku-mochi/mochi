---
level: 3
mode: reference
status: draft
last_verified: 2026-06-16
confidence: 0.85
owners: [송준서]
title: 능동 회수 알림·회수 — 폴더 길잡이
description: journal/proactive-recall/ 의 4종 설계 문서가 무엇이고 어디서 무엇을 보는지, 정본 2저널과 이전 저널들이 어디로 흡수됐는지의 길잡이. 능동 회수(알림+화면) 작업을 이어받을 때 가장 먼저 읽어라. 정본은 2026-06-16-notification-planner / 2026-06-15-ux-decision 두 저널이며, 본 폴더는 그 둘을 정제·확정한 산출물이다.
---

# journal/proactive-recall/ — 폴더 길잡이

> 능동 회수(알림 + 화면)의 **정제·확정 산출물**. 과정·토론은 날짜별 저널, 결정은 여기.
> **정본** = `2026-06-16-proactive-recall-notification-planner`(알림) + `2026-06-15-proactive-recall-ux-decision`(화면). 충돌 시 정본이 이긴다.

## 문서 (어디서 무엇을)

| 문서 | 무엇 | 언제 읽나 |
|---|---|---|
| [schema.md](schema.md) | `notification_plan` + `notification_outbox` 2테이블 + stages DSL (codex 검증) | 알림 발송 테이블·마이그레이션·cron을 만들기 전 |
| [notification-agent.md](notification-agent.md) | 알림 정책 + Agent(플래너 hook / 가드 cron) + 발송(서버 push 단일) | 플래너·cron·발송 빌더를 만들기 전 |
| [ux-ui.md](ux-ui.md) | 회수 3단(분류 아님) + 알림 landing 매핑 + 홈 IA | 회수 화면·알림 탭 라우팅을 만들기 전 |
| [tech-plan.md](tech-plan.md) | 구현 순서(P1–P6 A/B · P7–P9 트랙 C) + 선결 + 검증 | 구현 착수 시 |

## 확정된 큰 결정

- **알림 = 알림 설계 Agent(tool-calling loop) + 규칙 가드.** 메인 Agent가 "알림 필요" 판정 → 알림 설계 Agent가 tool(예약조회·수정·생성)로 계획 → cron이 outbox 발송.
- **발송 = 서버 APNs push 단일.** EventKit 무관(능동 회수는 따로 등록 안 함).
- **회수 = 분류 아님.** 3단(홈 한 칸→자세히→상세), 알림 단건은 상세 직행.
- **스키마**: 생성 분리(plan) / 발송 통합(outbox). codex 적대검증 7 ACCEPT·과설계 3 거부.

## 이전 저널 → 흡수 지도

| 이전 저널 | 어디로 |
|---|---|
| `…-notification-planner`(정본) | schema · notification-agent (알림 정책·계획) |
| `…-ux-decision`(정본) | ux-ui (회수 3단·landing·홈) |
| `…-notification-decision` | notification-agent §3(보낸다/참는다 게이트)·§7(위험) |
| `…-tech-design` | schema(2테이블 재배치)·tech-plan(인프라·단계) |
| `…-design`(3트랙 기획) | notification-agent §1(무게/시각)·tech-plan §8(트랙 분리) |
| `…-track-c-bundling-validation` | tech-plan §8(트랙 C 본체, 묶음) |

## 범위 밖 (나중)

채팅 reminder 승격 → `tech-plan.md` §8. EventKit 양방향 미러는 **안 함**(2026-06-16 — 일회성 등록은 별개 유지). (트랙 C 회수 본체·민감 필터는 범위 내 — A/B 다음 단계 P7–P9.)
