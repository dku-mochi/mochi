---
level: 2
mode: committed
status: active
last_verified: 2026-06-05
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
│  │  URL/Text/Image) │                          │  + AppIntents:   │   │
│  └────────┬─────────┘                          │  CaptureScreen…  │   │
│                                                │  Commit/Open…    │   │
│   ▲ 외부 공유시트                              │  QuickCapture    │   │
│     (ShareEntryView 메모/확인 UI)              │  + Inbox/Search  │   │
│                                                └────────┬─────────┘   │
│                                                  ▲ 백탭 단축어 → 모찌  │
│                                                    snippet 카드 (외부  │
│                                                    앱 위, 캡쳐/메모    │
│                                                    선택). 메모만 모찌  │
│                                                    foreground 진입     │
│                                                    + Siri·Spotlight    │
│           │                      │                      │             │
│           ▼                      ▼                      │             │
│         App Group  (group.app.mochi)                    │             │
│         ├─ Realm DB (mochi.realm)         ←─────────────┘             │
│         ├─ Inbound Queue (*.json)              ← ShareExtension only  │
│         ├─ Pending Back-Tap (*.png + *.memo)   ← snippet stash/marker │
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
│  │  GET  /users/me     GET /health                    │               │
│  │  planned(no route): list /sync /search /conv.      │               │
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
│                  users, auth_accounts, refresh_tokens)               │
│                                                                       │
│  Mochi Worker  ──►  LISTEN mochi_item_outbox / poll                   │
│  (FOR UPDATE SKIP LOCKED, AgentRunPersistence, DLQ)                   │
│                                                                       │
│  Vertex AI │ gemini-3.1-flash-lite (multimodal function calling)      │
│  Vertex AI │ text-embedding-005                                       │
└───────────────────────────────────────────────────────────────────────┘
```

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
                             ├─ CoreAgentClient   (AgentStreamClient — SSE)
                             ├─ CoreIntegrations  (EventKit / Reminders)
                             └─ DesignSystem      (MochiTheme, IntentBadge)

App  ──► ShareExtension       (NSItemProvider → InboundIngestPayload)
App  ──► AppIntents/          (QuickCaptureIntent + CaptureScreenshotIntent + BackTapSnippetView
                               + CommitBackTapCaptureIntent + OpenBackTapMemoIntent + MochiShortcuts)
                              ※ 별도 extension 타겟이 아니라 App 타겟 내부 (Targets/App/Sources/AppIntents/).
                              Apple 제약: AppShortcutsProvider 와 그것이 참조하는 AppIntent 는
                              메인 App 타겟에 있어야 시스템이 인덱싱한다.
```

**의존 규칙**:
- Feature 모듈끼리 직접 의존 금지. 조합은 `RootFeature` 가 책임.
- 각 `*DI.swift` (예: `MochiItemRepositoryDI`) 는 그 객체를 소유하는 Core 모듈에 위치.
- Cores 는 ComposableArchitecture 가 아닌 `swift-dependencies` 만 import — TCA 의존성 누수를 막는다.

### 2.3 캡처 진입 채널

| 채널 | 진입점 | 출력 |
|---|---|---|
| 외부 앱 공유 시트 (의식적 캡처) | `ShareExtensionPrincipal` (`NSExtensionPrincipalClass`) → `ShareEntryView` 메모/확인 모달 → 사용자가 저장 탭 | `InboundIngestPayload` JSON → App Group inbound 큐 (channel = `.screenshot` / `.safari` / `.appShareSheet` 등, host·hasImage 기반 `guessChannel` 결정) |
| iOS 백탭 (snippet 카드) | 사용자가 설치한 단축어 → `Take Screenshot` (Show Preview OFF) → **이미지 변환(PNG)** → **모찌 화면 캡쳐 액션** (`CaptureScreenshotIntent`, **메인 App 타겟 내부**, `openAppWhenRun = false`) → PNG 가 `pending-backtap/<captureID>.png` 에 stash, `ShowsSnippetView` 로 `BackTapSnippetView` 가 외부 앱 위에 카드로 표시 (모찌 앱은 깨우지 않음). 사용자가 카드의 "캡쳐" / "메모" 선택. | **캡쳐** → `CommitBackTapCaptureIntent` (`openAppWhenRun = false`) 가 background commit — pending → `captures/` 이동 + Realm `MochiItem(channel: .screenshot, syncState: .pendingUpload)` upsert + pending PNG 폐기. 백엔드 ingest 는 다음 모찌 active 시점의 `MochiItemSyncWorker` 가 시도 (snippet background process 는 인증·네트워크 인프라 부재 가능). **메모** → `OpenBackTapMemoIntent` (`openAppWhenRun = true`) 가 pending PNG 폐기 + `.memo` marker stash + 모찌 foreground 진입 → `RootFeature` 가 marker 발견 → `BackTapModalFeature` 풀스크린 모달 (textarea). |
| Siri / Spotlight (텍스트 메모) | `QuickCaptureIntent` + `MochiShortcuts` (**메인 App 타겟 내부**, `Targets/App/Sources/AppIntents/`) — App Group inbound 큐에 직접 적재 (모찌 UI 우회). 시스템 수준 result dialog 표시 가능. | 동일 JSON (channel = `.appIntent`, `userMemo` 또는 `url`) |
| 앱 내 직접 입력 | `MochiItemFeature` (TCA) | Realm 직접 upsert |

> **AppIntents 의 위치**: `QuickCaptureIntent` · `CaptureScreenshotIntent` · `MochiShortcuts` 는 별도 extension 타겟이 아니라 **메인 App 타겟 안** (`Targets/App/Sources/AppIntents/`) 에 있다. iOS 16+ 의 `AppShortcutsProvider` 는 메인 앱 타겟에 위치해야 시스템이 인덱싱한다 (Apple Developer Forums thread 759160). 이전에 별도 extension 으로 두었던 시기에는 단축어 앱·"앱과 공유" 액션·Siri·Spotlight 어디에서도 발견되지 않는 회귀가 있었음.
>
> **세 surface 가 의도적으로 분리되어 있다** — 의도가 다르므로 코드도 분리되는 게 더 정직하다:
> - **공유시트** = 사용자가 *의식적*으로 "이걸 모찌에 저장하고 싶다" 를 결정하는 순간. 메모를 받을 기회를 주는 게 자연스럽다 → `ShareEntryView` 모달.
> - **백탭** = "지금 이 화면" 을 즉시 stash + 사용자가 캡쳐/메모 중 선택. `CaptureScreenshotIntent` 가 PNG 한 장을 `pending-backtap/<captureID>.png` 에 떨구고 `ShowsSnippetView` 로 `BackTapSnippetView` 를 외부 앱 위에 카드로 표시 — **모찌 앱을 깨우지 않는다** (이전 모달 흐름은 YouTube 같은 외부 앱이 사라져 사용자 컨텍스트가 손실되는 UX 문제가 있었음. Papago 가 쓰는 패턴을 차용). **캡쳐** 선택 시 `CommitBackTapCaptureIntent` 가 background 에서 pending → `captures/` 이동 + Realm `MochiItem(.pendingUpload)` upsert + pending PNG 폐기. 외부 앱은 계속 보이고 snippet 만 사라진다 — iOS 17 의 `ShowsSnippetView` + `Button(intent:)` 조합에는 자동 dismiss API 가 없어 `CommitBackTapCaptureIntent` 의 반환 타입에 `ProvidesDialog` 를 conform 하여 시스템 결과 dialog ("모찌에 저장됐어요") 가 snippet 카드를 갈음하도록 한다 (iOS 18+ `SnippetIntent` / `dismissesIntent` 가 정식 해법이지만 deployment target 17.0). 백엔드 ingest 는 다음 모찌 active 시점의 `MochiItemSyncWorker` 가 시도 — snippet `openAppWhenRun = false` 흐름은 background process 에서 실행될 수 있어 `AppDependencies.bootstrap()` 이 호출되지 않은 상태일 수 있고, 그 시점에 `mochiAPIClient` · `AuthCoordinator` 등 인증/네트워크 인프라가 부재한다. Realm 에 박아둔 `.pendingUpload` 가 안전한 fallback 이며, 모달 흐름의 "백엔드 + 로컬 fallback" 과 정합. `.syncFailed` 로 marking 된 뒤 자동 재시도는 없음 (사용자 명시적 retry UI 가 필요, `docs/TODO.md`). **메모** 선택 시 `OpenBackTapMemoIntent` 가 pending PNG 즉시 폐기 + `<captureID>.memo` marker stash + 모찌 foreground 진입 → `RootFeature` 가 marker 발견 → `BackTapModalFeature` 풀스크린 모달 (textarea). 메모 분기는 키보드 입력이 필요해 모찌 앱을 깨우는 게 정당. `.memo` marker 는 모달의 어느 *정상 분기* (저장/취소) 든 폐기됨이 invariant — snippet 시스템 dismiss (사용자 외부 탭 / timeout) 시 commit intent 가 둘 다 실행되지 않을 수 있어 `.png` 잔재 가능. `RootFeature` 가 launch / scenePhase active 시점에 `.png` 를 모두 stale 폐기 + `.memo` 는 가장 최근 한 장만 promote 한다.
> - **음성/검색** = 텍스트 메모. 다른 두 surface 와 입력 종류 자체가 다름.
>
> **inbound queue 와 pending-backtap 디렉터리는 의도가 다르다**: 큐는 "이미 사용자가 저장 결정을 내린 캡처의 4-Intent 분석 대기열" (ShareExtension·`QuickCaptureIntent` 가 떨굼). pending-backtap 은 snippet 흐름의 단명 stash — `.png` 는 캡쳐 분기 commit 직후 또는 메모 분기 진입 직후에 폐기, `.memo` marker 는 모달 종료 시 폐기. snippet 시스템 dismiss 잔재는 `RootFeature` 가 launch / active 시점에 sweep.
>
> **출처앱 컨텍스트 (자동신호) — sentinel JSON**: 단축어가 출처앱을 평문 대신 sentinel JSON(`{"__mochi_ctx__":{"sourceApp":X}}`)으로 `text` 채널에 실어 보내면 `ShareExtensionPrincipal` 이 `CaptureContextSentinel`(CorePersistence)로 분해한다 — UI 엔 `SourceAppChip`("X에서 캡처"), 백엔드 `text` 엔 정규화 1줄(`[출처앱: X]`)로 합치고, 사용자 입력은 `user_memo` 로 끝까지 격리한다(자동신호 `text` ↔ 사용자의도 `user_memo` 2채널). sentinel 이 아니면 평문을 그대로 `text` 로 흡수(단축어 미재생성 하위호환). **일반 메모 모드**: 백탭 ShareExt 시트에서 스크린샷을 (×) 로 버리면 `imageRefs=[]` + channel `.appDirectInput` 으로 적재되고, 취소·제거 경로의 고아 PNG(`captures/`)는 `ShareExtensionPrincipal` 이 청소한다. sentinel·메모모드 모두 **백엔드/계약/DB 무변경**(출처앱 jsonb 1급화는 보류).
>
> **ShareExtension 직접 전송 (무이미지 best-effort 선반영) + 큐 진실원천**: ShareExt 는 단명 별도 프로세스라 `AppDependencies.bootstrap()` 이 돌지 않아 `mochiAPIClient`·`AuthCoordinator` 가 부재한다. 캡처는 **항상 inbound 큐에 먼저 적재**된다 — 로컬 Realm ingest·동기화·유실 방지의 진실원천(다음 active tick 의 drain → upsert → `MochiItemSyncWorker` 업로드). 그 위에서 무이미지(URL/텍스트)면 **Keychain access group** 으로 access token 을 읽고(`AuthSessionStore.accessTokenIfValid`, refresh 시도 안 함) App Group 공유 baseURL(`AppGroup.sharedAPIBaseURL`, App 부팅 시 `setSharedAPIBaseURL` 로 공유)로 `OpenAPIMochiClient` 를 경량 구성해 `POST /mochi_items` 를 **best-effort 선반영**한다(`ShareExtDirectUpload`, 짧은 timeout) — 서버 분석을 앱 부팅 전 조기 트리거. 선반영이 성공해도 큐는 그대로이고, 멱등키(`payload.id`)가 메인 앱 drain·SyncWorker 재전송과 **같은 행을 반환**해 이중 적재가 불가능하다(로컬 누락·유실 0). **이미지 포함은 선반영을 시도하지 않는다** — ShareExt 메모리 한계(~120MB)의 OOM 위험으로 큐(메인 앱 `MochiItemSyncWorker`)에만 맡긴다. 백엔드/openapi/DB 무변경(같은 ingest 재사용).

`MochiApp.tick()` 이 앱 launch 와 `scenePhase == .active` 시점에:
1. `InboundQueueConsumer.drain()` → 큐를 비우고 Realm 에 ingest
2. `MochiSyncWorker.runOnce()` → `syncState == .pendingUpload` 인 MochiItem 를 backend 에 업로드 → `.uploaded` 또는 `.syncFailed`

별도로 `RootFeature` 가 `.appLaunched` / `.appBecameActive` 시점에 `pending-backtap/` 을 검사 → (a) `.png` 잔재 (snippet 시스템 dismiss 후 남은 것) 는 모두 sweep, (b) `.memo` marker 가 있으면 가장 최근 한 장의 captureID 를 추출해 `BackTapModalFeature` 메모 phase 로 띄움 (인증된 상태에서만; 미인증이면 다음 active 시점까지 대기).

### 2.4 4-Intent 라이프사이클 (2분할 — 처리상태 ⊥ 의미상태)

2026-06-04 빅뱅으로 lifecycle 은 **2분할**됐다(DOMAIN_DESIGN §7). **item 처리상태**와 **intent instance 의미상태**가 직교한다.

- **처리상태** (`mochi_items.lifecycle_kind`, item 단위): `ingested → analyzing → analyzed`(분석완료·instance 적재됨·iOS SSE `final`/폴링 컷오버 신호), 실패 시 `→ failed`. archive 없음.
- **의미상태** (`intent_instances.lifecycle_kind`, instance 단위): instance 는 분석 성공 시 `active` 로 태어난다. `CoreDomain.LifecyclePolicy.validate(from:to:intent:)` 가 (1) `(current→next)` 페어가 intent_type 별 허용인지 (2) `.archived(reason:)` 의 reason 이 intent_type 별 허용인지 검증.

| intent_type | 자동 동작 | 합법 전이(의미상태) |
| --- | --- | --- |
| `schedule` | EventKit/Google Calendar sync | `active → archived(scheduleEnded\|userManual)` |
| `todo` | Reminders sync | `active → archived(todoCompleted\|userManual)` |
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

---

## 3. Backend — `mochi-backend`

### 3.1 핵심 결정

- **언어/Runtime**: Python 3.12, FastAPI, uv 패키지 관리
- **아키텍처**: Modular Monolith + Hexagonal (per-module `domain / application / infrastructure / presentation`)
- **DB**: Postgres 16 + pgvector (HNSW + cosine), async SQLAlchemy 2 + asyncpg, Alembic
- **AI**: Vertex AI · `gemini-3.1-flash-lite` (multimodal function calling, streaming) · text-embedding-005
- **관측**: structlog (JSON, contextvars 로 request_id/idempotency_key/path 바인딩)
- **인증**: PyJWT + PyJWKClient (RS256/ES256/EdDSA), JWKS TTL 캐시; dev mode 는 `Bearer dev:<subject>` (environment=local 한정)

### 3.2 모듈 트리

```
app/
├── core/                          cross-cutting
│   ├── config.py                  Pydantic Settings
│   ├── db.py                      AsyncEngine/AsyncSession factory
│   ├── logging.py                 structlog
│   ├── middleware.py              X-Mochi-Request-ID + Idempotency-Key 바인딩
│   ├── error_envelope.py          ErrorEnvelope + Exception handlers
│   ├── security.py                JWKS-backed CurrentUser (dev vs prod 분리)
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
│   │   ├── application/           AgentOrchestrator + AgentRunPersistence + MochiWorker
│   │   ├── infrastructure/
│   │   │   ├── registry.py        StaticToolRegistry
│   │   │   └── tools/             PlatformContextTool / WebFetchTool / EmbedTool / MultimodalAnalyzeTool
│   │   ├── prompts/system_prompts.py   PromptVersion(name/model/eval/revised_on/rationale)
│   │   └── presentation/router.py      GET /mochi_items/{id}/stream (SSE)
│   ├── search/
│   │   ├── domain/                SearchQuery / Citation / 3 outbound ports
│   │   ├── application/           HybridSearch use case
│   │   ├── infrastructure/        PostgresHybridIndex (owner-scoped BM25 + 벡터) + rrf
│   │   └── presentation/router.py      POST /search
│   ├── notifications/                   PR-B — APNs background push
│   │   ├── domain/                APNsClient/PushTokenRepository port, DevicePushToken
│   │   ├── application/           RegisterPushToken, SendAnalysisNotification, make_push_token_repository
│   │   ├── infrastructure/        HttpxAPNsClient(http2+ES256 JWT), PostgresPushTokenRepository, DevicePushTokenRow
│   │   └── presentation/router.py      POST /devices/push-token
│   └── conversations/
│       ├── domain/                Conversation / Message / Citation
│       ├── application/           SendMessage, GetConversation
│       ├── infrastructure/        SQLAlchemy ORM
│       └── presentation/          POST /conversations, POST /conversations/{id}/messages
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

#### Agent worker

> 기동: `app/main.py` lifespan 에서 API 와 같은 프로세스의 백그라운드 태스크로 실행 (`asyncio.create_task(worker.run_forever())`, shutdown 시 graceful stop). 별도 워커 프로세스 아님 — 단일 인스턴스 dev/제출 전제.

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
  └─ (done 커밋 직후, 분석 try 밖, best-effort) SendAnalysisNotification → APNs alert(전 단말) + LA .ready(해당 item). push 실패는 격리(done 유지) — 누락은 iOS reconcile 이 메움
실패 + attempt<max: status='pending' (재시도)
실패 + attempt=max: status='dead_letter' + mochi_items.lifecycle_kind='failed'
```

#### 실시간 반영 (iOS, PR-B)

처리완료를 iOS 가 받는 경로는 **프로세스 상태**로 3분담된다(캡처 채널 무관):

- **foreground = SSE**: iOS `AgentStreamClient` 가 `GET /mochi_items/{id}/stream` 구독. 서버는 worker 의 `mochi_items.lifecycle_kind` 를 read-only 폴링(1s)해 `node`/`final`/`failed` emit — 실제 분석은 worker 단독(이중 실행 방지). iOS 는 `final` 수신 시 `GET /mochi_items/{serverID}` 재조회로 분석결과 fetch.
- **background/종료 = APNs**: SSE 소켓이 suspend 되므로 worker push 훅이 인계(완료 alert + LA `.ready`).
- **fallback = 폴링**: SSE 실패/끊김 시 3초 폴링(`GET /mochi_items/{serverID}`, 제거 금지). scenePhase active 복귀 시 reconcile(SSE 재연결 + 1회 폴링).

#### 자연어 검색

```
POST /search (Bearer)
  ↓
SearchQuery(text, scope, owner_id=user)
  ↓
HybridSearch.execute
  ├─ PostgresHybridIndex.bm25  (owner_id 필터, ts_rank_cd)
  ├─ PostgresHybridIndex.vector (owner_id 필터, embeddings <=> CAST(:vec AS vector))
  ├─ reciprocal_rank_fusion(k=60)
  ├─ (optional) Reranker
  └─ AnswerSynthesizer.synthesize → answer + citations
  ↓
SearchResponse
```

### 3.5 보안

| 항목 | 처리 |
|---|---|
| 인증 | dev = `Bearer dev:<subject>` (environment=local only) → SHA-256 결정론적 UserID. prod = PyJWT + PyJWKClient, RS256/ES256/EdDSA, iss/aud/exp/iat/sub 검증 |
| 인가 | 모든 read/write 는 `owner_id` 키워드 인자 강제 — cross-tenant 누설을 컴파일 시점에 차단 |
| 멱등성 | `Idempotency-Key` 헤더 필수. `mochi_item:{owner_id}:{raw_key}` 의 SHA-256 으로 owner-scoping |
| 분산 추적 | `X-Mochi-Request-ID` 헤더 echo + structlog contextvars 자동 바인딩 |
| 에러 envelope | `{code, message, requestId, retryAfter}` 통일 포맷, iOS `APIErrorEnvelope` 와 1:1 |
| SSRF | WebFetchTool/PlatformContextTool: 호스트 블록리스트 + 모든 A/AAAA 답변 IP 검증 (DNS rebinding 방어) + 매 redirect 재검증 + 스트리밍 byte limit + MIME 화이트리스트 |

### 3.6 OpenAPI 계약 (⓪-tier 단일 원천)

- `make openapi` (= `scripts/export_openapi.py`) → `openapi.json` 정적 추출 + iOS `CoreNetworking/openapi.json` 동기화. FastAPI 3.1 의 `anyOf:[X, {type:null}]` 은 `export_openapi.py` 가 3.0 `nullable:true` 로 낮춘다 (swift-openapi-generator 가 `type:null` 을 skip 하는 문제 회피).
- iOS `CodeGen/generate.sh`(swift-openapi-generator)가 `openapi.json` → `CoreNetworking/Sources/Generated/{Client,Types}.swift` 생성. `OpenAPIMochiClient` 어댑터가 `MochiAPIClient` 라이브 구현(날짜 transcoder + auth 미들웨어 + 6 op 위임, `putCaptureImage` 만 GCS 직접 PUT).
- 동기화 게이트: `ship-precheck §5a`(백엔드 code↔openapi.json no-diff) + `§5b`(openapi.json↔생성물 no-diff). CI(`ship-precheck.yml`)는 §5a 재실행.

---

## 4. iOS ↔ Backend 계약

> **API 계약의 단일 원천은 [`mochi-backend/openapi.json`](../mochi-backend/openapi.json)** — 백엔드 `presentation/` 에서 `make openapi` 로 생성된다. **엔드포인트 목록·요청/응답 스키마·필드 타입은 이 문서에 복제하지 않는다**(로컬 구동 시 `GET /docs` Swagger UI). 어느 라우트가 실재하고 iOS 가 배선됐는지의 단일 원천은 [`DOMAIN_DESIGN.md`](DOMAIN_DESIGN.md) §6 이다. 이 절은 그 위에 얹히는 *런타임 규약*(헤더)·*매핑*만 다룬다.

### 4.1 Request headers

| 헤더 | 필수 | 의미 |
|---|---|---|
| `Authorization: Bearer <token>` | 모든 라우트 (health 제외) | dev 토큰 또는 JWT |
| `X-Mochi-Request-ID` | 옵션 (없으면 서버가 생성) | 분산 추적 키 |
| `Idempotency-Key` | `POST /mochi_items` | owner-scoped SHA-256 으로 정규화 |

### 4.2 Endpoints

엔드포인트 목록·요청/응답 스키마는 **`openapi.json`** 단일 원천(위 §4 노트). 각 라우트의 도메인 의미·실재/배선 상태(✅실재배선 / ◑서버만 / ○미존재)는 [`DOMAIN_DESIGN.md`](DOMAIN_DESIGN.md) §6 표를 본다.

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
- agent loop 가 LLM 에 광고하는 URL 그라운딩 도구는 `PlatformContextTool` 과 `WebFetchTool` 이다. `PlatformContextTool` 은 YouTube/X/Instagram URL 을 먼저 처리한다: YouTube는 oEmbed+watch page metadata, X는 `publish.x.com/oembed`, Instagram은 Meta oEmbed 토큰이 있으면 공식 oEmbed·없으면 OG fallback 을 사용한다. Instagram은 이미지 맥락 의존도가 높아 screenshot Vision 결과를 primary context 로 둔다. `EmbedTool`/`MultimodalAnalyzeTool` 은 스키마 재사용·후속 wire 용으로 보존.
- screenshot/image 분석은 `lab/active/extraction-strategy` 의 C 전략을 prompt-level grounding 으로 채택한다: 모델이 내부적으로 `fact` / `opinion` / `info` typed statement 를 세운 뒤 final summary/entities 를 만들며, `facts/opinions/key_info/entities` 버킷을 모두 채우도록 강제하지 않는다. Agent 입력에는 매 run `Asia/Seoul` 현재 기준시각을 넣어 상대 날짜·요일·마감 해석 기준을 고정한다.

### 5.5 Agent loop & 개인화 (Arch2 — LLM = 분석가)

- **`GeminiAgentClient(LLMClient)`** (`gemini-3.1-flash-lite`/global) — function-calling 루프. LLM 이 분석가: `finalizeAnalysis`(V7, boolean instances) 로 가변 개수 `intent_instances`(`intent_type`·`payload`(typed)·`label`·`reasoning`) + `needs_review` + `review_options` + summary·entities 를 직접 저술한다. **서버 derive 없음**(점수·대표·위계 폐기 — `_to_analysis_result` 가 DTO→instance 1:1 분해). `platformContext`/`webFetch` 로 URL 그라운딩. `AgentOrchestrator` 가 첫 user turn 에 `# 시간 컨텍스트`(Asia/Seoul 현재시각)를 주입한다. orchestrator 의 `ANALYZED` 노드가 루프를, `PERSISTED` 노드가 `MochiItemGateway.apply_analysis` write-back(intent_instances delete-reinsert + 처리상태 `→analyzed`)을 담당.
- **개인화**: `user_profiles` 에 유저 특성 요약(관심사·평소 분류 성향)을 sliding-window 로 적립(`RefreshUserProfile`, 디바운스), 분석 시 system prompt 에 주입 → 쓸수록 정확. 상세 흐름은 `DOMAIN_DESIGN.md §8.2`.
- text+URL = 실연결. 이미지 bytes 분석·임베딩 적재(INDEXED)는 design-ahead.

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
| App Intents | `mochi-ios/Targets/App/Sources/AppIntents/` — `QuickCaptureIntent`, `CaptureScreenshotIntent` (snippet trigger), `BackTapSnippetView`, `CommitBackTapCaptureIntent` (캡쳐 분기 background), `OpenBackTapMemoIntent` (메모 분기 foreground), `MochiShortcuts` (메인 App 타겟 내부) |
| iOS 백탭 메모 모달 | `mochi-ios/Targets/Features/FeatureMochiItem/Sources/BackTapModalFeature.swift`, `BackTapModalView.swift` |
| Backend FastAPI 진입 | `mochi-backend/app/main.py`, `mochi-backend/app/api.py` |
| Backend 도메인 | `mochi-backend/app/modules/*/domain/` |
| Backend 마이그레이션 | `mochi-backend/alembic/versions/` |
| Backend 워커 | `mochi-backend/app/modules/agent/application/mochi_item_worker.py` |
| Backend agent loop | `mochi-backend/app/modules/agent/infrastructure/gemini_agent_client.py`, `application/orchestrator.py` |
| Backend 개인화 | `mochi-backend/app/modules/agent/application/refresh_user_profile.py`, `infrastructure/profile_store.py` |
| OpenAPI 스펙 | `mochi-backend/openapi.json` (정적 추출, `make openapi` 로 갱신) |

— 끝 —
