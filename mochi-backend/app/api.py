from fastapi import APIRouter, status

from app.modules.agent.presentation.router import router as agent_router
from app.modules.auth.presentation.router import auth_router, users_router
from app.modules.mochi_items.presentation.router import router as mochi_items_router
from app.modules.search.presentation.router import router as search_router


def build_v1_router() -> APIRouter:
    router = APIRouter(prefix="/api/v1")

    @router.get("/health", tags=["health"], status_code=status.HTTP_200_OK)
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    router.include_router(auth_router)
    router.include_router(users_router)
    router.include_router(mochi_items_router)
    router.include_router(agent_router)
    router.include_router(search_router)
    return router
