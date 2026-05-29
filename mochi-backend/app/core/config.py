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
    gemini_embedding_model: str = "text-embedding-005"
    embedding_dim: int = 768

    # 백탭 캡쳐 의도 분류 — `_workspace/2026-05-25-intent-classification-bench.md`
    # v6 spec. flash-lite + global location 이 p50 ~2.8s / ~85KB 최적 조합.
    gemini_intent_model: str = "gemini-3.1-flash-lite"
    gemini_intent_location: str = "global"

    # Agent loop
    agent_max_steps: int = 8
    agent_step_timeout_seconds: float = 30.0
    agent_total_timeout_seconds: float = 120.0

    # Agent loop LLM (function-calling 분석) — 비용 최우선: 백탭 분류와 동일 flash-lite/global.
    # 함수호출 신뢰도가 부족하면 .env 로 gemini-3.1-flash 등으로 상향 가능.
    gemini_agent_model: str = "gemini-3.1-flash-lite"
    gemini_agent_location: str = "global"

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

    # PlatformContext tool — Instagram 공식 oEmbed 는 Meta app token + review 가 필요하다.
    instagram_oembed_access_token: str | None = None
    instagram_oembed_api_version: str = "v20.0"

    # Hybrid search
    bm25_k: int = 80
    vector_k: int = 80
    rrf_k_constant: int = 60
    reranker_enabled: bool = False
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

    # External IdP — Apple
    auth_apple_audience: str = "com.IndexFinger.mochi"
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

    @property
    def auth_google_client_id_list(self) -> tuple[str, ...]:
        return tuple(s.strip() for s in self.auth_google_client_ids.split(",") if s.strip())


@lru_cache
def get_settings() -> Settings:
    return Settings()
