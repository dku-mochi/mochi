from httpx import ASGITransport, AsyncClient

from app.main import app


async def test_health_returns_ok() -> None:
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/api/v1/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


async def test_unknown_route_returns_error_envelope() -> None:
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/api/v1/captures/00000000-0000-0000-0000-000000000000")
    # 인증 미들웨어 또는 404가 ErrorEnvelope 포맷으로 떨어져야 한다 (도메인/HTTP exception handler).
    body = response.json()
    assert "code" in body and "requestId" in body
