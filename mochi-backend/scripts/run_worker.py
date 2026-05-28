"""Capture outbox 워커 진입점.

사용법:
    uv run python scripts/run_worker.py
    또는
    PYTHONPATH=. uv run python scripts/run_worker.py
"""

import asyncio
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[1]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from app.core.config import get_settings  # noqa: E402
from app.core.logging import configure_logging  # noqa: E402
from app.modules.agent.application.capture_worker import CaptureWorker  # noqa: E402


async def main() -> None:
    configure_logging()
    settings = get_settings()
    worker = CaptureWorker(max_steps=settings.agent_max_steps)
    await worker.run_forever()


if __name__ == "__main__":
    asyncio.run(main())
