---
level: 3
mode: log
status: active
last_verified: 2026-06-13
confidence: 0.8
owners: [송준서]
title: 쇼핑 카드 favicon 교체 + 쿠팡/네이버 딥링크·제휴 수수료 BM 조사
description: 기록 상세 "지금 할 수 있어요"의 쿠팡·네이버 검색 카드 작업 로그. ① 단색 bag.fill 아이콘을 favicon 으로 교체(코드 변경·머지됨). ② 딥링크 가능성 조사(결론 universal link). ③ 제휴 수수료(어필리에이트) BM 타당성 조사 — 쿠팡 성립·네이버 부적합·약관 리스크. 쇼핑 카드 수익화를 검토·결정하기 전 읽어라. BM 부분은 아직 탐색 단계(코드 변경 없음, 외부 가입·심사 선행 필요).
---

# 쇼핑 카드 favicon + 제휴 BM 조사 — 2026-06-13

## 한 일

### 1. 쇼핑 검색 카드 아이콘 favicon 교체 (코드 변경 — 머지 대기)
- `DetailView.swift` 의 쿠팡·네이버 검색 행 아이콘을 단색 `bag.fill` → favicon 으로 교체.
- 기존 `FaviconTile`(DesignSystem, Kingfisher, `host/favicon.ico` + 보라 첫글자 폴백) 재사용. `DetailLinkRow` 에 `usesFavicon` 플래그 추가, purple50 타일 레이아웃은 보존.
- `primaryURL` 원본 행(Instagram에서 보기 등)은 현행 SF Symbol 유지(scope 한정).
- 검증: `tuist build FeatureDetail` → Build Succeeded. CHANGELOG `## 2026-06-13 — ios` 기록함.
- **미확인**: 실기기에서 `search.naver.com/favicon.ico` 가 실제 로드되는지(404 면 보라 'S' 폴백). `xcodebuild` 라 Claude 가 직접 못 띄움 → 사용자 실기기 확인 필요.

### 2. 딥링크 조사 (코드 변경 없음)
- 질문: 쿠팡·네이버 검색을 앱으로 딥링크할 수 있나?
- **방법 A — universal link(현행 https)**: 앱 설치 시 OS 가 AASA 등록 경로면 앱으로 자동 라우팅. 실제 AASA `curl` 조회 결과:
  - `link.coupang.com` ✅ 등록 경로 `/re/*` `/re2/*` 뿐 (= 파트너스 추적 딥링크 전용). `www`/`m.coupang.com` 은 403 봇차단으로 미확인.
  - `shopping.naver.com`·`m.shopping.naver.com` = "페이지 없음"(파일 없음), `search.naver.com` = 404. → **네이버 검색은 universal link 미등록 → 사파리로 열림.**
- **방법 B — custom scheme**: 네이버 `naversearchapp://inappbrowser?url=<검색URL>&target=new&version=6` 로 인앱브라우저 가능(비교적 안정). 쿠팡 `coupang://` 은 상품/카테고리용만 알려짐, 검색 scheme 공식 문서 없음(리스크). scheme 은 Info.plist `LSApplicationQueriesSchemes` 등록 + canOpenURL 게이트 + https 폴백 필요.
- 결론: 검색 쿼리만 보유(상품 ID 없음)라 딥링크 단독 실익 작음. **단, 아래 BM 의 파트너스 추적 링크(`link.coupang.com/re/*`)가 곧 universal link 라 딥링킹+수익이 한 번에 해결됨(아래 참고).**

### 3. 제휴 수수료(어필리에이트) BM 조사 (코드 변경 없음 — 탐색 단계)
- 배경: 사용자 의도는 쇼핑 카드 링크로 제휴 수수료 수익(쿠팡파트너스 류) 창출.
- **쿠팡 파트너스 — 성립함.**
  - 수수료 카테고리별 1~3%(뷰티·패션·육아 3 / 식품·생활 2 / 가전·디지털 1).
  - 등록 가능 매체에 **모바일 앱 URL 포함**. 딥링크 API(`coupangUrls` 임의 쿠팡 URL 배열 → `shortenUrl`/추적링크, `subId` 채널추적) 로 **검색 URL 도 추적 링크로 변환 가능**.
  - 현재 우리 `coupang.com/np/search?q=` 는 추적 ID 없어 **수수료 0**. → 파트너스 딥링크 API 변환 필요.
  - 변환 결과 `link.coupang.com/re/...` 는 universal link 라 앱 자동 진입까지 동시 해결.
- **네이버 — 구조 부적합.**
  - 네이버 쇼핑 커넥트 = 공식 어필리에이트지만 **스마트스토어 등록 상품 + 개인 크리에이터 후기 콘텐츠** 모델. 일반 검색→링크엔 직접 안 맞음.
  - 일반 검색 제휴 공식 없음. 제3자 CPS(링크프라이스 등) 우회는 커버리지·약관 복잡. → **MVP 에선 쿠팡만 수익화, 네이버는 단순 검색 링크 유지** 권고.
- **약관/법 리스크 3가지**:
  1. 자동 리다이렉트 금지("스치기만 해도 진입" = 30일 수익 몰수+계정 해지). 우리는 **명시적 탭 구조라 안전**, 단 자동 열기/프리페치 금물.
  2. 대가성 문구 표기 의무(공정위) — "쿠팡파트너스 활동으로 수수료를 받습니다" 류 고지 UI 필요.
  3. API 사전 승인(파트너스 가입 + 앱 매체 심사 통과) 선행.
- **제품 정합성**: `shopping_product` 카드는 "사고 싶던 것 다시 찾기" = 회수 미션과 정렬. 억지 광고 아니라 **BM 이 미션을 해치지 않음**(강점).

## 결정 / 이유
- favicon 교체: 검색 링크라 OG 이미지 무의미(검색결과 대표 이미지 없음), 목적지 브랜드는 favicon 이 정확. 기존 컴포넌트 재사용으로 저비용. (사용자 선택 = "favicon 으로 교체")
- BM: 아직 **결정 아님 — 탐색 단계**. 사용자 요청은 "저널에 작성만". 방향 확정 시 docs/journal 후속.

## 다음 할 일
- (favicon) 실기기에서 쿠팡·네이버 favicon 실제 로드 확인. 네이버 폴백 빠지면 host 를 `naver.com` 으로 조정 검토.
- (BM, 사용자 결정 후) ① 쿠팡파트너스 가입 + 앱 매체 심사(외부 절차, 선행 필수) → ② 백엔드 쿠팡 딥링크 API 변환 레이어 설계 → ③ iOS 카드 추적 링크 교체 + 대가성 문구 노출.

## 막힌 것 / 사람 결정 필요
- **BM 채택 여부 자체가 미정** — 수익화 방향으로 갈지(쿠팡 only), 보류할지 사용자 결정 대기.
- 결정 시 외부 가입·심사가 코드보다 선행 → 사용자가 파트너스 가입부터 시작해야 실동작.

## 출처
- 쿠팡 수수료율: https://savvykr.com/coupang-partners-commission-rate-guide/
- 쿠팡 딥링크 API: https://yourtime.kr/entry/쿠팡파트너스-deeplink딥링크-API-활용하는-법 · https://vivoldi.com/tutorial/tips/60
- 네이버 쇼핑 커넥트: https://waneestudio.com/1546/
- 쿠팡 자동삽입 위반 사례: https://www.clien.net/service/board/park/19112381
- 네이버 앱 scheme(naversearchapp): https://developers.naver.com/docs/utils/mobileapp/
- AASA 직접 조회(`curl`): link.coupang.com `/re/*` `/re2/*` / 네이버 검색 도메인 미등록
