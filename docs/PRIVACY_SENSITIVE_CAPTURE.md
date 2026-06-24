---
level: 2
mode: committed
status: active
last_verified: 2026-06-24
confidence: 0.8
owners: [송준서, 이용찬, 박세현]
description: 민감 캡처 보호 설계(on-device 감지·마스킹·최소전송)의 committed 정본. 캡처 ingestion·업로드·저장 경로를 손대기 전 반드시 읽어라 — 도메인 불변식이라 우회 금지(code-reviewer/qa-validator 가 P1 으로 잡음). 변경 시 정합성 폭포 필수.
---

# 민감 캡처 보호 설계

> 모찌는 스크린샷, 링크, 메모를 AI 가 분석하는 앱이므로 사용자가 의도하지 않은 민감 정보가 입력될 수 있다. 이 문서는 민감 이미지/텍스트를 기기에서 먼저 감지하고, 사용자에게 위험도를 알려주며, 서버에는 필요한 의미 정보만 최소 전송하는 설계를 정의한다.

---

## 1. 목표

### 1.1 보안 목표

- 원본 스크린샷은 기본적으로 iPhone 로컬 저장소에만 보관한다.
- 민감도가 높은 캡처는 서버 업로드 전에 사용자에게 경고한다.
- 서버 AI 분석이 필요하더라도 원본 식별 정보 대신 privacy-preserving semantic payload 를 전송한다.
- 서버에 올라간 캡처 이미지(업로드용 파생본 — 원본 PNG 는 위 첫 항목대로 단말 로컬 전용)는
  GCS 에 owner-scoped 로 보존한다. 분석·복구 pull·채팅 `view_item_image` 가 재조회를
  전제하므로 구 "분석 후 TTL 삭제" 목표는 폐기한다 (2026-06-12 결정 — as-built 정합:
  삭제 경로가 처음부터 없었고 복구 pull 이 보존에 의존). 삭제는 계정/항목 삭제 정책과
  함께 후속 결정.
- 원본, OCR 텍스트, embedding, 분석 결과를 모두 개인정보 파생 데이터로 취급한다 (OCR 텍스트는
  영속·ephemeral 2종으로 갈린다 — 바로 아래 표).

**텍스트 산출물 2종 — 보호 모델이 다르다 (2026-06-24).** OCR 에서 나온 화면 텍스트는 수명·노출이
다른 두 갈래로 갈린다. 둘을 섞지 않는다.

| | (a) 영속 텍스트 `mochi_items.text` | (b) 분석용 ephemeral `mochi_items.analysis_ocr_text` |
|---|---|---|
| 무엇 | 사용자가 명시 공유했거나 semantic-replace 된 의미 보존 텍스트(§2.1) | iOS Vision OCR 이 뽑은 **raw 화면 transcript**(블러 전 원본 — 카드번호 등 원문 가능) |
| 수명 | 영속(검색·노출 대상) | 추론 직전까지만 DB 에 존재, 분석 done(또는 영구 실패) 즉시 NULL(`apply_analysis`·DLQ) |
| 노출/인덱스 | 검색 haystack·API Response·채팅 상세·embedding 에 포함 | **어디에도 없음** — 검색 인덱스·Response·채팅 상세·embedding 전부 미투입(grep 게이트로 강제) |
| 민감 처리 | 민감도 게이트 유지(semantic-replace·블러) | 민감도 **점수** 게이트 미적용(이름·번호 감지로 OCR 자체를 막는 over-gating 회피 — 사용성 우선). 대신 **사용자의 명시적 정책 선택을 따른다**(§2.2 불변식) |

ephemeral OCR 의 효용은 "정보밀도 높은 일반 스크린샷에서 멀티모달이 놓치는 글자를 분석 순간에만
메운다"는 것이고, 영속/노출/인덱스가 없으므로 §9 의 노출 게이트 제거 결정과 양립한다(추가 노출
표면이 생기지 않는다).

### 1.2 제품 목표

- 사용자가 "AI 가 내 화면을 가져간다"는 불안을 느끼지 않게 한다.
- 일정, 할 일, 지식, 메모 분류 정확도를 가능한 유지한다.
- 민감도 경고는 막연한 공포가 아니라 감지된 근거를 함께 보여준다.
- 사용자가 로컬 저장, 마스킹 분석, 원본 분석 허용 중 선택할 수 있게 한다.

---

## 2. 핵심 원칙

### 2.1 원본 비공개, 의미 보존

민감 영역을 단순히 지우면 AI 분류와 검색 품질이 크게 떨어진다. 따라서 원본 값을 제거하되 의미 정보는 구조화해 보존한다.

예:

```text
원본: 신한카드 1234-5678-9012-3456 으로 스타벅스 48,000원 결제
전송: [신용카드: 신한카드 끝자리 3456] 으로 [가맹점: 스타벅스] [금액: 48000원] 결제
```

서버는 전체 카드번호를 보지 못하지만, 검색과 요약에 필요한 결제 맥락은 유지한다.

> **개인화 프로필도 같은 원칙을 따른다.** `user_profiles`(`DOMAIN_DESIGN.md §3`)는 최근 입력의
> raw 내용이 아니라 추상 요약만 저장하며, `owner_id` 로 격리되어 cross-tenant 누설을 차단한다.
> 두 관점 모두 같다 — agent loop 분석에 주입하는 `summary`("관심사·평소 분류 성향")도, 채팅에
> 배경·톤으로 주입하는 `chat_summary`("이 사람이 누구인지" 페르소나)도 **입력은 `summary`/
> `user_memo` 만**(raw 캡처 text 제외, `RefreshUserProfile`). 채팅 주입은 패턴 추상이지 저장 원문이
> 아니므로, 모델은 이를 외부 web 쿼리에 원문째 재표현하지 않는다(§10).

### 2.2 위험도 기반 정책

모든 캡처를 같은 방식으로 처리하지 않는다. iOS 에서 민감도 점수를 계산하고, 점수에 따라 기본 동작을 다르게 한다.

| 점수 | 등급 | 기본 동작 |
|---:|---|---|
| 0-2 | 낮음 | 일반 업로드 가능 |
| 3-5 | 주의 | 텍스트/메타데이터 중심 업로드 |
| 6-8 | 민감 | 사용자 경고, 원본 업로드 차단 기본값 |
| 9-10 | 매우 민감 | 로컬 저장 기본값, 명시 승인 없이는 서버 분석 금지 |

> **ephemeral OCR 불변식 (2026-06-24).** 분석용 `analysis_ocr_text`(§1.1 (b))는 민감도 점수가
> 아니라 **사용자가 고른 이미지 정책에 종속**한다 — effective policy 가 `originalUpload`(비민감
> 기본값, 또는 사용자가 원본 업로드를 명시 승인)일 때만 동봉하고, `blurredUpload`·`localOnly` 는
> 미동봉한다. 근거: OCR 은 블러 전 raw 라 사용자가 이미지에서 가리기로 한 값(카드번호 등)을 그대로
> 담는다 — 사용자가 가린 것을 OCR 로 서버에 흘리지 않는다(§9 블러 정합). `localOnly` 는 이미지도
> 안 보내므로 당연히 OCR 도 안 보낸다. iOS 는 OCR 을 큐 JSON + Realm **isolated 컬럼**(`privacy` 와
> 동일하게 격리 — 메인 업로드 워커가 Realm 에서 읽어 정책 게이트를 적용하므로 보관하되, 검색·노출·
> 다른 화면 어디서도 읽지 않는다)에 싣고, originalUpload 캡처에만 추출한다(blurred/localOnly 는 OCR
> 자체를 만들지 않음). 서버는 추론 직후 삭제(영속 정본 없음), 로그는 길이·존재 여부(부울)만 — OCR
> 원문은 로그·메트릭에도 남기지 않는다. (on-device 영속이 추가 노출은 아니다 — originalUpload 캡처는
> 원본 이미지도 단말에 보존되므로 OCR 은 그 부분집합. 업로드 후 Realm OCR 정리[clear]는 후속 위생 옵션.)

### 2.3 Intent 별 보존 필드

민감정보 제거 기준은 캡처의 의도에 따라 다르다.

| Intent | 보존할 의미 정보 | 제거/치환할 정보 |
|---|---|---|
| `schedule` | 날짜, 시간, 장소, 제목, 참석자 수 | 전화번호, 이메일, 개인 식별자 |
| `todo` | 마감일, 행동 동사, 대상, 우선순위 | 인증코드, 계정정보, 보안문구 |
| `knowledge` | 제목, 핵심 문장, URL 도메인, 주제어 | 토큰이 포함된 URL query, 계정명 |
| `memo` | 사용자가 작성한 텍스트 | 설정에 따라 로컬 전용 가능 |

---

## 3. iOS 네이티브 감지 리소스

### 3.1 Vision OCR

이미지에서 텍스트와 위치 정보를 추출한다.

- Apple Vision text recognition: https://developer.apple.com/documentation/vision/recognizetextrequest
- 용도:
  - 스크린샷 OCR
  - 텍스트별 bounding box 확보
  - 마스킹 영역 계산
  - 감지 근거 생성

### 3.2 VisionKit / Live Text 계열

이미지나 카메라 입력에서 텍스트, URL, 주소, 전화번호, 날짜, 바코드 같은 항목을 인식한다.

- Apple VisionKit: https://developer.apple.com/documentation/visionkit
- DataScannerViewController: https://developer.apple.com/documentation/visionkit/datascannerviewcontroller
- 용도:
  - Live Text 수준의 데이터 탐지
  - URL, 주소, 전화번호, 바코드 등 UI 상호작용 가능한 데이터 감지
  - 카메라 기반 입력이 생길 경우 실시간 경고

### 3.3 NSDataDetector

OCR 텍스트에서 Apple 기본 데이터 패턴을 탐지한다.

- Apple NSDataDetector: https://developer.apple.com/documentation/foundation/nsdatadetector
- 탐지 대상:
  - 전화번호
  - 링크
  - 주소
  - 날짜/시간
  - 운송 정보

주의: `NSDataDetector` 는 검증기가 아니라 탐지기다. 불확실한 후보를 버릴 수 있으므로 단독 판정이 아니라 민감도 점수의 신호로 사용한다.

### 3.4 NaturalLanguage NER — 제외 (한국어 미지원)

Apple NaturalLanguage 의 `.nameType`(named entity recognition)은 **한국어를 지원하지 않는다**
(한국어는 Language/Script/TokenType 스킴만). 한국어 NER 커스텀 모델(BERT/임베딩 계열)은 Share
Extension 120MB 메모리 한도와 충돌한다. 따라서 **NER(사람·장소·조직 이름)은 사용하지 않는다.**

근거: 민감 캡처 판정의 핵심(주민번호·카드·OTP·계좌·토큰)은 검증기(체크섬)+문맥 근접으로 충분히
잡히고, 이름은 본래 가중치가 가장 낮다(§4.2). NER 부재가 전체 감지력을 거의 손상시키지 않는다.

### 3.5 한국형 룰 기반 탐지

네이티브 API 만으로는 한국형 개인정보와 서비스 문맥을 충분히 다루기 어렵다. 아래 항목은 직접 룰을 둔다.

- 주민등록번호 후보
- 휴대폰 번호
- 이메일
- 카드번호 후보 + Luhn check
- 계좌번호 후보 + 은행명 문맥
- 인증번호/OTP/보안코드 문맥
- 비밀번호/API key/token 문맥
- 사업자등록번호
- 운전면허/여권번호 후보
- 병원/처방/진단/보험 문맥
- 급여/세금/계약/송금/결제 문맥
- 메신저/메일/DM/알림 화면 문맥
- QR 코드/바코드

---

## 4. 민감도 스코어링

### 4.1 Signal 모델

```swift
public struct SensitivitySignal: Equatable, Sendable {
    public var type: SensitivityType
    public var score: Int
    public var textRange: Range<String.Index>?
    public var boundingBox: CGRect?
    public var reason: String
}

public enum SensitivityType: String, Sendable {
    case nationalID
    case cardNumber
    case bankAccount
    case otpCode
    case passwordOrToken
    case phoneNumber
    case email
    case address
    case personName
    case organization
    case medical
    case finance
    case legalOrContract
    case barcode
}
```

### 4.2 기본 가중치

| Signal | 점수 |
|---|---:|
| 주민등록번호 후보 | 5 |
| 카드번호 Luhn 통과 | 5 |
| API key/token/password 문맥 | 5 |
| 인증번호/OTP 문맥 + 4-8자리 숫자 | 4 |
| 병원/처방/진단/보험 문맥 | 4 |
| 계좌/송금/은행 문맥 | 3 |
| 주소 | 3 |
| 급여/세금/계약 문맥 | 3 |
| QR/바코드 | 2 |
| 전화번호 | 2 |
| 이메일 | 2 |
| 사람 이름 | 1 |
| 조직명 | 1 |

### 4.3 조합 가중치

단일 신호보다 조합이 중요하다.

- 사람 이름 + 전화번호 + 주소: 추가 3점
- 은행명 + 계좌번호 후보 + 금액: 추가 3점
- 인증번호 문구 + 짧은 숫자 + 만료시간 문구: 추가 3점
- 병원명 + 진단/처방 문구 + 사람 이름: 추가 4점
- 회사명 + 계약/급여/세금 문구: 추가 3점

최종 점수는 10점으로 cap 한다.

---

## 5. 사용자 경험

### 5.1 경고 문구

점수 6 이상이면 저장/분석 전에 경고한다.

```text
민감한 정보가 포함된 화면일 수 있어요.
전화번호, 주소, 인증번호로 보이는 항목을 찾았어요.
```

### 5.2 선택지

저장 시점에 **고신뢰(검증 통과) 민감 신호**가 감지되면 `PrivacyChoiceView` 시트로 묻는다 —
저신뢰 신호(문맥 없는 짧은 숫자·단독 전화/이메일)는 점수에만 기여하고 저장 흐름을 막지 않아
false positive 의 UX 마찰을 차단한다.

- **원본 그대로 저장** (`originalUpload`)
- **민감한 곳 가리고 저장** (`blurredUpload`) — 감지 영역만 가우시안 블러. 선택 시 결과 미리보기(crossfade + 자물쇠 배지)로 안심시킨다.
- **이 기기에만 저장** (`localOnly`) — 서버에 이미지 미전송, 폰에만 보관.

기본 추천(`SensitivityScorer.recommendedPolicy`):

- 0-5점(low/caution): 원본 그대로
- 6-8점(sensitive): 민감한 곳 가리고 (기본 추천)
- 9-10점(highlySensitive): 이 기기에만

로컬에는 **항상 원본 PNG 를 보존**하고(`§1.1`), 서버에는 정책본(블러본/원본/미전송)을 올린다.
블러 정책인데 블러본 생성에 실패하면 원본 유출을 막기 위해 업로드를 스킵한다.

**가림 에디터 인터랙션**(`PrivacyChoiceView` / `RedactionImageEditor`): 블러 정책에선 미리보기가 라이브
에디터가 된다 — OCR 줄을 탭=토글 / 쓸기=칠하기로 가린다. 작은 글자를 확인·미세조정하도록 핀치 확대
(1~5x)·팬·집중 보기(헤더/옵션을 접어 캔버스 확대)를 제공한다. 표시 좌표계는 이미지 **실제 비율**로
잠가(`scaledToFit`) 마스크·테두리·히트테스트가 표시 이미지와 정확히 일치한다(극단 비율 캡처에서 가림
박스가 글자와 어긋나 보이던 표시 버그 수정, 2026-06-24). **저장 블러본은 정규화 rect 로 굽기 때문에
줌/표시 변경과 독립**이라 영향받지 않는다.

**가림 화면 재진입**: 캡처 화면의 "가리기 / 가린 곳 고치기" 진입점으로 가림 화면에 다시 들어가 더
가리거나 끌 수 있다(자동 감지가 놓친 줄을 보태거나 마음이 바뀐 경우의 안전 보정). 직전에 켠 영역은
**rect 기준으로 복원**해 자동 감지 영역뿐 아니라 **사용자가 손으로 칠한 줄도 보존**한다 — 불변식:
사용자가 가린 것은 재진입에서 풀리지 않는다. always-localOnly(§5.3) 켜짐 시엔 진입점을 띄우지 않는다.

### 5.3 설명 원칙

- 감지된 항목의 원문 전체를 다시 노출하지 않는다.
- "인증번호로 보이는 숫자"처럼 유형 중심으로 설명한다.
- 원본 업로드 허용은 매번 명시 승인으로 처리한다.
- 설정에서 "민감 캡처는 항상 로컬 저장" 옵션을 제공한다(2026-06-22 구현 — 설정 토글 → `SensitiveCapturePreference`(AppGroup UserDefaults 공유) → ShareExtension 이 읽어, 고신뢰 민감 신호 감지 시 선택 시트 없이 `localOnly` 로 저장. 사용자가 시트에서 localOnly 를 고른 것과 동일 상태라 저장 경로 불변. 감지 시 "이 기기에만 저장됨" 비차단 확인 토스트는 후속 §5.1 폴리시로 분리).
- **APNs alert / Live Activity(push-to-start) payload 는 백엔드 분석 결과(summary·후보 라벨)만 싣는다** — 원본 캡션·이미지·App Group 로컬 경로는 제외한다(LA 썸네일은 payload 가 아니라 단말 디스크에서 직접 read, push-to-start 의 `thumbnailRelativePath=null`). alert push 가 기존부터 잠금화면에 summary 를 노출하므로 LA push-to-start 도 노출 정보원이 동일하다(회귀 아님, 팀 결정 2026-06-09). 민감도별 summary 마스킹은 alert·LA 공통 후속 과제로 분리.

---

## 6. 서버 전송 Payload

### 6.1 Privacy-preserving semantic payload

서버에는 원본 이미지 대신 구조화된 의미 표현을 보낸다.

```json
{
  "text": "[가맹점: 스타벅스] [금액: 48000원] 결제 완료. [카드: 신한카드 끝자리 3456]",
  "privacy": {
    "sensitivityScore": 7,
    "sensitivityLevel": "sensitive",
    "redactionStatus": "semantic_replaced",
    "originalImageUploaded": false
  },
  "redactions": [
    {
      "type": "cardNumber",
      "replacement": "[카드: 신한카드 끝자리 3456]",
      "risk": "high"
    }
  ]
}
```

### 6.2 백엔드 저장 필드

도메인 모델과 API 스키마에는 아래 필드가 필요하다.

```text
sensitivity_score: int
sensitivity_level: low | caution | sensitive | highly_sensitive
redaction_status: none | detected | masked | semantic_replaced | user_approved_original
original_image_uploaded: bool
privacy_policy: local_only | text_only | redacted_image | original_allowed
```

> 분석용 ephemeral OCR 은 위 영속 필드와 별개의 **transient ingest 입력**이다 — `MochiItemCreateRequest.
> analysisOcrText`(Create 에만, nullable)로 들어와 `mochi_items.analysis_ocr_text` 에 잠깐 머물다 추론
> 후 NULL. 위 semantic payload(`text`)에 합쳐지지 않는다(별도 필드). 정본·동봉 정책은 §1.1 (b)·§2.2 +
> `ARCHITECTURE.md` MochiItem ingestion.

### 6.3 Agent fallback

서버 Agent 는 원본 이미지가 없을 수 있음을 기본 전제로 한다.

- 원본 이미지 없음: semantic payload + OCR 텍스트 기반 분석 (여기 "OCR 텍스트" = §2.1 의 영속
  semantic `text` 필드. 분석용 ephemeral `analysis_ocr_text`(§1.1 (b))는 `localOnly` 에 미동봉이라
  이 경우 포함되지 않는다 — §2.2 불변식)
- redacted 이미지 있음: redacted 이미지 + semantic payload 함께 분석 (`blurredUpload` 도 ephemeral OCR 미동봉)
- 원본 승인됨: 업로드 이미지로 분석 (GCS 보존 — §1.1 의 TTL 폐기 결정. `originalUpload` 에서만 ephemeral OCR 동봉)

---

## 7. 모듈 제안

### 7.1 iOS

```text
CorePrivacy
├── ImageTextExtractor
├── SensitiveDataDetector
├── SensitivityScorer
├── RedactionPlanner
└── PrivacyPreservingPayloadBuilder
```

연동 지점:

- `ShareExtension`: inbound payload 생성 전 1차 감지
- `CommitBackTapCaptureIntent`: 백탭 snippet 의 캡쳐 분기 1차 감지 지점 (계획 — pending PNG 를 영구 `captures/` 로 promote 하기 전에 호출. **MVP §8 구현 순서 기준 아직 미통합** 이며, 현재 intent 는 감지 없이 promote 한다. snippet `openAppWhenRun = false` background process 에서 Vision OCR 비용을 어디까지 허용할지는 별도 결정 필요)
- `BackTapModalFeature`: 백탭 snippet 의 메모 분기 — 사용자 입력 텍스트에 대한 1차 감지 (계획). 메모 분기는 PNG 가 즉시 폐기되므로 OCR 대상은 아니며, 텍스트 내 인증번호/카드번호 등 패턴 감지 위주
- `MochiItemFeature`: 앱 내 직접 입력 감지
- `MochiItemSyncWorker`: 민감도에 따른 업로드 정책 적용
- `FeatureSettings`: 기본 privacy mode 설정

### 7.2 Backend

```text
mochi_items/domain
- CapturePrivacy
- SensitivityLevel
- RedactionStatus

mochi_items/presentation
- CapturePrivacyRequest
- CapturePrivacyResponse

agent/application
- semantic payload only 분석 경로
```

---

## 8. MVP 구현 순서

1. iOS Vision OCR 로 텍스트와 bounding box 추출
2. `NSDataDetector` 로 URL/전화번호/주소/날짜 탐지
3. 한국형 룰로 인증번호, 카드번호, 계좌, 토큰 문맥 탐지
4. `SensitivityScorer` 로 0-10점 계산
5. 6점 이상 경고 UI 표시
6. 저장 시점 선택 시트(`PrivacyChoiceView`) — 블러 선택 시 결과 미리보기로 안심
7. `MochiItemSyncWorker`·`ShareExtDirectUpload` 에서 `originalUpload`/`blurredUpload`/`localOnly` 분기 (로컬 원본 보존, 서버엔 정책본; 블러본 실패 시 업로드 스킵)
8. Agent/search 가 이미지 없는(`localOnly`) 캡처를 정상 처리하도록 fallback (기존 이미지 optional 경로 재사용)

---

## 9. 남은 결정 사항

- 민감도 점수 threshold·가중치를 실제 사용자 테스트 후 조정할지 여부 (`SensitivityScorer` §4)
- embedding 을 민감도 6 이상에도 생성할지 여부 (블러 업로드 시 블러본으로 embedding 생성됨)
- 로컬 전용(`localOnly`) 캡처를 자연어 검색에 포함하려면 온디바이스 검색 인덱스를 둘지 여부
- **백탭 캡처(`CommitBackTapCaptureIntent` — UI 없는 background intent)의 민감 처리** — 저장 시점에 선택 시트를 띄울 수 없는 구조적 제약. 자동 블러(보수적 안전) vs 앱 진입 후 사후 조정 중 팀 결정 필요. **분석용 ephemeral OCR 동봉도 같은 선상에서 deferred** — 백탭은 현재 sensitive scan 자체를 안 거쳐 OCR 이 없다(동봉하려면 업로드 직전 재스캔 필요). 백탭 민감 처리가 정해질 때 함께 결정(2026-06-24, ephemeral OCR PR 은 ShareExt·메인앱 큐 경로만 우선 구현).

> **노출 게이트는 블러 저장으로 해소됨 (2026-06-21 결정).** 민감 영역을 저장 시점에 가우시안
> 블러 처리해 업로드하므로 **서버에 올라간 이미지 자체가 안전하다**. 따라서 다운스트림 노출
> 표면(`view_item_image`·`similar`·즐겨찾기·사진앱 저장·능동 회수 알림)에 개별 민감 게이트를
> 두지 않는다 — 게이트(각 표면마다 `sensitivity_level` 검사) 대신 "애초에 안전한 이미지를 올린다"로
> 문제를 근본 제거한다(§2). 마스킹 방식은 **가우시안 블러**로 확정(deblur/재-OCR 방지 위해 강하게).
> 서버 privacy 메타데이터(`sensitivity_*`)는 추가하지 않는다 — 서버는 올라온 이미지가 진실이며
> 블러본/원본을 구분할 필요가 없다(Simplicity First).

---

## 10. 채팅 web 툴의 외부 반출 경계 (2026-06-10)

채팅 탭의 LLM 루프는 `web_search`(Tavily)·`web_fetch` 로 외부에 닿는다 — 사용자의 기록이
**제3자(검색 프로바이더·임의 웹서버)로 새어 나갈 수 있는 유일한 채팅 경로**라 경계를 명시한다.

- **검색 쿼리에 기록 원문 금지** — 시스템 프롬프트 행동규칙이 "기록 원문·식별 가능 파생
  표현을 데이터 경계 밖으로 나가는 쿼리에 넣지 않는다"를 강제한다 (`chat_prompts.py`,
  chat@v1 부터 선제 명시). 툴 파라미터 설명에도 동일 규칙을 중복 명시 — 일반화된 쿼리로
  재표현(rephrase)하게 한다. 프롬프트 기반 가드(③티어)라는 한계는 인지 — 기계 강제가
  필요해지면 쿼리 PII 필터를 후속으로 검토.
- **주입된 페르소나 프로필(chat@v11)도 같은 경계** — `chat_summary` 가 system prompt 에
  배경·톤으로 들어가지만(§2.1), 이는 "기록 원문"과 같은 데이터라 위 규칙이 그대로 적용된다.
  주입 슬롯 문구(`_profile_block`)가 "사실 출처 아님·【item】 인용 금지·구체 사실은 검색으로
  회수"를 못박아, 모델이 프로필 내용을 web 쿼리로 반출하거나 근거로 단정하지 않게 한다.
- **web_fetch 는 기존 SSRF 가드 무수정 재사용** — agent `WebFetchTool`(호스트 블록리스트·
  사설/링크로컬 IP 차단·redirect 마다 재검증·사이즈/MIME 상한)을
  `agent.application.tool_factories` 경유로 그대로 쓴다. 채팅 쪽 래퍼는 텍스트화·truncation 만.
- **web_search 는 고정 호스트(api.tavily.com)** — 모델이 임의 호스트로 요청을 보낼 수 없다.
  임의 URL 접근은 전부 가드 있는 web_fetch 로만 가능하다.
- **`view_item_image`(2026-06-12) 는 외부 반출 경로가 아니다** — 채팅 모델이 기록의 업로드
  이미지를 다시 보는 툴이지만, 분석 파이프라인과 동일하게 Vertex AI 가 `gs://` 를 직접
  read 한다(백엔드 bytes 무접촉, 제3자 전송 없음 — 데이터 경계는 분석 시점과 동일).
  민감도 게이트는 불필요 — 민감 영역은 저장 시점에 블러 처리되어 서버 이미지 자체가
  안전하다(§2, §9 결정). 채팅이 다시 보는 이미지도 블러본이라 추가 게이트가 필요 없다.
  이미지는 현재 턴 in-memory 전용 — 과거 턴 히스토리에 재주입되지 않으며 대화 DB 에
  이미지 URI 가 영속되지 않는다.
