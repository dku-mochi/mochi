---
level: 2
mode: reference
status: active
last_verified: 2026-05-29
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
| AI | Vertex AI · Gemini 3.5 Flash (multimodal function calling, streaming) · text-embedding-005 |
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
│   ├── security.py                JWT 의존성 (CurrentUser)
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
│   └── search/
│       ├── domain/                SearchQuery, Citation, RetrievalIndex/Reranker/AnswerSynthesizer ports
│       ├── application/           HybridSearch use case (BM25 + 벡터 → RRF → reranker → synthesizer)
│       ├── infrastructure/        PostgresHybridIndex, rrf
│       └── presentation/router.py
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
```

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
- **prod**: JWKS 기반 JWT 검증 (TODO 명시) — 미설정 시 `auth.jwt_not_configured` 로 즉시 503
- dev 토큰은 `local` 외 환경에서는 거부되어 prod 누설을 차단
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

### Hybrid Search RAG
- `bm25_k=80`, `vector_k=80` 두 후보를 만들어 RRF (`k=60`) 융합
- recall@50 가 90% 이상 측정될 때만 cross-encoder reranker 활성화 (settings.toggleable)
- 임베딩 차원 768, `HNSW (m=16, ef_construction=64) cosine`

### WebFetch SSRF 가드
- 호스트 블록리스트 + 사설/링크로컬/루프백/메타데이터/multicast/reserved IP 차단
- **매 redirect hop 마다 호스트 정책 재검증** — DNS rebinding 우회 방지
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

| Method | Path | 인증 | 설명 |
| --- | --- | --- | --- |
| GET | `/api/v1/health` | 불필요 | 헬스체크 |
| POST | `/api/v1/mochi_items` | Bearer | 캡처 ingestion (Idempotency-Key 필수) |
| POST | `/api/v1/mochi_items/presign` | Bearer | GCS Signed PUT URL 발급 |
| POST | `/api/v1/mochi_items/back-tap` | Bearer | 백탭 캡처 JSON ingest |
| GET | `/api/v1/mochi_items/{id}` | Bearer | 캡처 조회 |
| GET | `/api/v1/mochi_items/{id}/stream` | Bearer | Agent state graph SSE 스트림 |
| POST | `/api/v1/search` | Bearer | Hybrid search RAG |
