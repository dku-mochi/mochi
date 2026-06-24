---
level: 3
mode: handoff
status: done
last_verified: 2026-06-25
confidence: 0.95
owners: [송준서]
title: 능동 검색 + ephemeral OCR — PR1(#59)·PR2(#60) develop 머지 완료 + 후속 항목
description: 2026-06-24 핸드오프(agent-active-search-ocr)의 잔여 작업 완료 기록. PR1(검색 트랙)·PR2(ephemeral OCR + iOS)를 구현·리뷰·머지하고 develop 최신화까지 끝냈다. 이 문서는 결정 변경(Realm 영속·v27 재번호)과 비차단 deferred 후속(OCR clear·double-scan·백탭 OCR·lab eval·migration live test)을 다음 세션에 넘긴다.
---

# 능동 검색 + ephemeral OCR — 머지 완료 (2026-06-25)

## 0. 한 줄 요약

이전 핸드오프(`2026-06-24-agent-active-search-ocr-handoff.md`)의 잔여 작업을 전부 완료했다.
**PR1 #59(검색 트랙)·PR2 #60(ephemeral OCR + iOS) 둘 다 develop 에 머지**되고 local develop 최신화됨.
develop canonical: 백엔드 472 tests / typecheck / lint / 누수 grep 0, iOS 빌드 + 97 core tests 통과.

## 1. 머지 결과

| PR | 브랜치 | 내용 | 리뷰 |
| --- | --- | --- | --- |
| #59 | feature/agent-active-search | hybridSearch·멀티쿼리 RRF·webSearch (백엔드) | code-reviewer(codex) PASS |
| #60 | feature/ephemeral-ocr | ephemeral OCR (백엔드+iOS+docs) | code-reviewer(codex) PASS, doc-guardian 정합 OK |

머지 순서: #59 먼저 → develop sync → #60 을 develop 위로 rebase(충돌 해소) → 머지.
develop 로그: `c5f93c6`(#60) → `560b781`(#59) → … 머지된 feature 브랜치 2개는 정리 후보(로컬·remote 잔존).

## 2. 이번 세션에서 바뀐 결정 (핸드오프와 다른 점)

- **iOS OCR Realm 영속 (계획은 "비영속")** — 핸드오프/Plan 은 "Realm 비영속(큐 JSON 에만)"이었으나,
  메인 업로드 워커(`MochiItemSyncWorker.uploadOne`)가 **Realm 에서** source 를 읽어 업로드하므로 비영속이면
  메인 경로에서 OCR 이 유실돼 기능 불능. → `RealmMochiItem.analysisOcrText`(@Persisted, **isolated 컬럼**,
  schema v13→v14)로 보관하되 검색·노출·다른 화면 어디서도 안 읽는다(grep 검증). 추가 노출 아님(originalUpload
  캡처만 추출 → 원본 이미지도 이미 로컬 영속이라 OCR 은 그 부분집합). 문서(PRIVACY §1.1·§2.2·§6.2, IngestSource
  주석, CHANGELOG)를 이 실제 동작에 맞춰 정정함.
- **OCR 정책 게이트 = effective policy == originalUpload 만 동봉** (오너 확정) — blurredUpload·localOnly 제외.
  민감도 점수가 아니라 사용자의 명시적 이미지 정책에 종속(블러로 가린 raw 누설 방지, PRIVACY §9 정합). 단일
  게이트 `EphemeralOCRGate`(CoreDomain) 를 두 업로드 경로 + 추출 단계가 공유.
- **PromptVersion v26 → v27 재번호** — PR1 이 v26(Tools 블록), PR2 가 v26(Visual grounding)으로 충돌. PR1 이
  먼저 머지돼 develop=v26 이므로, PR2 머지 시 **v27 로 재번호** + rationale 체인(V25→V26 tools, V26→V27 OCR).
- **백엔드 codex P1 수정** — confirmed_instances 경로(즉시 ANALYZED, outbox 미적재)는 삭제 훅을 우회해 OCR 이
  영구 잔류. `ingest.execute` 가 `analysis_ocr_text=None if command.confirmed_instances else …` 로 코드 강제 + 회귀 테스트.

## 3. 비차단 후속 (다음 할 일)

전부 머지 차단 아님 — 우선 동작 구현 원칙으로 분리. 우선순위 순:

1. **iOS OCR 업로드 후 Realm clear** (위생) — 업로드 성공 후 `source.analysisOcrText = nil` 로 비우면 on-device
   ephemeral 이 서버 삭제 훅과 대칭이 된다. 현재는 isolated 컬럼에 잔존(추가 노출은 아님 — PRIVACY §2.2 에 옵션으로 명시).
2. **ShareExt double-scan 최적화** — `detectPrivacy` 선감지와 `attachingAnalysisOCR` 가 originalUpload 캡처에서
   OCR scan 을 2회 돈다. 선감지 scan 결과(`SensitiveCaptureScanResult.ocrText`)를 재사용하면 1회로. ShareExt 120MB·지연.
3. **백탭(`CommitBackTapCaptureIntent`) OCR** — 현재 nil(deferred). 백탭은 sensitive scan 자체를 안 거치는 known
   gap 이라, 백탭 민감감지 통합과 함께 업로드 직전 재스캔으로 동봉.
4. **`classify_and_act@v27` lab eval 회귀검증** — Visual grounding OCR 단락 추가가 분석 품질에 미치는 영향 A/B
   (MEMORY[prompt-editing-research-first]). 프롬프트 본문 수정은 eval 자산.
5. **마이그레이션 0026 라이브 up/down** — docker 미가용으로 로컬 미실행. revision 체인(0025→0026 단일 head)·오프라인
   검증만 함. `make db-up && make migrate && alembic downgrade -1 && alembic upgrade head` 로 확인 필요.
6. **`Data(contentsOf:)` 전체 로드** (ShareExtensionPrincipal) — 120MB 한도에서 `CGImageSourceCreateWithURL` 직접이
   더 안전. 단 기존 `detectPrivacy` 도 동일 패턴이라 이 PR 회귀 아님 — 별도 정리.

## 4. 검증 재현

- 백엔드: `cd mochi-backend && make test`(472) `make lint` `make typecheck`, 누수 `rg analysis_ocr_text app/modules/conversations app/modules/search`(0).
- iOS: `cd mochi-ios && tuist test CoreDomain`(30) `tuist test CorePrivacy`(34) `tuist test CorePersistence`(33). 실기빌드는 `xcodebuild`(사용자).
- 정합: `bash .claude/scripts/ship-precheck.sh all`(7 pass).
