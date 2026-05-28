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
