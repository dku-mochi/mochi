# FINDINGS — shopping-product-link

쇼핑 캡처 → 카드 상세 구매 링크 실험 (2026-06-13~).

**아이디어**: 주간 정리 category 로 분리되는 쇼핑 캡처에 대해, 카드 상세에 구매 링크를
단다. 특정 판매자를 우리가 정할 수 없으므로 상품 상세가 아니라 **커머스 검색 결과
상태의 링크**(쿠팡/네이버 등)를 제공한다.

**검증 단계**:
1. `exp1_product_id.py` — 캡처(스크린샷/메모)에서 상품을 *검색어로 쓸 수 있을 만큼*
   정확히 식별할 수 있는가. flash-lite(프로덕션 agent 모델) vs 3.5-flash 비교 + LLM judge.
2. `exp2_search_link.py` — 식별된 상품명으로 검색 상태 URL 이 실제로 동작하는가
   (인코딩·URL 패턴 유효성·봇 차단 여부 + 실기기 수동 확인용 링크 목록).

---

## 실험 결과 메모

### exp1 — 상품 식별 (2026-06-13, `results/exp1_20260613_021957.json`)

30케이스 (스크린샷 22 + 합성 메모 8, 쇼핑/비쇼핑 혼재):

| 지표 | flash-lite (프로덕션 agent) | 3.5-flash |
|---|---|---|
| 쇼핑 검출 | 15건 | 15건 |
| is_shopping 판단 적절 (judge) | 30/30 | 30/30 |
| exact (모델/품번 수준) | 13/15 | 13/15 |
| product_match (judge, 1-5) | 3.93 | 3.97 |
| searchable (judge, 1-5) | 3.90 | 3.90 |

- 옷·화장품·전자기기 스크린샷 모두 브랜드+상품명 수준으로 식별 ("로지텍 MX 마스터 3S 펄화이트",
  "아비브 어성초 패드 140매", "쿠어 스탠드 칼라 넥 다운 푸퍼").
- 감점은 의도적 모호 메모 2건뿐 ("신발 예쁜 거 봐둠"→"신발") — 모델이 category 로 정직하게
  강등. **specificity(exact/category/unknown) 필드로 링크 노출을 게이트하면 된다.**
- **flash-lite ≈ 3.5-flash 동급** → 프로덕션 agent 분석 단계에서 product_query 를 함께
  뽑는 확장이 현실적 (별도 모델/패스 불필요).

### exp2 — 검색 상태 링크 (2026-06-13, `results/exp2_20260613_022115.json`)

exp1 산출 상품명 20건 × 4 제공자, iPhone Safari UA 로 GET:

| 제공자 | 결과 |
|---|---|
| **쿠팡** `coupang.com/np/search?q=` | 18/20 status 200 + **본문에 상품 토큰 전부 등장**(검색 결과 서버 렌더 확인), 2건 간헐 403(봇 차단) |
| 네이버쇼핑 `search.shopping.naver.com/search/all?query=` | 전건 418(봇 차단) — 서버측 사전 검증 불가, 브라우저 동작은 별도 확인 필요 |
| 네이버 통합 `search.naver.com/search.naver?query=` | 전건 200 + 토큰 등장 — 안전한 폴백 |
| 구글 | 전건 200 이나 본문 JS 렌더라 서버측 관련성 판단 불충분 |

- 한국어 상품명 percent-encoding 문제 없음. URL 패턴 전부 유효(redirect 정상).
- **결론: "검색된 상태" 링크는 가능하다.** 쿠팡이 1순위(서버에서 결과 존재까지 확인됨),
  네이버 통합이 폴백. 네이버쇼핑은 달 수는 있으나 서버 사전검증 없이.
- 봇 차단(403/418) ≠ 사용자 브라우저 실패 — 최종 UX 는 `results/exp2_links_*.md` 의
  링크를 실기기에서 탭해 확인 (미수행, 남은 단계).

### 프로덕션 반영 (2026-06-13 완료)

1. 분석 프롬프트: 쇼핑 캡처 한정 `entities(kind="shopping_product")` 산출 — specificity 는 별도
   필드 대신 프롬프트 게이트("검색 가능 수준 미달이면 생략")로 내장 (`system_prompts.py`).
2. 노출: entities 저장 경로 재사용(DDL 무변경) → `MochiItemResponse.shoppingProductQuery`
   projection → iOS Realm v9 미러 → 상세 "지금 할 수 있어요"에 쿠팡·네이버 행.
3. 사전 검증 서버 잡은 두지 않음 (쿠팡 간헐 403 이라 신뢰 불가, 검색 상태 링크는 dead-link 개념이 약함).

**남은 단계**: `results/exp2_links_*.md` 실기기 탭 확인 (쿠팡 앱 핸드오프 포함).
