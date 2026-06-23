---
level: 3
mode: log
status: active
last_verified: 2026-06-15
confidence: 0.9
owners: [송준서, 이용찬, 박세현]
description: 외부 설정·비밀값 체크리스트 + 활성 작업·다음 sprint 목표. 다음 중 하나라도 손대기 전 읽어라 — 인증·외부 통합, sprint 작업 분배, /sprint-end 직후. 자주 바뀜 · `/sprint-end` 가 done 항목을 docs/archive/ 로 이관.
---

# TODO — 외부 설정 & 비밀값

> Apple/Google 로그인 구현을 코드로 끝낼 수 없는 항목들을 모은 체크리스트.
> 각 항목은 `[ ]` → `[x]` 로 채워가며, 비밀값은 `.env` 또는 Keychain/Secrets Manager 에만 두고 절대 커밋하지 않는다.

---

## 1. Apple Developer Portal

### 1.1 App ID — Sign In with Apple capability
- [x] developer.apple.com → Identifiers → 모찌 App ID 선택
- [x] **Sign In with Apple** capability 체크 → Save
- [x] Bundle ID: `app.mochi` (Project.swift `bundleIdPrefix`)
- 결과: Xcode 빌드 시 `App.entitlements` 의 `com.apple.developer.applesignin` 권한이 매칭되어 빌드 가능

### 1.1b Keychain Sharing capability (ShareExt 직접 전송 — PR-A)
- [x] developer.apple.com → Identifiers → `app.mochi` + `app.mochi.ShareExtension` 둘 다 **Keychain Sharing** capability 체크 → Save
- [x] keychain access group `$(AppIdentifierPrefix)app.mochi` (App·ShareExtension entitlements 에 박힘 — 코드는 kSecAttrAccessGroup 생략, entitlement 첫 그룹 자동 공유)
- 결과: ShareExtension 이 메인 앱 Keychain 의 access token 을 읽어 URL/텍스트/이미지 캡처를 서버에 best-effort 선반영(큐는 항상 적재 — 로컬·동기화·유실방지의 진실원천). **dev 재로그인 1회 필요**(entitlement 변경으로 기존 keychain 그룹 전환 — 자동 마이그레이션 안 함). 시뮬레이터는 자동 서명이라 무관, 실기기 빌드는 §1.2 재발급 선행.

### 1.2 Provisioning Profile 재발급
- [x] App ID 변경(Sign In with Apple·**Keychain Sharing**) 후 development / distribution provisioning profile 재발급
- [x] Xcode → Signing & Capabilities → 새 profile 자동 선택 확인

### 1.3 (옵션) 백엔드 → Apple revocation 연동
백엔드에서 사용자 계정 삭제 시 Apple 측의 refresh token 도 revoke 하려면:
- [ ] Apple Developer → Keys → 새 키 생성 (Sign In with Apple 서비스 활성)
- [ ] `.p8` 파일 다운로드 (1회만 가능) — **절대 git에 커밋 금지**
- [ ] Key ID, Team ID 메모
- 본 마일스톤에선 자체 DB 의 refresh token 만 revoke 하면 충분. Apple 측 revoke 는 후속.

### 1.4 APNs — Apple Push (PR-B, Live Activity·background 알림)
- [x] APNs Auth Key(.p8) 발급 — `AuthKey_CA6C3JCHW3.p8`(Key ID `CA6C3JCHW3`), Team `U9SLX327XS` (2026-06-05). **절대 git 커밋 금지.**
- [x] App ID `app.mochi` 에 **Push Notifications capability** 활성
- [x] `Targets/App/Support/App.entitlements` 에 `aps-environment` 추가됨 (현재 `development` — distribution 빌드 시 `production` 으로)
- [x] provisioning profile 재발급 (§1.2 와 함께 — Push capability 포함)
- [x] Info.plist `NSSupportsLiveActivities=true` 확인(있음) / 필요 시 `NSSupportsLiveActivitiesFrequentUpdates`
- 환경 주의: device token 은 환경에 묶임 — **TestFlight/App Store=production, Xcode 직접빌드=sandbox**. iOS 가 등록 시 environment 를 명시(`POST /devices/push-token`), 잘못 매칭 시 `BadDeviceToken`.

---

## 2. Google Cloud Console

### 2.1 OAuth Client ID (iOS)
- [ ] console.cloud.google.com → APIs & Services → Credentials → **Create Credentials → OAuth client ID**
- [ ] Application type: **iOS**
- [ ] Bundle ID: `app.mochi`
- [ ] Team ID: `U9SLX327XS` (Project.swift `developmentTeam`)
- [ ] 생성된 **iOS client ID** 메모: `XXXXXXXXX-YYYYYYYY.apps.googleusercontent.com`
- [ ] Reversed client ID 메모: `com.googleusercontent.apps.XXXXXXXXX-YYYYYYYY`

### 2.2 (옵션) Web/Backend Client ID
백엔드가 ID Token 의 `aud` 클레임을 검증할 때, 모바일 client id 외에 web client id 도 허용해 두면 future-proof.
- [ ] Application type: **Web application** 추가 생성
- [ ] **Web client ID** 메모

### 2.3 GoogleService-Info.plist
- [ ] iOS OAuth client 생성 화면에서 `GoogleService-Info.plist` 다운로드
- [ ] `mochi-ios/Targets/App/Resources/GoogleService-Info.plist` 로 배치
- [ ] **.gitignore 에 이미 등록되어 있음** — 커밋 금지 (개인별 자료)
- [ ] CI 가 필요해지면 secrets 에 base64 로 저장 후 워크플로에서 디코드

### 2.4 OAuth Consent Screen
- [ ] User type: **External**
- [ ] App name: 모찌(MOCHI), Support email, Developer email
- [ ] Scopes: `email`, `profile`, `openid` 만
- [ ] Test users (개발 단계): 팀원 Google 계정 추가

---

## 3. iOS — Xcode/Tuist 후속 작업

### 3.0 iCloud 단축어 제작 & 온보딩 연결 (백탭 → 모찌 snippet 흐름)

백탭 캡처는 **사용자가 단축어 앱에 설치하는 iCloud 단축어**가 `Take Screenshot → 이미지 변환(PNG) → 모찌 화면 캡쳐` 로 동작한다. `CaptureScreenshotIntent` (`openAppWhenRun = false`) 가 PNG 를 `pending-backtap/<captureID>.png` 에 stash 한 뒤 `ShowsSnippetView` 로 `BackTapResultSnippet`(캡처 분기 = `BackTapSnippetView`)을 외부 앱 위에 카드로 띄운다 — **모찌 앱은 깨우지 않는다** (사용자 컨텍스트 보존). 카드의 두 버튼 (`CommitBackTapCaptureIntent` / `OpenBackTapMemoIntent`) 이 분기를 결정. 단축어 자체는 코드가 아니므로 1회 수동 제작 + iCloud 공유 URL 발급이 필요하다 (다만 빌더 스크립트가 `/tmp/build_mochi_shortcut.py` 에 존재 — handoff 문서 §11 참고).

- [ ] 개발 디바이스의 **단축어** 앱에서 새 단축어 생성. 이름: `모찌 백탭 캡쳐`.
- [ ] **액션 구성** (3단계)
  - [ ] `스크린샷 찍기` 액션 추가. **미리보기 표시 (Show Preview) → OFF** ← 핵심. 켜져 있으면 매 백탭마다 마크업 시트가 떠서 자동화가 깨진다.
  - [ ] `이미지 변환` 액션 추가. 포맷 `PNG`. **이게 없으면** 시스템 locale 에 따라 한국어 파일명(`이미지.png`) 이 붙어 BackgroundShortcutRunner sandbox extension 발급이 실패한다 (`_INIssueSandboxExtensionWithTokenGeneratorBlock` 에러). 변환 액션이 ASCII 임시 파일명을 부여해 우회한다.
  - [ ] `모찌 화면 캡쳐` 액션 추가. 입력은 위 변환 출력 자동 연결.
- [ ] **단축어 설정 (i)** — 백탭 전용이라면 공유시트 표시 OFF 로 두는 게 깔끔 (외부 앱 공유는 ShareExtension 이 별도 surface).
- [ ] **테스트 (snippet 흐름)** — iOS 17 실기 검증 필수 (Apple Forum thread/783911 에 일부 `Button(intent:)` 렌더링 이슈 보고. 모찌 deployment target = 17.0)
  - [ ] 단축어 앱 안에서 직접 실행 (▶) → **외부 앱이 사라지지 않고** 그 위에 모찌 snippet 카드가 떠오르는지 확인.
  - [ ] 백탭 두 번 → 동일 흐름 확인 (설정 → 손쉬운 사용 → 터치 → 뒤로 탭 → 두 번 탭 → 단축어 선택)
  - [ ] **캡쳐 분기** — snippet 카드의 "캡쳐" 탭 → 카드 자동 dismiss + 외부 앱 그대로. 모찌 앱 다시 열어 Inbox 에 새 캡처가 들어왔는지 확인. `pending-backtap/<captureID>.png` 폐기되었는지 확인 (`ls ~/Library/Containers/.../pending-backtap/`).
  - [ ] **메모 분기** — snippet 카드의 "메모" 탭 → 모찌 앱 foreground 진입 + 풀스크린 모달 (textarea) → 저장. Inbox 에 텍스트 캡쳐. `<captureID>.png` 폐기 + `<captureID>.memo` 폐기 확인.
  - [ ] **취소 분기** — 메모 모달에서 "취소" → marker 폐기 + Inbox 변화 없음.
  - [ ] **snippet 시스템 dismiss 잔재** — snippet 떠 있는 상태에서 어느 버튼도 안 누르고 외부 영역 탭 → 다음 모찌 launch / scenePhase active 시점에 `RootFeature` 가 stale `.png` sweep 하는지 확인.
  - [ ] (대조군) Safari → 공유시트 → 모찌 → `ShareEntryView` 메모/저장 → Inbox. 백탭과 다른 surface 임을 확인.
- [x] **iCloud 공유 URL 발급** (2026-05-29 dev 머지로 반영)
  - [x] 단축어 길게 누름 → 공유 → `iCloud 링크 복사`. 결과 형태: `https://www.icloud.com/shortcuts/<hash>`
  - [x] 발급된 URL 을 `BackTapPage` "단축어 등록하기" CTA 가 여는 값으로 교체. 현재 적용된 URL: `https://www.icloud.com/shortcuts/e24ac8bf17ef45a088e4b3cdc76aa44b` (`BackTapPage.swift:15` 의 `shortcutURL`).
- [ ] **버전 관리**: 단축어 정의나 `CaptureScreenshotIntent` 시그니처가 바뀌면 iCloud URL 도 함께 갱신. CHANGELOG 의 `ios` 범위로 한 줄 남길 것.

⚠️ `Show Preview ON` 또는 `이미지 변환` 액션 누락은 자동화를 깬다. 온보딩 가이드에서 두 가지 다 명시.

### 3.1 Info.plist URL Scheme (Google)
- [ ] `Targets/App/Support/Info.plist` 에 `CFBundleURLTypes` 등록 (Reversed client ID)
- 실제 값은 §2.1 의 Reversed client ID 로 치환되어야 함.
- ⚠️ 현재는 **비워 둠**(주석만 — Info.plist L55~59). 플레이스홀더를 박으면 App Store Connect 업로드 validation 이 "URL scheme not in correct format" 으로 실패하므로 §2.1 iOS client 값 확보 후 추가한다. Google 미설정이라 현재 TestFlight 는 Apple 로그인만 동작.

### 3.2 Entitlements — Sign In with Apple
- [x] `Targets/App/Support/App.entitlements` 에 `com.apple.developer.applesignin = ["Default"]` 추가됨
- §1.1 App ID 작업이 끝나야 Xcode 빌드 통과

### 3.3 GoogleService-Info.plist 배치
- [ ] §2.3 참고. 빌드 전에 필수.

### 3.4 백탭 snippet / 모달 에러 핸들링 보강 (production 직전)

snippet 흐름의 `CommitBackTapCaptureIntent` 와 모달의 `BackTapModalFeature.commitMemo` 는 실패를 silent dismiss + pending 폐기로 처리한다 (`CommitBackTapCaptureIntent.swift:62`, `BackTapModalFeature.swift:88`). MVP 의 의식적 trade-off — 디스크 풀 / Realm 손상 같은 pre-upsert 실패는 일상적이지 않고, 진짜 fix 는 별도 alert/retry 인프라가 필요하기 때문. 그러나 베타에서 "메모 사라짐" 보고가 1건이라도 생기면 즉시 보강.

- [ ] **`CommitBackTapCaptureIntent` 실패 신호**: snippet 카드는 `openAppWhenRun = false` 라 background commit. Realm upsert 가 실패해도 사용자에게 알리지 못한다. (a) 실패 marker 파일 (`<captureID>.commit-failed`) stash → 다음 active 시점에 모찌 알림 표시. (b) `IntentResult` 가 `.result(dialog:)` 또는 `.result(view:)` 로 짧은 에러 snippet 반환. (b) 가 즉시성 우수.
- [ ] **`commitMemo` 실패 시 UI state 유지**: Realm upsert 실패면 phase 를 `.memo` 로 복귀 + `memoText` 보존 + 인라인 에러 메시지. 사용자가 입력한 텍스트 손실 방지.
- [ ] **`MochiItemSyncWorker` 의 `.syncFailed` retry**: 현재 `.pendingUpload` 만 retry 대상이라 한 번 실패 후엔 자동 재시도 없음. (a) `.syncFailed` 도 backoff 후 한 번 더 retry 하거나, (b) Inbox 에 retry 버튼 UI 추가. (b) 가 사용자에게 명시적이라 권장. snippet 캡쳐 분기는 백엔드 ingest 를 안 하므로 모든 캡쳐가 `.pendingUpload` 로 진입 → `MochiItemSyncWorker` retry 정책 신뢰도가 더 중요해졌다.
- [ ] **ErrorReporter (sentry / firebase crashlytics) 도입** 후 위 세 흐름과 통합. 단순 catch 가 아닌 structured error 로 보고.

### 3.5 이미지 업로드 파이프라인 — 백엔드 ingest 가 PNG bytes 안 받음 (codex P1 #4)

`CommitBackTapCaptureIntent` 가 영구 `captures/<captureID>.png` 로 이미지 bytes 를 저장하지만, `MochiItemSyncWorker` 가 백엔드 `POST /api/v1/mochi_items` 호출 시 보내는 `ImageRefDTO` 는 `objectKey/mimeType/byteSize/sha256` 만 — `objectKey: nil` 인 채로 metadata 만 전달된다. 백엔드는 multimodal 분석에 필요한 PNG 자체를 받지 못한다. 이건 snippet pivot 으로 도입된 결함이 아니라 **기존부터 비어 있던 업로드 파이프라인** — 모달 흐름에서도 동일했음. (`CommitBackTapCaptureIntent.swift:87`, `MochiItemSyncWorker.swift:42`, `IngestSource.swift:53`)

- [x] **백엔드 presigned URL 발급 엔드포인트** (2026-05-30): `POST /api/v1/mochi_items/presign` → `{ objectKey, uploadURL, expiresAt }`. GCS V4 Signed PUT URL, 키 파일 없이 SA impersonation(signBlob) 서명.
- [x] **iOS `MochiItemSyncWorker.uploadOne`** 이 원본 PNG 를 업로드용 파생본(긴 변 1920px 이하, JPEG q60)으로 변환 → 파생본 bytes 기준 `sha256/mimeType/byteSize` 계산 → presign → GCS PUT → `objectKey` 채워서 ingest 호출 (2026-05-30).
- [x] **`ImageRef.objectKey` 채워지면 Realm 도 갱신**. 이후 sync 호출은 이미 채워진 `objectKey` 재사용 (중복 업로드 금지).
- [x] **iOS back-tap 호출 계약 변경**: 백엔드가 `POST /mochi_items/back-tap` 을 multipart → JSON `{objectKey, sha256, mimeType, byteSize}` 로 바꿨다(2026-05-30). iOS 는 presign→PUT 후 objectKey 를 JSON 으로 전달한다.
- [x] **백엔드 multimodal worker** (2026-05-30): `objectKey` → `gs://{bucket}/{objectKey}` 로 **Gemini 가 직접 read** (다운로드 불필요). classify·분석 모두 `Part.from_uri`.

백엔드·iOS 측 모두 2026-05-30 완료. 남은 후속은 민감 캡처 정책(`CorePrivacy`)이 들어온 뒤 업로드 파생본 생성 지점에서 `local_only/text_only/redacted_image/original_allowed` 분기를 거는 일이다.

---

## 4. Backend — `.env`

`.env.example` 에 추가된 키를 실제 값으로 채워 `.env` 작성. **`.env` 는 절대 커밋 금지.**

```
# === App ===
# 운영/스테이징 배포는 반드시 설정. 미설정(=local)은 dev 토큰·dev sign-in·well-known dev secret 을
# 허용하는 permissive 모드다. 부팅 가드(_verify_startup_safety): environment=local 인데 운영용
# AUTH_ACCESS_SECRET 이 주입돼 있으면 ENVIRONMENT 누락으로 보고 부팅을 거부한다(fail-open 방지).
ENVIRONMENT=production

# === Self-issued JWT ===
AUTH_ACCESS_SECRET=<openssl rand -base64 48>     # 32+ chars 권장
AUTH_ACCESS_TTL_SECONDS=1800                     # 30분
AUTH_REFRESH_TTL_SECONDS=2592000                 # 30일
AUTH_CAPTURE_TTL_SECONDS=15552000                # 180일 (capture token sliding TTL — 기본값 있음, 튜닝 시만)
AUTH_CAPTURE_MAX_ACTIVE=5                        # 사용자당 capture token 활성 cap — 기본값 있음, 튜닝 시만
AUTH_JWT_ISSUER=mochi.app
AUTH_JWT_AUDIENCE=mochi.app

# === Apple ID Token verification ===
AUTH_APPLE_AUDIENCE=app.mochi        # bundle id
AUTH_APPLE_JWKS_URL=https://appleid.apple.com/auth/keys

# === Google ID Token verification ===
# iOS client_id (필수). 콤마로 web client_id 도 함께 허용 가능.
AUTH_GOOGLE_CLIENT_IDS=XXXXXXXXX-YYYYYYYY.apps.googleusercontent.com
AUTH_GOOGLE_JWKS_URL=https://www.googleapis.com/oauth2/v3/certs

# === Agent PlatformContext ===
# Instagram 공식 oEmbed 사용 시만 설정. 비우면 OG fallback 으로 동작.
INSTAGRAM_OEMBED_ACCESS_TOKEN=
INSTAGRAM_OEMBED_API_VERSION=v20.0

# === APNs — Apple Push (PR-B) ===
# team_id/key_id/bundle_id 는 공개 식별자. p8 내용만 비밀(절대 커밋 금지).
# p8 → base64: `base64 -i AuthKey_CA6C3JCHW3.p8 | tr -d '\n'`. 비우면 push no-op(local dev).
APNS_TEAM_ID=U9SLX327XS
APNS_KEY_ID=CA6C3JCHW3
APNS_BUNDLE_ID=app.mochi
APNS_AUTH_KEY_P8_BASE64=<base64 of AuthKey_CA6C3JCHW3.p8>

# === 채팅 web_search — Tavily ===
# 미설정 시 web_search 툴만 채팅 레지스트리에서 제외 — 서버·머지 블록 없음.
TAVILY_API_KEY=<tavily.com 발급 키>

# === 검색·채팅 임베딩/리랭크 — Voyage AI (2026-06-12) ===
# 미설정 시 vector·rerank 경로만 비활성(BM25/키워드 degrade) — 서버·머지 블록 없음.
# MongoDB Atlas 발급 키(`al-` 접두)도 지원 — 클라이언트가 엔드포인트 자동 라우팅.
VOYAGE_API_KEY=<dash.voyageai.com 또는 MongoDB Atlas 발급 키>
# reranker 는 키가 있으면 기본 활성(reranker_enabled=true). 기존 .env 에
# RERANKER_ENABLED=false 가 남아 있으면 reranker 가 꺼진 채 돈다 — true 로 갱신 필요.
```

### 4.1 비밀값 생성
- [ ] `AUTH_ACCESS_SECRET` 은 `openssl rand -base64 48` 로 생성
- [ ] dev / staging / prod 마다 다른 값 사용
- [ ] 운영에서는 AWS Secrets Manager / GCP Secret Manager 등으로 격상
- [ ] 운영/스테이징은 `ENVIRONMENT=production`(또는 `staging`) 설정 — 미설정(=local)이면 부팅 가드가 운영용 secret 감지 시 부팅을 거부한다(dev auth fail-open 방지)

### 4.2 시크릿 회전 정책
- [ ] `AUTH_ACCESS_SECRET` 교체 시 모든 사용자가 강제 재로그인됨 (refresh token 도 access 만 무효, refresh는 DB hash 매칭이라 영향 없음). 보안 사고 시 즉시 회전.

### 4.3 PlatformContext / Instagram oEmbed
- [x] YouTube/X/Instagram URL 은 Agent `platformContext` 로 먼저 그라운딩 (2026-05-30).
- [ ] Instagram 공식 oEmbed 를 운영에서 쓰려면 Meta app token + oEmbed 권한/리뷰를 확보하고 `INSTAGRAM_OEMBED_ACCESS_TOKEN` 을 설정.

### 4.4 Voyage 임베딩 색인 (2026-06-12)
- [ ] 각자 로컬 `.env`: `VOYAGE_API_KEY` 설정 + 기존 `RERANKER_ENABLED=false` 줄을 `true` 로 (또는 삭제 — 기본값이 true).
- [ ] 마이그레이션 0018 적용 후 기존 데이터 재색인: `PYTHONPATH=. uv run python scripts/backfill_embeddings.py` (멱등 — 재실행 안전).
- [ ] 토큰 미설정 상태에서는 Instagram OG fallback + screenshot Vision context 를 조합해 분석 정확도를 보강.

### 4.4 채팅 web_search — Tavily
- [x] Tavily API 키 발급(무료 1,000회/월, LLM-agent 전용 — journal 2026-06-10 권고) 후 `.env` `TAVILY_API_KEY` 설정 (2026-06-10)
- 미설정이어도 동작: web_search 툴만 채팅 레지스트리에서 제외되고 채팅·web_fetch 는 정상.

---

## 5. 운영 / 보안 후속

- [ ] **Rate limit**: `/auth/apple`, `/auth/google`, `/auth/refresh`, `/auth/capture-tokens` 에 IP + subject 단위 rate limit (slowapi 등). brute force/refresh storm 방어.
- [ ] **Audit log**: 로그인 성공/실패, refresh rotation, reuse_detected 이벤트를 structlog 의 `auth.*` 카테고리로 남기고 알람 대상으로 등록.
- [x] **계정 삭제 (Right to be Forgotten)** (2026-06-23): `DELETE /api/v1/users/me`(access JWT) → `users.mark_deleted`(`deleted_at` 세팅) + **모든 capture token revoke**(`CaptureTokenRepository.revoke_all_for_user`, reason=`user_account_deleted`). iOS: 설정 §회원 탈퇴 → 확인 다이얼로그 → 성공 시 로그아웃 경로 재사용(로컬 clear + refresh revoke). 남은 후속: ① email 익명화(`deleted+{id}@invalid.local`) — 현재는 `deleted_at` 만, ② Apple `revoke` 엔드포인트 호출(Apple IdP 측 토큰 폐기, client_secret JWT 필요).
- [ ] **Apple App Store 심사 요구사항**: Sign In with Apple 을 제공하면 다른 third-party 로그인(Google 등) 이 있을 때 **반드시** 함께 제공해야 함 (App Review §4.8). 모찌는 이미 둘 다 제공 ✅.
- [ ] **약관/개인정보처리방침 링크 실제 URL**: 로그인 화면 + **설정 정보 섹션**(2026-06-22 추가, `SettingsView.termsURL`/`privacyPolicyURL`) 둘 다 현재 placeholder(`https://mochi.app/terms`·`/privacy`). 실제 URL 나오면 교체.
- [ ] **iOS Keychain access control**: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 로 device-bound + 백업 제외(이미 적용 예정). Face ID gate 는 옵션.

### 5.1 민감 캡처 보호

상세 설계: [민감 캡처 보호 설계](./PRIVACY_SENSITIVE_CAPTURE.md)

**저장 시점에 민감 영역을 블러 처리해 업로드**하므로 서버 이미지 자체가 안전하다 — 다운스트림 노출
표면(`view_item_image`·`similar`·즐겨찾기·사진앱 저장·회수 알림)에 **별도 민감 게이트가 필요 없다**
(2026-06-21 결정 — PRIVACY §2). 게이트 대신 "안전한 이미지를 올린다"로 문제를 근본 제거.

- [x] iOS `CorePrivacy` 모듈: `ImageTextExtractor`(Vision OCR), `SensitiveDataDetector`(NSDataDetector + 한국형 검증기), `SensitivityScorer`, `RedactionPlanner`, `ImageBlurRedactor`, `SensitiveCaptureScanner`.
- [x] 한국형 검증기: 주민등록번호(생년월일 월별 일수+체크섬), 카드번호(Luhn), 사업자등록번호(체크섬), 계좌/은행 문맥, 인증번호/OTP(대소문자), API key/token(Bearer 포함), 의료/금융 문맥 + 명시 라벨(`카드번호:`/`비밀번호:`/`주민번호:`/`계좌번호:`) 보강. 검증/문맥/라벨 통과만 채택해 false positive 억제.
- [x] 민감도 0-10 점수 + `low/caution/sensitive/highlySensitive` 등급화. 검증 통과(high-precision) 신호만 저장 흐름에 시트를 띄워 FP 마찰 차단(저신뢰 신호는 점수만).
- [x] 저장 선택 시트(`PrivacyChoiceView`): `원본 그대로` / `민감한 곳 가리고(블러, 기본 추천)` / `이 기기에만`. 블러 선택 시 결과 미리보기(crossfade + 자물쇠 배지)로 안심.
- [x] 업로드 정책 분기(`MochiItemSyncWorker`·`ShareExtDirectUpload`): `originalUpload`/`blurredUpload`/`localOnly`. 로컬엔 원본 PNG 보존, 서버엔 정책본(블러본 없으면 안전하게 업로드 스킵).
- [x] `NSPhotoLibraryAddUsageDescription` Info.plist 추가 (2026-06-14, 상세 ⋯ "이미지 저장" — 사진앱 add-only 권한). 블러본이 서버 정본이므로 사진앱 반출도 안전.
- [ ] (후속·팀 결정) 백탭 캡처(`CommitBackTapCaptureIntent` — background intent, UI 없음)의 민감 처리 방식: 자동 블러 vs 앱 진입 후 사후 조정. UI 가 없어 저장 시점 시트를 띄울 수 없는 구조적 제약.
- 제외: NER(사람·조직 이름)은 Apple NaturalLanguage 한국어 미지원 + Share Extension 120MB 메모리 한도로 미사용(PRIVACY §3.4). 서버 privacy 메타데이터(`sensitivity_*`)는 미추가 — 서버는 올라온 이미지가 진실(블러본/원본 구분 불필요), iOS 내부 정책으로 충분.

---

## 6. 검증 시나리오 (수동)

릴리스 전 실기 검증:
- [ ] Apple 로그인 첫 인가: fullName 받아 users.display_name 채워짐
- [ ] Apple 재로그인: fullName 없이도 같은 user_id 매칭 (auth_accounts.subject 기준)
- [ ] Apple "Hide my email" 사용자 정상 로그인
- [ ] Google 로그인 신규/재로그인
- [ ] 같은 이메일을 Apple + Google 둘 다로 로그인 시 어떻게 묶을지: **이번 마일스톤은 분리 (provider × subject 별 user)**. 향후 계정 통합 UI 가 필요해지면 별도 작업.
- [ ] access 만료(30분) 자동 갱신 (UI 끊김 없이)
- [ ] refresh 도난 시뮬레이션: 같은 refresh 두 번 사용 → 두 번째에 401 + family 전체 revoke + **같은 사용자 capture token 전체 revoke** 확인
- [ ] ShareExt 직접 전송: 앱을 30분+ 안 연 상태(access 만료)에서 공유 → Console.app `app.mochi.ShareExtension` 에 `token-source=capture` + `success` 로그, 항목 즉시 서버 분석 시작
- [ ] 로그아웃 → ShareExt 공유: 직접 전송 skip(no-token) + 큐 폴백 / 재로그인 후 drain 정상
- [ ] 로그아웃 후 access 즉시 무효? (HS256 short-TTL 이므로 30분 내 재사용 가능 — 의식적 trade-off. blacklist 도입은 후속)
- [ ] 앱 강제 종료/재시작 시 Keychain 에서 토큰 복구 & 자동 로그인
