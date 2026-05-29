---
level: 3
mode: log
status: active
last_verified: 2026-05-29
confidence: 0.9
owners: [송준서]
description: capture → mochi_item 대규모 rename 작업 로그 + handoff. 다음 세션이 이어받으려면 이 파일부터 + /Users/jun/.claude/plans/modular-floating-reddy.md 를 같이 본다. rename 진행 중 같은 식별자 추가 신규작업 금지.
---

# capture → mochi_item rename 작업 로그

## 0. TL;DR

- 의미 분리: `capture` = 이미지 캡처 **행위**, `mochi_item` = URL+이미지+링크 통합 **도메인 객체**.
- 승인된 플랜: `/Users/jun/.claude/plans/modular-floating-reddy.md` §1 + architect 정밀 플랜 (대안 B 5묶음).
- 실행 형태: **B1~B5 묶음 commit**. 각 묶음이 독립 commit + 검증 게이트.
- 시작 시점 dirty tree: 6파일 (`.claude/hooks/pre-bash.sh`, `session-start.sh`, `ship-precheck.sh`, `CLAUDE.md`, `docs/CHANGELOG.md`, `docs/DOMAIN_DESIGN.md`) — v2.6 하네스 마무리, 사용자 결정으로 rename 변경과 함께 진행.

## 1. 사용자 확정 매핑 결정 (7개)

1. **에러코드 / NotFoundError 메시지**: `"mochi_item.not_found"` 단순 갈음 (호환 X — 신규 프로젝트).
2. **idempotency key prefix**: `"capture:"` → `"mochi_item:"`. 완전 신규라 invalidate 무관.
3. **Search 모듈 도미노**: `Citation.capture_id` → `mochi_item_id`, JSON wire field `captureId` → `mochiItemId` (전체 일관성).
4. **Realm 스키마**: 완전 신규 빌드 → schemaVersion 증가 + Realm 파일 삭제 OK. migration block 빈 채로.
5. **ShareExtension `InboundCapturePayload`**: → `InboundIngestPayload` (일관성).
6. **`CaptureProgressView`**: → `MochiItemProgressView` (코드 의미상 post-ingest 분석 lifecycle, 도메인 객체 진행).
7. **AppGroup `captures/` 디렉토리**: **보존** (캡처 행위 의미 + 데이터 호환).

행위/도메인 매핑:
- `IngestCapture` → `Ingest`, `IngestCaptureCommand` → `IngestCommand`, `IngestCaptureResult` → `IngestResult`
- `BackTapCapture` → `BackTapIngest`
- `OverrideCaptureIntent` → `OverrideIntent`
- `CaptureSyncWorker` (iOS) → `MochiItemSyncWorker` (도메인 객체 동기화)
- `CaptureChannel` / `CaptureSource` → `IngestChannel` / `IngestSource`
- `CaptureScreenshotIntent`, `CommitBackTapCaptureIntent`, `QuickCaptureIntent` (iOS AppIntents) → **보존** (행위)

## 2. 사전 grep snapshot (rename 시작 시점)

### 2.1 백엔드 — `from app.modules.captures` 외부 hit (sed 대상)

- `app/api.py:5` — `from app.modules.captures.presentation.router import router as captures_router`
- `app/core/deps.py:8,9` — IntentClassifier 포트, VertexAIGeminiClassifier
- `app/modules/agent/presentation/router.py:14` — GetCaptureForOwner, make_capture_repository
- `app/modules/intents/domain/lifecycle_policy.py:6` — captures.domain.entities import
- `alembic/env.py:14` — captures.infrastructure (orm, outbox)
- 모듈 내부 self-import 다수 (디렉토리 mv 후 sed 로 자동 정합)

### 2.2 백엔드 tests — sed 대상

- `tests/unit/test_override_capture_intent.py`
- `tests/unit/test_back_tap_capture.py`
- `tests/unit/test_capture_entity.py`
- `tests/unit/test_intent_classification_result.py`
- `tests/unit/test_ingest_capture_e2e.py`
- `tests/unit/test_lifecycle_policy.py`

### 2.3 iOS — Capture 식별자 분포 (Step 12~16 대상)

- CoreDomain: `Capture.swift`, `CaptureAnalysis.swift`, `CaptureSource.swift` (Capture/CaptureAnalysis/CaptureSource/CaptureChannel)
- CorePersistence: `CaptureRepository.swift`, `CaptureRepositoryDI.swift`, `CaptureSyncWorker.swift`
- CoreNetworking: `MochiAPIClient.swift` (CaptureIngestRequest, CaptureDTO), `URLSessionMochiAPIClient.swift` (ingestCapture, getCapture, path `/api/v1/captures`)
- Features: `FeatureCapture/` 전체 (CaptureFeature, CaptureProgressView, BackTapModalFeature, BackTapModalView)
- App: `import FeatureCapture` (RootView, MainTabFeature, AppDependencies, RootFeature)
- ShareExtension: `InboundCapturePayload`, `channelGuess: CaptureChannel`
- AppIntents: `CaptureScreenshotIntent`, `CommitBackTapCaptureIntent`, `QuickCaptureIntent` — **보존**

## 3. 진행 상태

- [x] 사전 grep snapshot
- [x] **B1 완료** — `f0e3d50` `refactor(be): rename captures module to mochi_items (paths only)`
  - 디렉토리 mv (18 파일) + 외부 import sed (11 파일) + ruff fix 1건
  - ruff 통과. mypy 35건 기존 부채 (rename 무관 — `app.modules.captures` 미해결 import 에러 0건).
- [x] **B2 완료** — `076b261` `refactor(be): rename Capture identifiers to MochiItem/Ingest`
  - 도메인/application/infrastructure/presentation/agent/search/shared/core 전부 식별자 갱신 (42 파일)
  - 파일 rename 4건 (ingest_capture→ingest, back_tap_capture→back_tap_ingest, override_capture_intent→override_intent, capture_worker→mochi_item_worker)
  - Tests rename 4건 + 본문 식별자 갱신
  - **B3 까지 의도적으로 유지된 잔존** (정상):
    - ORM `__tablename__ = "captures"/"capture_outbox"/"capture_image_refs"` (B3 alembic 과 짝)
    - ForeignKey 문자열 `"captures.id"` (B3)
    - ORM 컬럼 attribute name `capture_id` (B3 — column rename 과 일치 유지)
    - SQL `FROM captures`, `JOIN captures`, `INSERT INTO agent_runs (... capture_id ...)`, `pg_notify('capture_outbox', ...)` (B3)
    - worker 의 `ClaimedOutbox.capture_id` + SQL `RETURNING capture_id` (B3)
  - 검증: ruff All checks passed. mypy Capture/mochi_item 관련 에러 0건.
- [x] **B3 완료** — alembic 0006 + ORM/SQL 동기화 + openapi.json 재생성 (커밋 예정)
  - alembic `0006_rename_captures_to_mochi_items`: rename_table 3 + alter_column 6(capture_id→mochi_item_id) + `ALTER INDEX ix_captures_fts → ix_mochi_items_fts`. downgrade 정확히 반대.
  - 검증: `make db-up` → upgrade head(0005→0006) → downgrade -1 → upgrade head 왕복 무결. psql 로 mochi_items/mochi_item_outbox/mochi_item_id/ix_mochi_items_fts 확인.
  - ORM(orm.py): __tablename__ 3 + FK 문자열 + capture_id→mochi_item_id 6 + **관계속성 `capture`→`mochi_item`(child 3곳 + back_populates 3곳)** — B2 에서 누락됐던 도메인명사 잔존. grep 상 `.capture` 접근자 외부 사용 0 이라 무위험, 최종 검증 grep(app/modules 도메인 Capture 0) 충족 위해 B3 에서 정리.
  - SQL: outbox(`pg_notify('mochi_item_outbox')` + docstring), worker(UPDATE/SELECT/RETURNING + `ClaimedOutbox` slots + log key + LISTEN 주석), orchestrator(INSERT agent_runs + bind dict), postgres_index(FROM/JOIN/alias/row attr), repository(row.mochi_item_id + IdempotencyKeyRow kwarg). Makefile worker 주석.
  - openapi.json: path `/api/v1/captures*`→`/api/v1/mochi_items*`, 스키마 `CaptureChannel→IngestChannel`/`CaptureCreateRequest→MochiItemCreateRequest`/`CaptureResponse→MochiItemResponse`. 보존 확인: `capturedAt` 만 잔존(결정 #7), `captureId`/`capture_id` wire 0.
  - 검증: `make test` 80 passed, `make lint` clean, `make typecheck` 35(기존 부채·신규 0).
  - **⚠️ 환경 제약**: 에이전트 exec 컨텍스트가 Framework Python library-validation 으로 `cryptography`/`numpy` dylib 로드 거부 → `make openapi` 직접 실행 불가(`make test` 는 unit-only 라 해당 체인 미접촉, 통과). openapi.json 은 `/tmp/export_openapi_shim.py`(두 패키지만 MagicMock 스텁 후 `app.openapi()` 덤프 = generator 출력과 동일, 앱 무변경)로 생성. **사용자 터미널에선 `make openapi` 정상** — B4/B5 마무리 시 한 번 재실행해 byte 동일 확인 권장.
  - **잔여 cosmetic(무위험, 의도)**: Postgres 자동생성 인덱스/FK 제약명은 옛 이름 유지(`ix_capture_outbox_capture_id`, `capture_outbox_capture_id_fkey` 등) — rename_table 이 자동 개명 안 함. ORM 이 이름 고정 안 해 기능·검증 grep 무영향. 승인된 최소 스코프(ix_captures_fts 만 명시 rename)와 일치.
- [x] **B4 완료** — iOS 전체 rename (40 파일 + 디렉토리/파일 git mv + Project.swift). 커밋 예정.
  - 디렉토리: `FeatureCapture`→`FeatureMochiItem`, `FeatureCaptureTests`→`FeatureMochiItemTests`. 파일 11개 rename(Capture/CaptureAnalysis/CaptureSource/CaptureRepository*/CaptureSyncWorker/RealmCapture*/CaptureFeature/CaptureProgressView/CaptureFeatureTests).
  - **2-그룹 전략** (교차그룹 라벨 위험 회피):
    - GROUP_FULL(도메인/네트워킹/Inbox/Detail/Tests): 타입 + 소문자 `captureID`→`mochiItemID`·`capture`→`mochiItem`·`captures`→`mochiItems`·`captureTapped`→`mochiItemTapped`·`capturesLoaded`→`mochiItemsLoaded` 전부.
    - GROUP_PRESERVE(AppGroup·AppIntents·RootFeature·BackTapModal·ShareExtension·Mock): 타입만 rename, **캡처 행위 vocab 보존**(`captureID` pending-file 핸들, `captures/` 디렉토리, `screenshotCaptureID`/`memoCaptureID`, `captureLabel`, `captureCaption`, `capturedImagesDirectoryURL`, AppIntent 명 `CaptureScreenshotIntent`/`CommitBackTapCaptureIntent`/`QuickCaptureIntent`).
  - 타입 매핑: `Capture`→`MochiItem`, `CaptureChannel`→`IngestChannel`, `CaptureSource`→`IngestSource`, `CaptureAnalysis`→`MochiItemAnalysis`, `CaptureRepository`→`MochiItemRepository`, `RealmCapture`→`RealmMochiItem`, `CaptureDTO`→`MochiItemDTO`, `CaptureIngestRequest`→`MochiItemIngestRequest`, `InboundCapturePayload`→`InboundIngestPayload`, `ingestCapture`/`getCapture`→`ingestMochiItem`/`getMochiItem`, 모듈 `import FeatureCapture`→`FeatureMochiItem`.
  - **wire 계약 정합**: `SearchResponse.Citation` `captureID`+CodingKey `"captureId"` → `mochiItemID`+`"mochiItemId"` (백엔드 CitationDTO=mochiItemId 확인). URL path `/api/v1/captures`→`/api/v1/mochi_items` (snake_case — sed가 camelCase `/mochiItems` 로 만든 것 교정). 에러코드 주석 `mochi_item.not_found`.
  - **교차그룹 break 2건 잡음**: BackTapModalFeature `@Dependency(\.captureRepository)`→`\.mochiItemRepository`, `updateSync(captureID:)`→`updateSync(mochiItemID:)` (정의가 GROUP_FULL 에서 rename됨).
  - **검증**: `tuist generate` ✔. `tuist build` — CoreDomain ✔, CorePersistence ✔, CoreNetworking ✔ (도메인·Realm·wire 계약 모듈 컴파일+링크 깨끗). 전 모듈 Swift 컴파일 통과. **전체 앱 link 실패는 `PerceptionCore.Perceptible`/`SwiftUICore not allowed client`/`CoreAudioTypes` — rename 무관 환경/static-product 링크 이슈** (사용자 Xcode/`tuist test` 에서 최종 확인 필요).
  - openapi-check: iOS 가 `/mochi_items` 호출로 전환 → captures 계약깨짐 해소(drift 14→12, 남은 12 = 등록된 known-drift: auth 외부처리·미구현 endpoint).
  - **zsh 함정**: `perl ... $FILES` 는 zsh 가 단어분할 안 해 실패 → `find -print0 | xargs -0` 사용. macOS sed 는 `\b` 미지원 → perl.
  - **잔여 cosmetic**: 테스트 메서드명 `test_..._capture`(2건, `_capture` 워드경계로 미매칭, 무해).
- [x] **B5 완료** — 문서 정합 폭포. 커밋 예정.
  - `DOMAIN_DESIGN.md`: §16-20 known-drift 헤더 → "명명 drift 해소" (구조 3-table vs 1-table 만 design-ahead 노트로 잔존), `captures.channel`/`CaptureChannel`→`mochi_items.channel`/`IngestChannel`, `Realm Capture`→`Realm MochiItem`, `단일 captures 테이블`→`mochi_items`.
  - `TODO.md`: `CaptureSyncWorker`→`MochiItemSyncWorker`, `CaptureSource.swift`→`IngestSource.swift`, `/api/v1/captures`→`/api/v1/mochi_items`, `서버 captures API`→`mochi_items API`.
  - `PRIVACY_SENSITIVE_CAPTURE.md`: 모듈경로 `captures/domain`·`captures/presentation`→`mochi_items/`, `CaptureSyncWorker`→`MochiItemSyncWorker`, `CaptureFeature`→`MochiItemFeature`, `백엔드 captures API`→`mochi_items API`.
  - `PRODUCT.md`: `Capture(`→`MochiItem(`, `CaptureSyncWorker`→`MochiItemSyncWorker`, `/api/v1/captures`→`/api/v1/mochi_items`.
  - `gcp-architecture.html`: 모든 API `/captures`→`/mochi_items`, `Capture ingestion`→`MochiItem ingestion`, `Capture 분석`→`MochiItem 분석`, `CaptureSyncWorker`→`MochiItemSyncWorker`.
  - `ARCHITECTURE.md`: `InboundCapturePayload`→`InboundIngestPayload`, `CaptureSyncWorker`→`MochiItemSyncWorker`, `CaptureFeature`→`MochiItemFeature`, `FeatureCapture`→`FeatureMochiItem`, `Capture(`→`MochiItem(`, bare `Capture`→`MochiItem`.
  - `mochi-backend/README.md`: 모듈 `captures/`→`mochi_items/`, `PostgresCaptureRepository`/`CaptureRepository`→`MochiItem*`, `CaptureSource`→`IngestSource`, `IngestCapture`→`Ingest`, 멱등 prefix `capture:`→`mochi_item:`, `"capture.not_found"`→`"mochi_item.not_found"`, API `/captures`→`/mochi_items`, `run(capture_id)`→`run(mochi_item_id)`.
  - `mochi-ios/README.md`: `FeatureCapture`→`FeatureMochiItem`, `CaptureFeature`→`MochiItemFeature`, `CaptureRepository`→`MochiItemRepository`, `InboundCapturePayload`→`InboundIngestPayload`, bare `Capture`→`MochiItem`.
  - `WORKFLOW.md`: 포트 명명 예시 `CaptureRepository`→`MochiItemRepository`.
  - 보존: 모든 AppIntent 명(`CaptureScreenshotIntent`/`CommitBackTapCaptureIntent`/`QuickCaptureIntent`/`OpenBackTapMemoIntent`/`BackTapSnippetView`), `captures/` AppGroup 디렉토리, `captureID` pending-file, `BackTapModalFeature/View`, `capturedAt`, Korean 캡처/캡쳐(행위).
  - `CHANGELOG.md`: append-only 라 과거 항목 보존(해소는 상단 신규 ios/backend 항목이 기록). `:137`/known-drift 도 과거 기록으로 보존.
  - 검증: `audit.sh l2` DOMAIN_DESIGN 강등 사유 0(명명 drift 해소). 비-CHANGELOG docs 전역 domain-noun capture 0건.

## 7. rename 전체 완료 요약 (B1~B5)
- B1 `f0e3d50`, B2 `076b261`, B3 `f973dc2` (backend), B4 `8703c06` (iOS), B5 (docs, 이 커밋).
- **남은 사용자 작업**: 사용자 Xcode 에서 `tuist test` (또는 빌드) 로 전체 앱 link+테스트 최종 확인 — 에이전트 환경은 `PerceptionCore`/`SwiftUICore` static-link 로 전체앱 link 불가(core 모듈 3종은 빌드 검증 완료). backend `make openapi` 도 사용자 터미널서 1회 재실행해 byte 동일 확인 권장(에이전트는 cryptography dylib 정책으로 셰임 생성).

## 4. 다음 할 일 (B3)

architect 플랜의 Step 9~11. 구체 작업:

### 4.1 새 alembic 0006 마이그레이션 추가
파일: `mochi-backend/alembic/versions/20260529_HHMM_0006_rename_captures_to_mochi_items.py`

upgrade:
```python
op.rename_table("captures", "mochi_items")
op.rename_table("capture_image_refs", "mochi_item_image_refs")
op.rename_table("capture_outbox", "mochi_item_outbox")

for table in ["entities", "embeddings", "idempotency_keys", "agent_runs",
              "mochi_item_outbox", "mochi_item_image_refs"]:
    op.alter_column(table, "capture_id", new_column_name="mochi_item_id")

op.execute("ALTER INDEX ix_captures_fts RENAME TO ix_mochi_items_fts")
```

downgrade: 정확히 반대 (rename_table 3 + alter_column 6 + index rename 1).

검증: `make db-up` → `alembic upgrade head` (0001~0006 차례대로) → `alembic downgrade -1` → `alembic upgrade head` 깨끗.

### 4.2 ORM `__tablename__` / FK 문자열 / column attribute name 동기화
파일:
- `mochi-backend/app/modules/mochi_items/infrastructure/orm.py`:
  - `MochiItemRow.__tablename__ = "mochi_items"`
  - `MochiItemImageRefRow.__tablename__ = "mochi_item_image_refs"`, FK `mochi_items.id`, 컬럼 `capture_id` → `mochi_item_id`
  - `EntityRow.capture_id` → `mochi_item_id`, FK `mochi_items.id`
  - `EmbeddingRow.capture_id` → `mochi_item_id`, FK `mochi_items.id`
  - `IdempotencyKeyRow.capture_id` → `mochi_item_id`
  - `AgentRunRow.capture_id` → `mochi_item_id`, FK `mochi_items.id`
- `mochi-backend/app/modules/mochi_items/infrastructure/outbox.py`:
  - `MochiItemOutboxRow.__tablename__ = "mochi_item_outbox"`, FK `mochi_items.id`, 컬럼 `capture_id` → `mochi_item_id`
  - SQL `pg_notify('mochi_item_outbox', :mochi_item_id)` (현재는 `pg_notify('capture_outbox', :mochi_item_id)` 인데 채널명 변경)
- `mochi-backend/app/modules/mochi_items/infrastructure/repository.py`:
  - `row.capture_id` → `row.mochi_item_id` (IdempotencyKeyRow 의 attribute name 따라)
  - `IdempotencyKeyRow(key=..., capture_id=mochi_item_id)` → `IdempotencyKeyRow(key=..., mochi_item_id=mochi_item_id)`
- `mochi-backend/app/modules/agent/application/mochi_item_worker.py`:
  - SQL `UPDATE capture_outbox` → `UPDATE mochi_item_outbox`
  - SQL `SELECT id, capture_id` → `SELECT id, mochi_item_id`
  - SQL `RETURNING id, capture_id, owner_id, attempts` → `mochi_item_id`
  - `ClaimedOutbox` slots + `__init__` + attribute: `capture_id` → `mochi_item_id`
  - `row.capture_id` → `row.mochi_item_id`
  - log key: `capture_id=str(claimed.capture_id)` → `mochi_item_id=str(claimed.mochi_item_id)`
  - `orchestrator.run(claimed.capture_id)` → `orchestrator.run(claimed.mochi_item_id)`
- `mochi-backend/app/modules/agent/application/orchestrator.py`:
  - SQL `INSERT INTO agent_runs (id, capture_id, ...)` → `mochi_item_id`
  - binding dict `"capture_id": run.mochi_item_id` → `"mochi_item_id": run.mochi_item_id` (key + value 일치)
- `mochi-backend/app/modules/search/infrastructure/postgres_index.py`:
  - SQL `FROM captures` → `FROM mochi_items`
  - SQL `JOIN captures c ON c.id = e.capture_id` → `JOIN mochi_items c ON c.id = e.mochi_item_id`
  - SQL `SELECT c.id AS capture_id` → `SELECT c.id AS mochi_item_id`
  - `Citation(mochi_item_id=row.capture_id, ...)` → `Citation(mochi_item_id=row.mochi_item_id, ...)`

### 4.3 `make openapi` → openapi.json 재생성
명령: `cd mochi-backend && make openapi`
검증:
- `openapi.json` diff 에 path `/api/v1/captures` → `/api/v1/mochi_items` 변환
- schema 명 `CaptureCreateRequest` → `MochiItemCreateRequest` 등
- `bash .claude/scripts/openapi-check.sh` 통과 (혹은 iOS path 와 drift 가 *예상치*)

### 4.4 검증
- `make lint` + `make typecheck` 그린
- `make test` — DB 필요, `make db-up` 띄운 뒤
- 커밋: `refactor(be): migrate captures table → mochi_items + rename FK columns (alembic 0006)`

## 5. 컨텍스트 부채 (다음 세션이 먼저 봐야 할 것)

1. `/Users/jun/.claude/plans/modular-floating-reddy.md` — 5묶음 플랜 전체.
2. architect 의 정밀 step-by-step 플랜 (위 4.1~4.4 가 그 압축).
3. 사용자 결정 7개 (이 문서 §1).
4. B1/B2 commit log 확인 (`git log --oneline -3`).

## 6. 미완 결정 (사용자 선택 대기 X — 모두 결정됨)

없음. 7개 모호성 모두 §1 에서 확정.
