---
level: 3
mode: log
status: active
last_verified: 2026-06-05
confidence: 0.7
owners: [송준서]
title: PR-B handoff — Live Activity·헷갈려요 APNs production 승격
description: ingest 재설계 PR-B(Live Activity/APNs) 구현 인수인계. 다음 세션이 바로 착수하도록 코드 현황·단계별 계획·결정·리스크·외부설정을 담음. Live Activity·push token·알림·outbox 훅을 손대기 전 읽어라. PR-C 머지·PR-A PR대기 상태 전제.
---

# PR-B handoff — Live Activity·헷갈려요 APNs production 승격

> **이 문서 하나로 PR-B 를 착수할 수 있게 쓴 인수인계다.** 설계 근거의 단일 원천은
> [`journal/2026-06-05-sharext-send-liveactivity-apns-memo-mode.md`](2026-06-05-sharext-send-liveactivity-apns-memo-mode.md)(§B)
> + plan 의 architect B 설계. 본 문서는 그 위에 **코드 현황(파일·라인) + 단계별 구현 + 검증 + 리스크**를 더해
> "바로 짜기" 수준으로 구체화한다. 끝나면 ARCHITECTURE/DOMAIN/PRODUCT 로 harvest 후 저널 삭제(WORKFLOW §2.2).

---

## 0. 현재 상태 (2026-06-05 기준, 이 작업의 출발점)

| 항목 | 상태 |
|---|---|
| Step 0 git 정리 | ✅ 리브랜딩 chore → develop PR #7 머지. develop = clean base |
| PR-C (출처앱 sentinel·메모모드·고아청소) | ✅ PR #8 **머지 완료** (develop 포함) |
| PR-A (ShareExt 직접전송·큐 진실원천) | 🟡 PR #9 **생성·머지 대기** — 실기(Keychain group·provisioning) 검증 후 사용자 머지 |
| **PR-B (본 문서)** | ⏸️ **착수 전.** develop(또는 PR-A 머지 후)에서 `feat/be-live-activity-apns` 분기 권장 |

**브랜치 분기 기준**: PR-A 가 develop 에 머지된 뒤 그 위에서 분기하면 충돌 0. (PR-B 는 백엔드+iOS Widgets/App 중심이라 PR-A 의 ShareExt 와 거의 안 겹침 — PR-A 머지 전 분기해도 무방.)

**앱 식별자 정본(확정)**: Bundle `app.mochi` / Team `U9SLX327XS` / App Group `group.app.mochi`. (리브랜딩 채택, PR-A 와 동일.)

---

## 1. 확정 결정 로그 (흔들지 말 것 — 저널 §B + architect)

- **실시간 분담 (2026-06-05 수정 — SSE 채택, PR-B 포함)**: foreground = **SSE 즉시 반영**(`AgentStreamClient` live 구현으로 3초 폴링 대체 — 지연·다건 부하 제거). background/종료 = **APNs**(SSE 는 long-lived 소켓이라 background 진입 시 suspend 되어 끊김 — 이게 background 에 APNs 가 *필수*인 이유). scenePhase active 복귀 시 **reconcile**(SSE 재연결 + 1회 동기화로 background 중 놓친 상태 메움). 폴링(`startForegroundPolling`)은 **SSE 연결 실패 시 fallback** 으로만 강등(제거 금지). → 이전 "SSE MVP 제외" 결정 뒤집음: 백엔드 SSE 는 이미 존재(`AgentEvent.finalAnalysis` 흘림), iOS 클라만 미구현이라 비용 낮고 foreground UX(즉시성) 이득이 크다.
- **알림 정책**: 분석 완료 시 **항상** 알림(무음 분기 없음 — 빈도는 OS 알림설정으로 사용자 조절). `needs_review=false` → "이렇게 저장했어요 — <요약>" **완료 알림**(informative, 탭→앱). `needs_review=true` → "어떤 의도로 남겼나요?" **interactive notification**(후보 선택). 본문은 iOS truncate 되니 **요약 1줄**(intent별 템플릿).
- **헷갈려요 인터랙션 표면**: **interactive notification 이 1급**(`UNNotificationCategory` actions + NotificationContent). Live Activity 는 처리상태(analyzing→ready) **ambient 표시 전담**(선택 액션 최소). 앱 내 needsReview 버킷이 푸시 미수신 시 **always-on fallback**.
- **Live Activity 범위**: **백탭 스크린샷만 점유**(`item.source.channel == .screenshot`). 공유시트 링크/텍스트는 LA 없이 완료 알림만.
- **APNs 클라**: **`httpx`(http2=True) + 직접 JWT ES256**(`cryptography` 또는 `PyJWT[crypto]`, JWT ≤1h 캐시). **aioapns 미채택**(추가 의존·추상화 회피, APNs 는 단일 POST `/3/device/{token}`).
- **모듈 위치**: **신규 `app/modules/notifications/`**(mochi_items/agent 와 분리 — push 는 별도 bounded context).
- **push 훅 격리**: outbox worker `status='done'` 커밋 **이후** best-effort. push 실패가 분석 롤백 금지. **재시도 없음**(누락은 iOS reconcile 이 메움).
- **LA phase 매핑**: `analyzing`→`.analyzing` / `analyzed`+`needs_review=false`→`.ready`(확정) / `analyzed`+`needs_review=true`→`.ready`(후보대기) / `failed`→end.
- **LA attributes mochiItemID 1급화**: 현재 `captureCaption` 8-char prefix 매칭 hack 제거.

---

## 2. 코드 현황 정본 (Explore 정독 결과 — 다시 안 찾아도 됨)

### 2.1 백엔드

| 대상 | 정본 위치 | 현황·패턴 |
|---|---|---|
| **outbox 훅 지점** | `app/modules/agent/application/mochi_item_worker.py:129-132` | 분석완료 → `UPDATE mochi_item_outbox SET status='done'` + `session.commit()`. 이 **commit 직후**에 push 훅. `RefreshUserProfile` best-effort 격리 패턴(`:111-128`, try/except + `session.rollback()`)을 그대로 차용. 분석결과는 이미 DB 영속 → `mochi_item_id`+`owner_id` 로 repo 재로드. |
| **모듈 레이어** | `app/modules/<m>/{domain,application,infrastructure,presentation}` | presentation=`router.py`+`schemas.py`, application=usecase, infrastructure=repo/orm, domain=entities/ports(Protocol). |
| **라우터 등록** | `app/api.py`(`include_router`) | 신규 `notifications_router` 추가. |
| **모듈 경계** | `tests/unit/test_module_boundaries.py:49` | 다른 모듈의 `infrastructure`/`presentation` import 금지. domain/application/app.shared/app.core 만 허용. |
| **config secret** | `app/core/config.py`(Pydantic Settings) + `.env.example` | env 이름 대문자. **p8 PEM 은 multiline 이라 base64 권장**(env 에서 `\n` literal 미해석) — config 에서 decode. |
| **alembic 최신** | `alembic/versions/20260605_0900_0009_intent_instances.py` | revision="0009", down_revision="0008". `op.create_table` 컨벤션: UUID PK(`postgresql.UUID(as_uuid=True)`), `owner_id` FK+index, `server_default=sa.text("now()")`, composite index(owner leftmost). **0010 이 이걸 그대로 따른다.** |
| **openapi 생성** | `scripts/export_openapi.py`(3.1→3.0 nullable 변환) + `Makefile`(`make openapi` = export + iOS 복사 `../mochi-ios/Targets/Cores/CoreNetworking/openapi.json`) | presentation schema 추가 → `make openapi` → iOS `CodeGen/generate.sh`. |
| **분석 응답** | `app/modules/mochi_items/presentation/{schemas.py,router.py}` `_to_response` | `intent_instances`·`needs_review`·`review_options`·`summary`·`lifecycle_kind` 직렬화. ⚠️ **`review_options` 는 현재 빈 배열**(projection 미계산) — interactive notification 후보를 주려면 계산 필요(§5 막힌것). |
| **httpx** | `auth/.../id_token_verifier.py`, `agent/.../tools/web_fetch.py` | http2 미활성. **APNs 는 `http2=True` 별도 클라**(web_fetch 와 분리). |

### 2.2 iOS — mock 파일 삭제/리네임 판정표

| 파일 | 줄수 | 판정 | 액션 |
|---|---|---|---|
| `Cores/CoreLiveActivity/Sources/MockUseCaseActivityAttributes.swift` | 61 | **리네임** | production 이 driving 중. `MockUseCaseActivityAttributes`→`MochiLiveActivityAttributes`. **`mochiItemID: UUID` 필드 추가**(8-char hack 제거). `captureCaption` 8-char 마커(`:51`)는 유지하되 매칭은 mochiItemID 로. |
| `Widgets/Sources/MockUseCaseLiveActivity.swift` | 282 | **리네임** | attributes type 따라감. `MockUseCaseLiveActivity`→`MochiLiveActivity`. UI(Lock/DynamicIsland 3-phase) 그대로. |
| `Widgets/Sources/LiveActivityIntents.swift` | 82 | **유지** | `SelectCandidateIntent`(App Group `live-activity-selection.json` 마커)·`OpenMochiOtherIntentIntent`. widget 자동 로드. |
| `Cores/CorePersistence/Sources/LiveActivityCoordinator.swift` | 64 | **유지** | production 계약 protocol(`startAnalyzing`/`transitionToReady`/`endIfActive`). `liveActivityCaption`(`:61-63`) 8-char hack 은 mochiItemID 1급화 후 제거. |
| `App/Sources/LiveActivityCoordinatorLive.swift` | 119 | **리네임 + push 배선** | live 구현. attributes 이름(`:25,29,51,99,102`) 교체. **`:38 pushType: nil` → `.token`** + LA push token 등록. `findActivity`(`:83-88`) 8-char 매칭 → mochiItemID 정확 매칭. |
| `App/Sources/Prototype/MockUseCaseNotificationPrototype.swift` | 211 | **삭제** | `#if DEBUG`, 10초 타이머 mock. **이미 호출 제거됨**(`MochiApp.swift:48` comment). 삭제 시 끊을 호출 없음. grep 으로 잔여 참조 0 확인. |
| `NotificationContent/Sources/NotificationViewController.swift` | 91 | **유지·재배선** | `userInfo` decode→`MultiSelectCandidateView`. category·후보를 APNs payload 로(현재 `MockUseCaseDefaults` 고정값). |
| `NotificationContent/Sources/MultiSelectCandidateView.swift` | 121 | **유지** | UI 렌더만. data-driven 으로. |
| `NotificationContent/Support/Info.plist` | — | **업데이트** | `UNNotificationExtensionCategory = "MOCK_USECASE_V0"` → production category(서버 payload 의 category 와 일치, 예 `MOCHI_REVIEW_V1`). |

### 2.3 iOS — 폴링·상태·APNs 진입점

| 대상 | 정본 위치 | 현황 |
|---|---|---|
| 폴링 | `Cores/CorePersistence/Sources/MochiItemSyncWorker.swift:215-223` | `startForegroundPolling(every:3)`. `MochiApp.body`(`:56`)+scenePhase active(`:62`). |
| LA 전환 | 같은 파일 `:234-297` `pollAnalysisOnce`, `:262-263` `lifecycleKind=="analyzed"` 감지, `:274-288` screenshot 채널 LA `.ready`. | foreground 한정(comment "background push는 APNs 도입 후"). |
| LA 시작 | 같은 파일 `uploadOne :76-87` `startAnalyzing`. | caption 8-char ID 임베딩 + thumbnailRelativePath. |
| deadline/강등 | 같은 파일 `:300` 90s, `:305-331` `demoteToManual`(needsReview=true 강등 + LA 종료). | reconcile 걸 지점. |
| 상태 모델 | `Cores/CoreDomain/Sources/MochiItemAnalysis.swift` | `instances`/`needsReview`/`reviewOptions`/`importance`. `MochiItem.id==IngestSource.id`, `SyncState.uploaded(serverID:)`. |
| **APNs 토큰 등록 (부재)** | `App/Sources/MochiApp.swift` | **AppDelegate 없음, UNUserNotificationCenter delegate 없음, registerForRemoteNotifications 없음.** → AppDelegate(`UIApplicationDelegateAdaptor`) 추가 + 권한 요청 + token 콜백 + 백엔드 등록 신규. |
| openapi 클라 | `Cores/CoreNetworking/Sources/{MochiAPIClient,OpenAPIMochiClient}.swift` | push-token 등록 op 추가 → `generate.sh`. |
| **SSE 클라 (foreground 폴링 대체)** | `Cores/CoreAgentClient/Sources/{AgentStreamClient,AgentStreamClientDI}.swift` | protocol `stream(mochiItemID:)→AsyncThrowingStream<AgentEvent>`. `AgentEvent`: nodeEntered/toolStarted/toolFinished/partialSummary/**finalAnalysis(MochiItemAnalysis)**/failed. **현재 `NotConfiguredAgentStreamClient` no-op — live 구현 0**(`AgentStreamClientDI.swift:6`). 백엔드 SSE 는 이미 존재(`GET /api/v1/mochi_items/{id}/stream`, agent 모듈 `presentation/router.py`, `finalAnalysis` emit) → iOS live 구현만 하면 폴링 대체 성립. |

---

## 3. 단계별 구현 계획 (각 단계 → 검증)

> 저널 §권장순서: **기획 정본 → push token API → APNs 클라(p8 선행) → 위젯**. 한 PR 이지만 commit 은 단계별로.

### B1. 기획 정본 (코드 전 — L1/L2 문서)
- `DOMAIN_DESIGN.md`: **처리상태↔LA phase 매핑**(§1 결정 로그) + **push token 테이블 섹션**(device_push_tokens 스키마, owner 격리). `PRODUCT.md`: 헷갈려요=interactive notification 1급 / LA=ambient(저널 §B 결정 흡수).
- → 검증: `doc-guardian` 모순 스캔 0. 팀 합의(L1/L2 수정 권한은 이미 확보).

### B2. alembic 0010 — `device_push_tokens`
- `alembic/versions/20260606_XXXX_0010_device_push_tokens.py` (down_revision="0009"). 컬럼: `id`(UUID PK), `owner_id`(UUID FK `users`/`user_profiles` cascade, index), `token`(text/String(512)), `token_type`(String: `apns_device`|`live_activity`), `mochi_item_id`(UUID nullable — LA 는 item 1:1, device 는 null), `environment`(String: `sandbox`|`production`), `created_at`/`updated_at`(server_default now()). composite unique index `(owner_id, token_type, mochi_item_id)` 또는 `(owner_id, token)`.
- → 검증: `make test`(upgrade/downgrade) + `alembic heads` 단일.

### B3. config + 백엔드 notifications 모듈
- `config.py`: `apns_key_id`/`apns_team_id`/`apns_bundle_id`(기본 `app.mochi`)/`apns_p8_key`(base64)/`apns_environment`. `.env.example` 주석(base64 변환법). **p8 내용·KeyID·TeamID 는 비밀 — 하드코딩/커밋 금지, `.env` 는 hook 차단**.
- `app/modules/notifications/`:
  - `domain/ports.py`: `APNsClient`(Protocol: `send(token, payload, pushType, topic)`), `PushTokenRepository`(Protocol).
  - `domain/entities.py`: `DevicePushToken`, `LiveActivityPushPayload`(content-state).
  - `infrastructure/apns_client.py`: httpx `AsyncClient(http2=True)` + ES256 JWT(`kid=KeyID`, `iss=TeamID`, `iat`, ≤1h 캐시). host = `api.sandbox.push.apple.com`/`api.push.apple.com`(environment). 헤더 `apns-topic`(=bundle id, LA 는 `<bundle>.push-type.liveactivity`), `apns-push-type`(`alert`|`liveactivity`).
  - `infrastructure/{repository.py,orm.py}`: `DevicePushTokenRow`, owner-scoped read/write.
  - `application/register_push_token.py`: `RegisterPushToken`(upsert by owner+type+mochi_item).
  - `application/send_notification.py`: `SendAnalysisNotification`(owner_id, mochi_item_id → token 조회 + LA push(analyzing→ready) + alert push(needs_review 분기)).
  - `presentation/{router.py,schemas.py}`: `POST /devices/push-token`(device/LA token 등록). `app/api.py` 등록.
- → 검증: `make lint`/`make typecheck`/`make test` + `make openapi` no-diff(op 반영).

### B4. outbox worker push 훅
- `mochi_item_worker.py:129-132` `status='done'` 커밋 **직후**: `try: await SendAnalysisNotification(...).run(owner_id, mochi_item_id) except Exception: log.warning(...)`(별도 세션/best-effort, 분석 롤백 금지). `RefreshUserProfile` 격리 패턴 차용. **재시도 없음**.
- LA push payload: `aps.content-state`에 top-3 후보 직렬화(<4KB), `apns-push-type: liveactivity`, `aps.timestamp`, `aps.event: update|end`, `aps.stale-date`(분석 deadline 90s 대응).
- → 검증: 백엔드 테스트 — push 함수가 예외 던져도 outbox `status='done'` 유지. payload<4KB 단위 테스트.

### B5. iOS — APNs 토큰 등록 진입점
- `MochiApp.swift`: `UIApplicationDelegateAdaptor` 로 AppDelegate 추가. `application(_:didFinishLaunching)` → `UNUserNotificationCenter.current().delegate = self` + `requestAuthorization([.alert,.sound,.badge])`(타이밍은 §5 — 첫 캡처 권장) + `registerForRemoteNotifications()`. `didRegisterForRemoteNotificationsWithDeviceToken:` → 백엔드 `POST /devices/push-token`(token_type=apns_device).
- `MochiAPIClient`/`OpenAPIMochiClient`: `registerPushToken(...)` op 추가(generate.sh).
- → 검증: `tuist test` 컴파일 + `generate.sh` no-diff. **실기 push 권한·토큰은 사용자**.

### B6. iOS — LA production 재배선 (mock 제거)
- `MockUseCaseActivityAttributes.swift` → `MochiLiveActivityAttributes` 리네임 + `mochiItemID: UUID` 필드. `MockUseCaseLiveActivity.swift` → `MochiLiveActivity` 리네임.
- `LiveActivityCoordinatorLive.swift`: attributes 이름 교체(`:25,29,51,99,102`), `:38 pushType: nil` → `.token` + `Activity.pushToken` 캡처 → 백엔드 `POST /devices/push-token`(token_type=live_activity, mochi_item_id). `findActivity` 8-char→mochiItemID 정확 매칭.
- `MockUseCaseNotificationPrototype.swift` **삭제** + grep 잔여 0.
- → 검증: `tuist test` + `ios-boundaries.sh`.

### B6½. iOS — SSE 구독으로 foreground 폴링 대체 (실시간 반영 업그레이드)
- `CoreAgentClient`: `AgentStreamClient` **live 구현**(`LiveAgentStreamClient`) — 백엔드 `GET /api/v1/mochi_items/{id}/stream` SSE 구독(`URLSession.bytes` line 파싱 또는 EventSource → `AgentEvent`). 인증 Bearer(`AuthTokenProvider`/`AuthMiddleware` 재사용). `AgentStreamClientDI.liveValue` NotConfigured→Live.
- `MochiItemSyncWorker`: foreground 시 `startForegroundPolling`(3초) 대신 **분석중 항목별 `stream(mochiItemID:)` 구독** → `.partialSummary`(진행 표시) / **`.finalAnalysis`** 수신 시 `applyAnalysis` + LA `.ready`(기존 `pollAnalysisOnce:274-288` 로직 재사용) / `.failed`→강등(`demoteToManual`). **SSE 연결 실패·끊김 시 폴링 fallback**(폴링 제거 금지 — 안전망).
- scenePhase `.active` 복귀 → SSE 재연결 + 1회 동기화(reconcile, B7 과 공유).
- → 검증: `tuist test`. 실기: 분석 완료 시 3초 폴링 대기 없이 **즉시** 반영.

### B7. iOS — 알림 핸들러 + reconcile + interactive notification
- `NotificationContent`: Info.plist category → production. `NotificationViewController` userInfo → APNs payload candidates 배선.
- `MochiApp`/AppDelegate `UNUserNotificationCenterDelegate`: `didReceive(response:)` → notification action(후보 선택) → `setIntent` API 호출(백그라운드 POST). 완료 알림 탭 → 앱 진입.
- **reconcile**: scenePhase `.active` 복귀 시(또는 remote notification 수신 후) `pollAnalysisOnce()` 1회 — background 중 놓친 push 메움(`MochiItemSyncWorker`).
- → 검증: `tuist test`. **실기: background 분석완료 → alert 도착 + LA `.ready` 갱신 + 후보 선택**(사용자).

---

## 4. 공유표면 / 견적 (저널 §B.4 — B 가 가장 무겁다)

| 항목 | 공유표면 | AI 편집 | 합의·외부 리드타임 |
|---|---|---|---|
| device/LA push token 테이블 | **DB 스키마**(alembic) | ~1.5h | 중 — 스키마 합의 |
| `POST /devices/push-token` | **API 계약**(openapi) | ~2h | 중 — contract-first |
| 백엔드 APNs 클라(httpx+JWT) | 백엔드 인프라 + **외부 비밀(p8)** | ~3h | **높음 — APNs key·환경변수** |
| outbox→push 배선 | 백엔드 application | ~2h | 낮음 |
| 실 LA attributes + 위젯 + 토큰 등록 | iOS Widgets/App | ~3h | 낮음 |
| 기획 정본(L1/L2) | **PRODUCT·DOMAIN/ARCHITECTURE** | ~1.5h | 중 |
| iOS SSE 클라(foreground 폴링 대체) | iOS CoreAgentClient (백엔드 SSE 이미 존재) | ~2h | 낮음 |

> **편집(~15h)보다 Apple APNs key·provisioning·실기 push 검증 리드타임이 지배적.** contract-first 킥오프 별건. SSE 는 백엔드 0(이미 존재)·iOS 인증 재사용이라 추가 비용 낮음.

---

## 5. 막힌 것 / 사람 결정 필요

1. **✅ p8 key ↔ Team ID 정합 — 해소(2026-06-05 확인, 송준서)** — p8 `AuthKey_CA6C3JCHW3.p8`(Key ID `CA6C3JCHW3`)는 정본 Team `U9SLX327XS`에서 **2026-06-05 발급 확정**. APNs JWT `iss`=`U9SLX327XS` · topic=`app.mochi` · `kid`=`CA6C3JCHW3` 정합. 추가 발급 불필요 — 그대로 env 주입(§7).
2. **review_options projection 미계산** — 백엔드가 현재 `review_options=[]`(빈배열). interactive notification 후보를 주려면 분석결과→review_options 계산을 `apply_analysis`/orchestrator `_to_analysis_result` 에서 채워야. (없으면 LA `.ready` 후보·notification 후보가 비어 헷갈려요 UX 불가.)
3. **알림 권한 요청 타이밍** — 온보딩 vs **첫 캡처 시**(권장). 거부 시 앱 내 needsReview 버킷이 always-on 진실원천(푸시는 보조).
4. **notification 액션 네트워크** — action tap → 백그라운드 즉시 POST(`setIntent`) vs 앱 깨우기. "다른 의도"는 foreground 필요. 구현 시.
5. **완료 알림 요약 포맷** — iOS truncate 한도 내 1줄, intent별 템플릿("일정으로 — 6/10 3시 …"). 구현 시.
6. **LA push token 등록 시점** — `Activity.request(pushType:.token)` 후 `for await tokenData in activity.pushTokenUpdates` 로 캡처 → 등록. token rotation 대응.

---

## 6. 리스크 / 트레이드오프

- **APNs sandbox/production 분기** — host 다름(`api.sandbox.push.apple.com` vs `api.push.apple.com`). device token 은 환경에 묶임 → 잘못 매칭 시 `BadDeviceToken`. `device_push_tokens.environment` 컬럼에 등록 환경 기록, 백엔드가 token별 환경으로 라우팅. **TestFlight=production, Xcode 직접빌드=sandbox**(혼동 잦음).
- **p8 외부 비밀** — env base64 주입, `TODO.md` 체크리스트. `.env` 직접출력은 `pre-bash.sh` 차단.
- **payload 4KB** — LA content-state top-3 truncate. 썸네일은 payload 미포함(디스크 read).
- **bootstrap 부재 LA 시작** — LA 는 **백탭(메인앱 `CommitBackTapCaptureIntent` 경로)** 전용이라 ShareExt(bootstrap 부재)와 무관. ShareExt 직접전송(PR-A)은 LA 안 띄움 — 정합.
- **알림 권한 거부** — 앱 내 needsReview 버킷이 always-on fallback(푸시 미수신해도 헷갈려요 처리 가능).
- **SSE 연결 lifecycle** — foreground SSE 는 토큰 만료·네트워크 끊김·scenePhase 전환에 재연결 필요. 끊기면 **폴링 fallback** 으로 강등(제거 금지). background 진입 시 소켓 suspend → APNs 가 인계(분담 경계).

---

## 7. 외부 설정 (사용자 — Apple)

- **APNs Auth Key(.p8)**: p8 `/Users/jun/keys/AuthKey_CA6C3JCHW3.p8`(Key ID `CA6C3JCHW3`) — **Team `U9SLX327XS` 발급 확정(2026-06-05)**. → env `APNS_P8_KEY`(base64)/`APNS_KEY_ID=CA6C3JCHW3`/`APNS_TEAM_ID=U9SLX327XS`/`APNS_BUNDLE_ID=app.mochi`/`APNS_ENVIRONMENT`. `docs/TODO.md` 체크리스트 등록.
- **Push Notifications capability**: App ID `app.mochi` + entitlement `aps-environment`(App.entitlements 에 추가 필요 — 현재 없음). provisioning 재발급(PR-A 의 Keychain Sharing 과 함께).
- **Live Activity**: Info.plist `NSSupportsLiveActivities=true`(이미 있는지 확인), `NSSupportsLiveActivitiesFrequentUpdates` 옵션.

---

## 8. 검증 분담 (마지막 게이트)

- **Claude 직접**: `make lint && make typecheck && make test`(backend, alembic·push 격리·payload<4KB), `tuist test`(iOS 컴파일·mock 제거·`ios-boundaries.sh`), `make openapi` no-diff + `generate.sh` no-diff.
- **사용자(실기 필수)**: APNs key·provisioning·`aps-environment` entitlement. **remote push·Live Activity push 는 실기기 검증 필수** — background 분석완료 → alert 도착 + LA analyzing→ready 갱신 + interactive notification 후보 선택 + reconcile.
- **단계별**: B 각 commit 후 `ship-precheck.sh all` + code-reviewer(→codex) + qa-validator(→codex).

## 9. 정합성 폭포 (PR-B 완료 시)
`PRODUCT.md`(헷갈려요·push UX) · `ARCHITECTURE.md` §2.5(폴링→push 핸드오프)·§2.3 · `DOMAIN_DESIGN.md`(LA phase·push token 테이블) · `openapi.json` · alembic 0010 · `TODO.md`(APNs 체크리스트) · iOS Widgets/App · `CHANGELOG.md`. → 완료 후 저널 2개(이 문서 + ingest 단일원천) harvest 후 삭제.

## 참조
- 단일원천: `journal/2026-06-05-sharext-send-liveactivity-apns-memo-mode.md` §B(설계·견적·막힌것)
- 코드: §2 표의 모든 경로
- 문서: `ARCHITECTURE.md` §2.3·§2.5 · `DOMAIN_DESIGN.md` §4.4·§7 · `PRODUCT.md`(헷갈려요) · `WORKFLOW.md` §3(공유표면)·§9(contract-first)
