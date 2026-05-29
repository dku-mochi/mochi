.PHONY: install dev test lint typecheck format migrate revision db-up db-down clean openapi

UV ?= uv

install:
	$(UV) sync

dev:
	# 0.0.0.0 바인딩 — 같은 Wi-Fi 의 실기기(iOS)에서 Mac 의 LAN IP 로 접근 가능해야 한다.
	# 127.0.0.1 로 두면 시뮬레이터만 동작하고 실기기 dogfooding 시 connection refused.
	$(UV) run uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

test:
	$(UV) run pytest -q

lint:
	$(UV) run ruff check .

format:
	$(UV) run ruff format .

typecheck:
	# `mochi-backend` 디렉토리 자체는 PyPI 패키지명이 아니므로 mypy에는 explicit packages 옵션이 필요.
	$(UV) run mypy --explicit-package-bases app

db-up:
	docker compose up -d db

db-down:
	docker compose down

migrate:
	$(UV) run alembic upgrade head

revision:
	$(UV) run alembic revision --autogenerate -m "$(M)"

clean:
	rm -rf .pytest_cache .ruff_cache .mypy_cache
	find . -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

# iOS의 swift-openapi-generator가 빌드 타임에 읽을 수 있도록 OpenAPI 스펙을 정적 JSON으로 추출.
openapi:
	PYTHONPATH=. $(UV) run python scripts/export_openapi.py > openapi.json
	@echo "openapi.json updated ($(shell wc -c < openapi.json) bytes)"
