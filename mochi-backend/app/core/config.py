from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """애플리케이션 환경 설정. `.env` → OS env 순으로 로드."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # App
    app_name: str = "mochi-backend"
    environment: str = Field(default="local")
    debug: bool = Field(default=True)
    api_version: str = "v1"

    # Database — Postgres + pgvector
    database_url: str = Field(
        default="postgresql+asyncpg://mochi:mochi@localhost:5432/mochi"
    )
    # 커넥션 풀 — SQLAlchemy 기본(5+10)과 동일값. worker_concurrency 를 올리면
    # 같이 상향한다(인스턴스수 × (pool_size+max_overflow) < Postgres max_connections).
    db_pool_size: int = 5
    db_max_overflow: int = 10

    # Vertex AI / Gemini
    google_cloud_project: str | None = None
    google_cloud_location: str = "us-central1"

    # 캡처 이미지 스토리지 — GCS (백탭 스크린샷 원본).
    # 클라이언트가 Signed PUT URL 로 GCS 에 직접 업로드 → 서버는 bytes 무접촉.
    # Gemini 가 gs://{bucket}/{object_key} 로 직접 읽으므로 다운로드 경로도 없다.
    # bucket / signer 미설정 시 presign 비활성(503) — local 환경 fallback.
    gcs_capture_bucket: str | None = None
    gcs_capture_prefix: str = "captures"
    gcs_signer_service_account: str | None = None   # Signed URL 서명용 impersonate 대상 SA email
    gcs_signed_url_ttl_seconds: int = 900            # 15분
    gemini_model: str = "gemini-3.5-flash"

    # Embedding / Rerank — Voyage AI (lab/active/rag-rerank-eval 2026-06-12 확정).
    # voyage-3-large@1024 + rerank-2.5: vector 단독 대비 R@1 0.15→0.43, MRR 0.56→0.88.
    # 키 미설정 시 vector·rerank 경로만 비활성(BM25/키워드 검색으로 degrade) — 서버는 정상 기동.
    voyage_api_key: str | None = None
    voyage_embedding_model: str = "voyage-3-large"
    voyage_embedding_dim: int = 1024
    voyage_rerank_model: str = "rerank-2.5"

    # 백탭 캡쳐 의도 분류 — `_workspace/2026-05-25-intent-classification-bench.md`
    # v6 spec. flash-lite + global location 이 p50 ~2.8s / ~85KB 최적 조합.
    gemini_intent_model: str = "gemini-3.1-flash-lite"
    gemini_intent_location: str = "global"

    # Agent loop
    agent_max_steps: int = 8
    agent_step_timeout_seconds: float = 30.0
    agent_total_timeout_seconds: float = 120.0
    # outbox 워커 코루틴 수 = 동시 in-flight 분석 건수. FOR UPDATE SKIP LOCKED 로
    # N 코루틴(또는 N 인스턴스) 동시 안전. 올릴수록 Vertex 동시 요청도 늘어 쿼터에 유의.
    worker_concurrency: int = 2

    # Agent loop LLM (function-calling 분석) — 비용 최우선: 백탭 분류와 동일 flash-lite/global.
    # 함수호출 신뢰도가 부족하면 .env 로 gemini-3.1-flash 등으로 상향 가능.
    gemini_agent_model: str = "gemini-3.1-flash-lite"
    gemini_agent_location: str = "global"

    # 채팅 탭 멀티턴 run (journal 2026-06-10). 비용 최우선 flash-lite 기본 —
    # 멀티스텝 툴콜 신뢰도가 부족하면 lab 벤치 후 .env 로 상향 (코드 수정 없이 교체).
    gemini_chat_model: str = "gemini-3.1-flash-lite"
    chat_run_timeout_seconds: float = 60.0   # SSE 로 기다리는 사용자 기준 — run 전체 상한

    # 사용자 개인화 프로필 (sliding-window 특성 요약)
    profile_window_size: int = 20              # 요약에 넣을 최근 항목 수
    profile_refresh_every_n_items: int = 5     # 마지막 갱신 이후 N개 쌓이면 재요약 (비용 bound)

    # WebFetch tool guards
    web_fetch_max_bytes: int = 2 * 1024 * 1024
    web_fetch_timeout_seconds: float = 8.0
    web_fetch_blocked_hosts: tuple[str, ...] = (
        "localhost",
        "127.0.0.1",
        "169.254.169.254",   # AWS / GCP metadata endpoint
        "metadata.google.internal",
        "0.0.0.0",
    )

    # 채팅 web_search — Tavily (journal 2026-06-10 PR-4). 미설정 시 web_search 툴만
    # 레지스트리에서 제외되고 서버는 정상 기동한다 (키 발급이 머지를 블록하지 않게).
    # ResourceFinder tool 의 web(해외/일반) 폴백 검색도 같은 키를 쓴다.
    tavily_api_key: str | None = None

    # ResourceFinder tool — 네이버 검색 API(shop/local/blog/news 단일 백본, lab exp4~7).
    # 미설정 시 findReferenceUrls 툴만 레지스트리에서 제외되고 서버는 정상 기동한다.
    naver_client_id: str | None = None
    naver_client_secret: str | None = None

    # recoverYoutubeUrl tool — YouTube Data API v3 (Secret: mochi-youtube-api-key).
    # 무키 youtube 검색의 confidence 가 낮을 때(인덱스 지연·봇차단) 폴백: 채널 식별→uploads
    # playlist 직접 조회(인덱스 무관)→search.list. 미설정 시 무키 검색만 동작(폴백·채널주소 비활성).
    youtube_api_key: str | None = None

    # PlatformContext tool — Instagram 공식 oEmbed 는 Meta app token + review 가 필요하다.
    instagram_oembed_access_token: str | None = None
    instagram_oembed_api_version: str = "v20.0"

    # Hybrid search — BM25+Vector→RRF→rerank-2.5. reranker 는 voyage 키가 있을 때만
    # wire 되므로 enabled 기본 True 가 안전하다 (키 없으면 RRF 순서 그대로).
    bm25_k: int = 80
    vector_k: int = 80
    rrf_k_constant: int = 60
    reranker_enabled: bool = True
    reranker_top_n: int = 30

    # Security / auth — 자체 발행 access JWT
    auth_jwt_audience: str = "mochi.app"
    auth_jwt_issuer: str = "mochi.app"
    auth_access_secret: str = Field(
        default="dev-insecure-please-rotate-in-prod-with-openssl-rand-base64-48",
        description="HS256 서명 키. 운영에서는 반드시 .env 로 32+ chars random 으로 회전.",
    )
    auth_access_ttl_seconds: int = 1800             # 30분
    auth_refresh_ttl_seconds: int = 60 * 60 * 24 * 30  # 30일

    # Capture-scoped token — ShareExtension 직접 전송 전용 (ingest+presign 한정 opaque token).
    # sliding: 검증 시 last_used 기준으로 연장(1h 디바운스) — 캡처를 쓰는 한 만료되지 않는다.
    auth_capture_ttl_seconds: int = 60 * 60 * 24 * 180  # 180일 (sliding)
    auth_capture_max_active: int = 5                    # 사용자당 동시 활성 cap (초과 시 oldest evict)

    # External IdP — Apple
    auth_apple_audience: str = "app.mochi"
    auth_apple_jwks_url: str = "https://appleid.apple.com/auth/keys"
    auth_apple_issuer: str = "https://appleid.apple.com"

    # External IdP — Google. 콤마로 여러 client_id 허용 (iOS + web).
    auth_google_client_ids: str = ""
    auth_google_jwks_url: str = "https://www.googleapis.com/oauth2/v3/certs"
    auth_google_issuers: tuple[str, ...] = (
        "accounts.google.com",
        "https://accounts.google.com",
    )

    # (레거시 / 외부 IdP) JWKS — 미사용. 호환을 위해 옵션 유지.
    auth_jwks_url: str | None = None

    # APNs — Apple Push (PR-B). team_id/key_id/bundle_id 는 공개 식별자, p8 내용만 비밀.
    # p8 는 multiline PEM 이라 base64 로 주입(.env 에서 \n literal 미해석 회피) — get_apns_client 가 decode.
    # apns_auth_key_p8_base64 미설정 시 push no-op(local dev). sandbox/production 환경은 토큰별로
    # device_push_tokens.environment 에 기록(클라가 등록 시 지정) — 서버 단일 환경 설정 없음.
    apns_team_id: str = "U9SLX327XS"
    apns_key_id: str = "CA6C3JCHW3"
    apns_bundle_id: str = "app.mochi"
    apns_auth_key_p8_base64: str | None = None

    # 능동 회수 알림 cron 워커 (P3/P4). 정본 journal/proactive-recall/.
    # killswitch False 면 워커 기동은 하되 루프가 no-op(§7). dry_run True 면 실발송 없이 payload 로그만
    # (발송 0 으로 threshold 튜닝, §6/§7) — 실발송 전환은 .env 로 recall_notifications_dry_run=false.
    recall_worker_enabled: bool = True
    recall_notifications_dry_run: bool = True
    recall_worker_poll_interval_seconds: int = 30
    recall_worker_lock_seconds: int = 120
    recall_daily_cap: int = 3                 # owner 하루 발송 cap (KST local date)
    recall_quiet_start_hour_kst: int = 21     # 야간 무음 시작 (KST)
    recall_quiet_end_hour_kst: int = 8        # 야간 무음 종료 (KST)
    recall_dismiss_cooldown_days: int = 7     # dismiss 후 같은 intent 재알림 쿨다운 (plan 경계 넘음)
    # 트랙 C(관련/맥락 회수) — 새 저장 시 임베딩 ANN 후보 생성·발송 게이트(P7~P9).
    recall_candidate_min_score: float = 0.6   # cosine 유사도 임계 (미만이면 회수 안 함, dry-run 튜닝)
    recall_candidate_limit: int = 10          # ANN 후보 조회 상한 (best 1건이 회수 앵커)
    recall_dedup_cooldown_days: int = 7       # 같은 item 재회수 방지 윈도우 (재스팸 dedup)
    recall_expires_days: int = 14             # 회수 outbox expires (지나면 stale skip)
    # 트랙 C LLM 선별 게이트 (2026-06-17, journal/proactive-recall/track-c-llm-gate-decision.md).
    recall_gate_enabled: bool = True          # False 면 LLM 건너뛰고 결정적 best-1 경로(롤백 안전판)
    recall_gate_dry_run: bool = True          # True 면 LLM 결정 로그만, outbox 미적재(발송측 dry_run 과 별개)
    recall_overfetch_limit: int = 40          # ANN overfetch 상한(필터 전)
    recall_gate_topn: int = 10                # 필터 후 LLM 에 넘길 후보 상한
    recall_near_dup_score: float = 0.92       # 근중복(재저장) 컷 — 이상이면 앵커 후보 제외
    recall_owner_cooldown_hours: int = 6      # owner 회수 최소 간격(트리거 디바운스, 결정적 백스톱)

    @property
    def auth_google_client_id_list(self) -> tuple[str, ...]:
        return tuple(s.strip() for s in self.auth_google_client_ids.split(",") if s.strip())


@lru_cache
def get_settings() -> Settings:
    return Settings()
