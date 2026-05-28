---
level: 2
mode: committed
status: active
last_verified: 2026-05-29
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
- 서버에 임시 이미지가 올라간 경우 분석 완료 후 TTL 기반으로 삭제한다.
- 원본, OCR 텍스트, embedding, 분석 결과를 모두 개인정보 파생 데이터로 취급한다.

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

### 2.2 위험도 기반 정책

모든 캡처를 같은 방식으로 처리하지 않는다. iOS 에서 민감도 점수를 계산하고, 점수에 따라 기본 동작을 다르게 한다.

| 점수 | 등급 | 기본 동작 |
|---:|---|---|
| 0-2 | 낮음 | 일반 업로드 가능 |
| 3-5 | 주의 | 텍스트/메타데이터 중심 업로드 |
| 6-8 | 민감 | 사용자 경고, 원본 업로드 차단 기본값 |
| 9-10 | 매우 민감 | 로컬 저장 기본값, 명시 승인 없이는 서버 분석 금지 |

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

### 3.4 NaturalLanguage

OCR 텍스트에서 사람, 장소, 조직 같은 named entity 를 탐지한다.

- Apple NaturalLanguage NER: https://developer.apple.com/documentation/naturallanguage/identifying-people-places-and-organizations
- 용도:
  - 사람 이름 탐지
  - 장소명 탐지
  - 조직명 탐지
  - 전화번호/주소/이메일 등 다른 신호와 조합해 민감도 가중

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

- 기기에만 저장
- 민감 영역 가리고 분석
- 텍스트만 분석
- 원본 분석 허용

기본값:

- 0-5점: 텍스트/메타데이터 분석
- 6-8점: 민감 영역 가리고 분석
- 9-10점: 기기에만 저장

### 5.3 설명 원칙

- 감지된 항목의 원문 전체를 다시 노출하지 않는다.
- "인증번호로 보이는 숫자"처럼 유형 중심으로 설명한다.
- 원본 업로드 허용은 매번 명시 승인으로 처리한다.
- 설정에서 "민감 캡처는 항상 로컬 저장" 옵션을 제공한다.

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

### 6.3 Agent fallback

서버 Agent 는 원본 이미지가 없을 수 있음을 기본 전제로 한다.

- 원본 이미지 없음: semantic payload + OCR 텍스트 기반 분석
- redacted 이미지 있음: redacted 이미지 + semantic payload 함께 분석
- 원본 승인됨: 임시 이미지 사용 후 TTL 삭제

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
- `CaptureFeature`: 앱 내 직접 입력 감지
- `CaptureSyncWorker`: 민감도에 따른 업로드 정책 적용
- `FeatureSettings`: 기본 privacy mode 설정

### 7.2 Backend

```text
captures/domain
- CapturePrivacy
- SensitivityLevel
- RedactionStatus

captures/presentation
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
6. `CaptureSyncWorker` 에서 `local_only`, `text_only`, `redacted_image`, `original_allowed` 분기
7. 백엔드 captures API 에 privacy metadata 저장
8. Agent/search 가 원본 이미지 없는 캡처를 정상 처리하도록 fallback 구현

---

## 9. 남은 결정 사항

- 민감도 점수 threshold 를 실제 사용자 테스트 후 조정할지 여부
- 원본 업로드 허용을 캡처별 1회 승인으로 할지, 설정에서 항상 허용을 둘지 여부
- embedding 을 민감도 6 이상에도 생성할지 여부
- 로컬 전용 캡처를 자연어 검색에 포함하려면 온디바이스 검색 인덱스를 둘지 여부
- 마스킹 이미지 생성 시 blur, solid fill, semantic overlay 중 어떤 방식을 기본으로 할지 여부
