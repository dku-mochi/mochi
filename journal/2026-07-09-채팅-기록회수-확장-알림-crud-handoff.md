---
level: 3
mode: handoff
status: active
last_verified: 2026-07-09
confidence: 1.0
owners: [송준서]
description: 채팅 기록 회수 표면 확장(누락 필드+TOP_K) + Recall Plan 채팅 CRUD(읽기·시각이동·취소, iOS 배선까지) 완료 핸드오프 — 미커밋, 후속 3건.
---

# 채팅 기록 회수 확장 + 알림 CRUD — Handoff (2026-07-09)

## 0. TL;DR (한 화면)

두 가지를 끝냈다. 둘 다 **백엔드+iOS 완료·검증, 미커밋**.

1. **채팅이 mochi item 의 절반만 보던 문제** — `search_items`/`get_item_detail` 이 aggregate 의 절반만 노출했다. 특히 코드 주석에 "능동 회수에 활용"이라 못박힌 `is_favorite`/`importance` 를 회수 주체인 채팅이 못 봤고, `place`(좌표·주소·별점)·`reference_links` 도 빠졌다. → 누락 필드 전부 노출 + 검색 상한 `TOP_K` 8→25.
2. **Recall Planner 가 만든 예정 알림을 채팅에서 못 읽고·못 바꾸던 문제** — 홈탭에서만 조정 가능했다. → 조회 툴 `list_notifications`(+"내일 알림?" 시각 필터) + 시각 이동·취소 propose 카드 2종 + iOS 배선.

검증: 백엔드 **537 passed**·lint·typecheck green, codex 2회(P0/P1 없음), iOS **Build Succeeded**. 커밋/PR·프롬프트 가이드·E2E 실기기는 안 함(§6).

## 1. 대화 흐름 — 어떻게 여기까지 왔는가

- 시작 질문: "현재 채팅이 mochi item 을 가져와 볼 수 있는 게 뭔가? 위치·알림 플랜도 넘어가나? 아이템 몇 개에서 context 를 자르나?"
- 조사 결과 두 갭 발견 → 사용자가 "place 말고 빠진 것 꼼꼼히 봐라 / TOP_K 8 너무 작다 / Recall Planner 에이전트가 실제로 있으니 그 알림 Plan 을 채팅에서 CRUD 하게 만들어라" 로 확장 지시.
- architect(Opus)로 알림 CRUD 설계 → 사용자에게 **편집 깊이**·**iOS 진행 범위** 2개를 물어 결정받음(§4).
- 구현 중 사용자가 "'내일 오는 알림 뭐 있어?' 에도 답하나?" 질문 → 서버 시각 필터(`fire_from`/`fire_to`)를 추가로 관통.

## 2. 현재 코드 상태 (작동 가능, 미커밋)

작동 가능. 백엔드 전체 green, iOS 컴파일 green. **아래는 이번 세션 변경분만** — 작업트리엔 다른 세션의 미커밋 변경(`upcoming_override*`, `test_place_*` 등)도 섞여 있으니 커밋 시 분리할 것.

### backend (`mochi-backend`)
- `app/modules/conversations/infrastructure/tools/get_item_detail.py` — item 레벨 place·reference_links·importance·is_favorite·category·shopping·has_images + instance reasoning·archive_reason 노출. **DB/repository 무변경**(repository 가 이미 로드하던 걸 툴이 버리던 문제).
- `.../tools/search_items.py` — 결과에 importance·is_favorite, `TOP_K` 8→25·`RERANK_CANDIDATES` 24→50·compact 3×60→10×120.
- `.../tools/list_notifications.py` **(신규)** — 예정 알림 조회 read 툴. `mochi_item_id`·`fire_from`/`fire_to` 필터.
- `.../tools/propose.py` — `ProposeRescheduleNotificationTool`·`ProposeCancelNotificationTool` + `make_upcoming_reader`. `_find_upcoming`(owner-scoped 매칭).
- `.../presentation/router.py` — 툴 3종 등록.
- `app/modules/notifications/application/repositories.py` — `make_upcoming_feed_repository`(cross-module 진입점).
- `.../application/get_upcoming_notifications.py`·`.../domain/upcoming_feed.py`·`.../infrastructure/upcoming_feed_repository.py` — `list_upcoming` 에 `item_id`/`fire_from`/`fire_to`(fire_to exclusive) 관통 + join plan owner 가드.
- tests: `test_chat_list_notifications.py`(신규), `test_chat_proposals.py`·`test_chat_run.py`·`test_chat_search_items.py`·`test_get_upcoming_notifications.py`.

### iOS (`mochi-ios`)
- `Targets/Cores/CoreAgentClient/Sources/ChatStreamClient.swift` — `ChatProposal.Kind` 에 `notification_reschedule`/`notification_cancel` + payload struct + `init?` 파싱.
- `Targets/Features/FeatureChat/Sources/ProposalCardView.swift` — 두 kind 카드 스타일.
- `Targets/Features/FeatureChat/Sources/ChatFeature.swift` — `execute` 에 두 action 분기 → `apiClient.rescheduleUpcoming`/`vetoUpcoming`(**기존 메서드 재사용**).

### docs
- `docs/CHANGELOG.md`(2건), `docs/ARCHITECTURE.md`(§3.6 proposal type), `docs/DOMAIN_DESIGN.md`(Favorite 회수 경로에 채팅 병기).

### 계약 상태
- **openapi.json 무변경** — 채팅 툴은 내부, 알림 조정은 기존 REST(`/recall/upcoming/{event_id}/reschedule`·`/veto`) 재사용. iOS generator 재생성 불필요.
- SSE proposal wire 는 openapi 밖 — 서버 라우터 docstring ↔ iOS `ChatProposal.Kind` 가 정본이며 양쪽에 새 type 2종 반영 완료(1:1).

## 3. codex 검증 결과

`codex exec`(read-only, medium) 직접 호출 2회. 둘 다 통과.

- **필드 확장/TOP_K**: P1(reasoning 노출)·P2(usefulness 노출) 제기됐으나 **실제 도메인 계약 대조 후 REJECT** — reasoning 은 `mochi_items` 상세 API(`schemas.py:199`)로 이미 iOS 노출, usefulness 는 resource_finder 신뢰 UI 노출값. TOP_K 주석 과장("latency 무관")만 수정. 빈 dict P3 는 PlaceInfo/ReferenceLink 필수필드라 불가(REJECT).
- **알림 CRUD**: **P0/P1 없음**. owner 가드·cross-tenant 방어(event_id 로 남의 알림 조작 불가 — REST 확정 경로가 `(event_id, owner_id, pending, fire_at>now)` 재검증)·필터 순서(WHERE 먼저)·kind 분기·모듈 경계 모두 양호 확인. **P3 2건 반영**: (1) invalid `fire_from/fire_to` → error(조용히 무시하면 "내일 알림?"에 전체 답), (2) join 된 plan 에 `owner_id == owner_id` defense-in-depth 추가.

## 4. 결정 / trade-off (왜 이렇게 했는가)

- **편집 깊이 = 시각 이동 + 취소만**(사용자 결정). 알림 문구/plan 구조 편집은 openapi+DSL+iOS 4중 폭포 + "사용자가 알림 설계를 손으로" = 미션 역행("회수의 능동 주체는 모찌")이라 제외.
- **iOS 배선까지 진행**(사용자 결정). 기존 recall REST 재사용이라 openapi 폭포 없이 SSE proposal wire 만 iOS 3파일.
- **reasoning/usefulness 유지** — 이미 사용자-facing 노출값이라 채팅 노출이 새 노출면 아님(codex 근거 대조).
- **TOP_K=25 는 방침 상향** — `lab/archive/rag-rerank-eval` 이 @10 천장 + 작은 코퍼스라 TOP_K 축을 측정 못 함(FINDINGS 명시). RERANK_CANDIDATES=50 만 파이프라인 C 로 검증된 값.
- **알림 시각 필터는 error, 검색 occurs 는 graceful** — 갈라지는 이유: 알림 조회는 시각이 질문의 본질(무시하면 오답), 검색은 키워드가 본체(occurs 는 보조).

## 5. 미완 결정 (사용자 선택 대기)

**없음.** 스코프(편집 깊이·iOS 범위)는 §4 에서 확정됐다. 아래 §6 은 결정이 아니라 남은 작업.

## 6. 다음 단계 + 검증 기준

1. **커밋/PR** — 미실행. 작업트리에 타 세션 미커밋 변경이 섞여 있으니 이번 변경분(§2 목록)만 골라 스테이징 → `/ship`(백엔드 lint/typecheck/openapi 동기화 게이트) → 커밋. 검증: `/ship` 7단계 green.
2. **프롬프트 가이드(③)** — `chat_prompts.py` 는 criteria-based 라 툴 description 으로 커버 중. "알림 질의 시 list_notifications 우선", "propose_reminder(로컬 원샷) vs 서버 알림 조정 혼동 방지" 를 본문에 넣을지는 **overfit 위험이라 E2E 관찰 후 research-first**(Gemini+skill-creator 조사)로 결정. 검증: 관찰된 오선택 케이스가 실재할 때만 착수.
3. **E2E 실기기** — "내 알림 뭐 있어?"·"내일 오는 알림?"·카드 확정→시각 이동/취소 동작 확인. `tuist test`(시뮬레이터 부팅)·실기기는 사용자 직접 영역. 검증: 카드 확정 후 `/recall/upcoming` 반영.
4. **lab 코퍼스 1000+ 확장** — TOP_K=25 재현율 실측 근거 마련(현 eval @10 천장). 별도 스코프.

## 7. 컨텍스트 부채 (다음 세션이 먼저 볼 것)

- `docs/ARCHITECTURE.md` §3.6 — SSE proposal wire 계약(openapi ⓪ 예외, iOS↔서버 docstring 1:1 규칙).
- `app/modules/conversations/infrastructure/tools/propose.py` 상단 docstring — propose 패턴(카드 payload 만 반환, 확정=REST). 새 카드 추가 시 이 규약 준수.
- `app/modules/notifications/domain/recall_plan.py` — 알림 Plan stages DSL(문구/구조 편집을 언젠가 하면 여기 + `validate_for`).
- `app/modules/notifications/presentation/recall_router.py` — 기존 REST(reschedule/veto/upcoming). 채팅 확정이 태우는 실행 경로.
- 편집 깊이 확장(문구=플래너 재생성 / 구조 편집)은 **의도적으로 안 함** — 재개 시 §4 의 미션 근거부터 다시 볼 것.
