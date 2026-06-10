---
level: 3
mode: log
status: active
last_verified: 2026-06-10
confidence: 0.85
owners: [송준서]
title: 채팅 탭 설계 확정 — proposal 패턴 + SSE 생성/전달 분리 + 툴 목록
description: 채팅 탭(멀티턴 RAG 대화)의 백엔드·프론트 설계 토론과 확정 결정 로그. 코드 변경 없음(설계만). LLM 루프 read-only + proposal 카드 패턴, SSE 생성/전달 분리, 툴 목록·한도 수치, 프론트 이벤트 스키마를 담는다. 채팅 탭 구현(백엔드 conversations·iOS FeatureChat)을 시작하기 전 읽어라. 송준서 승인 — 단, API 계약(⓪)·channel enum 신설은 팀 합의 선행.
---

# 채팅 탭 설계 확정 — 2026-06-10

> 코드 변경 없음. **설계 토론 + 결정 확정**만. 다음 세션이 doc-guardian → architect 플랜부터 이어받으면 된다.

## 한 일

- 채팅 탭(현재 placeholder)의 제품 방향·백엔드·프론트 설계를 토론하고 핵심 결정을 확정했다.
- 채팅의 정체성 재확인: **검색이 아니라 "기록 기반 질문·요청 채팅"** (UX_SPEC §3.4 2026-06-10 메모와 일치). 대표 시나리오 — "오늘 데이트 어디서 할까?"(기록+웹 추천), "이번주 공부하려고 기록한 것 알려줘"(시간+intent 회수), "이 메모 없애줘/수정해줘"(행동).

## 결정 / 이유

### 제품 (탭 구성)

- **탭 탭 → 세션 리스트가 아니라 바로 대화 화면.** 대화가 짧은 과업형이라 "지난 대화 재개" 빈도가 낮고, 메신저 감각("모찌에게 묻는다")이 캐릭터 브랜드와 맞다. 세션 리스트는 상단 히스토리 아이콘 뒤(시트/push).
- 빈 대화 상태: 모찌 캐릭터 + 인사 1줄 + 추천 칩 4종(찾기·추천·요약·수정 — 홈과 동일, 능력 폭 교육용) + 하단 입력바(자동 포커스 X — 키보드가 칩·인사를 가림).
- 세션 단절: 명시적 "새 대화" 버튼 + 비활성 시간 기반 자동 분리. 사용자가 세션을 관리하게 하지 않는다(미션 — "모찌가 알아서").

### 아키텍처 핵심: LLM 루프는 read-only, 모든 쓰기는 proposal 카드 ✅ 채택

수정·삭제·일정·알림·메모 생성 툴은 **DB를 직접 건드리지 않고 구조화된 proposal 만 반환** → 채팅 버블에 확인 카드 렌더 → 사용자가 탭하면 **기존 REST 엔드포인트**가 실행.

- 끊김 안전: 루프에 부수효과가 없어 사용자 이탈·서버 죽음에도 데이터 불변. 재시도/중복 실행 문제 소멸.
- 파괴적 행동 확인 UX가 공짜로 따라옴 (휴먼인더루프 pending tool 상태머신 불필요 — MVP 과설계 회피).
- 알림 구성 고민 해소: 알림 proposal 확정 시 **iOS 로컬 알림**(UNUserNotificationCenter) 등록. 백엔드 테이블·스케줄러·푸시 배선 불필요. 크로스디바이스 필요가 생기면 그때 서버 푸시로 승격.
- 비용: "이 메모 없애줘"에 탭 1회 추가 — 어차피 원하던 확인 동작.

### 백엔드

**SSE — 생성과 전달의 분리.** uvicorn 기본 동작은 클라이언트 끊김 시 제너레이터 취소(= 생성 중단)라, 요청 핸들러 안에서 루프를 직접 돌리지 않는다:

```
POST /conversations/{id}/messages
  → agent run 을 asyncio.create_task 로 분리 실행
  → 각 단계(assistant 텍스트·tool call·결과)를 messages 에 즉시 영속
  → SSE 응답은 in-process queue(run_id → queue) 구독·중계만
```

- 끊겨도 태스크는 완주, 복귀 시 `GET /conversations/{id}/messages` 스냅샷 재조회 (Last-Event-ID 스트림 재개는 MVP 불필요).
- Redis 등 외부 브로커 불필요(단일 인스턴스 in-memory). 서버 재시작 시 진행 중 run 유실은 감수 — run status(`running/completed/failed`) + stale 타임아웃 처리만.
- 완주 근거: 루프 read-only라 무위험, 비용 미미, "돌아왔더니 답이 와 있다"가 모찌다움.

**한도 수치:**

| 항목 | 값 | 근거 |
|---|---|---|
| max tool | 5라운드 / 총 8콜 | 전형 1–2라운드, 웹 체인 3. 초과 시 "지금까지 찾은 걸로 답변" 폴백(에러 아님) |
| run 타임아웃 | 60초 | SSE 대기 사용자 기준 |
| 컨텍스트 윈도우 | 최근 20 messages(≈10턴) 슬라이딩 | 세션 자동 분리 설계라 초과가 드묾. 요약 압축은 MVP 생략 |
| 히스토리 내 tool result | 상위 3건 id+제목으로 축약 | tool result 가 토큰 대부분. 현재 턴 것만 풀 |
| search top-k | 8건, 스니펫 200–300자 | 입력 예산 ~16k tokens |

**툴 목록 (확정):**

1. `search_items` — keyword + BM25 시작 (Hybrid Search 는 박세현 lab 실험 후 내부 구현만 교체). **구조화 필터가 본질**: `query?, intent_type?, date_from/to?, channel?, limit` — "이번주 공부 기록"은 시간+intent 필터 문제.
2. `get_item_detail(id)` — 검색은 스니펫만 주므로 후속 질문·수정 proposal 작성에 풀 컨텐츠 필요.
3. `propose_item_update` / `propose_item_delete` — lifecycle 전이(할일 완료 등) 포함, `lifecycle_policy.is_allowed()` 검증 통과 필수.
4. `propose_create_schedule` / `propose_reminder` — 일정 = schedule instance 가진 MochiItem 생성 proposal(확정 시 기존 ingestion 경로). 알림 = iOS 로컬 알림.
5. `propose_create_memo` — "내일 우유 사야 해, 기록해줘". 채팅 = 캡처 표면. ✅ MVP 포함 확정.
6. `web_search` / `web_fetch` — 기존 SSRF 가드 경유 필수, 결과 truncation.
7. 툴 아님: 현재 시각·타임존·"이번주" 범위는 시스템 프롬프트 주입 ("오늘" 들어간 질문의 전제).

**channel enum 에 `chat` 신설 ✅ 확정** — proposal 확정으로 생성되는 item 의 입력 채널.

**톤 (시스템 프롬프트 4섹션, 기준+이유로 작성 — 예시 나열 금지):**
① 정체성·톤 — 모찌 캐릭터, 해요체, 기본 1–3문장, 과장 금지 ② grounding — 기록 우선, **기억 출처와 웹 출처를 문장 안에서 구분**, 없으면 솔직히, citation 마커 의무 ③ 행동 규칙 — 쓰기는 proposal 로만, 추측으로 item 특정 금지 ④ 사용자 컨텍스트 — 현재 시각·타임존.

**citation 배선:** 모델이 본문에 `【item:id】` 단순 마커 → 서버 파싱 → `message_citations` 영속 + SSE `citation` 이벤트. 마커는 단순할수록 flash 계열 신뢰도가 높다.

**모델:** flash-lite 는 멀티스텝 tool-calling 신뢰도가 약할 수 있음 → lab 에서 flash-lite vs flash 툴콜 정확도 측정 후 채팅 루프 모델 결정 (비용 최우선 원칙 유지하되 루프만 예외 후보).

### 프론트 (iOS)

**SSE 이벤트 스키마 (렌더링 기준):**

```
message_delta  {text}
tool_started   {name, label}        — "기록을 뒤지고 있어요…"
tool_finished  {name, summary}      — "기록 6개를 찾았어요"
citation       {index, item_id, title, snippet}
proposal       {type, payload}      — 확인 카드
done           {message_id} / error
```

- **출처**: 문장 끝 번호 뱃지(¹²) 인라인 + 버블 하단 근거 모찌 미니카드 행. 탭 → 상세 zoom. 스트리밍 중 마커 자리 치환 렌더.
- **툴 로딩**: `tool_started/finished` 를 모찌 상태 버블로 — 캐릭터 애니메이션 + 툴별 동사형 카피. 완료 후 답변 위 접힌 "과정 보기" 1줄(탭 펼침). 스피너 금지(캐릭터 제품).
- **세션 관리**: 히스토리 리스트(첫 질문 요약 자동 제목) 스와이프 삭제 → `DELETE /conversations/{id}` (soft delete).
- **복귀 처리(숨은 필수)**: iOS 백그라운드 진입 시 SSE 끊김 → 포그라운드 복귀 시 진행 중 run 있으면 메시지 스냅샷 재조회.

### 파급 (구현 시 함께)

1. **홈 입력바 라우팅 변경** — 현재 "제출 시 검색 탭 RAG 회수"(UX_SPEC §3.4) → **채팅 탭 새 대화의 첫 메시지**로. 칩 4종이 광고하는 추천·수정은 검색 탭이 수행 불가.
2. **검색 vs 채팅 역할 분담** — 검색 = 결정적 브라우징(그리드·필터, 3초 룩업), 채팅 = 자연어 질문·행동. 채팅 근거 카드 → 검색/상세 연결.
3. **DOMAIN_DESIGN §10.3 게이트 개방** — `conversations` · `messages` · `message_citations` DDL 확정 + 멀티턴 엔드포인트. **API 계약 ⓪티어 공유표면** — openapi.json 폭포(backend code-first → iOS generate.sh) 타야 함.

## 추록 (같은 날 후속) — doc-guardian 스캔 + architect 플랜 완료

### doc-guardian STOP 2건 → 송준서 결정으로 해소

- **M1** — 수정 proposal 확정을 실행할 item 콘텐츠 수정 REST 부재 → **`PATCH /mochi_items/{id}` 신설** 확정. 필드 범위는 **넓게**(송준서 2차 결정 — "좁게 시작" 권고 기각): `text`/`user_memo`/`summary` + `instances[]`(instance `payload`/`label` 수정 및 lifecycle 전이 포함, 한 트랜잭션) — "이 일정 3시로 바꿔줘"가 MVP 에서 동작해야 함. proposal 확정 = REST 1콜 유지(부분 적용 실패 모드 회피). lifecycle 전이는 PATCH 내부에서도 `lifecycle_policy.is_allowed()` 검증.
- **M2** — 일정 proposal 확정 item 이 분석 파이프라인을 다시 타면 확정 내용과 다른 결과 가능(§5.2 "instance 는 분석 성공 시에만 생성" 충돌) → **분석 생략 + 확정 instance 직접 생성** 확정. 구현: 별도 라우트 대신 기존 `POST /mochi_items` 에 optional `confirmedInstances` 확장(단일 ingest 결정 유지) — 존재 시 instance 즉시 active 생성 + `lifecycle_kind='analyzed'` + outbox 미적재, Idempotency-Key 로 멱등. §5.2 에 예외("사용자 확정 = 분석보다 상위 신뢰") 명문화를 **구현과 같은 PR 에**. memo 확정은 기존대로 분석 경유.

### 플랜 레벨 결정 (부모 Claude)

- **A1 (SSE × ⓪)**: SSE 라우트는 openapi.json 에 명시하되 iOS 는 raw URLSession 소비(기존 `LiveAgentStreamClient` 전례). ⓪ 예외를 ARCHITECTURE §3.6 에 명문화.
- **계약 형태**: **POST-as-SSE** — `POST /conversations/{id}/messages` 응답이 곧 SSE 스트림. 분리형(202+GET stream)은 구독 전 이벤트 유실 레이스로 기각. 복귀는 스냅샷 재조회 + running 이면 2초 폴링(run 60초 상한이라 bounded). 동일 conversation 에 running run 존재 시 409.
- conversation 생성: 첫 메시지 POST 가 conversationID 없으면 암묵 생성(라운드트립 절약). 세션 제목은 LLM 요약 대신 첫 user 메시지 40자 truncate.
- iOS: 대화는 **Realm 미러 없음, 서버 단일원천**(§6 규약은 MochiItem 소관 — §10.3 승격 시 예외 명시). 세션 자동 분리 비활성 30분(클라이언트 판정, UserDefaults). 히스토리는 시트. `recallRequested` → `chatRequested` rename.
- web_search 프로바이더 권고 1순위 **Tavily**(무료 1,000회/월, LLM-agent 전용) — 키 발급은 사람, 키 미설정 시 툴 레지스트리 제외로 PR 블록 안 함.
- privacy(A3): 시스템 프롬프트 행동규칙에 "기록 원문·식별 가능 파생 표현을 외부 검색 쿼리에 넣지 않는다" 명시. PRIVACY 문서 1절 추가는 폭포에서.

### PR 구조 (상세는 architect 산출 — 재도출 가능)

```
백엔드: PR-1 스키마+모듈 골격+세션 CRUD (LLM 없음)
      → PR-2 agent run+SSE+read 툴 2종+프롬프트+citation
      → PR-3 proposal 툴 5종+PATCH+confirmedInstances (M1·M2, §5.2 예외 동봉)
      → PR-4 web_fetch 팩토리+web_search (키 합의가 이것만 블록)
iOS:   PR-1 Core 계약+FeatureChat 스캐폴드+기본 대화 UI (mock, 즉시 착수 가능)
      → PR-2 툴 상태 버블+과정 보기+citation ┐
      → PR-3 proposal 카드+확정 5종           ├ 병렬 (전부 mock, 백엔드 무관)
      → PR-4 세션 관리+홈 라우팅 전환+UX_SPEC 폭포 ┘
      → PR-5 live 배선 (블로킹: 백엔드 PR-1~3 + openapi 폭포 + ⓪합의)
```

핵심 구조: 백엔드는 신규 `app/modules/conversations/` 자급자족형(ARCHITECTURE §3.2 의 낡은 동기 SendMessage 트리는 폐기·교체). 기존 `GeminiAgentClient` 는 finalize 전용이라 재사용 불가 → `GeminiChatClient`(mode=AUTO, stream) 신설, 모델은 `gemini_chat_model` env(기본 flash-lite, lab 벤치 후 교체). WebFetchTool(SSRF 가드)은 `agent/application/tool_factories.py` 팩토리 경유로 경계테스트 통과(가드 무수정). run 영속은 별도 테이블 없이 user message 행에 `run_id/run_status/run_started_at` + 읽기 시점 90초 lazy stale repair. 테이블 3개: `conversations`(soft delete) / `messages`(role·tool_payload·proposals jsonb) / `message_citations`(item FK 없음 — 삭제 후 출처 스냅샷 보존). iOS 는 `ChatStreamClient`(기존 AgentStreamClient 와 별도 프로토콜 — enum 합치면 과설계) + `ChatAPIClient`(CoreNetworking, MochiAPIClient 와 분리해 mock 병렬 진행) + proposal 카드 상태머신(`pending→confirming→confirmed/cancelled/expired/failed`, 404=만료, 알림 권한 거부 시 failed+설정 열기).

### 발견된 기존 drift (이번 작업서 안 고침, 기록만)

- `mochi-backend` `search/infrastructure/postgres_index.py` BM25/vector 쿼리에 `deleted_at IS NULL` 누락 — §3 "모든 조회 가림" 위반. 신규 search_items 툴엔 필터 포함, 기존 건 별도 이슈.
- `mochi-ios/README.md` stale 2건: "수기 URLSessionMochiAPIClient" 서술(⓪승격 전 내용) + 구 단일 lifecycle 체인 표. 채팅 작업이 닿는 김에 해소 권고.
- ARCHITECTURE §1 다이어그램 "planned: /search /conv." ↔ /search 라우트 실재. 채팅 라우트 추가 시 함께 해소.

## 다음 할 일

1. **팀 합의 (편집보다 리드타임 지배)**: ① ⓪ API 계약 일괄 — conversations 라우트군 + PATCH /mochi_items + confirmedInstances 확장 + SSE 명시 방식, ② channel enum `chat`(백엔드 + iOS CoreDomain 동시), ③ DOMAIN_DESIGN §5.2 불변식 예외(L2), ④ web_search 키(Tavily 권고, PR-4 만 블록)
2. 합의 대기와 무관하게 착수 가능: iOS PR-1(mock) + 백엔드 PR-1(스키마·CRUD — 단 머지는 합의 후)
3. lab — flash-lite vs flash 툴콜 정확도 벤치 (PR-2 머지 후 env 교체만이라 비블로킹)
4. 문서 폭포는 각 PR 동봉 (체크리스트는 architect 산출 — DOMAIN_DESIGN §2/§5.2/§6.4/§10.3, ARCHITECTURE §1/§2.2/§2.3/§3.2/§3.4/§3.6, openapi.json, 양 README, TODO.md, UX_SPEC §1.5/§2/§3.4/§3.5/§5+신규 절, PRIVACY 1절, CHANGELOG)

## 막힌 것 / 사람 결정 필요

- **팀 합의 4건** (위 다음 할 일 1번) — 송준서 단독 결정은 끝났고, 3인 공유표면 합의만 남음.
