# 모찌 (MOCHI)

> Multimodal AI 기반 스크린샷·링크·기록 통합관리 에이전트

2026 SW중심대학 디지털 경진대회 SW부문 출품작 / 팀 **세얼간이**

스크린샷·링크·메모를 남기는 순간은 최대한 가볍게, 필요한 기억은 모찌가 알아서 다시 떠올려주는 iOS 서비스입니다. 캡처 한 번이면 모찌가 내용을 분석해 일정·할 일·지식·메모로 분류하고, 캘린더·미리알림 연동과 능동 회수 알림까지 이어집니다.

## 구성

| 디렉터리 | 역할 | 안내 |
| --- | --- | --- |
| [`mochi-ios/`](mochi-ios/) | iOS 클라이언트 — SwiftUI + TCA, Tuist | [README](mochi-ios/README.md) |
| [`mochi-backend/`](mochi-backend/) | API 서버 — FastAPI, Modular Monolith + Hexagonal | [README](mochi-backend/README.md) |

빌드·실행·테스트 방법은 각 프로젝트 README에 있습니다. 두 프로젝트의 API 계약 단일 원천은 `mochi-backend/openapi.json`이며, iOS 클라이언트 코드는 여기서 swift-openapi-generator로 생성됩니다.
