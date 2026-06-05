---
level: 3
mode: log
status: active
last_verified: 2026-05-29
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
- [ ] developer.apple.com → Identifiers → 모찌 App ID 선택
- [ ] **Sign In with Apple** capability 체크 → Save
- [ ] Bundle ID: `app.mochi` (Project.swift `bundleIdPrefix`)
- 결과: Xcode 빌드 시 `App.entitlements` 의 `com.apple.developer.applesignin` 권한이 매칭되어 빌드 가능

### 1.1b Keychain Sharing capability (ShareExt 직접 전송 — PR-A)
- [ ] developer.apple.com → Identifiers → `app.mochi` + `app.mochi.ShareExtension` 둘 다 **Keychain Sharing** capability 체크 → Save
- [ ] keychain access group `$(AppIdentifierPrefix)app.mochi` (App·ShareExtension entitlements 에 박힘 — 코드는 kSecAttrAccessGroup 생략, entitlement 첫 그룹 자동 공유)
- 결과: ShareExtension 이 메인 앱 Keychain 의 access token 을 읽어 무이미지(URL/텍스트) 캡처를 서버에 best-effort 선반영(큐는 항상 적재 — 로컬·동기화·유실방지의 진실원천). **dev 재로그인 1회 필요**(entitlement 변경으로 기존 keychain 그룹 전환 — 자동 마이그레이션 안 함). 시뮬레이터는 자동 서명이라 무관, 실기기 빌드는 §1.2 재발급 선행.

### 1.2 Provisioning Profile 재발급
- [ ] App ID 변경(Sign In with Apple·**Keychain Sharing**) 후 development / distribution provisioning profile 재발급
- [ ] Xcode → Signing & Capabilities → 새 profile 자동 선택 확인

### 1.3 (옵션) 백엔드 → Apple revocation 연동
백엔드에서 사용자 계정 삭제 시 Apple 측의 refresh token 도 revoke 하려면:
- [ ] Apple Developer → Keys → 새 키 생성 (Sign In with Apple 서비스 활성)
- [ ] `.p8` 파일 다운로드 (1회만 가능) — **절대 git에 커밋 금지**
- [ ] Key ID, Team ID 메모
- 본 마일스톤에선 자체 DB 의 refresh token 만 revoke 하면 충분. Apple 측 revoke 는 후속.

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

백탭 캡처는 **사용자가 단축어 앱에 설치하는 iCloud 단축어**가 `Take Screenshot → 이미지 변환(PNG) → 모찌 화면 캡쳐` 로 동작한다. `CaptureScreenshotIntent` (`openAppWhenRun = false`) 가 PNG 를 `pending-backtap/<captureID>.png` 에 stash 한 뒤 `ShowsSnippetView` 로 `BackTapSnippetView` 를 외부 앱 위에 카드로 띄운다 — **모찌 앱은 깨우지 않는다** (사용자 컨텍스트 보존). 카드의 두 버튼 (`CommitBackTapCaptureIntent` / `OpenBackTapMemoIntent`) 이 분기를 결정. 단축어 자체는 코드가 아니므로 1회 수동 제작 + iCloud 공유 URL 발급이 필요하다 (다만 빌더 스크립트가 `/tmp/build_mochi_shortcut.py` 에 존재 — handoff 문서 §11 참고).

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
  - [x] 발급된 URL 을 `BackTapPage` "단축어 등록하기" CTA 가 여는 값으로 교체. 현재 적용된 URL: `https://www.icloud.com/shortcuts/ff449fd3fe924e81bb0e7e931360701b` (`OnboardingView.swift` 의 `handlePrimaryTap()`).
- [ ] **버전 관리**: 단축어 정의나 `CaptureScreenshotIntent` 시그니처가 바뀌면 iCloud URL 도 함께 갱신. CHANGELOG 의 `ios` 범위로 한 줄 남길 것.

⚠️ `Show Preview ON` 또는 `이미지 변환` 액션 누락은 자동화를 깬다. 온보딩 가이드에서 두 가지 다 명시.

### 3.1 Info.plist URL Scheme (Google)
- [x] `Targets/App/Support/Info.plist` 에 `CFBundleURLTypes` 등록 (Reversed client ID)
- 실제 값은 §2.1 의 Reversed client ID 로 치환되어야 함.
- ⚠️ 현재는 `PLACEHOLDER_REVERSED_CLIENT_ID` 로 들어가 있음. 콘솔에서 값 받은 뒤 교체.

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
# === Self-issued JWT ===
AUTH_ACCESS_SECRET=<openssl rand -base64 48>     # 32+ chars 권장
AUTH_ACCESS_TTL_SECONDS=1800                     # 30분
AUTH_REFRESH_TTL_SECONDS=2592000                 # 30일
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
```

### 4.1 비밀값 생성
- [ ] `AUTH_ACCESS_SECRET` 은 `openssl rand -base64 48` 로 생성
- [ ] dev / staging / prod 마다 다른 값 사용
- [ ] 운영에서는 AWS Secrets Manager / GCP Secret Manager 등으로 격상

### 4.2 시크릿 회전 정책
- [ ] `AUTH_ACCESS_SECRET` 교체 시 모든 사용자가 강제 재로그인됨 (refresh token 도 access 만 무효, refresh는 DB hash 매칭이라 영향 없음). 보안 사고 시 즉시 회전.

### 4.3 PlatformContext / Instagram oEmbed
- [x] YouTube/X/Instagram URL 은 Agent `platformContext` 로 먼저 그라운딩 (2026-05-30).
- [ ] Instagram 공식 oEmbed 를 운영에서 쓰려면 Meta app token + oEmbed 권한/리뷰를 확보하고 `INSTAGRAM_OEMBED_ACCESS_TOKEN` 을 설정.
- [ ] 토큰 미설정 상태에서는 Instagram OG fallback + screenshot Vision context 를 조합해 분석 정확도를 보강.

---

## 5. 운영 / 보안 후속

- [ ] **Rate limit**: `/auth/apple`, `/auth/google`, `/auth/refresh` 에 IP + subject 단위 rate limit (slowapi 등). brute force/refresh storm 방어.
- [ ] **Audit log**: 로그인 성공/실패, refresh rotation, reuse_detected 이벤트를 structlog 의 `auth.*` 카테고리로 남기고 알람 대상으로 등록.
- [ ] **계정 삭제 (Right to be Forgotten)**: `users.deleted_at` 세팅 + email 익명화(`deleted+{id}@invalid.local`) + 모든 refresh token revoke + (옵션) Apple `revoke` 엔드포인트 호출.
- [ ] **Apple App Store 심사 요구사항**: Sign In with Apple 을 제공하면 다른 third-party 로그인(Google 등) 이 있을 때 **반드시** 함께 제공해야 함 (App Review §4.8). 모찌는 이미 둘 다 제공 ✅.
- [ ] **로그인 화면 약관/개인정보처리방침 링크**: 실제 URL 로 교체 (현재 placeholder).
- [ ] **iOS Keychain access control**: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 로 device-bound + 백업 제외(이미 적용 예정). Face ID gate 는 옵션.

### 5.1 민감 캡처 보호

상세 설계: [민감 캡처 보호 설계](./PRIVACY_SENSITIVE_CAPTURE.md)

- [ ] iOS `CorePrivacy` 모듈 추가: `ImageTextExtractor`, `SensitiveDataDetector`, `SensitivityScorer`, `RedactionPlanner`.
- [ ] Vision OCR 로 스크린샷 텍스트와 bounding box 추출.
- [ ] `NSDataDetector` 로 URL, 전화번호, 주소, 날짜/시간 탐지.
- [ ] `NaturalLanguage` 의 named entity recognition 으로 사람, 장소, 조직 후보 탐지.
- [ ] 한국형 룰 기반 탐지 추가: 주민등록번호 후보, 카드번호 Luhn check, 계좌/은행 문맥, 인증번호/OTP, API key/token, 병원/처방/계약/급여 문맥.
- [ ] 민감도 점수 0-10 산출 및 `low/caution/sensitive/highly_sensitive` 등급화.
- [ ] 점수 6 이상 캡처에 사용자 경고 UI 표시: `기기에만 저장`, `민감 영역 가리고 분석`, `텍스트만 분석`, `원본 분석 허용`.
- [ ] `MochiItemSyncWorker` 에 업로드 정책 분기 추가: `local_only`, `text_only`, `redacted_image`, `original_allowed`.
- [ ] 서버 mochi_items API 에 privacy metadata 추가: `sensitivity_score`, `sensitivity_level`, `redaction_status`, `original_image_uploaded`, `privacy_policy`.
- [ ] Agent/search 가 원본 이미지 없는 semantic payload 를 정상 분석하도록 fallback 구현.
- [ ] 민감 캡처 embedding 생성/삭제 정책 결정 및 계정 삭제 플로우에 반영.

---

## 6. 검증 시나리오 (수동)

릴리스 전 실기 검증:
- [ ] Apple 로그인 첫 인가: fullName 받아 users.display_name 채워짐
- [ ] Apple 재로그인: fullName 없이도 같은 user_id 매칭 (auth_accounts.subject 기준)
- [ ] Apple "Hide my email" 사용자 정상 로그인
- [ ] Google 로그인 신규/재로그인
- [ ] 같은 이메일을 Apple + Google 둘 다로 로그인 시 어떻게 묶을지: **이번 마일스톤은 분리 (provider × subject 별 user)**. 향후 계정 통합 UI 가 필요해지면 별도 작업.
- [ ] access 만료(30분) 자동 갱신 (UI 끊김 없이)
- [ ] refresh 도난 시뮬레이션: 같은 refresh 두 번 사용 → 두 번째에 401 + family 전체 revoke 확인
- [ ] 로그아웃 후 access 즉시 무효? (HS256 short-TTL 이므로 30분 내 재사용 가능 — 의식적 trade-off. blacklist 도입은 후속)
- [ ] 앱 강제 종료/재시작 시 Keychain 에서 토큰 복구 & 자동 로그인
