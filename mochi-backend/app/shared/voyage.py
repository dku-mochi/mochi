"""Voyage AI 어댑터 — 임베딩(voyage-3-large) + 리랭크(rerank-2.5).

모델·차원·입력 구성은 ``lab/active/rag-rerank-eval``(2026-06-12) 확정값:

- 임베딩: ``voyage-3-large`` @ 1024, 문서는 ``input_type=document`` / 쿼리는 ``query``
- 임베딩 input: summary + intent labels (``build_embedding_text``)
- 리랭커: ``rerank-2.5`` — vector 단독 대비 R@1 0.15→0.43, MRR 0.56→0.88.
  lite 는 어려운 케이스에서 정답을 놓쳐 비채택.

설계:
- 의존은 httpx 뿐 (voyageai SDK 는 lab 전용 — 메인 의존성에 올리지 않는다)
- 일시 오류(타임아웃·연결·429·5xx)는 지수 백오프 재시도 — 경로별 예산이 다르다:
  인터랙티브(쿼리 임베딩·리랭크)는 사용자가 기다리므로 2회/5s, 배치(문서 임베딩 —
  INDEXED·backfill)는 3회/10s (리뷰 P2: retry 정책 경로 무차별 → 장애 시 1분짜리 검색)
- **모든 실패는 ``VoyageError`` 로만 나간다** (transport·비정상 JSON 포함, 리뷰 P1) —
  검색·채팅·색인 호출부가 ``except VoyageError`` 하나로 키워드 검색 degrade /
  backfill 재색인으로 흡수한다
"""

import asyncio
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from typing import Any

import httpx

from app.core.logging import get_logger

log = get_logger("voyage")

#: 키 접두로 발급처를 판별한다 — MongoDB Atlas 발급 키(``al-``)는 Voyage 본가 엔드포인트를
#: 거부(403)하고 자체 게이트웨이만 받는다 (voyageai SDK 의 get_default_base_url 과 동일 로직).
_VOYAGE_BASE_URL = "https://api.voyageai.com/v1"
_MONGODB_BASE_URL = "https://ai.mongodb.com/v1"
_EMBED_BATCH_MAX = 128          # Voyage embeddings API 의 요청당 입력 상한
_RETRYABLE_STATUS = frozenset({429, 500, 502, 503, 504})

#: 경로별 재시도·타임아웃 예산. 인터랙티브 경로(쿼리 임베딩·리랭크)는 사용자가 기다린다 —
#: 최악 지연 = attempts × timeout + backoff. 배치(문서 임베딩)는 워커/스크립트라 여유.
_INTERACTIVE_ATTEMPTS = 2
_INTERACTIVE_TIMEOUT_SECONDS = 5.0
_BATCH_ATTEMPTS = 3
_BACKOFF_BASE_SECONDS = 0.5
_BACKOFF_MAX_SECONDS = 4.0


class VoyageError(RuntimeError):
    """Voyage API 호출 실패 (재시도 소진 포함). 이 클라이언트의 유일한 외부 예외."""


class _RetryableVoyageError(VoyageError):
    """재시도 대상(429/5xx) — ``_post`` 재시도 루프 내부에서만 쓰인다."""


def build_embedding_text(summary: str | None, labels: Iterable[str | None]) -> str:
    """임베딩·리랭크 문서 텍스트 — summary + intent labels (rag-rerank-eval 고정 조건).

    ingestion(INDEXED)·backfill 이 같은 함수를 쓴다 — 색인 시점이 달라도 문서 표현이
    갈라지면 안 된다. 빈 값은 빈 문자열을 반환하고 호출자가 색인을 건너뛴다.
    """
    parts = [summary or "", *(label or "" for label in labels)]
    return " ".join(part for part in parts if part).strip()


@dataclass(frozen=True, slots=True)
class RerankedDocument:
    """리랭크 결과 1건 — ``index`` 는 입력 documents 리스트 기준 위치."""

    index: int
    relevance_score: float


class VoyageClient:
    """Voyage embeddings / rerank HTTP 클라이언트.

    ``transport`` 는 테스트 주입용 (httpx.MockTransport). 호출마다 AsyncClient 를
    새로 여는 것은 의도 — 프로세스 수명 동안 이벤트 루프가 바뀌는 환경(테스트·워커)에서
    커넥션 풀 수명 문제를 피한다. 호출량이 사용자 액션 단위라 풀링 이득이 작다.
    """

    def __init__(
        self,
        api_key: str,
        *,
        embedding_model: str = "voyage-3-large",
        embedding_dim: int = 1024,
        rerank_model: str = "rerank-2.5",
        timeout_seconds: float = 10.0,
        transport: httpx.AsyncBaseTransport | None = None,
        base_url: str | None = None,
    ) -> None:
        self._api_key = api_key
        self._embedding_model = embedding_model
        self._embedding_dim = embedding_dim
        self._rerank_model = rerank_model
        self._timeout_seconds = timeout_seconds
        self._transport = transport
        self._base_url = base_url or (
            _MONGODB_BASE_URL if api_key.startswith("al-") else _VOYAGE_BASE_URL
        )

    @property
    def model_version(self) -> str:
        """embeddings.model_version 에 기록되는 식별자 — 모델·차원 변경 시 재색인 판별 키."""
        return f"{self._embedding_model}@{self._embedding_dim}"

    async def embed_documents(self, texts: Sequence[str]) -> list[list[float]]:
        """문서 임베딩 (``input_type=document``, 배치 예산). 배치 상한을 넘으면 나눠 보낸다."""
        return await self._embed(
            texts,
            input_type="document",
            attempts=_BATCH_ATTEMPTS,
            timeout_seconds=self._timeout_seconds,
        )

    async def embed_query(self, text: str) -> list[float]:
        """쿼리 임베딩 (``input_type=query``, 인터랙티브 예산) — doc/query 비대칭 인코딩이 확정 조건."""
        vectors = await self._embed(
            [text],
            input_type="query",
            attempts=_INTERACTIVE_ATTEMPTS,
            timeout_seconds=_INTERACTIVE_TIMEOUT_SECONDS,
        )
        return vectors[0]

    async def rerank(
        self, *, query: str, documents: Sequence[str], top_k: int
    ) -> list[RerankedDocument]:
        """관련도순 상위 ``top_k`` — 입력 인덱스를 보존해 호출자가 원본과 재결합한다."""
        if not documents:
            return []
        body = await self._post(
            "/rerank",
            {
                "query": query,
                # 빈 문서는 API 가 거부한다 — 후보 탈락 대신 공백 1자로 순위만 보존.
                "documents": [doc or " " for doc in documents],
                "model": self._rerank_model,
                "top_k": min(top_k, len(documents)),
            },
            attempts=_INTERACTIVE_ATTEMPTS,
            timeout_seconds=_INTERACTIVE_TIMEOUT_SECONDS,
        )
        try:
            return [
                RerankedDocument(index=int(r["index"]), relevance_score=float(r["relevance_score"]))
                for r in body["data"]
            ]
        except (KeyError, TypeError, ValueError) as exc:
            raise VoyageError(f"unexpected rerank response shape: {type(exc).__name__}") from exc

    async def _embed(
        self, texts: Sequence[str], *, input_type: str, attempts: int, timeout_seconds: float
    ) -> list[list[float]]:
        if not texts:
            return []
        out: list[list[float]] = []
        for start in range(0, len(texts), _EMBED_BATCH_MAX):
            chunk = list(texts[start : start + _EMBED_BATCH_MAX])
            body = await self._post(
                "/embeddings",
                {
                    "input": chunk,
                    "model": self._embedding_model,
                    "input_type": input_type,
                    "output_dimension": self._embedding_dim,
                },
                attempts=attempts,
                timeout_seconds=timeout_seconds,
            )
            try:
                vectors = [list(map(float, item["embedding"])) for item in body["data"]]
            except (KeyError, TypeError, ValueError) as exc:
                raise VoyageError(f"unexpected embeddings response shape: {type(exc).__name__}") from exc
            for vector in vectors:
                if len(vector) != self._embedding_dim:
                    raise VoyageError(
                        f"embedding dimension mismatch: got {len(vector)}, expected {self._embedding_dim}"
                    )
            out.extend(vectors)
        if len(out) != len(texts):
            raise VoyageError(f"embedding count mismatch: got {len(out)}, expected {len(texts)}")
        return out

    async def _post(
        self, path: str, payload: dict[str, Any], *, attempts: int, timeout_seconds: float
    ) -> dict[str, Any]:
        """일시 오류(transport·429/5xx)는 지수 백오프 재시도, 소진 시 ``VoyageError`` 로 래핑.

        transport 예외를 원형으로 흘리면 호출부의 ``except VoyageError`` degrade 가 뚫려
        검색 500/채팅 턴 실패로 직행한다 (리뷰 P1) — 이 메서드 밖으로는 VoyageError 만 나간다.
        """
        last_exc: Exception | None = None
        for attempt in range(1, attempts + 1):
            try:
                return await self._post_once(path, payload, timeout_seconds=timeout_seconds)
            except (httpx.TransportError, _RetryableVoyageError) as exc:
                last_exc = exc
                if attempt < attempts:
                    await asyncio.sleep(
                        min(_BACKOFF_BASE_SECONDS * 2 ** (attempt - 1), _BACKOFF_MAX_SECONDS)
                    )
        # 키·페이로드를 메시지에 싣지 않는다 — 예외 타입만으로 재시도/우회 판단에 충분.
        raise VoyageError(
            f"voyage {path} failed after {attempts} attempts: {type(last_exc).__name__}"
        ) from last_exc

    async def _post_once(
        self, path: str, payload: dict[str, Any], *, timeout_seconds: float
    ) -> dict[str, Any]:
        async with httpx.AsyncClient(timeout=timeout_seconds, transport=self._transport) as client:
            response = await client.post(
                f"{self._base_url}{path}",
                json=payload,
                headers={"Authorization": f"Bearer {self._api_key}"},
            )
        if response.status_code in _RETRYABLE_STATUS:
            raise _RetryableVoyageError(f"voyage {path} transient failure: HTTP {response.status_code}")
        if response.status_code != 200:
            raise VoyageError(f"voyage {path} failed: HTTP {response.status_code}")
        try:
            data: dict[str, Any] = response.json()
        except ValueError as exc:  # HTTP 200 + 비정상 JSON 도 VoyageError 로 (리뷰 P2)
            raise VoyageError(f"voyage {path} returned malformed JSON") from exc
        return data
