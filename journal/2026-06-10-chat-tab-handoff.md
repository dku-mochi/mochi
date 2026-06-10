---
level: 3
mode: log
status: active
last_verified: 2026-06-10
confidence: 0.9
owners: [송준서]
title: 채팅 탭 구현 Handoff — 백엔드 PR-1~3 + iOS PR-1 완료, 잔여 BE PR-4·iOS PR-2~5
description: 채팅 탭(기록 기반 질문·요청 대화) 구현의 세션 인수인계. 설계 정본은 2026-06-10-chat-tab-design.md, 이 문서는 "무엇이 끝났고(커밋 맵·리뷰 반영 내역) 무엇이 남았는가(BE PR-4, iOS PR-2~5, 머지 절차, 이연된 nit)"의 단일 원천. 채팅 작업을 이어받는 사람·AI는 design 문서 → 이 문서 순으로 읽어라.
---

# 채팅 탭 구현 — Handoff (2026-06-10)

> 설계 정본: [`2026-06-10-chat-tab-design.md`](2026-06-10-chat-tab-design.md) (왜 이 구조인가). 이 문서는 **진행 상태와 잔여 작업**만 소유한다.

## 0. TL;DR

채팅 탭 **백엔드·iOS 모두 코드 완성** — 백엔드 PR-1~4(스키마·CRUD → agent run·POST-as-SSE → proposal·PATCH·confirmedInstances → web 툴) + iOS PR-1~5(화면 → citation 렌더 → proposal 카드 → 히스토리·자동분리·홈 라우팅 → live 배선). 전 PR 리뷰 완료 — BE PR-4·iOS PR-2~5 는 작업 후 일괄 딥리뷰(사용자 지시)로 **P1 1건(`bytes.lines` 빈 줄 미방출 → 라이브 SSE 전달 0건 — 기존 분석 스트림도 동일 결함) + P2 4건 + nit 2건 발견·전부 반영**(`SSEEventParser` 바이트 단위 재설계 + CoreAgentClientTests 신설). lint/typecheck/테스트(백 164·iOS 전 타겟 7스위트) + ⓪폭포 + ship-precheck(backend·ios) 전부 green. **팀 합의 4건 + Tavily 키 발급 완료**. 잔여: **실기기 E2E**(전송→백그라운드→복귀, 알림 권한), lab 모델 벤치(비블로킹), develop 머지.

브랜치 스택 (전부 develop 기준 직렬 — 순서대로 머지):
```
develop
 └─ feat/be-chat-conversations  4a8e7ce  BE PR-1: 0016 3테이블 + 세션 CRUD + channel chat
     └─ feat/ios-chat-tab       8c599ec  캘린더 테스트 복구(pre-existing, 사용자 지시로 수리)
                                e346e66  iOS PR-1: FeatureChat + 메신저 UI (mock)
         └─ feat/be-chat-run    1c84f45  BE PR-2: agent run + POST-as-SSE + read 툴 + chat@v1
             └─ feat/be-chat-proposals  ace9d44  BE PR-3: proposal 5종 + PATCH + confirmedInstances + chat@v2
                 └─ feat/be-chat-web    a9852fd  BE PR-4: web_search(Tavily)+web_fetch(가드 재사용) + chat@v3
                                        98c99b1  iOS PR-2: citation 렌더(마커→뱃지·근거 카드·과정 보기)
                                        9cd692b  iOS PR-3: proposal 카드 + 확정 5경로 + channel chat
                                        522b9e4  iOS PR-4: 히스토리·30분 자동분리·홈 라우팅 전환
                                        039d808  iOS PR-5: live 배선(SSE·복귀 폴링·워치독 75초)
```

## 1. 대화 흐름 — 어떻게 여기까지 왔는가

1. **설계** (design 문서에 전부 기록): proposal 패턴(LLM 루프 read-only) · POST-as-SSE · 한도/윈도우 수치 · 툴 7종 확정. doc-guardian STOP 2건은 사람 결정으로 해소 — M1(PATCH 신설, **범위 넓게**: 사용자 2차 결정으로 instance payload 까지) · M2(사용자 확정 instance 는 분석 생략).
2. **구현 순서**: BE PR-1 → iOS PR-1(사용자 지시로 백엔드 직후 iOS 선행, /swiftui-design 사용) → BE PR-2 → BE PR-3. 각 PR 마다 code-reviewer 딥리뷰 → P1/P2 반영 → ship-precheck → 커밋.
3. **사용자 피드백 반영**: ① 채팅 입력바가 탭바와 이중 레이어로 어색 → **플랫 독**(탭바와 같은 불투명 흰색+헤어라인, X DM 패턴)으로 교체 ② 캘린더 테스트 pre-existing 컴파일 실패 수리 지시 ③ PATCH 필드 "훨씬 넓게" ④ 팀 합의 4건 완료 통보.

## 2. 현재 코드 상태 — 작동 가능 여부

**백엔드** (`make test` 158 passed / lint / typecheck / `make openapi` no-diff): 서버 띄우고 마이그레이션(0016·0017) 적용하면 `/conversations` 전 라우트 동작. 단 **실 LLM 호출(GeminiChatClient)은 Vertex 자격증명 환경에서만** — 유닛테스트는 fake LLM. `gemini_chat_model` 기본 flash-lite.

**iOS** (`tuist build`·`tuist test` 전 타겟 green, 경계 0 위반): 채팅 탭이 **mock 스트림**(`MockChatStreamClient`, AppDependencies 주입)으로 풀 플로우 데모 가능 — 칩 탭 → 툴 pill → 타이핑 → 스트리밍 답변. 서버와 통신하지 않음(live 는 PR-5).

핵심 파일 지도:
- BE: `app/modules/conversations/` — application/`begin_chat_turn.py`(409·암묵생성)·`run_chat_turn.py`(루프 본체), infrastructure/`run_registry.py`·`gemini_chat_client.py`·`turn_store.py`·`tools/{search_items,get_item_detail,propose}.py`, prompts/`chat_prompts.py`(chat@v2 활성)
- BE 확정 실행 경로: `mochi_items/application/update_mochi_item.py`(PATCH) · `ingest.py`(confirmedInstances 분기)
- iOS: `Targets/Features/FeatureChat/` + `Cores/CoreAgentClient/ChatStreamClient*.swift`
- 계약: `mochi-backend/openapi.json`(=iOS 미러) + SSE wire format 은 `conversations/presentation/router.py` docstring(서버 정본) ↔ iOS `ChatStreamEvent`(클라 정본) — ARCHITECTURE §3.6 에 ⓪ 예외 명문화

## 3. 결정 / trade-off (이번 세션의 리뷰 반영 — 왜 고쳤나)

**BE PR-2 리뷰 (P1 1 + P2 4 전부 반영):**
- **P1 — search_items 날짜 KST 정규화**: 프롬프트가 {now}를 KST 로 주는데 모델의 offset 없는 ISO 를 naive 로 두면 asyncpg 가 UTC 간주 → "오늘" window 가 9시간 밀려 00~09시 기록 누락. naive → KST 부여로 수정. **대표 시나리오("이번주 공부 기록")의 정확성 버그라 P1.**
- P2 — 409 가드 TOCTOU: 동시 POST 2건이 모두 has_running_run 통과 가능 → **마이그레이션 0017 partial unique index**(대화당 running 1행)로 DB 가 흡수, IntegrityError→409 변환. 암묵 생성 PK 동시충돌도 동일 처방.
- P2 — stale 임계 파생화: `stale_threshold_seconds(timeout)` = max(90, timeout+30) — .env 로 타임아웃 올려도 살아있는 run 을 FAILED 오판 안 함.
- P2 — 라운드 경계 개행: 툴콜 전 선행 텍스트와 최종 답변의 무구분 연결 방지(스트림·영속 동시 반영으로 스냅샷 정합 유지).
- P2 — SSE payload 키를 라우터 docstring 에 명시(PR-5 구현자의 오매핑 방지).

**BE PR-3 리뷰 (P1 0 + P2 2 반영):**
- P2 — archiveReason 위생: 비-archived 전이에 끼면 active 행에 reason 영속 → propose `_parse_lifecycle` 와 PATCH 라우터 양쪽에서 **무시(None 강제)**.
- P2 — chat@v2 회귀 가드: V2 가 `V1.body.replace()` 파생이라 V1 수정 시 silent no-op 으로 "쓰기 불가" 규칙 부활 위험 → `test_active_chat_prompt_is_v2_with_proposal_rules` 로 고정.

**iOS PR-1 리뷰 (P2 1 반영)**: 툴만 돌고 실패한 턴의 빈 버블 껍데기 제거(text 비면 무조건 제거 — "과정 보기" UI 가 들어올 때까지).

**의도된 동작으로 결정한 것**: search_items 의 intent 필터는 archived instance 도 매칭(완료된 약속도 회상 대상 — 코드 주석 명시). 세션 제목 = 첫 메시지 40자 truncate(LLM 요약 안 씀).

## 4. 미완 결정 / 사람 액션 대기

- ~~web_search 프로바이더 키 발급~~ — **완료(2026-06-10)**: Tavily 키 발급·`.env` 설정, `docs/TODO.md` §4.4 기록. PR-4 구현 완료.
- **codex 재리뷰 여부** — codex 사용량 한도(2026-06-11 13:11 복구)로 오늘 리뷰는 전부 code-reviewer 자체 딥리뷰(BE PR-4 + iOS PR-2~5 일괄 리뷰에서 P1 1건 적중·수정). 복구 후 codex 재확인 여부는 사람 판단.
- **머지 절차** — 스택 순서대로 develop 에 머지(또는 squash 단일 PR). push 는 사용자 확인 필요(워크플로우 규칙).

## 5. 다음 단계 + 검증 기준

| # | 작업 | 검증 |
|---|---|---|
| 1 | ~~BE PR-4~~ **완료(a9852fd)**: tool_factories + web_fetch 래퍼(HTML 텍스트화+truncation) + web_search(Tavily) + chat@v3(출처 3원 구분) + PRIVACY §10·TODO §4.4 폭포 | 키 게이트 테스트 포함 164 passed + lint/typecheck/precheck ✅ (리뷰는 사용자 지시로 스킵) |
| 2 | ~~iOS PR-2~~ **완료(98c99b1)**: ChatMarkup(raw 보관·표시 직전 변환·미완성 꼬리 트리밍) + 위첨자 뱃지 + 근거 미니카드(탭→로컬 id 해석→상세) + "과정 보기" | 마커 치환 5 테스트 green. 시뮬레이터 육안은 사용자 |
| 3 | ~~iOS PR-3~~ **완료(9cd692b)**: 상태머신 + 확정 5경로 + 404=만료 + iOS `IngestChannel.chat` 신설 | TestStore 5분기 green. 알림 실기기는 사용자 |
| 4 | ~~iOS PR-4~~ **완료(522b9e4)**: 히스토리 시트·30분 자동분리·홈 라우팅 전환 + UX_SPEC 폭포. MainTab 라우팅 테스트는 App 테스트 타겟 부재로 미작성 — fold·자동분리·재개는 ChatFeature 레벨 테스트로 커버 | TestStore green |
| 5 | ~~iOS PR-5~~ **완료(039d808)**: LiveChatStreamClient(SSEEventParser 공유·워치독 75초) + OpenAPIChatClient + 복귀 스냅샷 폴링(2초×45) + live 치환 | TestClock 폴링 테스트 + ship-precheck ios ✅. **실기기 E2E 는 사용자** |
| 6 | lab: flash-lite vs flash 툴콜 정확도 벤치 → `gemini_chat_model` env 결정 (비블로킹) | lab/ FINDINGS |
| 7 | 머지: 스택 순서대로 develop. 각 머지 전 `bash .claude/scripts/ship-precheck.sh all` | precheck ❌ 0 |

**이연된 nit (의도적으로 안 고침 — 다음 작업자가 닿을 때):**
- run 중 RuntimeError 시 스트림에 뜬 proposal 이 스냅샷에 없을 수 있음 → iOS PR-3 의 expired 처리에 포함할 것 (PR-3 리뷰 nit)
- propose args 의 비-dict 타입은 generic 에러로 떨어짐(복구는 됨), reminder 의 related_mochi_item_id 실재 미검증(딥링크 dangle 가능)
- `gemini_chat_client` max_output_tokens=1024 + finish_reason 미확인(긴 요약 절단 가능), `store.append` bool 미확인(soft-delete 된 대화 — 무해)
- confirmedInstances 경로의 item 은 summary/category 영구 None(검색은 text 로 동작) — 필요해지면 확정 시 title 을 summary 로 복사 검토

**기존 drift (이번 작업 범위 밖, 별도 이슈 후보):**
- `search/infrastructure/postgres_index.py` BM25/vector 에 `deleted_at IS NULL` 누락 (§3 위반 — 신규 search_items 툴엔 포함했음)
- `mochi-ios/README.md` stale 2건: 수기 URLSessionMochiAPIClient 서술(⓪승격 전), 구 단일 lifecycle 체인 표
