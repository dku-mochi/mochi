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

## 3. 진행 상태 (실시간 갱신)

- [x] 사전 grep snapshot (이 문서)
- [ ] **B1 in_progress** — 백엔드 모듈 디렉토리 이동 + 외부 import path sed
- [ ] B2 — 백엔드 식별자 rename
- [ ] B3 — alembic 0006 + ORM tablename + openapi 재생성
- [ ] B4 — iOS 전체 + Tuist regenerate (사용자 직접 실행 필요)
- [ ] B5 — 문서 정합 + 게이트

## 4. 다음 할 일

B1 — `git mv captures mochi_items` + 외부 import sed 후 `make typecheck && make lint`. test 는 docker DB 띄운 후.
