# 모찌 (MOCHI) — 시스템 아키텍처

> Multimodal AI 기반 스크린샷·링크·기록 통합관리 에이전트
> 2026 SW중심대학 디지털 경진대회 / 팀 **세얼간이** (송준서·박세현·이용찬)

이 문서는 두 저장소(`mochi-ios`, `mochi-backend`)가 합쳐서 만들어 내는 시스템 전체의 아키텍처를 정리한다.

---

## 1. High-level Topology

```
┌──────────────────────────── iOS Device ──────────────────────────────┐
│                                                                       │
│  ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐   │
│  │  Share Extension │   │ AppIntents Ext.  │   │   Main App (UI)  │   │
│  │  (NSItemProvider │   │ (Back-Tap 단축어)│   │  SwiftUI + TCA   │   │
│  │  URL/Text/Image) │   │  Siri/Spotlight  │   │  Inbox / Search  │   │
│  └────────┬─────────┘   └────────┬─────────┘   └────────┬─────────┘   │
│           │                      │                      │             │
│           ▼                      ▼                      │             │
│         App Group  (group.com.IndexFinger.mochi)        │             │
│         ├─ Realm DB (mochi.realm)         ←─────────────┘             │
│         ├─ Inbound Queue (*.json)                                     │
│         └─ Captured Images (HEIC/JPEG)                                │
│                                                                       │
│  CaptureSyncWorker actor ──►  URLSession (X-Mochi-Request-ID,         │
│                                Idempotency-Key, Authorization)        │
└────────────────────────────────────────────┬──────────────────────────┘
                                             │ HTTPS
                                             ▼
┌──────────────────────────── Backend ──────────────────────────────────┐
│  FastAPI Modular Monolith + Hexagonal Architecture                    │
│                                                                       │
│  ┌────────────────────── /api/v1 ─────────────────────┐               │
│  │  POST /captures   GET /captures/{id}               │               │
│  │  GET  /captures/{id}/stream (SSE)                  │               │
│  │  POST /search                                      │               │
│  │  GET  /health                                      │               │
│  └────────┬────────────────────┬────────────────────┬─┘               │
│           │                    │                    │                 │
│           ▼                    ▼                    ▼                 │
│  ┌──────────────┐    ┌──────────────┐     ┌──────────────┐            │
│  │  captures /  │    │   agent /    │     │   search /   │            │
│  │ (Hexagonal)  │    │ (Hexagonal)  │     │ (Hexagonal)  │            │
│  │              │    │              │     │              │            │
│  │ Ingest → DB  │    │ Orchestrator │     │ Hybrid RAG   │            │
│  │ + Outbox     │    │ + Tools      │     │ (BM25+벡터+  │            │
│  │              │    │              │     │  RRF→Rerank) │            │
│  └──────┬───────┘    └──────┬───────┘     └──────┬───────┘            │
│         │                   │                    │                    │
│         └──────► Postgres + pgvector ◄───────────┘                    │
│                 (captures, capture_image_refs,                        │
│                  entities, embeddings, idempotency_keys,              │
│                  capture_outbox, agent_runs, tool_calls)              │
│                                                                       │
│  Capture Worker  ──►  LISTEN capture_outbox / poll                    │
│  (FOR UPDATE SKIP LOCKED, AgentRunPersistence, DLQ)                   │
│                                                                       │
│  Vertex AI │ Gemini 3.5 Flash (multimodal function calling)           │
│  Vertex AI │ text-embedding-005                                       │
└───────────────────────────────────────────────────────────────────────┘
```

---

## 2. iOS — `mochi-ios`

### 2.1 핵심 결정
- **UI 스택:** SwiftUI + The Composable Architecture (TCA 1.x). `@Reducer`, `@ObservableState`, `@Bindable`, `TestStore`.
- **프로젝트 도구:** Tuist 4.x — `Project.swift` 단일 파일에 다중 framework target.
- **언어/타겟:** Swift 5.10, iOS 17+, `SWIFT_STRICT_CONCURRENCY=complete`.
- **로컬 DB:** Realm (App Group 공유 파일, `mochi.realm`, schema v2).
- **네트워킹:** `URLSessionMochiAPIClient`. 향후 `swift-openapi-generator` 로 생성된 클라이언트로 교체.

### 2.2 모듈 그래프

```
App  ──► Features ──► Cores ─┬─ CoreDomain        (pure model, 의존성 없음)
                             ├─ CorePersistence   (Realm + AppGroup + Repository)
                             ├─ CoreNetworking    (MochiAPIClient + DTO)
                             ├─ CoreAgentClient   (AgentStreamClient — SSE)
                             ├─ CoreIntegrations  (EventKit / Reminders)
                             └─ DesignSystem      (MochiTheme, IntentBadge)

App  ──► ShareExtension       (NSItemProvider → InboundCapturePayload)
App  ──► AppIntentsExtension  (QuickCaptureIntent + MochiShortcuts)
```

**의존 규칙:**
- Feature 모듈끼리 직접 의존 금지. 조합은 `RootFeature` 가 책임.
- 각 `*DI.swift` (e.g. `CaptureRepositoryDI`) 는 그 객체를 *소유하는* Core 모듈에 위치.
- Cores 는 ComposableArchitecture 가 아닌 `swift-dependencies` 만 import — TCA 의존성 누수를 막는다.

### 2.3 캡처 진입 채널

| 채널 | 진입점 | 출력 |
|---|---|---|
| 외부 앱 공유 시트 | `ShareExtensionPrincipal` (코드 기반, `NSExtensionPrincipalClass`) | `InboundCapturePayload` JSON → App Group inbound 큐 |
| iOS 백탭/Siri/Spotlight | `QuickCaptureIntent` + `MochiShortcuts` (`AppIntentsExtension`) | 동일한 `InboundCapturePayload` JSON |
| 앱 내 직접 입력 | `CaptureFeature` (TCA) | Realm 직접 upsert |

`MochiApp.tick()` 이 앱 launch 와 `scenePhase == .active` 시점에:
1. `InboundQueueConsumer.drain()` → 큐를 비우고 Realm 에 ingest
2. `CaptureSyncWorker.runOnce()` → `syncState == .pendingUpload` 캡처를 백엔드에 업로드 → `SyncState.uploaded` 또는 `.syncFailed`

### 2.4 4-Intent 라이프사이클

`CoreDomain.LifecyclePolicy.validate(from:to:intent:)` 가 다음 두 가지를 모두 검증:
1. (current.kind → next.kind) 페어가 Intent 별 허용 집합에 있는지
2. `.archived(reason:)` 의 reason 이 Intent 별 허용 reason 집합에 있는지

| Intent | 자동 동작 | 합법 전이 |
| --- | --- | --- |
| `schedule` | EventKit/Google Calendar sync | `ingested → analyzing → active → archived(scheduleEnded\|userManual)` |
| `todo` | Reminders sync | `ingested → analyzing → active → archived(todoCompleted\|userManual)` |
| `knowledge` | RAG 인덱싱 | `active → decaying → reviewRequested → archived(knowledgeStale\|userManual)` 또는 → active 복귀 |
| `memo` | 영구 보관 | `active → archived(userManual)` 만 |

위반 시 `LifecycleTransitionError`. 백엔드 `app/modules/intents/domain/lifecycle_policy.py` 가 동일 invariant 를 보장.

### 2.5 Realm Mapper Losslessness

`RealmCaptureMapper` 는 다음을 모두 round-trip 보존한다:
- `entities` (kind + value + provenance: textRange / ocrBoundingBox)
- `actionCandidates` (calendar / reminder / openURL / followUpSearch)
- `tags`
- `imageRefs` (sha256 + objectKey 포함)
- `SyncState` 세부 (uploaded serverID + 시각, syncFailed retryAfter)
- `LifecycleState` (archived reason, failed reason)

---

## 3. Backend — `mochi-backend`

### 3.1 핵심 결정
- **언어/Runtime:** Python 3.12, FastAPI, uv 패키지 관리
- **아키텍처:** Modular Monolith + Hexagonal (per-module `domain / application / infrastructure / presentation`)
- **DB:** Postgres 16 + pgvector (HNSW + cosine), async SQLAlchemy 2 + asyncpg, Alembic
- **AI:** Vertex AI · Gemini 3.5 Flash (multimodal function calling, streaming) · text-embedding-005
- **관측:** structlog (JSON, contextvars 로 request_id/idempotency_key/path 바인딩)
- **인증:** PyJWT + PyJWKClient (RS256/ES256/EdDSA), JWKS TTL 캐시; dev mode 는 `Bearer dev:<subject>` (environment=local 한정)

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
│   ├── captures/
│   │   ├── domain/                Capture / CaptureSource / ImageRef / LifecycleState (pure)
│   │   ├── application/           IngestCapture, GetCaptureForOwner, make_capture_repository
│   │   ├── infrastructure/        SQLAlchemy ORM (CaptureRow, CaptureImageRefRow,
│   │   │                          EntityRow, EmbeddingRow, IdempotencyKeyRow,
│   │   │                          AgentRunRow, ToolCallRow), OutboxNotifier
│   │   └── presentation/          POST/GET /captures + Pydantic API schemas
│   ├── intents/
│   │   └── domain/lifecycle_policy.py     4-Intent 상태 머신 (단일 진실 공급원)
│   ├── agent/
│   │   ├── domain/                AgentNode/AgentRun/Tool ABC/LLMClient port
│   │   ├── application/           AgentOrchestrator + AgentRunPersistence + CaptureWorker
│   │   ├── infrastructure/
│   │   │   ├── registry.py        StaticToolRegistry
│   │   │   └── tools/             WebFetchTool / EmbedTool / MultimodalAnalyzeTool
│   │   ├── prompts/system_prompts.py   PromptVersion(name/model/eval/revised_on/rationale)
│   │   └── presentation/router.py      GET /captures/{id}/stream (SSE)
│   └── search/
│       ├── domain/                SearchQuery / Citation / 3 outbound ports
│       ├── application/           HybridSearch use case
│       ├── infrastructure/        PostgresHybridIndex (owner-scoped BM25 + 벡터) + rrf
│       └── presentation/router.py      POST /search
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

**모듈 간 규칙 (`tests/unit/test_module_boundaries.py` 가 강제):**
1. 어떤 모듈도 다른 모듈의 `infrastructure/` · `presentation/` 내부를 직접 import 할 수 없다. 허용된 진입은 `domain/`, `application/`, `app.shared`, `app.core` 만.
2. 모든 `domain/` 레이어는 프레임워크 패키지(sqlalchemy / fastapi / httpx / google / pgvector) 를 import 할 수 없다.

### 3.4 데이터 흐름

#### 캡처 ingestion
```
POST /captures (with Idempotency-Key, Bearer)
  ↓
RequestContextMiddleware (request_id 바인딩)
  ↓
CaptureCreateRequest (Pydantic validate)
  ↓
IngestCapture.execute (use case)
  ├─ idempotency_key 가 owner-scoped 로 이미 있나? → 있으면 기존 capture 반환
  ├─ Capture aggregate 생성 (lifecycle=ingested)
  ├─ PostgresCaptureRepository.add → captures + capture_image_refs INSERT (한 트랜잭션)
  ├─ remember_idempotency → idempotency_keys INSERT
  └─ OutboxNotifier.emit → capture_outbox INSERT + pg_notify('capture_outbox', capture_id)
  ↓
DB COMMIT (atomic)
  ↓
201 Created + CaptureResponse
```

#### Agent worker
```
CaptureWorker.run_forever
  ↓
SELECT ... FOR UPDATE SKIP LOCKED
  - status='pending' OR (status='in_flight' AND locked_until<now)  ← in_flight 만료 reclaim
  - attempts < MAX_ATTEMPTS
  ↓
status='in_flight', attempts++, locked_until=now+60s
  ↓
AgentOrchestrator(persistence=AgentRunPersistence(session)).run(capture_id)
  ├─ start() → agent_runs INSERT
  ├─ for node in HAPPY_PATH:
  │    update_node() → agent_runs.current_node = node
  ├─ finish() / fail()
  └─ (도중 실패하면 예외 re-raise → worker가 outbox 재시도/DLQ 분기 결정)
  ↓
성공: outbox status='done'
실패 + attempts<MAX: status='pending' (재시도)
실패 + attempts>=MAX: status='dead_letter' (DLQ)
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
| 멱등성 | `Idempotency-Key` 헤더 필수. `capture:{owner_id}:{raw_key}` 의 SHA-256 으로 owner-scoping |
| 분산 추적 | `X-Mochi-Request-ID` 헤더 echo + structlog contextvars 자동 바인딩 |
| 에러 envelope | `{code, message, requestId, retryAfter}` 통일 포맷, iOS `APIErrorEnvelope` 와 1:1 |
| SSRF | WebFetchTool: 호스트 블록리스트 + 모든 A/AAAA 답변 IP 검증 (DNS rebinding 방어) + 매 redirect 재검증 + 스트리밍 byte limit + MIME 화이트리스트 |

### 3.6 OpenAPI 계약

- `make openapi` (혹은 `PYTHONPATH=. uv run python scripts/export_openapi.py`) → `openapi.json` 정적 추출 (~17KB)
- iOS `swift-openapi-generator` 가 빌드 타임에 이 파일을 소스로 사용
- `CI` 가 backend test 후 openapi 를 재생성·diff 하여 drift 차단 (향후 추가)

---

## 4. iOS ↔ Backend 계약

### 4.1 Request headers

| 헤더 | 필수 | 의미 |
|---|---|---|
| `Authorization: Bearer <token>` | 모든 라우트 (health 제외) | dev 토큰 또는 JWT |
| `X-Mochi-Request-ID` | 옵션 (없으면 서버가 생성) | 분산 추적 키 |
| `Idempotency-Key` | `POST /captures` | owner-scoped SHA-256 으로 정규화 |

### 4.2 Endpoints

| Method | Path | 응답 | 비고 |
|---|---|---|---|
| GET | `/api/v1/health` | `{status: "ok"}` | 인증 불필요 |
| POST | `/api/v1/captures` | `CaptureResponse` (201) | `CaptureCreateRequest` body, `imageRefs` 포함 |
| GET | `/api/v1/captures/{id}` | `CaptureResponse` | owner-scoped |
| GET | `/api/v1/captures/{id}/stream` | SSE `text/event-stream` | Agent state graph (node/final/failed) |
| POST | `/api/v1/search` | `SearchResponse` | Hybrid Search RAG, owner-scoped |

### 4.3 DTO 매핑

iOS `CoreNetworking.MochiAPIClient` 의 DTO 가 backend `openapi.json` 의 스키마와 1:1 매칭. CodingKeys 로 `userMemo`/`requestId`/`imageRefs` 등 camelCase 매핑.

---

## 5. 핵심 도메인 모델

### 5.1 `Capture` aggregate
- 단일 UUID 식별 (iOS `Capture.id == CaptureSource.id`, 백엔드 `captures.id`).
- 4-tuple: `source`, `analysis?`, `lifecycleState`, `syncState`.
- `analysis` 는 백엔드 agent loop 완료 후 채워짐.

### 5.2 `Intent` (4-Intent)
- `schedule` / `todo` / `knowledge` / `memo` — iOS·백엔드 동일 문자열 값
- Intent별 차등 lifecycle (위 2.4 표)

### 5.3 `AgentRun`
- `(capture_id, current_node, tool_calls, total_tokens, total_latency_ms, started_at, ended_at?, failure_reason?)`.
- `HAPPY_PATH = [ingested, normalized, analyzed, routed, persisted, indexed, synced]`. 실패 시 어디서든 `failed` 로 분기.

### 5.4 `Tool` (Pydantic 기반 타입 안전)
- `TIn`, `TOut` 두 Pydantic 모델로 generic. `schema()` 가 Gemini function-calling 용 JSON Schema 자동 생성.
- 현재 wire: `WebFetchTool`, `EmbedTool`, `MultimodalAnalyzeTool` (실 호출 stub).

---

## 6. 테스트 & DX

| 영역 | 도구 |
|---|---|
| 백엔드 단위 테스트 | pytest 8 (asyncio mode auto) — lifecycle policy / RRF / health / module boundaries / ingest E2E |
| 백엔드 정적 검사 | ruff + mypy `--explicit-package-bases` |
| iOS 단위 테스트 | XCTest + TCA TestStore — CoreDomain (Intent, LifecyclePolicy), CorePersistence (InMemoryRepo), FeatureInbox/Capture/Search |
| iOS 정적 검사 | SwiftLint (`.swiftlint.yml`) |
| CI | GitHub Actions — backend (Postgres + pgvector 서비스), iOS (Tuist install/generate/xcodebuild) |
| 로컬 DB | docker compose (`make db-up`) — pgvector/pgvector:pg16 |

---

## 7. 알려진 미완 구현 (다음 단계)

`make` 가능 작업은 완료되었지만, 다음은 본 PR 범위를 벗어나 **개별 도메인 별 별도 구현 작업**으로 진행해야 한다:

1. **실 Gemini multimodal function calling**
   - `app/modules/agent/infrastructure/tools/multimodal_analyze.py` 가 placeholder → google-genai 클라이언트로 교체
   - `AgentOrchestrator` 의 `ANALYZED` 노드에서 LLM 실 호출 + tool dispatch loop 구현
   - 결과를 `captures` 테이블 `intent / summary / importance / confidence / model_version` 에 반영
2. **실 RAG 파이프라인**
   - chunker (예: 300-token / 30-overlap, 한국어 friendly)
   - Vertex AI text-embedding-005 호출 → `embeddings` 테이블 upsert
   - `naive_embed` 제거 → 실 query embedding
   - cross-encoder reranker (예: bge-reranker)
   - 평가 fixtures (recall@k, MRR, citation accuracy)
3. **이미지 byte upload**
   - S3/GCS presigned URL 발급 엔드포인트
   - iOS `CaptureSyncWorker` 가 image bytes 업로드 후 `object_key` 를 받아 capture 요청에 포함
   - MIME 화이트리스트 + 서버측 size 재검증
4. **iOS SSE 클라이언트**
   - `CoreAgentClient.AgentStreamClient` 의 라이브 구현 (URLSession bytes stream + `event:`/`data:` 파서 + reconnection)
5. **swift-openapi-generator 통합**
   - `mochi-ios` 빌드에 generator 플러그인 추가
   - 수기 `MochiAPIClient` DTO 를 generated 코드로 치환
   - CI 에서 backend `openapi.json` 과 iOS 빌드 결과 drift 차단
6. **백엔드 integration tests**
   - `tests/integration/` 에 Postgres testcontainer 기반 E2E (이미지 round-trip, idempotent replay, lifecycle 거부, owner-scoped search, SSE shape, outbox 재청구)
7. **운영 controls**
   - rate limit (slowapi / fastapi-limiter)
   - OpenTelemetry 트레이싱, DB 타이밍, worker 메트릭
   - DLQ inspection/requeue 엔드포인트
   - PII 로깅 정책 + redaction

---

## 8. 폴더 인덱스

| 영역 | 경로 |
|---|---|
| iOS 진입 | `mochi-ios/Targets/App/Sources/MochiApp.swift` |
| iOS 도메인 | `mochi-ios/Targets/Cores/CoreDomain/Sources/` |
| iOS 저장소 | `mochi-ios/Targets/Cores/CorePersistence/Sources/RealmCaptureRepository.swift` |
| iOS 네트워킹 | `mochi-ios/Targets/Cores/CoreNetworking/Sources/URLSessionMochiAPIClient.swift` |
| Share Extension | `mochi-ios/Targets/ShareExtension/Sources/ShareExtensionPrincipal.swift` |
| App Intents | `mochi-ios/Targets/AppIntentsExtension/Sources/QuickCaptureIntent.swift` |
| Backend FastAPI 진입 | `mochi-backend/app/main.py`, `mochi-backend/app/api.py` |
| Backend 도메인 | `mochi-backend/app/modules/*/domain/` |
| Backend 마이그레이션 | `mochi-backend/alembic/versions/` (0001 초기, 0002 outbox, 0003 capture_image_refs) |
| Backend 워커 | `mochi-backend/app/modules/agent/application/capture_worker.py` |
| OpenAPI 스펙 | `mochi-backend/openapi.json` (정적 추출, `make openapi` 로 갱신) |

---

## 9. 변경 기록 (이번 라운드)

세팅 + codex 7라운드 리뷰 반영의 결과:
- iOS UI 스택: ReactorKit/UIKit → **SwiftUI + TCA 1.x**
- iOS 단일 Project.swift → **다중 framework target (Cores × 6, Features × 5, App, ShareExt, AppIntentsExt, Tests × 5)**
- Backend `schemas/services/agents` (technical) → **`modules/{captures,intents,agent,search}` (domain) × Hexagonal**
- 도메인 invariants 코드화: `LifecyclePolicy.validate(...)` (iOS+backend), `test_module_boundaries.py`
- 운영 패턴: transactional outbox + LISTEN/NOTIFY + DLQ + in_flight reclaim
- 계약: `X-Mochi-Request-ID`, `Idempotency-Key (owner-scoped sha256)`, `ErrorEnvelope`, OpenAPI 정적 추출
- 보안: PyJWT JWKS prod path + dev token (environment=local) 분리, SSRF DNS rebinding 방어

— 끝 —
