---
level: 2
mode: reference
status: active
last_verified: 2026-07-15
confidence: 0.9
owners: [송준서, 이용찬, 박세현]
description: FastAPI 백엔드 진입점·빌드 가이드·모듈 구조. 백엔드 코드 시작 시 또는 make 명령·헥사고날 레이어 규칙·Idempotency·SSRF 가드 작업 시 읽어라. 모듈 경계 테스트(test_module_boundaries.py) 의도 + openapi.json 생성 흐름 포함.
---

# 모찌 백엔드 (mochi-backend)

> Multimodal AI 기반 스크린샷·링크·기록 통합관리 에이전트 — FastAPI 백엔드

2026 SW중심대학 디지털 경진대회 SW부문 출품작 / 팀 **세얼간이**

## 기술 스택

| 분류 | 기술 |
| --- | --- |
| 언어 | Python 3.12 |
| 패키지 관리 | uv 0.8+ |
| 웹 프레임워크 | FastAPI (Modular Monolith + Hexagonal Architecture) |
| 비동기 ORM | SQLAlchemy 2 (asyncio, typed `MappedAsDataclass`) + asyncpg |
| 마이그레이션 | Alembic (autogenerate + compare_type) |
| DB | Postgres 16 + pgvector (HNSW + cosine) |
| AI | Vertex AI · `gemini-3.1-flash-lite` (multimodal function calling, streaming) / Voyage AI · `voyage-4-large@1024` (임베딩) + `rerank-2.5` (리랭커) |
| 로깅 / 관측 | structlog (JSON, bound contextvars: request_id, idempotency_key) |

## 모듈 구조 — Modular Monolith + Hexagonal

```
app/
├── core/                          cross-cutting concerns
│   ├── config.py                  Pydantic Settings (env-driven)
│   ├── db.py                      AsyncEngine / AsyncSession factory
│   ├── logging.py                 structlog 설정
│   ├── middleware.py              X-Mochi-Request-ID + Idempotency-Key 바인딩
│   ├── error_envelope.py          통일 에러 응답 + Exception handler
│   ├── security.py                인증 의존성 — CurrentUser(HS256 JWT·dev) + CurrentCaptureUser(ingest/presign 전용, +capture token)
│   └── deps.py                    `DBSession = Annotated[AsyncSession, Depends(get_session)]`
├── shared/                        모듈 간 공통 enum (Intent, ids)
├── modules/
│   ├── mochi_items/
│   │   ├── domain/                MochiItem, IngestSource, LifecycleState (pure)
│   │   ├── application/           Ingest use case
│   │   ├── infrastructure/        SQLAlchemy ORM + PostgresMochiItemRepository
│   │   └── presentation/          FastAPI router + Pydantic API schemas
│   ├── intents/
│   │   └── domain/lifecycle_policy.py     4-Intent 상태 머신 (단일 진실 공급원)
│   ├── agent/
│   │   ├── domain/                AgentNode, AgentRun, Tool ABC, LLMClient port
│   │   ├── application/           AgentOrchestrator (state graph)
│   │   ├── infrastructure/
│   │   │   ├── registry.py        StaticToolRegistry
│   │   │   └── tools/             PlatformContextTool, WebFetchTool (SSRF/MIME/size 가드), Embed, MultimodalAnalyze
│   │   ├── prompts/system_prompts.py     버전 관리되는 system prompt
│   │   └── presentation/router.py        SSE 스트림 엔드포인트
│   ├── search/
│   │   ├── domain/                SearchQuery, Citation, RetrievalIndex/Reranker ports
│   │   ├── application/           HybridSearch use case (BM25 + 벡터 → RRF → reranker)
│   │   ├── infrastructure/        PostgresHybridIndex, rrf
│   │   └── presentation/router.py
│   ├── conversations/             채팅(질문 탭) 멀티턴 대화 — 설계: journal/2026-06-10-chat-tab-design.md
│   │   ├── domain/                Conversation/Message/MessageCitation + ChatTool·ChatLLMClient·ChatTurnStore ports + run_events
│   │   ├── application/           BeginChatTurn(암묵 생성·동시 run 409) · RunChatTurn(detached run — 한도 폴백·owner-scoped citation 복구) · queries
│   │   ├── infrastructure/        ORM·repository · RunRegistry(in-process queue) · GeminiChatClient(첫 라운드 ANY→AUTO, stream) · turn_store · tools/(read-only)
│   │   ├── prompts/               chat@v10 — PromptVersion 버저닝, 기준+why
│   │   └── presentation/router.py POST /{id}/messages(POST-as-SSE) · GET 목록/스냅샷 · DELETE
│   └── notifications/             푸시 토큰 + 능동 회수 알림(트랙 A/B)
│       ├── domain/                DevicePushToken, APNsClient port · RecallPlan/RecallPlanStages · RecallReaction · RecallFeedEntry
│       ├── application/           RegisterPushToken, SendNotification · PlanRecallNotifications(eligibility 게이트 + LLM 플래너) · NotificationWorker(cron) · SendRecallNotification · RecordRecallReaction · GetRecallFeed · 순수함수(recall_occurrence·recall_guards)
│       ├── infrastructure/        HttpxAPNsClient(HTTP/2), PostgresPushTokenRepository · notification_plan/outbox ORM·repository · GeminiRecallPlanner(tool-loop)
│       └── presentation/          router.py(/devices/push-token) · recall_router.py(/recall/feed · /recall/events/{id} · /recall/events/{id}/reaction)
├── api.py                         /api/v1 라우터 조립
└── main.py                        FastAPI app factory + 미들웨어 + 예외 핸들러
```

### 의존성 방향 (Hexagonal)

```
presentation  ─►  application  ─►  domain
       ▲                    │            ▲
       │                    ▼            │
infrastructure  ──────►   ports  ──────┘
```

- `domain/` 은 외부 의존이 없다 (SQLAlchemy도 import 금지)
- `application/` 은 `domain/ports.py` 의 Protocol만 본다
- `infrastructure/` 가 outbound port의 실제 구현을 제공
- `presentation/` 은 use case를 호출하고 Pydantic API 스키마로 직렬화

### 모듈 간 규칙

- 다른 모듈의 `domain/`/`application/` 만 import 가능. `infrastructure/`/`presentation/` 은 모듈 외부에 노출하지 않는다.
- 단, `shared/` 는 모든 모듈이 자유롭게 사용 가능 (Intent, ID newtype 등 공통 어휘).

### Infrastructure 어댑터 규칙 — async-first

- 외부 I/O(LLM·HTTP·DB)는 **native async** 로 호출한다 — `httpx.AsyncClient`, SQLAlchemy async 엔진, google-genai `client.aio.*`. sync SDK 를 `asyncio.to_thread` 로 감싸 "스레드로 동시성 흉내" 내지 않는다 (이 서비스는 I/O-bound 라 코루틴 동시성이 본질).
- native async 가 **없는 sync-only SDK 만** 예외로 `to_thread` 허용(예: `google-cloud-storage` blob 서명 — `gcs_storage.py`). 단 `to_thread` 는 `wait_for` 타임아웃으로 **실제 취소되지 않으므로**(좀비 스레드), 타임아웃을 거는 경로엔 그 한계를 주석으로 남긴다.
- ruff `ASYNC`(flake8-async) 룰셋이 코루틴 내 일부 blocking 호출을 ②티어로 검출한다 — 규약은 린터가 못 잡는 "native async 우선" 판단만 담는다.

## 시작하기

### 사전 준비
```bash
brew install uv
docker --version    # docker compose 사용
```

### 설치 및 로컬 실행
```bash
make install
cp .env.example .env

make db-up          # docker compose로 Postgres + pgvector
make migrate        # alembic upgrade head
make dev            # uvicorn --reload --port 8000
```

OpenAPI: http://localhost:8000/docs

### 테스트·린트·타입 체크
```bash
make test
make lint
make format
make typecheck
make eval       # 분석 에이전트 golden eval (live Gemini, RUN_EVAL 가드). 결정적 채점기 단위테스트는 make test(tests/eval) 에 이미 포함
```

> **eval 안전망** (`eval/`): `scorer.py`(결정적 8축 채점) + `run_golden.py`(production drift-0 러너) + `golden/`(케이스) + `tests/eval/`(hermetic ② 게이트). `make eval CASES=eval/golden/<name>.json RUNS=3` 로 live 측정. golden 정본 버전은 `system_prompts.ACTIVE_PROMPT.eval_dataset_version`.

### Vertex AI 인증
```bash
gcloud auth application-default login
gcloud config set project <YOUR_PROJECT_ID>
```

## 핵심 설계 포인트

### Idempotency-Key
- 모든 POST `/api/v1/mochi_items` 는 `Idempotency-Key` 헤더 필수
- 키는 `mochi_item:{owner_id}:{raw_key}` 로 스코핑되어 다른 사용자의 동일 키와 충돌하지 않는다 (`PostgresMochiItemRepository._scope_idempotency_key`)
- 동일 `(owner, key)` 재요청 시 새 캡처 생성 없이 기존 capture를 반환 (`idempotency_keys` 테이블 + `Ingest.execute` 가 보장)
- 응답 본문의 `id` 는 **서버가 ingest 시 부여하는 자체 mochi_item PK** 다 (클라가 보낸 `Idempotency-Key` 와 별개 UUID). iOS 는 이 서버 id 로 이후 `GET /api/v1/mochi_items/{id}` 조회·폴링한다 — 로컬 id 로는 404.

### Ownership
- `MochiItemRepository` 의 모든 read/write 메서드는 `owner_id` 키워드 인자를 강제로 받는다 — cross-tenant 누설을 컴파일 시점에 막는다
- 인증은 `app/core/security.py` — `Bearer dev:<subject>` 토큰은 `environment == "local"` 에서만 허용되고, 그 외 환경에서는 `auth.dev_token_not_allowed_in_env` 로 명시 거부된다

### Auth Boundary (dev vs prod)
- **dev**: `Bearer dev:jun` 같은 토큰 → SHA-256 해시 기반 결정론적 `UserID` 생성, 로컬에서도 멀티-유저 시나리오 테스트 가능
- **prod**: 자체 발행 access JWT 검증 (HS256, `AUTH_ACCESS_SECRET`, TTL 30분) + 회전 refresh token. JWKS 는 Apple/Google **ID token 검증에만** 사용 (`/auth/{apple,google}`)
- dev 토큰은 `local` 외 환경에서는 거부되어 prod 누설을 차단
- **capture token** (`POST /auth/capture-tokens`, access JWT 필수): ShareExtension 직접 전송용 `mct_` opaque 토큰. DB 엔 SHA-256 hash 만(`capture_tokens`, 마이그레이션 0019), **ingest + presign 두 라우트에서만 유효**(`CurrentCaptureUser` — 다른 라우트에선 JWT 파싱 실패로 자동 401, 권한 상승 차단). sliding 180일(검증 시 연장, 1h 디바운스 UPDATE) + 사용자당 활성 5개 cap(oldest evict). logout 바디 `captureToken` 동봉 시 함께 revoke, refresh reuse 감지 시 사용자 전체 연쇄 revoke
- **`POST /auth/dev`**: Apple/Google 시트 없이 `subject` 만으로 정식 access/refresh JWT 를 발급하는 dogfooding 전용 엔드포인트. `environment != "local"` 이면 503 (`auth.dev_sign_in_disabled`). subject 가 같으면 `_derive_dev_user_id` 와 동일한 UUID 로 `users` 행 멱등 upsert (`auth_accounts` 는 건드리지 않아 provider CHECK 제약 회피). iOS 의 "임시 로그인 (dev)" 버튼이 사용.

### X-Mochi-Request-ID
- 클라이언트가 보낸 값이 있으면 echo, 없으면 생성 후 응답 헤더에 반환
- structlog `contextvars` 에 바인딩되어 모든 로그 라인에 자동 포함 (분산 추적 용이)

### Error Envelope (iOS `APIErrorEnvelope` 와 1:1)
```json
{ "code": "mochi_item.not_found", "message": "...", "requestId": "abc", "retryAfter": null }
```
- DomainException 계층(`NotFoundError`, `UnauthorizedError`, `RateLimitedError`, `FeatureUnavailableError` …)이 모두 동일 포맷으로 직렬화

### Agent State Graph
```
ingested → normalized → analyzed → routed → persisted → indexed → synced
                                                           ▼
                                                        failed
```
- `AgentOrchestrator.run(mochi_item_id)` 가 노드를 진전시키며 모든 `tool_calls` 의 input/output digest, tokens, latency 를 `agent_runs` / `tool_calls` 테이블에 기록
- iOS는 `/mochi_items/{id}/stream` SSE 로 노드 전환을 실시간 수신

### 워커 동시성 / DB 풀
- outbox 워커는 `WORKER_CONCURRENCY`(기본 2)개의 코루틴 → 동시 in-flight 분석 = N. Gemini 호출은 native async(`.aio`)라 스레드 없이 코루틴 동시성이며, `wait_for(step_timeout)` 가 타임아웃 시 Vertex 요청을 **실제 취소**한다 (to_thread 좀비 스레드 없음)
- `FOR UPDATE SKIP LOCKED` + item-level lock 으로 N 코루틴·N 인스턴스 모두 동시 안전 → prod 수평확장은 인스턴스 복제
- DB 풀은 `DB_POOL_SIZE`(기본 5) / `DB_MAX_OVERFLOW`(기본 10). 워커를 올리면 풀도 함께 상향 — `인스턴스수 × (pool_size + max_overflow) < Postgres max_connections`(기본 100), 초과 시 PgBouncer

### 능동 회수 알림 (트랙 A/B)
"놓치기 쉬운 순간은 쉽게 남기고, 필요한 기억은 쉽게 떠오른다" — 모찌가 먼저 떠올려준다. "생성 분리(plan) / 발송 통합(outbox)" 2테이블 구조 (정본 `journal/proactive-recall/`).
- **`notification_plan`** — 계획 1행. `plan_kind`(`deadline_backoff`/`recurring_nudge`/`spaced`) + JSONB `stages` DSL(relative/recurring/spaced trigger, `RecallPlanStages` Pydantic 검증 후 삽입). 같은 `source_intent_id` 에 active plan 1개(부분 UNIQUE). anchor(마감·일정일)는 심볼 참조 — 발송 시 `intent_instances.payload` 최신 조회(사용자 수정 자동 추종).
- **`notification_outbox`** — 발송+반응 큐. occurrence 를 lazy materialize, `sent`/`opened_at`/`dismissed_at`(recall_log 흡수).
- **플래너** (`PlanRecallNotifications`) — 메인 분석 후단 best-effort hook(독립세션·격리)이 결정적 eligibility 게이트(intent 종류·미래 date·importance)로 후보를 거른 뒤, Gemini tool-loop 플래너(`get_scheduled` 묶기 tool + 구조화 finalize, flash-lite)가 plan 1행 생성(같은 source_intent supersede).
- **cron 워커** (`NotificationWorker`, `app/main.py` lifespan 에 1 인스턴스) — active plan→occurrence 계산(relative/recurring/spaced, spaced 는 반응 기준 전진)→하드 가드(cap·야간무음·dismiss cooldown·트랙B 양보, per-owner advisory lock, KST)→outbox lazy materialize→APNs 발송. deferred(cap/야간/트랙B)는 `next_retry_at` 도달 시 재평가로 회생. intent archived→plan `cancelled(intent_archived)`. occurrence-math·가드는 순수함수 분리.
- **킬스위치 / dry-run** — `recall_worker_enabled=False` 면 워커 기동은 하되 루프 no-op. `recall_notifications_dry_run`(기본 **True**) 이면 실발송 없이 payload 로그만(발송 0 으로 threshold 튜닝). 실발송 전환은 `.env` 로 `recall_notifications_dry_run=false`.
- **반응 + spaced 소생** — `POST /recall/events/{id}/reaction`(opened/dismissed/stop, (event_id,owner_id)+status='sent' first-write-wins 멱등). opened+spaced+knowledge(decaying/reviewRequested)→active 소생(`lifecycle_policy` 재사용). stop→plan `cancelled(user_dismiss)`. 회수 화면 fetch 는 `GET /recall/feed`(홈 한 칸·자세히) + `GET /recall/events/{id}`(알림 landing fallback).

### Hybrid Search RAG
- `bm25_k=80`, `vector_k=80` 두 후보를 만들어 RRF (`k=60`) 융합
- recall@50 가 90% 이상 측정될 때만 cross-encoder reranker 활성화 (settings.toggleable)
- 임베딩 voyage-4-large@1024 (input=summary+labels, doc/query input_type 비대칭), `HNSW (m=16, ef_construction=64) cosine`. `VOYAGE_API_KEY` 미설정 시 vector·rerank 만 비활성(BM25 degrade). 기존 데이터 재색인: `scripts/backfill_embeddings.py`

### WebFetch SSRF 가드
- 정책·페치는 `tools/safe_fetch.py` 단일 지점 — `WebFetchTool`·`PlatformContextTool` 공유(fix-drift 방지).
- 호스트 블록리스트 + 호스트 리터럴 IP + **모든 A/AAAA 응답** 의 사설/링크로컬/루프백/메타데이터/multicast/reserved IP 차단. IPv4-mapped IPv6(`::ffff:a.b.c.d`)는 내부 IPv4 로 unwrap 후 판정(인코딩 우회 차단).
- **연결-핀(TOCTOU 차단)**: `guarded_get` 이 호스트를 한 번 resolve·검증한 뒤 **검증한 IP 로 직접 연결**하고, 원본 host 를 SNI(`extensions['sni_hostname']`)·Host 헤더로 보존해 인증서 검증·가상호스팅을 유지한다. 검증 IP 와 연결 IP 가 동일해 권한 DNS 통제 공격자의 연결-시점 rebinding 을 차단. 매 redirect hop 도 재핀.
- MIME 화이트리스트 (`text/html`, `text/plain`, `application/json`, `application/xhtml+xml`)
- **스트리밍 byte counter** — `web_fetch_max_bytes` 초과 시 즉시 abort (전체 다운로드 후 길이 체크 아님)
- redirect 최대 5회

### PlatformContext
- Agent loop 는 YouTube/X/Instagram URL 에 대해 `webFetch` 보다 먼저 `platformContext` 를 호출한다.
- YouTube: oEmbed 제목/채널 + watch page 의 `ytInitialPlayerResponse` 설명/길이를 결합한다.
- X/Twitter: `publish.x.com/oembed` 로 post text/author embed HTML 을 구조화한다.
- Instagram: `INSTAGRAM_OEMBED_ACCESS_TOKEN` 이 있으면 Meta Instagram oEmbed, 없으면 OG meta fallback. Instagram은 이미지 맥락 의존도가 높아 screenshot Vision 결과를 primary context 로 두고 platform metadata 는 보조 신호로 쓴다.

### Screenshot grounding
- Agent 입력에는 항상 `Asia/Seoul` 현재 기준시각이 포함된다. `다음 주`, `금요일`, `5일 남음` 같은 상대 시간은 이 컨텍스트로 해석한다.
- 이미지가 붙은 항목은 extraction-strategy C 기준을 따른다: 내부적으로 `fact` / `opinion` / `info` typed statement 로 근거를 세운 뒤 final summary/entities 를 만든다. `facts/opinions/key_info/entities` 버킷을 모두 채우도록 강제하지 않는다.

### 4-Intent 생명주기 검증
- `app/modules/intents/domain/lifecycle_policy.is_allowed` 는 (current.kind → next.kind) 페어 + Intent별 archive reason 두 가지를 모두 검증
- 예: `schedule` 캡처는 `archived(scheduleEnded|userManual)` 만 허용. `archived(todoCompleted)` 는 거부
- iOS `CoreDomain.LifecyclePolicy.validate(...)` 가 동일한 invariant를 유지 — 클라이언트도 같은 정책으로 사전 검증

### Module Boundary 강제
- `tests/unit/test_module_boundaries.py` 가 두 가지 invariant를 코드로 검사
  1. 어떤 모듈도 다른 모듈의 `infrastructure/` · `presentation/` 내부를 직접 import할 수 없다 (`domain/` · `application/` · `app.shared` · `app.core` 만 허용)
  2. 모든 `domain/` 레이어는 sqlalchemy · fastapi · httpx · google · pgvector 등 프레임워크 패키지를 import할 수 없다

## API 개요

전체 엔드포인트·요청/응답 스키마의 단일 원천은 **`openapi.json`** 이다 (`make openapi` 생성물, 서버 구동 시 `GET /docs` Swagger UI). iOS 배선 예외(서버만 실재·라우트 미존재 등)는 [`docs/DOMAIN_DESIGN.md`](../docs/DOMAIN_DESIGN.md) §6.4 를 본다.

대분류: `auth/*`(Apple·Google·dev·refresh·logout) · `users/me` · `mochi_items`(ingest(+confirmedInstances §5.2 예외) · PATCH 콘텐츠+instance · presign · 조회 · list · calendar · todos/upcoming · instance lifecycle 완료/완료취소 · reanalyze · SSE stream) · `search`(Hybrid RAG) · `conversations`(채팅 — 메시지 전송 POST-as-SSE·세션 목록·메시지 스냅샷·삭제·proposal 카드 상태 PATCH) · `recall`(능동 회수 — feed·landing fallback·reaction) · `devices`(push 토큰) · `health`. 모든 보호 라우트는 `Authorization: Bearer`, `POST /mochi_items` 는 `Idempotency-Key` 필수. (2026-06-04 단일 ingest — back-tap·intent override 라우트 폐기)
