.PHONY: install dev test eval lint typecheck format migrate revision db-up db-down clean openapi usage-report

UV ?= uv

install:
	$(UV) sync

dev:
	# 0.0.0.0 바인딩 — 같은 Wi-Fi 의 실기기(iOS)에서 Mac 의 LAN IP 로 접근 가능해야 한다.
	# 127.0.0.1 로 두면 시뮬레이터만 동작하고 실기기 dogfooding 시 connection refused.
	$(UV) run uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

test:
	$(UV) run pytest -q

# 분석 에이전트 골든 eval (live Gemini, RUN_EVAL 가드). GOOGLE_CLOUD_PROJECT 필요. CASES/RUNS 오버라이드 가능.
# 결정적 채점기 단위 테스트는 `make test`(tests/eval) 에 이미 포함된다 — 이건 live 측정용.
eval:
	RUN_EVAL=1 PYTHONPATH=. $(UV) run python eval/run_golden.py --cases $(or $(CASES),eval/golden/text_classification.json) --runs $(or $(RUNS),3)

lint:
	$(UV) run ruff check .

format:
	$(UV) run ruff format .

typecheck:
	# `mochi-backend` 디렉토리 자체는 PyPI 패키지명이 아니므로 mypy에는 explicit packages 옵션이 필요.
	$(UV) run mypy --explicit-package-bases app

# LLM 토큰/비용 사용량 리포트. BY=day|user|item (기본 day).
usage-report:
	PYTHONPATH=. $(UV) run python scripts/llm_usage_report.py --by $(or $(BY),day)

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

# OpenAPI 스펙을 정적 JSON으로 추출하고 iOS CoreNetworking 으로 동기화.
# openapi.json = 단일 계약. 백엔드 코드가 source, 이 JSON 이 생성물.
# 동기화 후 iOS 클라이언트 재생성: mochi-ios/CodeGen/generate.sh
openapi:
	PYTHONPATH=. $(UV) run python scripts/export_openapi.py > openapi.json
	@echo "openapi.json updated ($(shell wc -c < openapi.json) bytes)"
	cp openapi.json ../mochi-ios/Targets/Cores/CoreNetworking/openapi.json
	@echo "→ synced to iOS CoreNetworking/openapi.json (재생성: mochi-ios/CodeGen/generate.sh)"
