---
level: 2
mode: committed
status: active
last_verified: 2026-06-25
confidence: 0.7
owners: [송준서, 이용찬, 박세현]
description: 시스템 토폴로지·iOS↔Backend 데이터흐름·API 계약의 committed 정본. 다음 중 하나라도 손대기 전 반드시 읽어라 — 두 프로젝트 모두 영향, presentation 스키마, openapi.json, Idempotency-Key, WebFetch SSRF 가드, 모노레포 빌드/배포. 일부 "목표 상태" 서술은 docs/l2/aspirational/ 로 분리 예정. 변경 시 양 README·openapi.json·plan(L3) 정합성 폭포 필수.
---

# 모찌(MOCHI) — 시스템 아키텍처

> Multimodal AI 기반 스크린샷·링크·기록 통합관리 에이전트
> 2026 SW중심대학 디지털 경진대회 / 팀 **세얼간이** (송준서·박세현·이용찬)

이 문서는 두 저장소(`mochi-ios`, `mochi-backend`) 가 합쳐 만들어 내는 시스템 전체의 아키텍처를 정리한다. 도메인 모델·테이블 스키마의 자세한 정의는 `DOMAIN_DESIGN.md`.

---

## 1. High-level Topology

```
┌──────────────────────────── iOS Device ──────────────────────────────┐
│                                                                       │
│  ┌──────────────────┐                          ┌──────────────────┐   │
│  │  Share Extension │                          │   Main App       │   │
│  │  (NSItemProvider │                          │  SwiftUI + TCA   │   │
│  │  URL/Text/Image) │                          │  RootFeature     │   │
│  └────────┬─────────┘                          │  4 Features      │   │
│                                                │  6 Cores         │   │
│   ▲ 외부 공유시트                              │                  │   │
│     (ShareEntryView 메모/확인 UI)              │  DesignSystem    │   │
│                                                └────────┬─────────┘   │
│                                                  ▲ 백탭 단축어:        │
│                                                    Take Screenshot     │
│                                                    → 앱과 공유 →        │
│                                                    ShareExtension       │
│                                                    (공유시트로 합류)    │
│           │                      │                      │             │
│           ▼                      ▼                      │             │
│         App Group  (group.app.mochi)                    │             │
│         ├─ Realm DB (mochi.realm)         ←─────────────┘             │
│         ├─ Inbound Queue (*.json)              ← ShareExtension only  │
│         ├─ Pending Back-Tap (verify markers)   ← 백탭 온보딩 검증     │
│         └─ Captured Images (HEIC/JPEG/PNG)                            │
│                                                                       │
│  MochiSyncWorker actor ──►  URLSession (X-Mochi-Request-ID,           │
│                              Idempotency-Key, Authorization)          │
└────────────────────────────────────────────┬──────────────────────────┘
                                             │ HTTPS
                                             ▼
┌──────────────────────────── Backend ──────────────────────────────────┐
│  FastAPI Modular Monolith + Hexagonal Architecture                    │
│                                                                       │
│  ┌────────────────────── /api/v1 ─────────────────────┐               │
│  │  POST /mochi_items   (단일 ingest)                │               │
│  │  POST /mochi_items/presign  GET /mochi_items/{id}  │               │
│  │  GET  /mochi_items/{id}/stream (SSE)               │               │
│  │  POST /devices/push-token (APNs, PR-B)             │               │
│  │  POST /auth/{apple,google,refresh,logout}          │               │
│  │  POST /auth/capture-tokens (ShareExt 직접전송용)    │               │
│  │  GET  /users/me     GET /health                    │               │
│  │  GET/PATCH /users/me/notification-preferences      │               │
│  │  GET  /mochi_items(list)  …/images/download-url    │               │
│  │  POST /search   /conversations/{id}/messages (SSE) │               │
│  │  planned(no route): /sync                          │               │
│  └────────┬────────────────────┬────────────────────┬─┘               │
│           │                    │                    │                 │
│           ▼                    ▼                    ▼                 │
│  ┌──────────────┐    ┌──────────────┐     ┌──────────────┐            │
│  │ mochi_items /│    │   agent /    │     │   search /   │            │
│  │ (Hexagonal)  │    │ (Hexagonal)  │     │ (Hexagonal)  │            │
│  │              │    │              │     │              │            │
│  │ Ingest → DB  │    │ Orchestrator │     │ Hybrid RAG   │            │
│  │ + Outbox     │    │ + Tools      │     │ (BM25+벡터+  │            │
│  │              │    │              │     │  RRF→Rerank) │            │
│  └──────┬───────┘    └──────┬───────┘     └──────┬───────┘            │
│         │                   │                    │                    │
│         └──────► Postgres + pgvector ◄───────────┘                    │
│                 (mochi_items, mochi_item_image_refs, entities,        │
│                  embeddings, idempotency_keys, user_profiles,         │
│                  mochi_item_outbox, agent_runs, tool_calls,           │
│                  users, auth_accounts, refresh_tokens,               │
│                  capture_tokens)                                      │
│                                                                       │
│  Mochi Worker  ──►  LISTEN mochi_item_outbox / poll                   │
│  (FOR UPDATE SKIP LOCKED, AgentRunPersistence, DLQ)                   │
│  Recall Worker ──►  notification_plan/outbox (능동 회수 A/B, dry-run)  │
│  (materialize+가드+종료연동 / send+APNs, killswitch)                   │
│                                                                       │
│  Vertex AI │ gemini-3.1-flash-lite (multimodal function calling)      │
│  Voyage AI │ voyage-4-large@1024 (embedding) + rerank-2.5 (reranker)  │
└───────────────────────────────────────────────────────────────────────┘
```

> **심사위원용 데모 표면 — `mochi-web` (여정 데모 + BFF, 2026-07-08 전면 재구축)**: 무설치 5분 체험(랜딩→페르소나 선택→기록→홈→검색→질문→리마인드→마무리)을 주는 Next.js 16 데모 웹(`mochi-web/`, 정본 `mochi-web/README.md`). **fallback-first** — 보이는 모든 피드는 웹 내장 페르소나 시드(`seed/`)이고, 네트워크는 채팅·검색·라이브 분석 3개뿐이며 셋 다 라이브와 **같은 wire 포맷의 폴백**이 뒤에 선다(클라이언트는 `x-mochi-mode` 헤더 외엔 모드를 모른다). 라이브는 `app/api/bff/*` Route Handler 가 페르소나 계정 JWT(HS256, `MOCHI_JWT_SECRET`·`MOCHI_PERSONA_UUID_*` — 서버 env 전용)를 직접 서명해 백엔드(`MOCHI_BACKEND_URL`)로 프록시한다. 채팅 SSE 는 패스스루하되 first-byte 8s/inter-event 15s 초과·오류 시 **스트림을 끊지 않고 폴백 이벤트를 이어붙여 완결**하고, rate limit 초과는 429 가 아니라 폴백 강등, 킬스위치는 `MOCHI_FORCE_FALLBACK=1`. wire 계약(§3.6 SSE·`mochiItemId` 케이싱·`【item:uuid】` 마커)은 `openapi.json` 정본을 따르며 라이브 citation uuid ↔ 시드 slug 매핑은 시더 산출물 `seed/backend-ids.json` 이 잇는다.

---

## 2. iOS — `mochi-ios`

### 2.1 핵심 결정

- **UI 스택**: SwiftUI + The Composable Architecture (TCA 1.x). `@Reducer`, `@ObservableState`, `@Bindable`, `TestStore`.
- **프로젝트 도구**: Tuist 4.x — `Project.swift` 단일 파일에 다중 framework target.
- **언어/타겟**: Swift 5.x, iOS 17+, `SWIFT_STRICT_CONCURRENCY=targeted` (TCA/Dependencies 동적 framework 링크 호환; `complete` 복귀는 후속).
- **로컬 DB**: Realm (App Group 공유 파일, `mochi.realm`).
- **네트워킹**: `openapi.json` → `swift-openapi-generator`(`CodeGen/generate.sh`) 생성 클라이언트(`Generated/{Client,Types}.swift`) + `OpenAPIMochiClient` 어댑터. 수기 `URLSessionMochiAPIClient` 삭제(⓪ 단일계약 승격).

### 2.2 모듈 그래프

```
App  ──► Features ──► Cores ─┬─ CoreDomain        (pure model, 의존성 없음)
                             ├─ CorePersistence   (Realm + AppGroup + Repository)
                             ├─ CoreNetworking    (MochiAPIClient + DTO)
                             ├─ CoreAgentClient   (AgentStreamClient·ChatStreamClient — SSE)
                             ├─ CoreIntegrations  (EventKit / Reminders)
                             └─ DesignSystem      (MochiTheme, IntentBadge)

App  ──► ShareExtension       (NSItemProvider → InboundIngestPayload; 백탭 단축어도 "앱과 공유"로 합류)
```

**의존 규칙**:
- Feature 모듈끼리 직접 의존 금지. 조합은 `RootFeature` 가 책임.
- 각 `*DI.swift` (예: `MochiItemRepositoryDI`) 는 그 객체를 소유하는 Core 모듈에 위치.
- Cores 는 ComposableArchitecture 가 아닌 `swift-dependencies` 만 import — TCA 의존성 누수를 막는다.

### 2.3 캡처 진입 채널

| 채널 | 진입점 | 출력 |
|---|---|---|
| 외부 앱 공유 시트 (의식적 캡처) | `ShareExtensionPrincipal` (`NSExtensionPrincipalClass`) → `ShareEntryView` 메모/확인 모달 → 사용자가 저장 탭 | `InboundIngestPayload` JSON → App Group inbound 큐 (channel = `.screenshot` / `.safari` / `.appShareSheet` 등, host·hasImage 기반 `guessChannel` 결정) |
| iOS 백탭 | 사용자가 설치한 단축어 → `Take Screenshot` (Show Preview OFF) → **앱과 공유**(Share Sheet) → `ShareExtensionPrincipal`. 외부 앱 공유 시트와 **동일한 ShareExtension 경로**로 합류한다 — 단축어가 share 를 자동 호출하는 것만 다르다(옛 snippet/AppIntent 직행 경로는 2026-06-25 제거). | 공유 시트 행과 동일 — `InboundIngestPayload` JSON → App Group inbound 큐(+ best-effort 직접 전송, channel = `.screenshot`). 캡처 직후 background 선감지(`startEarlyDetection`)·민감 시 가림 시트도 공유 시트와 공통. |
| 앱 내 직접 입력 | `MochiItemFeature` (TCA) | Realm 직접 upsert |
| 캘린더 탭 일정 추가 (2026-06-15) | `MochiCalendarFeature` DaySheet "+ 일정 추가" → 제목+시간 폼(선택일 prefill) | `POST /mochi_items` (channel = `.appCalendar`, `confirmedInstances` schedule, §5.2 사용자 확정 예외) + 시스템 캘린더 등록(`CoreIntegrations.SystemCalendarRegistrar` — 채팅 일정 확정과 공용, 채팅 전용에서 추출) |

> **입력 surface — 모두 ShareExtension 으로 수렴**: 외부 입력은 ShareExtension 단일 진입점(`ShareExtensionPrincipal`)으로 들어온다.
> - **공유시트** = 사용자가 *의식적*으로 "이걸 모찌에 저장하고 싶다" 를 결정하는 순간 → `ShareEntryView` 모달(메모 입력 기회).
> - **백탭** = "지금 이 화면" 을 즉시 모찌에 보낸다. 단축어가 `Take Screenshot` 후 **앱과 공유**(Share Sheet)로 ShareExtension 을 호출하므로 공유 시트와 **같은 진입점**으로 합류한다 — 사용자 관점에선 "캡처 즉시 모찌 시트". 두 경로 모두 캡처 직후 선감지(`startEarlyDetection`)·민감 가림·best-effort 직접 전송을 거친다.
> - **제거된 경로(2026-06-25)**: 옛 백탭 snippet/AppIntent 직행(`CaptureScreenshotIntent` → snippet → `CommitBackTapCaptureIntent`/`OpenBackTapMemoIntent`)과 AppShortcuts 텍스트 메모(`QuickCaptureIntent`)를 모두 삭제했다 — 둘 다 ShareExtension 선감지를 안 거치는 무감지 진입점이라, 민감 처리 일원화를 위해 정리. 모찌는 더는 AppIntent/AppShortcuts 를 노출하지 않는다.
>
> **inbound queue 와 pending-backtap 디렉터리**: 큐는 "이미 사용자가 저장 결정을 내린 캡처의 4-Intent 분석 대기열" (ShareExtension 이 떨굼). `pending-backtap/` 은 옛 snippet stash 였으나 그 경로가 제거된 지금은 **온보딩 백탭 검증 핸드셰이크 마커(`verify.active`/`verify.hit`)** 전용이다(`AppGroup` — ShareExtension 이 검증 hit 를 기록).
>
> **출처앱 컨텍스트 (자동신호) — sentinel JSON**: 단축어가 출처앱을 평문 대신 sentinel JSON(`{"__mochi_ctx__":{"sourceApp":X}}`)으로 `text` 채널에 실어 보내면 `ShareExtensionPrincipal` 이 `CaptureContextSentinel`(CorePersistence)로 분해한다 — UI 엔 `SourceAppChip`("X에서 캡처"), 백엔드 `text` 엔 정규화 1줄(`[출처앱: X]`)로 합치고, 사용자 입력은 `user_memo` 로 끝까지 격리한다(자동신호 `text` ↔ 사용자의도 `user_memo` 2채널). sentinel 이 아니면 평문을 그대로 `text` 로 흡수(단축어 미재생성 하위호환). **일반 메모 모드**: 백탭 ShareExt 시트에서 스크린샷을 (×) 로 버리면 `imageRefs=[]` + channel `.appDirectInput` 으로 적재되고, 취소·제거 경로의 고아 PNG(`captures/`)는 `ShareExtensionPrincipal` 이 청소한다. sentinel·메모모드 모두 **백엔드/계약/DB 무변경**(출처앱 jsonb 1급화는 보류).
>
> **ShareExtension 직접 전송 (best-effort 선반영) + 큐 진실원천**: ShareExt 는 단명 별도 프로세스라 `AppDependencies.bootstrap()` 이 돌지 않아 `mochiAPIClient`·`AuthCoordinator` 가 부재한다. 캡처는 **항상 inbound 큐에 먼저 적재**된다 — 로컬 Realm ingest·동기화·유실 방지의 진실원천(다음 active tick 의 drain → upsert → `MochiItemSyncWorker` 업로드). 그 위에서 **공유 Keychain** 에서 인증 토큰을 ① **capture token**(`KeychainCaptureTokenStore`, 장수명 capture-scoped — §3.5) → ② access token(`AuthSessionStore.accessTokenIfValid`, 만료 60s 여유) 순으로 고르고(refresh 는 어느 쪽도 시도 안 함 — 단명 프로세스의 회전 토큰 유실 위험 회피; capture token 은 서버 sliding 이 정본이라 로컬 만료로 게이트하지 않음) App Group 공유 baseURL(`AppGroup.sharedAPIBaseURL`, App 부팅 시 `setSharedAPIBaseURL` 로 공유)로 `OpenAPIMochiClient` 를 경량 구성해 `POST /mochi_items` 를 **best-effort 선반영**한다(`ShareExtDirectUpload`, 짧은 timeout, 실패 사유는 `app.mochi.ShareExtension` os.Logger 로 구분 기록) — 서버 분석을 앱 부팅 전 조기 트리거. capture token 도입(2026-06-13) 전엔 access token(TTL 30분)만 써서 앱을 ~30분 안 연 상태의 직접 전송이 항상 실패했다 — 이게 주된 실패 원인이었고, capture token 이 "마지막 캡처 후 180일(sliding)" 로 창을 넓힌다. 이미지가 있으면 App Group 원본을 앱 본체와 같은 JPEG upload variant 로 줄인 뒤 presign → GCS PUT → ingest 를 순차 시도하고, 성공한 `objectKey` 는 큐 JSON 에도 반영해 다음 active tick 의 중복 PUT 을 줄인다. 선반영이 성공해도 큐는 그대로이고, 멱등키(`payload.id`)가 메인 앱 drain·SyncWorker 재전송과 **같은 행을 반환**해 이중 적재가 불가능하다(로컬 누락·유실 0). 백엔드/openapi/DB 무변경(같은 ingest 재사용).

`MochiApp.tick()` 이 앱 launch 와 `scenePhase == .active` 시점에:
1. `InboundQueueConsumer.drain()` → 큐를 비우고 Realm 에 ingest
2. `MochiSyncWorker.runOnce()` → `syncState == .pendingUpload` 인 MochiItem 를 backend 에 업로드 → `.uploaded` 또는 `.syncFailed`

> **서버→로컬 복구 (pull) — 재설치/기기 변경 후 데이터 복구**: 앱을 지웠다 깔면 Keychain 토큰이 사라져 재로그인해야 하고, 로컬 Realm·`captures/` 이미지도 비어 "넣어둔 게 다 사라진" 것처럼 보인다. 하지만 서버엔 owner 항목이 그대로 있다(같은 Apple 계정 = 같은 `user_id`, mochi_item 은 `owner_id` 스코핑). `MochiItemSyncWorker.pullRemote()` 가 `GET /mochi_items`(limit 200) 로 받은 항목을 `MochiItemDTO.toMochiItem()` 으로 역매핑해 Realm 에 upsert 한다. **머지 규약: 복구 항목은 서버 id 를 로컬 Realm primary key 로 채택**(`syncState=.uploaded(serverID:)`) — 재설치 직후 로컬엔 매칭 키가 없으므로 서버 id 를 정체성으로 삼아야 재pull 이 같은 행을 덮어 멱등이다(새 캡처의 "서버 id ≠ 로컬 id" 규약과 별개 — 복구 항목은 서버가 정본). **이미 로컬에 있는 항목(`MochiItem.id` + `syncState.uploaded(serverID:)` 두 키로 식별)은 건너뛴다** — 로컬 origin 항목이 server-id PK 로 중복 insert 되는 것을 막고, 로컬 전용 수정(userTitle 등)을 보존한다(분석 갱신은 SSE/폴링 책임). 이미지는 `objectKey` 만 있고 로컬 파일이 없으면 `POST /mochi_items/images/download-url`(GCS Signed GET URL)로 원본을 받아 `captures/<sha256>.<ext>` 에 복원한다(content-addressed 멱등 → 기존 `LocalThumbnail` 무변경). 트리거: 세션 복원·새 로그인 직후(`RootFeature.sessionResolved`/`signedIn`), 홈 빈 상태 폴백(`HomeFeature.onAppear`), 설정 "전체 동기화" 버튼(`SettingsFeature`). **pull↔upload 경합 정리(2026-06-11)**: skip 의 두 키도 못 막는 틈이 있다 — `uploadOne` 의 서버 commit 과 로컬 `updateSync(.uploaded)` 사이(actor reentrancy)에 pull 이 끼면 같은 캡처가 server-id PK 행으로 한 번 더 들어온다(간헐 중복). 업로드 완료 시(serverID 확정) 그 PK 의 복제 행을 지우고, pull 진입 시에도 중복 쌍(로컬 origin 행의 serverID == 다른 행의 PK)을 정리한다 — 로컬 origin 행이 정본.

### 2.4 4-Intent 라이프사이클 (2분할 — 처리상태 ⊥ 의미상태)

2026-06-04 빅뱅으로 lifecycle 은 **2분할**됐다(DOMAIN_DESIGN §5). **item 처리상태**와 **intent instance 의미상태**가 직교한다.

- **처리상태** (`mochi_items.lifecycle_kind`, item 단위): `ingested → analyzing → analyzed`(분석완료·instance 적재됨·iOS SSE `final`/폴링 컷오버 신호), 실패 시 `→ failed`. archive 없음.
- **의미상태** (`intent_instances.lifecycle_kind`, instance 단위): instance 는 분석 성공 시 `active` 로 태어난다. `CoreDomain.LifecyclePolicy.validate(from:to:intent:)` 가 (1) `(current→next)` 페어가 intent_type 별 허용인지 (2) `.archived(reason:)` 의 reason 이 intent_type 별 허용인지 검증.

| intent_type | 자동 동작 | 합법 전이(의미상태) |
| --- | --- | --- |
| `schedule` | EventKit/Google Calendar sync | `active → archived(scheduleEnded\|userManual)` |
| `todo` | Reminders sync | `active ↔ archived(todoCompleted)`(완료/완료취소), `active → archived(userManual)` |
| `knowledge` | RAG 인덱싱 | `active ↔ decaying ↔ reviewRequested → archived(knowledgeStale\|userManual)` |
| `memo` | 영구 보관 | `active → archived(userManual)` 만 |

한 캡쳐의 TODO_A 완료가 같은 캡쳐의 TODO_B·Schedule_C 와 독립(행 단위). 위반 시 `LifecycleTransitionError`. 백엔드 `app/modules/intents/domain/lifecycle_policy.py` 가 동일 invariant 를 보장.

### 2.5 Realm Mapper Losslessness

`RealmMochiItemMapper` 는 다음을 모두 round-trip 보존한다:
- `entities` (kind + value + provenance: textRange / ocrBoundingBox)
- `actionCandidates` (calendar / reminder / openURL / followUpSearch)
- `tags`
- `attachments` (sha256 + objectKey 포함)
- `SyncState` 세부 (uploaded serverID + 시각, syncFailed retryAfter)
- `LifecycleState` (archived reason, failed reason)
- `isFavorite` (즐겨찾기 신호 — **서버 동기화** 필드라 pull 복구 시 `toMochiItem` 에서 반드시 보존. userTitle 의 로컬전용과 반대)

---

## 3. Backend — `mochi-backend`

### 3.1 핵심 결정

- **언어/Runtime**: Python 3.12, FastAPI, uv 패키지 관리
- **아키텍처**: Modular Monolith + Hexagonal (per-module `domain / application / infrastructure / presentation`)
- **DB**: Postgres 16 + pgvector (HNSW + cosine), async SQLAlchemy 2 + asyncpg, Alembic
- **AI**: Vertex AI · `gemini-3.1-flash-lite` (multimodal function calling, streaming) / Voyage AI · `voyage-4-large@1024` (임베딩) + `rerank-2.5` (리랭커)
- **관측**: structlog (JSON, contextvars 로 request_id/idempotency_key/path 바인딩)
- **인증**: 자체 발행 access JWT (HS256, TTL 30분, `AUTH_ACCESS_SECRET`) + 회전 refresh token(30일, reuse 감지 시 family revoke) + **capture-scoped token**(`mct_` opaque, sliding 180일, ingest+presign 한정 — ShareExt 직접 전송용). JWKS(PyJWKClient)는 Apple/Google **ID token 검증에만** 사용. dev mode 는 `Bearer dev:<subject>` (environment=local 한정)

### 3.2 모듈 트리

```
app/
├── core/                          cross-cutting
│   ├── config.py                  Pydantic Settings
│   ├── db.py                      AsyncEngine/AsyncSession factory
│   ├── logging.py                 structlog
│   ├── middleware.py              X-Mochi-Request-ID + Idempotency-Key 바인딩
│   ├── error_envelope.py          ErrorEnvelope + Exception handlers
│   ├── security.py                CurrentUser (HS256 JWT·dev) + CurrentCaptureUser (ingest/presign 전용, +mct_)
│   └── deps.py                    DBSession = Annotated[AsyncSession, Depends(get_session)]
├── shared/                        모듈 간 공통 어휘 (Intent, ID newtypes)
├── modules/
│   ├── mochi_items/
│   │   ├── domain/                MochiItem / LifecycleState (출처·intent 인라인, pure)
│   │   ├── application/           IngestMochiItem, GetMochiItemForOwner, make_mochi_item_repository
│   │   ├── infrastructure/        SQLAlchemy ORM (MochiItemRow, IntentInstanceRow,
│   │   │                          MochiItemImageRefRow, EntityRow, EmbeddingRow,
│   │   │                          IdempotencyKeyRow, MochiItemOutboxRow,
│   │   │                          AgentRunRow, ToolCallRow), OutboxNotifier
│   │   └── presentation/          POST/GET /mochi_items + Pydantic API schemas
│   ├── intents/
│   │   └── domain/lifecycle_policy.py     4-Intent 상태 머신 (단일 진실 공급원)
│   ├── agent/
│   │   ├── domain/                AgentNode/AgentRun/Tool ABC/LLMClient port
│   │   ├── application/           AgentOrchestrator + AgentRunPersistence + MochiWorker + tool_factories(타 모듈용 가드 툴 진입점)
│   │   ├── infrastructure/
│   │   │   ├── registry.py        StaticToolRegistry
│   │   │   └── tools/             PlatformContextTool / WebFetchTool / MultimodalAnalyzeTool
│   │   ├── prompts/system_prompts.py   PromptVersion(name/model/eval/revised_on/rationale)
│   │   └── presentation/router.py      GET /mochi_items/{id}/stream (SSE)
│   ├── search/
│   │   ├── domain/                SearchQuery / Citation / 3 outbound ports
│   │   ├── application/           HybridSearch use case
│   │   ├── infrastructure/        PostgresHybridIndex (owner-scoped BM25 + 벡터) + rrf
│   │   └── presentation/router.py      POST /search
│   ├── notifications/                   APNs background push (PR-B) + 능동 회수 알림 (트랙 A/B 구현·C 설계)
│   │   ├── domain/                APNsClient/PushTokenRepository port, DevicePushToken
│   │   │                          + recall_plan(stages DSL Pydantic), recall_planning/reaction/feed ports
│   │   ├── application/           RegisterPushToken, SendAnalysisNotification, SendCalendarSyncPush(silent), make_push_token_repository
│   │   │                          + PlanRecallNotifications(eligibility 게이트 + LLM 플래너) · NotificationWorker
│   │   │                            (cron: materialize+하드가드+종료연동 / send+APNs 410 분류, dry-run·killswitch)
│   │   │                          · SendRecallNotification · RecordRecallReaction(opened/dismissed/stop + spaced 소생)
│   │   │                          · GetRecallFeed/GetRecallLanding · recall_occurrence·recall_guards(순수함수, DB무관)
│   │   ├── infrastructure/        HttpxAPNsClient(http2+ES256 JWT), PostgresPushTokenRepository, DevicePushTokenRow
│   │   │                          + NotificationPlanRow/NotificationOutboxRow · GeminiRecallPlanner(tool-loop, flash-lite)
│   │   │                          · recall_plan/context/reaction/feed repositories
│   │   └── presentation/          POST /devices/push-token · POST /recall/events/{id}/reaction
│   │                              · POST /recall/items/{id}/reaction(피드 표면, item 기준)
│   │                              · GET /recall/feed · GET /recall/events/{id}(landing fallback)
│   └── conversations/                   채팅 탭 — LLM 루프 read-only + proposal (journal 2026-06-10)
│       ├── domain/                Conversation/Message/MessageCitation, ChatTool·ChatLLMClient·ChatTurnStore ports, run_events
│       ├── application/           BeginChatTurn(암묵 생성·동시 run 409) · RunChatTurn(detached run 본체) · queries(스냅샷+stale lazy repair)
│       ├── infrastructure/        ORM·repository · RunRegistry(in-process queue) · GeminiChatClient(첫 라운드 ANY→AUTO, stream) · turn_store(연산별 자체 세션) · tools/(search_items(hybrid: 키워드+의미→rerank)·get_item_detail·view_item_image(캡처 이미지를 gs:// 로 직접 보기 — 버킷 미설정 시 제외)·propose 5종·web_fetch(agent 가드 재사용)·web_search(Tavily, 키 미설정 시 제외) — 전부 read-only)
│       ├── prompts/               chat@v10 활성 (PromptVersion 버저닝)
│       └── presentation/          POST /{id}/messages(POST-as-SSE) · GET 목록/스냅샷 · DELETE · PATCH proposals/{id}(카드 확정/취소 영속)
├── api.py                         /api/v1 라우터 조립
└── main.py                        FastAPI factory + 미들웨어 + 예외 핸들러
```

### 3.3 의존성 방향 (Hexagonal)

```
presentation  ─►  application  ─►  domain
       ▲                    │            ▲
       │                    ▼            │
infrastructure  ──────►   ports  ──────┘
```

**모듈 간 규칙** (`tests/unit/test_module_boundaries.py` 가 강제):
1. 어떤 모듈도 다른 모듈의 `infrastructure/` · `presentation/` 내부를 직접 import 할 수 없다. 허용된 진입은 `domain/`, `application/`, `app.shared`, `app.core` 만.
2. 모든 `domain/` 레이어는 프레임워크 패키지(sqlalchemy / fastapi / httpx / google / pgvector) 를 import 할 수 없다.

### 3.4 데이터 흐름

#### MochiItem ingestion

```
(이미지 첨부 시 선행) iOS 원본 PNG → 업로드용 JPEG(긴 변 1920px 이하, q60)
  → POST /mochi_items/presign(업로드 bytes 기준 sha256/mimeType) → V4 Signed PUT URL
  → 클라가 GCS 직접 업로드 → objectKey 확보
  ↓
POST /mochi_items (단일 ingest 경로, with Idempotency-Key, Bearer)
  ↓
RequestContextMiddleware (request_id 바인딩)
  ↓
MochiItemCreateRequest (Pydantic validate)
  ↓
IngestMochiItem.execute (use case)
  ├─ idempotency_key 가 owner-scoped 로 이미 있나? → 있으면 기존 mochi_item 반환
  ├─ MochiItem aggregate 생성 (lifecycle=ingested)
  ├─ PostgresMochiItemRepository.add → mochi_items(출처 인라인) + mochi_item_image_refs INSERT (한 트랜잭션)
  ├─ remember_idempotency → idempotency_keys INSERT
  └─ OutboxNotifier.emit → mochi_item_outbox INSERT + pg_notify('mochi_item_outbox', mochi_item_id)
  ↓
DB COMMIT (atomic)
  ↓
201 Created + MochiItemResponse
```

> **ephemeral OCR 동봉 (2026-06-24)**: `MochiItemCreateRequest.analysisOcrText`(nullable, **Create 에만** — Response/Update 미포함)로 iOS Vision OCR 화면 transcript 를 받아 분석 컨텍스트로만 쓴다. iOS 는 effective 이미지 정책이 `originalUpload`(비민감 기본·사용자 원본 승인)일 때만 싣고 `blurredUpload`·`localOnly` 는 미동봉한다(사용자가 가린 raw 를 OCR 로 누설 안 함 — `PRIVACY_SENSITIVE_CAPTURE.md §2.2`). 서버는 `mochi_items.analysis_ocr_text`(마이그레이션 0026)에 잠깐 보관하다 worker 분석 done(또는 영구 실패) **즉시 NULL** — Response·검색 haystack·embedding 어디에도 안 싣는다(누수 grep 게이트, `PRIVACY §1.1`). 분석 입력엔 `source.text` 와 분리한 별도 "# 화면 텍스트 (OCR)" 블록으로 주입한다(`classify_and_act@v29`, 이미지 보완·대체 아님).

#### Agent worker

> 기동: `app/main.py` lifespan 에서 API 와 같은 프로세스의 백그라운드 태스크로 `WORKER_CONCURRENCY`(기본 2)개의 `run_forever()` 코루틴을 실행 (shutdown 시 N개 graceful stop). 동시 in-flight 분석 = N. 여전히 단일 프로세스이며, prod 수평확장은 인스턴스 복제로 한다 — `FOR UPDATE SKIP LOCKED` + item-level lock 이 N 코루틴·N 인스턴스 모두 동시 안전을 보장한다.

```
MochiWorker.run_forever
  ↓
SELECT ... FOR UPDATE SKIP LOCKED
  - status='pending' OR (status='in_flight' AND locked_until<now)  ← in_flight 만료 reclaim
  - attempt < max_attempt
  ↓
status='in_flight', attempt++, locked_until=now+60s, last_lease_owner=$pod
  ↓
AgentOrchestrator(persistence=AgentRunPersistence(session)).run(mochi_item_id)
  ├─ start() → agent_runs INSERT (UNIQUE mochi_item_id, attempt)
  ├─ for node in HAPPY_PATH:
  │    update_node() → agent_runs.current_node = node
  ├─ finish() / fail()
  └─ (도중 실패하면 예외 re-raise → worker 가 outbox 재시도/DLQ 분기 결정)
  ↓
성공: mochi_item_outbox status='done'
  └─ (done 커밋 직후, 분석 try 밖, best-effort) SendAnalysisNotification → APNs alert(전 단말, 완료/needs_review 분기 문구) + needs_review=true 면 LA **push-to-start**(`la_start` 토큰으로 background LA 시작). push 실패는 격리(done 유지) — 누락은 iOS reconcile 이 메움. **전역 선호 게이트(2026-07-14)**: `users.notify_analysis_enabled=false` 면 needs_review confirm push 를 `push.notify_skipped(reason=preference_off)` 로그 후 미발송(발송 시점 게이트만 — 분석·인앱 헷갈려요 버킷 불변)
  └─ (같은 훅) 확정(needs_review=false) schedule/todo 포함 시 **silent push**(`SendCalendarSyncPush` — apns-push-type=background·priority 5·`content-available:1`+`mochiItemID`, alert 없음) → iOS `didReceiveRemoteNotification` 이 foreground tick 과 같은 순서로 따라잡는다: **inbound 큐 drain(ShareExt 캡처는 push 도착 시점 로컬 Realm 에 없다 — 큐 JSON 뿐) → 멱등 업로드(runOnce, ShareExt 직접 전송과 같은 행) → 해당 item reconcile → `SystemCalendarSyncEngine` 이 시스템 캘린더·미리알림 반영**(UX_SPEC §1.5 자동 관리, 2026-07-14 — drain·upload 선행은 같은 날 실기기 불발 fix: reconcile 은 `uploaded:` 링크로만 항목을 찾는다). 사용자 노출 알림이 아니라 **알림 선호 게이트 미적용**. 미도달(OS 스로틀·강제종료)은 앱 실행/복귀 reconcile 백스톱이 따라잡는다
실패 + attempt<max: status='pending' (재시도)
실패 + attempt=max: status='dead_letter' + mochi_items.lifecycle_kind='failed'
```

#### 실시간 반영 (iOS, PR-B)

처리완료를 iOS 가 받는 경로는 **프로세스 상태**로 3분담된다(캡처 채널 무관):

- **foreground = SSE**: iOS `AgentStreamClient` 가 `GET /mochi_items/{id}/stream` 구독. 서버는 worker 의 `mochi_items.lifecycle_kind` 를 read-only 폴링(1s)해 `node`/`final`/`failed` emit — 실제 분석은 worker 단독(이중 실행 방지). iOS 는 `final` 수신 시 `GET /mochi_items/{serverID}` 재조회로 분석결과 fetch.
- **background/종료 = APNs**: SSE 소켓이 suspend 되므로 worker push 훅이 인계 — 완료 alert(전 단말) + needs_review=true 면 LA **push-to-start**(잠금화면에서 후보 선택, 탭하면 위젯이 reanalyze 직접 호출) + 확정 schedule/todo 포함 시 **silent push**(content-available → iOS background reconcile + `SystemCalendarSyncEngine` 의 시스템 캘린더·미리알림 반영, 2026-07-14).
- **fallback = 폴링**: SSE 실패/끊김 시 3초 폴링(`GET /mochi_items/{serverID}`, 제거 금지). scenePhase active 복귀 시 reconcile(SSE 재연결 + 1회 폴링).

#### 능동 회수 알림 (트랙 A/B/C)

> **트랙**: A=지식 spaced · B=마감 역산(`notification_plan` 경유) / C=관련·맥락 회수(plan 없이 `notification_outbox` 직행 `kind=recall`) — **A/B/C 모두 구현됨(2026-06-16)**. C 는 새 item 분석 done 후 worker 가 best-effort 로 유사 과거 기록을 임베딩 ANN 조회(`generate_recall_candidates`) → 게이트(점수·dedup·dismiss cooldown·야간/cap/트랙B 양보는 fire_at 미루기) → outbox 직행. 발송 패스 클레임이 `plan_id IS NULL OR active plan` 이라 recall 행 발송. 1:1 단건 맥락 회수(임베딩 ANN), 주제 묶음=비범위. 상세 `journal/proactive-recall/tech-plan.md` §8 P7–P9. 민감 필터는 안 넣음 — 본문이 추상화 LLM 요약이라 A/B 와 동일 ungated(`sensitivity_level` 실구현 시 발송 게이트로, `PRIVACY_SENSITIVE_CAPTURE.md` §9).
> 기동: `app/main.py` lifespan 에 `NotificationWorker.run_forever()` 1개를 MochiWorker 옆에 추가(graceful stop). killswitch `recall_worker_enabled`, dry-run 기본 True(발송 0 튜닝). 정본 `journal/proactive-recall/`.

```
[생성] 분석 done 직후 best-effort hook (분석 try 밖, 독립 세션)
  PlanRecallNotifications: eligibility 게이트(intent 종류·미래 date·importance — v21 무손상)
    → GeminiRecallPlanner(tool-loop, get_scheduled 묶기) → notification_plan 1 row(stages 검증)
  ↓
[발송] NotificationWorker.run_forever (poll)
  ① materialize: active plan(next_eligible_at<=now) → source intent fresh 로드(archived→plan cancelled, HIGH-2)
       → occurrence 계산(relative/recurring/spaced; spaced 는 반응 기준 전진) → 하드 가드
       (cap·야간무음·dismiss cooldown·트랙B 양보, per-owner advisory lock, KST) → outbox lazy materialize
       (deferred=cap/야간/트랙B 는 next_retry_at 도달 시 재평가로 회생)
  ② send: status='pending' AND fire_at<=now claim(plan active JOIN, expires 가드)
       → 전역 선호 게이트(users.notify_recall_enabled=false → skipped(preference_off), A/B/C 공용,
         발송 시점만 — plan/materialize 불변, 다시 켜면 다음 fire_at 재개) → dry-run/실발송
       APNs alert(payload mochiItemID·sourceIntentID·routeType·recallEventID·kind)
       410/Unregistered→토큰 무효화+dead_letter / 5xx→backoff
  ↓
[반응] POST /recall/events/{id}/reaction (opened/dismissed/stop) — 알림 표면(푸시 탭 landing·지난 알림), 발송 1건과 1:1
  → outbox.opened_at/dismissed_at (first-write-wins) + opened+spaced+knowledge → instance 소생(reviewRequested/decaying→active, savepoint 격리)
  → stop → plan cancelled(user_dismiss)
[피드 반응] POST /recall/items/{item_id}/reaction (opened/stop, 2026-07-10) — 피드 표면(홈 한 칸·자세히·회수 상세), item 기준
  피드 카드는 event 유무와 무관하게 존재해(트랙 A: sent event 없음 가능, 트랙 C: pending 노출) event 기준 보고가
  유실됐다 — "열어본/그만 카드가 재fetch 마다 부활" 원인. opened → kind=recall 행 opened_at(+pending 은 skipped(opened))
  + knowledge 소생 / stop → active spaced plan 전부 cancelled + kind=recall 행 skipped(cancelled)+dismissed_at
[회수 화면] GET /recall/feed(홈 한 칸·자세히) · GET /recall/events/{id}(알림 landing fallback)
  피드 후보(트랙 C)는 item 별 최신 event 가 opened 면 제외("열어본 회수는 피드에서 빠진다")
```

#### 자연어 검색

```
POST /search (Bearer)
  ↓
SearchQuery(text, scope, owner_id=user)
  ↓
HybridSearch.execute
  ├─ PostgresHybridIndex.bm25  (owner_id + deleted_at IS NULL, 단어별 ILIKE substring + ts_rank_cd 랭킹)
  ├─ PostgresHybridIndex.vector (owner_id + deleted_at IS NULL,
  │     voyage-4-large 쿼리 임베딩(input_type=query, 1024d) <=> embeddings HNSW)
  ├─ reciprocal_rank_fusion(k=60)
  └─ VoyageReranker (rerank-2.5, reranker_enabled)
  ↓
SearchResponse (citations — 문장 답변 없음: 질문·답변은 채팅 탭 소관, 2026-07-14 answer 필드 제거)
```

**임베딩·리랭크 (2026-06-12, `lab/active/rag-rerank-eval` 확정)**: 모델 `voyage-4-large@1024`,
문서 임베딩 input = `summary + intent labels`(`app/shared/voyage.build_embedding_text` 단일
원천 — INDEXED 노드·backfill 공용), doc/query `input_type` 비대칭. reranker `rerank-2.5`
(vector 단독 대비 R@1 0.15→0.43, MRR 0.56→0.88). 색인은 agent orchestrator 의 **INDEXED
노드**가 분석 직후 best-effort 로 수행하고(실패해도 run 유지 — Gemini 재분석 비용 방지),
누락분은 `scripts/backfill_embeddings.py` 가 멱등 재색인한다.

**degrade 계약**: `VOYAGE_API_KEY` 미설정·일시 장애 시 vector·rerank 경로만 비활성 —
검색탭은 BM25+RRF, 채팅 `search_items` 는 키워드(ILIKE)로 degrade 하고 서버는 정상 동작한다.
검색이 외부 AI API 장애로 죽지 않는다.

채팅 `search_items` 도 같은 인프라를 쓴다: 키워드(ILIKE AND) + 의미(vector) 두 갈래 후보를
구조화 필터(intent·시간 2축) 공통 적용으로 모은 뒤 rerank-2.5 가 최종 순위 (갈래당 후보 24).

**공유 retrieval 커널 (2026-07-09)**: 키워드 매칭식(단어별 ILIKE substring + `ts_rank_cd` 랭킹)·
RRF 융합·pgvector 직렬화는 `app/shared/retrieval.py` 가 **단일 원천**이다 — `/search`(A,
`HybridSearch`+`PostgresHybridIndex`)와 채팅/분석 agent(B, `search_items`)가 문자 그대로 같은
구현을 쓴다. 이전엔 두 경로가 코드가 갈라져, 한국어 조사 회귀(2026-06-10) 수정이 B 에만
들어가고 A 의 `bm25` 는 tsvector `@@` 로 남아 같은 버그를 유지했다(커널 단일화로 구조적 재발
방지). 경로별로 정당하게 다른 것(출력 = citations vs 아이템 리스트, 필터 모델, query 수 = 단일
vs 다중 융합, haystack 컬럼)은 호출부가 주입하며 커널이 강제하지 않는다.

**유사 회수 (similar, 2026-06-13)**: 같은 `embeddings` HNSW 인프라를 **seed-vector** 로 재사용한다 —
대상 item 의 저장된 벡터로 cosine 이웃 top-k(자기 제외·owner-scoped·임계값 미달 시 빈 배열).
`/search`(query→RAG 답변)와 달리 답변 없는 이웃 조회이고, 입력이 query 텍스트가 아니라 기존 벡터다.
retrieval 책임은 search 모듈(새 seed-item 포트 필요 — 기존 `RetrievalIndex.vector(query)` 는 텍스트
기반이라 재사용 불가), 라우트만 `/mochi_items/{id}/similar`. 계약·응답 스키마·연결 이유(reasons)·
민감 게이트 자리는 [`DOMAIN_DESIGN.md`](DOMAIN_DESIGN.md) §10.5 가 단일 기록(구현 시 openapi 로 승격).

### 3.5 보안

| 항목 | 처리 |
|---|---|
| 인증 | dev = `Bearer dev:<subject>` (environment=local only) → SHA-256 결정론적 UserID. prod = **자체 발행 access JWT(HS256**, `AUTH_ACCESS_SECRET`, iss/aud/exp/sub 검증, TTL 30분**)**. JWKS(PyJWKClient)는 Apple/Google ID token 검증(`/auth/{apple,google}`)에만 쓴다 |
| capture-scoped token | `mct_` prefix opaque(SHA-256 hash 만 DB 보관, `capture_tokens`), **ingest+presign 2개 라우트 한정**(`CurrentCaptureUser` — 그 외 라우트에선 JWT 파싱 실패로 자동 401). sliding 180일(검증 시 연장, 1h 디바운스) + 사용자당 활성 5개 cap(초과 시 oldest evict). revoke 연쇄: logout(동봉 시)·refresh reuse 감지(사용자 전체)·계정 탈퇴(훅). **한계**: 강제 로그아웃(refresh 실패)땐 서버측 revoke 수단이 없어 로컬 삭제 + 만료/reuse 훅이 안전망 |
| 인가 | 모든 read/write 는 `owner_id` 키워드 인자 강제 — cross-tenant 누설을 컴파일 시점에 차단 |
| 멱등성 | `Idempotency-Key` 헤더 필수. `mochi_item:{owner_id}:{raw_key}` 의 SHA-256 으로 owner-scoping |
| 분산 추적 | `X-Mochi-Request-ID` 헤더 echo + structlog contextvars 자동 바인딩 |
| 에러 envelope | `{code, message, requestId, retryAfter}` 통일 포맷, iOS `APIErrorEnvelope` 와 1:1 |
| SSRF | WebFetchTool/PlatformContextTool 공유 가드(`safe_fetch.guarded_get`): 호스트 블록리스트 + 모든 A/AAAA 답변 IP 검증(IPv4-mapped unwrap 포함) + **연결-핀(검증한 IP 로 직접 연결, host 를 SNI/Host 로 보존 → 연결-시점 rebinding/TOCTOU 차단)** + 매 redirect 재핀 + 스트리밍 byte limit + MIME 화이트리스트 |

### 3.6 OpenAPI 계약 (⓪-tier 단일 원천)

- `make openapi` (= `scripts/export_openapi.py`) → `openapi.json` 정적 추출 + iOS `CoreNetworking/openapi.json` 동기화. FastAPI 3.1 의 `anyOf:[X, {type:null}]` 은 `export_openapi.py` 가 3.0 `nullable:true` 로 낮춘다 (swift-openapi-generator 가 `type:null` 을 skip 하는 문제 회피).
- iOS `CodeGen/generate.sh`(swift-openapi-generator)가 `openapi.json` → `CoreNetworking/Sources/Generated/{Client,Types}.swift` 생성. `OpenAPIMochiClient` 어댑터가 `MochiAPIClient` 라이브 구현(날짜 transcoder + auth 미들웨어 + 6 op 위임, `putCaptureImage` 만 GCS 직접 PUT).
- 동기화 게이트: `ship-precheck §5a`(백엔드 code↔openapi.json no-diff) + `§5b`(openapi.json↔생성물 no-diff). CI(`ship-precheck.yml`)는 §5a 재실행.
- **SSE 의 ⓪티어 예외 (2026-06-10 명문화)**: SSE 스트리밍 라우트(`GET /mochi_items/{id}/stream`, `POST /conversations/{id}/messages`)는 openapi.json 에 **라우트로는 명시**되지만 이벤트 wire format 은 OpenAPI 로 표현되지 않아, iOS 는 generated client 가 아닌 **raw URLSession**(`CoreAgentClient` — `LiveAgentStreamClient` 전례, 채팅은 `LiveChatStreamClient` 후속)으로 소비한다. 이벤트 스키마의 iOS 정본은 `CoreAgentClient` 의 event enum(`AgentEvent`/`ChatStreamEvent`), 서버 정본은 해당 라우터 docstring — 채팅 이벤트 7종(`message_delta`/`tool_started`/`tool_finished`/`citation`/`proposal`/`done`/`error`, payload 에 `run_id`)은 양쪽이 1:1 이어야 하며 변경 시 함께 고친다. `proposal` payload 는 type 별 free-form — `create_schedule` 은 `confirmed_instances`·`text`·`display` 외에 **propose-시점 경량 LLM 이 도출한 `category`/`summary`(optional)** 를 싣고(2026-06-21), iOS `ChatStreamClient.CreateSchedulePayload` 가 수기 디코드해 확정 시 `confirmedInstances` ingest(top-level `category`/`summary`)로 운반한다(DOMAIN_DESIGN §5.2). **`notification_reschedule`(`event_id`·`fire_at`·`display`)·`notification_cancel`(`event_id`·`kind`·`display`)**(2026-07-09)은 Recall Planner 가 자동 설계한 예정 알림을 채팅에서 조정하는 카드로, 확정 시 **기존** `POST /recall/upcoming/{event_id}/reschedule`·`/veto` 를 태운다(REST 재사용이라 openapi 무변경 — SSE proposal wire 만 iOS 배선). cancel copy 는 kind 분기(spaced=이번 회차만 skip, deadline/nudge=시리즈 전체 정지)로 REST 의미와 1:1. 조회는 read-only 툴 `list_notifications`(예정 알림 + `fire_from`/`fire_to`·`mochi_item_id` 필터).

---

## 4. iOS ↔ Backend 계약

> **API 계약의 단일 원천은 [`mochi-backend/openapi.json`](../mochi-backend/openapi.json)** — 백엔드 `presentation/` 에서 `make openapi` 로 생성된다. **엔드포인트 목록·요청/응답 스키마·필드 타입은 이 문서에 복제하지 않는다**(로컬 구동 시 `GET /docs` Swagger UI). openapi 만으론 알 수 없는 iOS 배선 예외는 [`DOMAIN_DESIGN.md`](DOMAIN_DESIGN.md) §6.4 가 소유한다. 이 절은 그 위에 얹히는 *런타임 규약*(헤더)·*매핑*만 다룬다.

### 4.1 Request headers

| 헤더 | 필수 | 의미 |
|---|---|---|
| `Authorization: Bearer <token>` | 모든 라우트 (health 제외) | dev 토큰 또는 JWT. **예외**: `POST /mochi_items` + `POST /mochi_items/presign` 은 capture token(`mct_…`)도 수용 (§3.5) |
| `X-Mochi-Request-ID` | 옵션 (없으면 서버가 생성) | 분산 추적 키 |
| `Idempotency-Key` | `POST /mochi_items` | owner-scoped SHA-256 으로 정규화 |

### 4.2 Endpoints

엔드포인트 목록·요청/응답 스키마·각 라우트의 의미는 **`openapi.json`** 단일 원천(위 §4 노트). iOS 배선 예외(서버만 실재·라우트 미존재 등)는 [`DOMAIN_DESIGN.md`](DOMAIN_DESIGN.md) §6.4 를 본다.

### 4.3 DTO 매핑

iOS `CoreNetworking.MochiAPIClient` 의 DTO 가 backend `openapi.json` 의 스키마와 1:1 매칭. CodingKeys 로 `userHint`/`requestId`/`attachments` 등 camelCase 매핑.

---

## 5. 핵심 도메인 모델

### 5.1 `MochiItem` aggregate

- iOS `MochiItem.id` 는 **로컬 식별자**(Realm PK + Idempotency-Key). 백엔드 `mochi_items.id` 는 ingest 시 **서버가 자체 부여하는 별개 UUID** 이며, iOS 는 업로드 응답의 서버 id 를 `SyncState.uploaded(serverID:)` 에 보관해 서버 조회(`getMochiItem`)에 쓴다 — 로컬 id 로 GET 하면 404.
- 4-tuple: `source`, `analysis?`, `lifecycleState`, `syncState`
- `analysis` 는 백엔드 agent loop 완료 후 채워짐

### 5.2 `Intent` (4-Intent)

- `schedule` / `todo` / `knowledge` / `memo` — iOS·백엔드 동일 문자열 값
- Intent 별 차등 lifecycle (§2.4 표)

### 5.3 `AgentRun`

- `(mochi_item_id, current_node, tool_calls, total_tokens, total_latency_ms, started_at, ended_at?, failure_reason?)`
- `HAPPY_PATH = [ingested, normalized, analyzed, routed, persisted, indexed, synced]`. 실패 시 어디서든 `failed` 로 분기.
- `UNIQUE (mochi_item_id, attempt)` 로 retry 중복 차단.

### 5.4 `Tool` (Pydantic 기반 타입 안전)

- `TIn`, `TOut` 두 Pydantic 모델로 generic. `schema()` 가 Gemini function-calling 용 JSON Schema 자동 생성.
- agent loop 가 LLM 에 광고하는 URL 그라운딩 도구는 `PlatformContextTool` 과 `WebFetchTool` 이다. `PlatformContextTool` 은 YouTube/X/Instagram URL 을 먼저 처리한다: YouTube는 oEmbed+watch page metadata, X는 `publish.x.com/oembed`, Instagram은 Meta oEmbed 토큰이 있으면 공식 oEmbed·없으면 OG fallback 을 사용한다. Instagram은 이미지 맥락 의존도가 높아 screenshot Vision 결과를 primary context 로 둔다. `MultimodalAnalyzeTool` 은 스키마 재사용용으로 보존. 임베딩은 LLM 도구가 아니라 orchestrator 가 INDEXED 노드에서 voyage 로 직접 색인한다(§3.4).
- screenshot/image 분석은 `lab/active/extraction-strategy` 의 C 전략을 prompt-level grounding 으로 채택한다: 모델이 내부적으로 `fact` / `opinion` / `info` typed statement 를 세운 뒤 final summary/entities 를 만들며, `facts/opinions/key_info/entities` 버킷을 모두 채우도록 강제하지 않는다. Agent 입력에는 매 run `Asia/Seoul` 현재 기준시각을 넣어 상대 날짜·요일·마감 해석 기준을 고정한다.

### 5.5 Agent loop & 개인화 (Arch2 — LLM = 분석가)

- **`GeminiAgentClient(LLMClient)`** (`gemini-3.1-flash-lite`/global) — function-calling 루프. LLM 이 분석가: `finalizeAnalysis`(V7, boolean instances) 로 가변 개수 `intent_instances`(`intent_type`·`payload`(typed)·`label`·`reasoning`) + `needs_review` + `review_options` + summary·entities 를 직접 저술한다. **서버 derive 없음**(점수·대표·위계 폐기 — `_to_analysis_result` 가 DTO→instance 1:1 분해). `platformContext`/`webFetch` 로 URL 그라운딩. `AgentOrchestrator` 가 첫 user turn 에 `# 시간 컨텍스트`(Asia/Seoul 현재시각)를 주입한다. orchestrator 의 `ANALYZED` 노드가 루프를, `PERSISTED` 노드가 `MochiItemGateway.apply_analysis` write-back(intent_instances delete-reinsert + 처리상태 `→analyzed`)을 담당.
- **개인화**: `user_profiles` 에 유저 특성 요약을 sliding-window 로 적립(`RefreshUserProfile`, 디바운스) → 쓸수록 정확. 두 관점 — `summary`(분류 성향)는 **분석** system prompt 에, `chat_summary`(페르소나)는 **채팅** system prompt 에 배경·톤으로 주입(`conversations` → `agent.application.load_chat_profile`, chat@v11). 도메인 위치: `DOMAIN_DESIGN.md` §3, 최소전송 `PRIVACY_SENSITIVE_CAPTURE.md` §2.1.
- text+URL+이미지(gs:// 첨부 — Vertex 직접 read) = 실연결. 임베딩 적재(INDEXED)는 design-ahead.
- **장소 지오코딩 도구(2026-07-08)**: `searchPlaceGeo` — 캡처가 가리킨 구체적 장소(식당·카페·매장 등)를 네이버 지역검색으로 키워드 검색해 상호·업종·주소·**WGS84 좌표**(mapx/mapy = 경도/위도×1e7, 라이브 실측 검증)를 회수한다. 이미지를 본 메인 에이전트가 후보 주소·업종을 캡처 근거와 대조해 일치 후보의 `place_entity` JSON 을 `entities(kind='place')` 로 복사(reference_url 규약 동형, item 당 최대 1개; 불일치면 빈손 — 좌표 발명 금지). **별점·매장사진 보강(2026-07-09)**: 후보를 Google Places(New) 텍스트검색으로 1:1 매칭(좌표 300m 이내일 때만 같은 가게로 인정 — 남의 별점 방지)해 rating·ratingCount·imageUrl(photoUri, googleusercontent)을 `place_entity` 에 추가 — `GOOGLE_PLACES_API_KEY` 미설정·호출 실패 시 보강만 생략(좌표·주소 백본 불변). repository 가 `MochiItem.place` 로 파싱(보강 필드도 projection 재검증: rating 0~5·imageUrl https+googleusercontent suffix) → `MochiItemResponse.place`(⓪ openapi) → iOS 상세 "장소" 섹션(NCP 키 있으면 **네이버 지도 NMapsMap 프리뷰**·없으면 MapKit 폴백 + 별점 라인 + 매장사진 타일 + 네이버 지도 길찾기 `nmap://` 딥링크, 미설치 시 웹 폴백). 키: 지오코딩은 기존 `NAVER_CLIENT_ID/SECRET` 재사용(없으면 tool 미노출), 보강은 `GOOGLE_PLACES_API_KEY`(선택), iOS 지도는 Info.plist `NMFNcpKeyId`(선택 — 발급 절차 docs/TODO.md §2.5·§3.6).
- **능동 검색 도구(2026-06-24)**: 분석 중 LLM 이 `hybridSearch`(자기 과거 기록 hybrid 검색 — 채팅 `search_items` 단일 구현을 owner_id 주입 어댑터로 공유)·`webSearch`(외부 사실, Tavily)를 능동 호출한다. `hybridSearch` 는 **저장 게이트가 아니라 분석 보강 신호** — 중복이어도 항상 저장하고(미션), 발견한 연결/중복/일정충돌은 summary·needs_review 에만 반영한다. 이는 분석 *후* 알림용 능동 회수(트랙C `generate_recall_candidates`, 임베딩 ANN→`notification_outbox`)와 **다른 단계**다: 전자는 분석 품질 보강(분석 중, LLM 이 과거를 떠올려 연결), 후자는 알림 발송 판단(분석 done 후 worker). owner_id 는 `ToolContext` 로 orchestrator 가 주입(LLM args 불신 — cross-tenant 방어), `conversations.application` 팩토리 경유 + duck-typing 으로 모듈 경계(§3.3) 준수.

---

## 6. 테스트 & DX

| 영역 | 도구 |
|---|---|
| 백엔드 단위 테스트 | pytest 8 (asyncio mode auto) — lifecycle policy / RRF / health / module boundaries / ingest E2E |
| 백엔드 정적 검사 | ruff + mypy `--explicit-package-bases` |
| iOS 단위 테스트 | XCTest + TCA TestStore — CoreDomain (Intent, LifecyclePolicy), CorePersistence (InMemoryRepo), FeatureInbox/MochiItem/Search |
| iOS 정적 검사 | SwiftLint (`.swiftlint.yml`) |
| CI | GitHub Actions — backend (Postgres + pgvector 서비스), iOS (Tuist install/generate/xcodebuild) |
| 로컬 DB | docker compose (`make db-up`) — pgvector/pgvector:pg16 |

---

## 7. 폴더 인덱스

| 영역 | 경로 |
|---|---|
| iOS 진입 | `mochi-ios/Targets/App/Sources/MochiApp.swift` |
| iOS 도메인 | `mochi-ios/Targets/Cores/CoreDomain/Sources/` |
| iOS 저장소 | `mochi-ios/Targets/Cores/CorePersistence/Sources/RealmMochiItemRepository.swift` |
| iOS 네트워킹 | `mochi-ios/Targets/Cores/CoreNetworking/Sources/OpenAPIMochiClient.swift` (+ `Generated/{Client,Types}.swift`) |
| Share Extension | `mochi-ios/Targets/ShareExtension/Sources/ShareExtensionPrincipal.swift` |
| Backend FastAPI 진입 | `mochi-backend/app/main.py`, `mochi-backend/app/api.py` |
| Backend 도메인 | `mochi-backend/app/modules/*/domain/` |
| Backend 마이그레이션 | `mochi-backend/alembic/versions/` |
| Backend 워커 | `mochi-backend/app/modules/agent/application/mochi_item_worker.py` |
| Backend agent loop | `mochi-backend/app/modules/agent/infrastructure/gemini_agent_client.py`, `application/orchestrator.py` |
| Backend 개인화 | `mochi-backend/app/modules/agent/application/refresh_user_profile.py`, `infrastructure/profile_store.py` |
| OpenAPI 스펙 | `mochi-backend/openapi.json` (정적 추출, `make openapi` 로 갱신) |

— 끝 —
