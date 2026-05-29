---
level: 2
mode: committed
status: active
last_verified: 2026-05-29
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
│         App Group  (group.com.IndexFinger.mochi)        │             │
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
│  │  POST /mochi_items       GET /mochi_items/{id}     │               │
│  │  PATCH /mochi_items/{id}                           │               │
│  │  GET  /mochi_items/sync?after=                     │               │
│  │  GET  /mochi_items/{id}/stream (SSE)               │               │
│  │  POST /search                                      │               │
│  │  POST /conversations  POST /conversations/{id}/msg │               │
│  │  GET  /health                                      │               │
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
│                 (mochi_items, mochi_sources, mochi_attachments,       │
│                  mochi_entities, embeddings, idempotency_keys,        │
│                  mochi_outbox, agent_runs, tool_calls, ...)           │
│                                                                       │
│  Mochi Worker  ──►  LISTEN mochi_outbox / poll                        │
│  (FOR UPDATE SKIP LOCKED, AgentRunPersistence, DLQ)                   │
│                                                                       │
│  Vertex AI │ Gemini Flash (multimodal function calling)               │
│  Vertex AI │ text-embedding-005                                       │
└───────────────────────────────────────────────────────────────────────┘
```

---

## 2. iOS — `mochi-ios`

### 2.1 핵심 결정

- **UI 스택**: SwiftUI + The Composable Architecture (TCA 1.x). `@Reducer`, `@ObservableState`, `@Bindable`, `TestStore`.
- **프로젝트 도구**: Tuist 4.x — `Project.swift` 단일 파일에 다중 framework target.
- **언어/타겟**: Swift 5.10, iOS 17+, `SWIFT_STRICT_CONCURRENCY=complete`.
- **로컬 DB**: Realm (App Group 공유 파일, `mochi.realm`).
- **네트워킹**: `URLSessionMochiAPIClient`. 향후 `swift-openapi-generator` 로 생성된 클라이언트로 교체.

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

`MochiApp.tick()` 이 앱 launch 와 `scenePhase == .active` 시점에:
1. `InboundQueueConsumer.drain()` → 큐를 비우고 Realm 에 ingest
2. `MochiSyncWorker.runOnce()` → `syncState == .pendingUpload` 인 MochiItem 를 backend 에 업로드 → `.uploaded` 또는 `.syncFailed`

별도로 `RootFeature` 가 `.appLaunched` / `.appBecameActive` 시점에 `pending-backtap/` 을 검사 → (a) `.png` 잔재 (snippet 시스템 dismiss 후 남은 것) 는 모두 sweep, (b) `.memo` marker 가 있으면 가장 최근 한 장의 captureID 를 추출해 `BackTapModalFeature` 메모 phase 로 띄움 (인증된 상태에서만; 미인증이면 다음 active 시점까지 대기).

### 2.4 4-Intent 라이프사이클

`CoreDomain.LifecyclePolicy.validate(from:to:intent:)` 가 다음 두 가지를 모두 검증:
1. `(current → next)` 페어가 Intent 별 허용 집합에 있는지
2. `.archived(reason:)` 의 reason 이 Intent 별 허용 reason 집합에 있는지

| Intent | 자동 동작 | 합법 전이 |
| --- | --- | --- |
| `schedule` | EventKit/Google Calendar sync | `ingested → analyzing → active → archived(schedule_ended\|user_manual)` |
| `todo` | Reminders sync | `ingested → analyzing → active → archived(todo_completed\|user_manual)` |
| `knowledge` | RAG 인덱싱 | `active → decaying → review_requested → archived(knowledge_stale\|user_manual)` 또는 → active 복귀 |
| `memo` | 영구 보관 | `active → archived(user_manual)` 만 |

위반 시 `LifecycleTransitionError`. 백엔드 `app/modules/intents/domain/lifecycle_policy.py` 가 동일 invariant 를 보장.

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
- **AI**: Vertex AI · Gemini Flash (multimodal function calling, streaming) · text-embedding-005
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
│   │   ├── domain/                MochiItem / MochiSource / Attachment / LifecycleState (pure)
│   │   ├── application/           IngestMochiItem, GetMochiItemForOwner, make_mochi_item_repository
│   │   ├── infrastructure/        SQLAlchemy ORM (MochiItemRow, MochiSourceRow,
│   │   │                          MochiAttachmentRow, MochiEntityRow, EmbeddingRow,
│   │   │                          IdempotencyKeyRow, MochiOutboxRow,
│   │   │                          AgentRunRow, ToolCallRow), OutboxNotifier
│   │   └── presentation/          POST/GET/PATCH /mochi_items + Pydantic API schemas
│   ├── intents/
│   │   └── domain/lifecycle_policy.py     4-Intent 상태 머신 (단일 진실 공급원)
│   ├── agent/
│   │   ├── domain/                AgentNode/AgentRun/Tool ABC/LLMClient port
│   │   ├── application/           AgentOrchestrator + AgentRunPersistence + MochiWorker
│   │   ├── infrastructure/
│   │   │   ├── registry.py        StaticToolRegistry
│   │   │   └── tools/             WebFetchTool / EmbedTool / MultimodalAnalyzeTool
│   │   ├── prompts/system_prompts.py   PromptVersion(name/model/eval/revised_on/rationale)
│   │   └── presentation/router.py      GET /mochi_items/{id}/stream (SSE)
│   ├── search/
│   │   ├── domain/                SearchQuery / Citation / 3 outbound ports
│   │   ├── application/           HybridSearch use case
│   │   ├── infrastructure/        PostgresHybridIndex (owner-scoped BM25 + 벡터) + rrf
│   │   └── presentation/router.py      POST /search
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
(이미지 첨부 시 선행) POST /mochi_items/presign → V4 Signed PUT URL → 클라가 GCS 직접 업로드 → objectKey 확보
  ↓
POST /mochi_items 또는 POST /mochi_items/back-tap (with Idempotency-Key, Bearer)
  ↓
RequestContextMiddleware (request_id 바인딩)
  ↓
MochiItemCreateRequest (Pydantic validate)
  ↓
IngestMochiItem.execute (use case)
  ├─ idempotency_key 가 owner-scoped 로 이미 있나? → 있으면 기존 mochi_item 반환
  ├─ MochiItem aggregate 생성 (lifecycle=ingested)
  ├─ PostgresMochiItemRepository.add → mochi_items + mochi_sources + mochi_attachments INSERT (한 트랜잭션)
  ├─ remember_idempotency → idempotency_keys INSERT
  └─ OutboxNotifier.emit → mochi_outbox INSERT + pg_notify('mochi_outbox', mochi_item_id)
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
성공: mochi_outbox DELETE (done 즉시 정리)
실패 + attempt<max: status='pending', available_at=now()+backoff
실패 + attempt=max: dead_letters INSERT + mochi_items.lifecycle_state='failed'
```

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
| SSRF | WebFetchTool: 호스트 블록리스트 + 모든 A/AAAA 답변 IP 검증 (DNS rebinding 방어) + 매 redirect 재검증 + 스트리밍 byte limit + MIME 화이트리스트 |

### 3.6 OpenAPI 계약

- `make openapi` (또는 `PYTHONPATH=. uv run python scripts/export_openapi.py`) → `openapi.json` 정적 추출
- iOS `swift-openapi-generator` 가 빌드 타임에 이 파일을 소스로 사용
- CI 가 backend test 후 openapi 를 재생성·diff 하여 drift 차단

---

## 4. iOS ↔ Backend 계약

### 4.1 Request headers

| 헤더 | 필수 | 의미 |
|---|---|---|
| `Authorization: Bearer <token>` | 모든 라우트 (health 제외) | dev 토큰 또는 JWT |
| `X-Mochi-Request-ID` | 옵션 (없으면 서버가 생성) | 분산 추적 키 |
| `Idempotency-Key` | `POST /mochi_items` | owner-scoped SHA-256 으로 정규화 |

### 4.2 Endpoints

| Method | Path | 응답 | 비고 |
|---|---|---|---|
| GET | `/api/v1/health` | `{status: "ok"}` | 인증 불요 |
| POST | `/api/v1/mochi_items` | `MochiItemResponse` (201) | `MochiItemCreateRequest` body, `attachments` 포함 |
| GET | `/api/v1/mochi_items/{id}` | `MochiItemResponse` | owner-scoped |
| PATCH | `/api/v1/mochi_items/{id}` | `MochiItemResponse` | server-wins |
| DELETE | `/api/v1/mochi_items/{id}` | 204 | soft delete |
| GET | `/api/v1/mochi_items` | `MochiItemResponse[]` | filter: `intent`, `lifecycle_state`, `after`, `limit` |
| GET | `/api/v1/mochi_items/sync?after=` | `MochiItemResponse[]` | catch-up sync |
| GET | `/api/v1/mochi_items/{id}/stream` | SSE `text/event-stream` | Agent state graph (node/final/failed) |
| POST | `/api/v1/search` | `SearchResponse` | Hybrid Search RAG, owner-scoped |
| POST | `/api/v1/conversations` | `Conversation` (201) | |
| POST | `/api/v1/conversations/{id}/messages` | `Message + Citations` | |

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
- agent loop 가 LLM 에 광고하는 호출 도구는 `WebFetchTool` (URL 그라운딩) 하나. `EmbedTool`/`MultimodalAnalyzeTool` 은 스키마 재사용·후속 wire 용으로 보존.

### 5.5 Agent loop & 개인화 (Arch2 — LLM = 분석가)

- **`GeminiAgentClient(LLMClient)`** (`gemini-3.1-flash-lite`/global) — function-calling 루프. LLM 이 분석가: `finalizeAnalysis` 로 구조화 분석(summary·intent·secondary·entities)을 직접 저술, `webFetch` 로 URL 그라운딩. orchestrator 의 `ANALYZED` 노드가 루프를, `PERSISTED` 노드가 `MochiItemGateway.apply_analysis` write-back(+lifecycle `→active`)을 담당.
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
| iOS 네트워킹 | `mochi-ios/Targets/Cores/CoreNetworking/Sources/URLSessionMochiAPIClient.swift` |
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
