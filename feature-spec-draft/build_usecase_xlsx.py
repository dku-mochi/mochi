#!/usr/bin/env python3
"""모찌 기능 UseCase 엑셀 생성 — 문서(docs/) 기반 임시 산출물. v2: codex 리뷰 22건 반영."""
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

# ---- 공통 스타일 ----
HEADER_FILL = PatternFill("solid", fgColor="8B6CFF")      # Soft Purple
HEADER_FONT = Font(name="Apple SD Gothic Neo", bold=True, color="FFFFFF", size=11)
CELL_FONT   = Font(name="Apple SD Gothic Neo", size=10, color="17172A")
WRAP_TOP    = Alignment(wrap_text=True, vertical="top")
CENTER      = Alignment(horizontal="center", vertical="center", wrap_text=True)
THIN = Side(style="thin", color="D9D4EC")
BORDER = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)

GROUP_FILLS = {
    "인증":"EDE7FF","온보딩":"DFF8EC","홈":"FFF9F1","질문":"EDE7FF","캘린더":"DFF8EC",
    "검색":"FFE8DA","상세":"FFF9F1","Inbox/분류":"EDE7FF","입력채널":"FFE8DA",
    "설정":"DFF8EC","알림/생명주기":"FFF9F1","민감캡처":"FFE8DA",
}
STATUS_FILLS = {  # 계약 상태 색
    "✅ 실연결":"DFF8EC","✅ 로컬(Realm)":"DFF8EC","✅ 서버 worker":"DFF8EC",
    "◑ 서버존재·iOS미배선":"FFF6D6","◑ iOS 3초 폴링":"FFF6D6",
    "○ route 미존재":"FFE0E0","◐ 계획/부분구현":"FFEFD9",
}

def style_header(ws, row, ncols):
    for c in range(1, ncols + 1):
        cell = ws.cell(row=row, column=c)
        cell.fill = HEADER_FILL; cell.font = HEADER_FONT
        cell.alignment = CENTER; cell.border = BORDER

# ============================================================
# 시트 1 — 기능 UseCase
# ============================================================
wb = Workbook()
ws = wb.active
ws.title = "기능 UseCase"

cols = ["UC ID","대분류","화면코드","기능명","액터","우선순위","사전조건","트리거",
        "기본 흐름(Main)","대안/예외 흐름","사후조건","관련 Intent/Lifecycle",
        "계약/구현 상태","근거 문서"]

# (UC,대분류,화면,기능명,액터,우선순위,사전조건,트리거,기본흐름,예외,사후조건,intent/lifecycle,계약상태,근거)
rows = [
 # ---- 인증 ----
 ("UC-01","인증","S-01","스플래시 세션 확인·라우팅","시스템","P0","앱 설치됨","앱 콜드 스타트",
  "①토큰 유효성 확인 ②유효+온보딩완료→홈 ③유효+온보딩미완료→온보딩 ④무효→로그인","토큰 만료→refresh rotation, 실패→로그인","적절한 첫 화면 진입","-","✅ 실연결","PRODUCT §6.1,8.1"),
 ("UC-02","인증","S-02","Apple 로그인","사용자","P0","미인증","Apple 버튼 탭",
  "①Apple 인증 ②POST /auth/apple ③JWT(RS256)+refresh rotation 발급 ④기존/신규 분기","취소·네트워크 실패→재시도","세션 수립","-","✅ 실연결","PRODUCT §4.3 / DOMAIN §6"),
 ("UC-03","인증","S-02","Google 로그인","사용자","P0","미인증","Google 버튼 탭",
  "①Google Sign-In ②POST /auth/google ③JWT+refresh 발급 ④기존/신규 분기","취소·실패→재시도","세션 수립","-","✅ 실연결","PRODUCT §4.3 / DOMAIN §6"),
 ("UC-04","인증","S-03","회원가입(신규 user 생성+약관 동의)","사용자·시스템","P0","OAuth 첫 성공","신규 provider/subject 인증",
  "①users 자동 생성 ②auth_accounts 연결 ③약관·개인정보 동의 ④AI 데이터+개인화 프로필 고지 ⑤온보딩","약관 미동의→차단 / 기존 연결→로그인","신규 회원, onboarding_completed_at=null","-","✅ 실연결","PRODUCT §4.3 / DOMAIN §4.2"),
 ("UC-05","인증","-","세션 유지·토큰 갱신","시스템","P0","로그인됨","access 만료",
  "①refresh token rotation ②새 access 발급","reuse_detected→family 폐기·재로그인","세션 연장","-","✅ 실연결","DOMAIN §4.2,9"),
 ("UC-06","인증","G-01","로그아웃","사용자","P1","로그인됨","로그아웃 탭",
  "①POST /auth/logout ②refresh 폐기 ③로컬 세션 정리","-","미인증 상태","-","✅ 실연결","DOMAIN §6"),
 # ---- 온보딩 ----
 ("UC-07","온보딩","S-04","온보딩-모찌 소개","사용자","P0","회원가입 직후","step1 진입",
  "①캐릭터 Fade In ②소개 카피 ③다음","건너뛰기 가능","step2","-","✅ 로컬(Realm)","PRODUCT §8.3"),
 ("UC-08","온보딩","S-04","백탭 단축어 등록 안내","사용자","P0","온보딩 진행","step2",
  "①백탭 설명 ②'단축어 등록하기' ③iOS Shortcuts 가이드","보류→설정에서 재등록","백탭 준비","-","✅ 로컬(Realm)","PRODUCT §4.2,8.3"),
 ("UC-09","온보딩","S-04","공유 저장 안내","사용자","P0","온보딩 진행","step3",
  "①공유시트 저장법 ②다음","-","step4","-","✅ 로컬(Realm)","PRODUCT §8.3"),
 ("UC-10","온보딩","S-04","캡처 자동정리 안내","사용자","P0","온보딩 진행","step4",
  "①AI 자동 4-Intent 분류 안내 ②시작하기","-","step5","-","✅ 로컬(Realm)","PRODUCT §8.3"),
 ("UC-11","온보딩","S-04","온보딩 완료→홈","사용자·시스템","P0","step5","'모찌 시작하기'",
  "①onboarding_completed_at 기록 ②홈 진입","-","온보딩 완료, 재실행 스킵","-","✅ 실연결","DOMAIN §4.2"),
 # ---- 홈 ----
 ("UC-12","홈","T-01","홈 진입·요약 로딩","사용자·모찌AI","P0","로그인+온보딩 완료","탭바 홈/앱 진입",
  "①Realm 로컬 로드 ②요약·제안 구성 ③2초 내 렌더","지연→스켈레톤","홈 표시","all","✅ 로컬(Realm)","PRODUCT §8.4,10"),
 ("UC-13","홈","T-01","4-Intent 요약 카드","사용자","P0","홈 표시","요약 카드 영역",
  "①Intent별 개수 ②카드 탭→해당 필터","개수 0→빈 상태","필터 목록 진입","all","✅ 로컬(Realm)","PRODUCT §8.4"),
 ("UC-14","홈","T-01","중요 제안(Daily Importance)","모찌AI","P0","홈 표시","앱 진입(24h 캐시)",
  "①로컬 analysis.importance(medium↑) 정렬 ②'모찌가 중요해 보여요' 노출(능동 회수) ③탭→상세","캐시 유효→재계산 생략","중요 항목 가시화","schedule/todo","◐ 계획/부분구현","DOMAIN 부록D (Gemini 재산출은 후속)"),
 ("UC-15","홈","T-01","이번 주 저장 기록 요약","모찌AI","P1","홈 표시","스크롤",
  "①Intent별 개수+키워드 요약","없음→안내","주간 회고","all","✅ 로컬(Realm)","PRODUCT §8.4"),
 ("UC-16","홈","T-01","최근 추가한 모찌 목록","사용자","P0","홈 표시","스크롤",
  "①썸네일·제목·출처·Intent·시간 카드 ②탭→상세","-","최근 항목 탐색","all","✅ 로컬(Realm)","PRODUCT §8.4"),
 ("UC-17","홈","C-03","홈 빠른 입력 버튼","사용자","P0","홈 표시","우측 상단 입력 버튼",
  "①빠른 캡처 모달 오픈","-","입력 모달 진입","all","✅ 로컬(Realm)","PRODUCT §7"),
 ("UC-18","홈","P-02","홈 헷갈려요 카드 처리","사용자·모찌AI","P0","confidence 낮은 항목","홈 카드 노출",
  "①후보 2개 라벨 제시 ②선택/직접 지정","다시 맡기기","Intent 확정","all","◑ 서버존재·iOS미배선","DOMAIN §4.4,부록C/D (override iOS 미배선)"),
 # ---- 질문 ----
 ("UC-19","질문","T-02","추천 질문 칩 선택","사용자","P1","질문 탭","칩 탭",
  "①추천 질문 자동 입력 ②질의 실행","-","답변 흐름","all","○ route 미존재","PRODUCT §8.5 (/conversations 미구현)"),
 ("UC-20","질문","T-02","자연어 질문·답변(RAG)","사용자·모찌AI","P1","질문 탭","질문 전송",
  "①Query 분석 ②Hybrid Search(owner 필터, BM25+벡터+RRF) ③Tool 호출 ④답변+근거 모찌(citation)","결과 없음→없다고 응답","답변+근거","all","○ route 미존재","PRODUCT §6.5,8.5 / ARCH §3.4 (route 없음)"),
 ("UC-21","질문","T-02","Tool 사용 과정 표시","모찌AI","P1","질의 진행","답변 생성 중",
  "①내부 도구를 친화 문구로 노출","-","투명성","-","○ route 미존재","PRODUCT §8.5"),
 ("UC-22","질문","T-02","근거 모찌 확인","사용자","P1","답변 표시","근거 카드 탭",
  "①참고 모찌 목록 ②탭→상세","-","근거 추적(환각 방지)","all","○ route 미존재","PRODUCT §8.5,11"),
 # ---- 캘린더 ----
 ("UC-23","캘린더","T-03","월간 캘린더 조회","사용자","P1","로그인","캘린더 탭",
  "①날짜별 개수+대표 Intent(argmax projection)+썸네일","빈 달→빈 상태","날짜 탐색","all","✅ 로컬(Realm)","PRODUCT §8.6 (list route 미존재→로컬)"),
 ("UC-24","캘린더","T-03","날짜별 모찌 상세","사용자","P1","캘린더 표시","날짜 셀 탭",
  "①해당 날짜 모찌 목록 시트 ②탭→상세","없음→안내","그날 기록 탐색","all","✅ 로컬(Realm)","PRODUCT §8.6"),
 ("UC-25","캘린더","T-03","캘린더 하단 할 일 리스트","사용자","P1","캘린더 표시","스크롤",
  "①마감 임박·미완료 할 일 ②완료 체크","-","할 일 관리","todo","✅ 로컬(Realm)","PRODUCT §8.6"),
 ("UC-26","캘린더","T-03","월/주 이동","사용자","P1","캘린더 표시","이전·다음",
  "①대상 기간 갱신","-","기간 탐색","all","✅ 로컬(Realm)","PRODUCT §8.6"),
 # ---- 검색 ----
 ("UC-27","검색","T-04","키워드·의미 검색(control/fallback)","사용자·모찌AI","P1","로그인","검색어 입력",
  "①Hybrid Search(owner 필터) ②결과 카드(제목·요약·Intent·출처·하이라이트). 기본 회수 아님(모찌가 먼저 띄움)","결과 없음→안내","검색 결과","all","○ route 미존재","PRODUCT §8.7 / ARCH §3.4 (POST /search 없음→로컬 필터)"),
 ("UC-28","검색","T-04","Intent·타입 필터","사용자","P1","검색 결과","필터 칩",
  "①전체/일정/할일/지식/기록/이미지/링크/메모/미확인/중요 필터","-","필터된 결과","all","✅ 로컬(Realm)","PRODUCT §8.7"),
 ("UC-29","검색","D-01","검색 결과→상세","사용자","P1","검색 결과","결과 카드 탭",
  "①모찌 상세 진입","-","상세 조회","all","✅ 실연결","PRODUCT §8.7,8.8"),
 # ---- 상세 ----
 ("UC-30","상세","D-01","모찌 상세 조회","사용자","P0","모찌 존재","카드/검색/캘린더 선택",
  "①active intents 동등 칩(대표=argmax projection, 위계 아님) ②원본 ③요약 ④엔티티 ⑤액션 후보 ⑥관련 모찌","분석 미완료→진행 표시","상세 확인","all (1:N)","◐ 계획/부분구현","단건 GET=✅ / flat intents=0009 타겟 / 액션후보·관련모찌=design-ahead (DOMAIN §4.4,§13.1 / ARCH §4.2)"),
 ("UC-31","상세","D-01","액션-캘린더 등록","사용자·시스템","P2","schedule 후보","'캘린더 등록' 탭",
  "①사용자 확인 ②EventKit/Google Calendar 등록","권한 거부→안내","일정 등록","schedule / active","◐ 계획/부분구현","PRODUCT §3,8.8 / ARCH §2.4"),
 ("UC-32","상세","D-01","액션-할 일/알림","사용자·시스템","P2","todo 후보","'할 일'/'알림' 탭",
  "①Reminders 등록 또는 알림 후보","권한 거부→안내","할 일/알림 등록","todo / active","◐ 계획/부분구현","PRODUCT §3,8.8"),
 ("UC-33","상세","D-01","Intent 수정(override)","사용자","P0","분류됨","'Intent 수정' 탭",
  "①4-Intent 직접 선택 ②로컬 setIntent","서버 PATCH /intent 미배선(로컬 전용)","분류 정정","all","◑ 서버존재·iOS미배선","DOMAIN §5,6 (PATCH iOS 미배선)"),
 ("UC-34","상세","D-01","원본 삭제","사용자","P1","모찌 존재","'삭제' 탭",
  "①확인 ②로컬 삭제(서버 DELETE route 미존재)","-","항목 제거","userManual archive","○ route 미존재","PRODUCT §10 (DELETE 없음)"),
 ("UC-35","상세","D-01","AI 분석 결과 수정","사용자","P1","분석됨","요약/엔티티 편집",
  "①요약·엔티티 수정 저장(로컬)","-","분석 정정","all","◐ 계획/부분구현","PRODUCT §10"),
 ("UC-36","상세","D-01","관련 모찌 탐색","사용자·모찌AI","P1","분석됨","관련 모찌 탭",
  "①의미적으로 가까운 모찌 ②탭→상세","없음→숨김","연관 탐색","knowledge","◐ 계획/부분구현","PRODUCT §8.8 (임베딩 적재 no-op)"),
 # ---- Inbox/분류 ----
 ("UC-37","Inbox/분류","I-01","신규 캡처 Inbox 확인","사용자","P0","신규 항목 유입","앱 active/홈 안내",
  "①InboundQueueConsumer.drain→Realm ingest ②신규 항목 노출","-","신규 캡처 가시화","ingested","✅ 로컬(Realm)","PRODUCT §6.3 / ARCH §2.3"),
 ("UC-38","Inbox/분류","I-01","업로드 동기화·실패 재시도(sync)","사용자·시스템","P0","pendingUpload","앱 active",
  "①MochiItemSyncWorker 업로드(presign→GCS→ingest, Idempotency-Key)","실패→pendingUpload 1회 retry 후 syncFailed, 자동 재시도 없음→'다시 보내기'","uploaded(serverID) 또는 syncFailed","ingested","✅ 실연결","ARCH §2.3 / DOMAIN 부록D"),
 ("UC-39","Inbox/분류","I-01","분석 진행·실패 폴링(analysis)","시스템·모찌AI","P0","업로드됨","서버 분석 진행",
  "①'정리하는 중' ②GET /mochi_items/{serverID} 3초 폴링 ③active→반영","lifecycle failed 또는 90s 초과→demoteToManual / requeueForAnalysis","분석 완료 반영","analyzing→active / failed","◑ iOS 3초 폴링","DOMAIN §5 부록D / ARCH §3.4 (SSE 미구독)"),
 ("UC-40","Inbox/분류","P-02","헷갈려요 분류 확정","사용자·모찌AI","P0","confidence 낮음(현 임시 <0.6)","카드 노출",
  "①후보 상위2 라벨(label??displayName) ②선택/'다른 의도' 직접 지정","박빙(복수의도)→둘 다 적용(헷갈림 아님)","Intent 확정","all (active set)","◐ 계획/부분구현","DOMAIN §4.4 부록C/D (τ_review 미확정, 0.6은 임시 client-derive)"),
 # ---- 입력채널 ----
 ("UC-41","입력채널","C-01","백탭 Snippet 카드 표시","사용자·시스템","P0","백탭 단축어 등록","뒷면 2회 탭",
  "①CaptureScreenshotIntent PNG stash(pending-backtap) ②ShowsSnippetView 외부 앱 위 카드(앱 안 깨움) ③[캡쳐]/[메모]","시스템 dismiss→.png 잔재 RootFeature launch/active sweep","입력 분기 선택","-","✅ 실연결","ARCH §2.3 / PRODUCT §8.9"),
 ("UC-42","입력채널","C-01","백탭 캡쳐 분기 저장","사용자·시스템","P0","Snippet 카드","'캡쳐' 탭",
  "①PNG 영구저장(captures/{owner})+sha256 ②Realm pendingUpload upsert ③ProvidesDialog 결과 dialog로 카드 갈음(외부앱 유지) ④다음 active privacy gate→점수6↑면 보류·P-01, 통과 시 ingest(Idempotency-Key)","background 인프라/OCR 부재→로컬 보존 우선","로컬 저장+업로드/감지 대기","screenshot / pendingUpload","◐ 계획/부분구현","PRODUCT §6.3,8.9 / ARCH §2.3 / PRIVACY §7.1 (privacy gate 미통합)"),
 ("UC-43","입력채널","C-02","백탭 메모 분기 저장","사용자","P0","Snippet 카드","'메모' 탭",
  "①PNG 폐기+.memo marker ②모찌 foreground→메모 모달 ③저장→MochiItem(appDirectInput)+POST /mochi_items(Idempotency-Key)","취소→marker 폐기 / 실패→SyncWorker fallback","메모 저장",".memo 가장 최근 1개만 promote","✅ 실연결","PRODUCT §8.9 / ARCH §2.3"),
 ("UC-44","입력채널","C-03","빠른 캡처 입력 모달","사용자","P0","앱 내","홈 입력 버튼",
  "①메모/스크린샷 입력 ②저장→AI 분류→홈 표시(Idempotency-Key)","-","즉시 저장(분석 비동기)","all","✅ 실연결","PRODUCT §6.2,7"),
 ("UC-45","입력채널","E-01","공유시트 이미지 저장","사용자","P0","공유시트 모찌 등록","외부 앱 이미지 공유",
  "①Share Extension 수신+힌트 입력 ②InboundIngestPayload 를 App Group inbound 큐 적재(업로드 안 함) ③본앱 active drain ④privacy gate(계획) ⑤presign→GCS PUT→objectKey ⑥POST /mochi_items(Idempotency-Key)","Share Extension 프로세스는 큐 적재만, 업로드·감지는 본앱 drain 시점","이미지 모찌 저장","screenshot","◐ 계획/부분구현","기본 ingest=✅ / 민감감지=계획 (PRODUCT §4.1,8.10 / ARCH §2.3,§3.4 / PRIVACY §7.1,§8)"),
 ("UC-46","입력채널","E-01","공유시트 텍스트 저장","사용자","P0","공유시트 등록","텍스트/선택텍스트 공유",
  "①텍스트 수신+1차 패턴 감지 ②메모 분석 ③저장(Idempotency-Key)","-","텍스트 모찌 저장","memo/knowledge","✅ 실연결","PRODUCT §8.10"),
 ("UC-47","입력채널","E-01","공유시트 링크 저장(WebFetch/PlatformContext)","사용자·모찌AI","P0","공유시트 등록","URL 공유",
  "①URL 수신 ②PlatformContext(YouTube/X/Instagram oEmbed)·일반 URL WebFetch(SSRF 가드) ③요약·Intent 분류","fetch 실패→메타데이터 fallback / SSRF 차단","링크 모찌 저장","knowledge/memo","✅ 실연결","PRODUCT §6.4,8.10 / ARCH §3.5,5.4"),
 ("UC-48","입력채널","E-02","Siri/Spotlight 메모","사용자","P2","단축어/AppIntent","음성/검색 명령",
  "①QuickCaptureIntent ②App Group 큐 직접 적재(UI 우회) ③result dialog","-","메모 큐 적재","appIntent","✅ 실연결","ARCH §2.3"),
 # ---- 설정 ----
 ("UC-49","설정","G-01","계정 정보·로그아웃","사용자","P1","로그인","설정 진입",
  "①계정 정보 ②로그아웃","-","계정 관리","-","✅ 실연결","PRODUCT §10"),
 ("UC-50","설정","G-01","계정 삭제","사용자·시스템","P1","로그인","'계정 삭제' 탭",
  "①확인 ②users.deleted_at soft delete ③로그아웃","email 익명화 미구현(TODO)","계정 비활성","-","◐ 계획/부분구현","PRODUCT §10 / DOMAIN §9"),
 ("UC-51","설정","G-01","Privacy mode 설정","사용자","P1","로그인","개인정보 설정",
  "①기본 privacy mode ②'민감 캡처 항상 로컬' ③원본 업로드 승인 정책","-","업로드 정책 반영","-","◐ 계획/부분구현","PRIVACY §5.2,5.3"),
 ("UC-52","설정","G-01","원본 데이터 삭제(전역)","사용자","P1","로그인","데이터 관리",
  "①원본/파생 일괄 삭제 확인(로컬)","서버 DELETE route 미존재","데이터 제거","-","○ route 미존재","PRODUCT §10"),
 ("UC-53","설정","G-01","데이터 내보내기","사용자","P2","로그인","'내보내기' 탭",
  "①사용자 데이터 export","export route 미존재","데이터 이동성","-","○ route 미존재","PRODUCT §10"),
 ("UC-54","설정","G-01","AI 사용 데이터 안내","사용자","P1","로그인","투명성 메뉴",
  "①분석 사용 데이터 종류 고지 ②개인화 프로필=관심사·분류 성향 요약(owner-scoped)","-","투명성","-","◐ 계획/부분구현","PRODUCT §10 / PRIVACY §2.1 / ARCH §5.5"),
 ("UC-55","설정","G-01","백탭 재등록 안내","사용자","P1","로그인","입력 설정",
  "①백탭 단축어 재등록 가이드","-","입력 채널 복구","-","✅ 로컬(Realm)","PRODUCT §4.2"),
 ("UC-56","설정","G-01","알림 설정","사용자","P2","로그인","알림 메뉴",
  "①일정·할 일 리마인드 on/off","-","알림 정책 반영","schedule/todo","◐ 계획/부분구현","PRODUCT §10,3"),
 # ---- 알림/생명주기 ----
 ("UC-57","알림/생명주기","G-02","일정 알림","시스템","P2","schedule active","일정 도래 전",
  "①알림 후보 생성 ②리마인드","알림 off→스킵","일정 환기","schedule / active","◐ 계획/부분구현","PRODUCT §5,3"),
 ("UC-58","알림/생명주기","G-02","할 일 리마인드","시스템","P2","todo 미완료","마감 임박",
  "①리마인드 ②홈 제안 유지","완료→중단","할 일 환기","todo / active","◐ 계획/부분구현","PRODUCT §5,8.4"),
 ("UC-59","알림/생명주기","-","일정 종료 자동 기록화","시스템","P1","schedule active","종료 시각 경과",
  "①worker 자동 전이 active→archived(scheduleEnded)","-","일정→기록 전환","schedule / archived","✅ 서버 worker","DOMAIN §7.4"),
 ("UC-60","알림/생명주기","-","할 일 완료 archive","사용자·시스템","P1","todo active","완료 처리",
  "①active→archived(todoCompleted)","-","할 일 종료","todo / archived","✅ 서버 worker","DOMAIN §7.4"),
 ("UC-61","알림/생명주기","-","지식 decay·review","시스템","P2","knowledge active","30일/180일 경과",
  "①30일 미회수→decaying ②180일→reviewRequested ③회수→active 복귀","-","지식 신선도 관리","knowledge / decaying·reviewRequested","✅ 서버 worker","DOMAIN §7.4"),
 # ---- 민감캡처 ----
 ("UC-62","민감캡처","-","민감도 감지·점수 산출","시스템","P1","캡처 입력","ingestion/promote 전",
  "①Vision OCR ②NSDataDetector ③NaturalLanguage NER ④한국형 룰(주민/카드Luhn/계좌/OTP/토큰/의료/금융)+조합 가중 ⑤0~10(cap)","신호 약함→낮음 등급","민감도 점수","-","◐ 계획/부분구현","PRIVACY §3,4 (백탭 미통합)"),
 ("UC-63","민감캡처","P-01","민감 캡처 경고 모달","사용자","P1","점수≥6","업로드/분석 전",
  "①경고 문구(유형 중심) ②감지 항목 유형만 표시(원문 비노출)","-","위험 인지","-","◐ 계획/부분구현","PRIVACY §5.1,5.3"),
 ("UC-64","민감캡처","P-01","민감 처리 선택","사용자","P1","경고 표시","선택지 탭",
  "①기기에만/마스킹/텍스트만/원본허용 ②원본 허용은 매번 명시 승인","9-10점→로컬 기본값","처리 정책 결정","-","◐ 계획/부분구현","PRIVACY §5.2,6"),
 ("UC-65","민감캡처","-","의미 보존 payload 전송","시스템","P1","서버 분석 필요","마스킹 후 업로드",
  "①원본값 제거·구조화 의미표현 ②privacy 메타(sensitivity_score/level/redaction_status/original_image_uploaded/privacy_policy/redactions[]) 동봉 ③원본 승인 시 TTL 삭제","원본 없음→OCR/semantic 분석 / redacted 있음→함께 분석","최소전송 분석","-","◐ 계획/부분구현","PRIVACY §2.1,6.2,6.3,8"),
]

for ci, name in enumerate(cols, 1):
    ws.cell(row=1, column=ci, value=name)
style_header(ws, 1, len(cols))

for ri, row in enumerate(rows, 2):
    fill_color = GROUP_FILLS.get(row[1], "FFFFFF")
    for ci, val in enumerate(row, 1):
        cell = ws.cell(row=ri, column=ci, value=val)
        cell.font = CELL_FONT
        cell.alignment = CENTER if ci in (1,6) else WRAP_TOP
        cell.border = BORDER
        if ci == 2:
            cell.fill = PatternFill("solid", fgColor=fill_color)
        if ci == 13:  # 계약/구현 상태
            sc = STATUS_FILLS.get(val, "FFFFFF")
            cell.fill = PatternFill("solid", fgColor=sc)
            cell.alignment = CENTER

widths = [8,11,8,23,11,7,20,17,38,26,20,18,20,28]
for ci, w in enumerate(widths, 1):
    ws.column_dimensions[get_column_letter(ci)].width = w
ws.freeze_panes = "A2"
ws.auto_filter.ref = f"A1:{get_column_letter(len(cols))}{len(rows)+1}"

# ============================================================
# 시트 2 — 화면 인벤토리
# ============================================================
ws2 = wb.create_sheet("화면 인벤토리")
inv_cols = ["화면코드","화면/표면","유형","진입 경로","우선순위","주요 기능 요약"]
inv = [
 ("S-01","스플래시","전체화면","앱 콜드 스타트","P0","세션 확인·라우팅·브랜드 인상"),
 ("S-02","로그인","전체화면","미인증 첫 진입","P0","Apple/Google OAuth·JWT+refresh rotation"),
 ("S-03","회원가입(OAuth+약관)","플로우","OAuth 신규 성공","P0","user 자동 생성·약관·AI 데이터 고지"),
 ("S-04","온보딩 튜토리얼(5단계)","페이저","회원가입 직후","P0","모찌소개·백탭등록·공유·자동정리·시작"),
 ("T-01","홈 탭","탭","기본 진입","P0","요약카드·중요제안(능동)·최근모찌·빠른입력·헷갈려요"),
 ("T-02","질문 탭(RAG)","탭","탭바","P1","자연어·추천칩·Tool표시·근거모찌 (route 미존재)"),
 ("T-03","캘린더 탭","탭","탭바","P1","월간 캘린더·날짜 상세·할 일 리스트"),
 ("T-04","검색 탭(control/fallback)","탭","탭바","P1","Hybrid·필터·결과카드 (기본 회수 아님)"),
 ("D-01","모찌 상세","푸시/시트","카드/검색/캘린더 선택","P0","원본·요약·엔티티·액션후보·동등 intent 칩"),
 ("I-01","Inbox(분석 대기·진행)","리스트/시트","신규 캡처","P0","sync 실패↔분석 실패 분리·폴링·재시도"),
 ("C-01","백탭 Snippet 카드","시스템 오버레이","뒷면 2탭","P0","외부앱 위 카드·캡쳐/메모·ProvidesDialog 갈음"),
 ("C-02","백탭 메모 모달","풀스크린 모달","Snippet '메모'","P0","textarea 메모 저장(Idempotency-Key)"),
 ("C-03","빠른 캡처 입력 모달","풀스크린 모달","홈 입력 버튼","P0","메모/스크린샷 즉시 입력"),
 ("E-01","Share Extension","시스템 시트","외부 앱 공유","P0","이미지/텍스트/링크+1차 민감감지+presign"),
 ("E-02","Siri/Spotlight 빠른 메모","시스템 다이얼로그","Siri/Spotlight","P2","텍스트 메모 큐 직접 적재"),
 ("P-01","민감 캡처 경고 모달","시트/알림","점수≥6","P1","경고·유형표시·처리 선택지·payload 정책"),
 ("P-02","헷갈려요 분류 확인 카드","인라인/시트","confidence 낮음","P0","후보 제시·직접 지정·다시 맡기기"),
 ("G-01","설정","푸시 화면","홈 설정 진입","P1","계정·privacy·데이터관리·알림·투명성"),
 ("G-02","알림/리마인드","시스템 알림+인앱","일정/할 일 도래","P2","일정 알림·할 일 리마인드·캘린더 연동"),
]
for ci, name in enumerate(inv_cols, 1):
    ws2.cell(row=1, column=ci, value=name)
style_header(ws2, 1, len(inv_cols))
for ri, row in enumerate(inv, 2):
    for ci, val in enumerate(row, 1):
        cell = ws2.cell(row=ri, column=ci, value=val)
        cell.font = CELL_FONT
        cell.alignment = CENTER if ci in (1,3,5) else WRAP_TOP
        cell.border = BORDER
for ci, w in enumerate([10,26,16,22,9,52], 1):
    ws2.column_dimensions[get_column_letter(ci)].width = w
ws2.freeze_panes = "A2"
ws2.auto_filter.ref = f"A1:{get_column_letter(len(inv_cols))}{len(inv)+1}"

# ============================================================
# 시트 3 — 4-Intent & 생명주기
# ============================================================
ws3 = wb.create_sheet("4-Intent & 생명주기")
li_cols = ["Intent","표시명","정의","예시","자동 동작","합법 전이(요약)","자동 전이(worker)"]
li = [
 ("schedule","일정","특정 시간 이벤트","내일 3시 팀 회의","캘린더 등록 후보·알림 후보","ingested→analyzing→active→archived(scheduleEnded|userManual)","종료 시각 경과→archived(scheduleEnded)"),
 ("todo","할 일","완료 여부가 중요","보고서 제출하기","Reminders sync·홈 제안 유지","ingested→analyzing→active→archived(todoCompleted|userManual)","완료→archived(todoCompleted)"),
 ("knowledge","지식","다시 학습·참고","RAG 구조 설명 글","RAG 인덱싱·임베딩","ingested→analyzing→active→decaying→reviewRequested→(active|archived(knowledgeStale|userManual))","30일 미회수→decaying / 180일→reviewRequested"),
 ("memo","기록","맥락 보존 메모","회의 내용·감상","영구 보관·타임라인","ingested→analyzing→active→archived(userManual)","-"),
 ("(공통 예외)","-","모든 Intent 분석 실패","-","outbox 재시도/DLQ","ingested/analyzing→failed→archived(userManual)","dead-letter(attempts>max)→failed"),
]
for ci, name in enumerate(li_cols, 1):
    ws3.cell(row=1, column=ci, value=name)
style_header(ws3, 1, len(li_cols))
intent_fill = {"schedule":"EDE7FF","todo":"FFE8DA","knowledge":"DFF8EC","memo":"EAF2FF"}
for ri, row in enumerate(li, 2):
    for ci, val in enumerate(row, 1):
        cell = ws3.cell(row=ri, column=ci, value=val)
        cell.font = CELL_FONT; cell.alignment = WRAP_TOP; cell.border = BORDER
        if ci in (1,2):
            cell.fill = PatternFill("solid", fgColor=intent_fill.get(row[0], "F0EEF6")); cell.alignment = CENTER
for ci, w in enumerate([12,8,22,18,22,46,40], 1):
    ws3.column_dimensions[get_column_letter(ci)].width = w
ws3.freeze_panes = "A2"
notes = [
 "비고1: intents = flat 1:N 리스트(위계 없음). confidence = max(applicability). active = {applicability ≥ τ}, 비면 memo fallback. 대표 intent = argmax projection(저장 위계 아님).",
 "비고2: '헷갈려요'(needs_review) = confidence < τ_review. τ_review 는 실험 확정 전(config). 현재 iOS 는 임시로 confidence < 0.6 client-derive.",
 "비고3: failed 는 ingested/analyzing 에서만 진입(active→failed 없음). failed→archived(userManual) 만. lifecycle 은 intent 와 독립(record 단위).",
]
for k, txt in enumerate(notes):
    r = len(li) + 3 + k
    c = ws3.cell(row=r, column=1, value=txt)
    c.font = Font(name="Apple SD Gothic Neo", italic=True, size=9, color="7A7A90")
    ws3.merge_cells(start_row=r, start_column=1, end_row=r, end_column=7)

# ============================================================
# 시트 4 — 구현·계약 상태 (제품 요구 ≠ 현재 계약)
# ============================================================
ws4 = wb.create_sheet("구현·계약 상태")
st_cols = ["기능 영역","관련 화면/UC","현재 상태","비고"]
st = [
 ("인증(apple/google/refresh/logout)","S-02/S-03/UC-02~06","✅ 실연결","JWT(RS256)+refresh rotation"),
 ("ingest POST /mochi_items·/back-tap·/presign","C-01/C-02/E-01/UC-38,42~47","✅ 실연결","Idempotency-Key 필수·presign GCS"),
 ("단건 조회 GET /mochi_items/{id}","I-01/D-01/UC-39","✅ 실연결","서버 PK 기준(로컬 id GET 404)"),
 ("이미지 bytes 분석","C-01/E-01/UC-45/65","✅ 실연결","Signed URL→Gemini gs:// read"),
 ("생명주기 자동 전이(worker)","UC-59~61","✅ 서버 worker","scheduleEnded/todoCompleted/decay"),
 ("Intent override PATCH /{id}/intent","D-01/UC-18,33","◑ 서버존재·iOS미배선","현재 setIntent 로컬 전용"),
 ("SSE GET /{id}/stream","I-01/UC-39","◑ 서버존재·iOS미구독","현재 3초 폴링"),
 ("검색 POST /search","T-04/UC-27","○ route 미존재","MVP 로컬 Realm 필터"),
 ("질문 /conversations·messages·citations","T-02/UC-19~22","○ route 미존재","RAG 대화 design-ahead(§13.3)"),
 ("list / DELETE /{id} / /sync","홈·캘린더·삭제·export/UC-34,52,53","○ route 미존재","현재 iOS 로컬 Realm 구동"),
 ("임베딩 적재(INDEXED)","검색 품질/UC-36","○ no-op(known drift)","gateway 미주입 시 skip"),
 ("typed 테이블(todos/calendar_events 등)","액션 후보/UC-31,32","○ design-ahead","τ 안정+소비코드 게이트(§13.1)"),
 ("민감 캡처 보호(감지·게이트·payload)","P-01/UC-42,62~65","◐ 계획/부분구현","백탭 promote 전 감지 미통합(§7.1)"),
 ("Daily Importance Gemini 재산출","T-01/UC-14","◐ 부분구현","현재 로컬 importance 24h 캐시"),
 ("계정/원본 삭제·export","G-01/UC-34,50,52,53","◐/○ 부분·미존재","soft delete만·email 익명화 TODO"),
]
for ci, name in enumerate(st_cols, 1):
    ws4.cell(row=1, column=ci, value=name)
style_header(ws4, 1, len(st_cols))
for ri, row in enumerate(st, 2):
    for ci, val in enumerate(row, 1):
        cell = ws4.cell(row=ri, column=ci, value=val)
        cell.font = CELL_FONT; cell.alignment = WRAP_TOP; cell.border = BORDER
        if ci == 3:
            cell.fill = PatternFill("solid", fgColor=STATUS_FILLS.get(val, "FFEFD9"))
            cell.alignment = CENTER
for ci, w in enumerate([34,30,20,34], 1):
    ws4.column_dimensions[get_column_letter(ci)].width = w
ws4.freeze_panes = "A2"
ws4.auto_filter.ref = f"A1:{get_column_letter(len(st_cols))}{len(st)+1}"

for w in (ws, ws2, ws3, ws4):
    w.row_dimensions[1].height = 28

out = "/Users/jun/Downloads/mochi/feature-spec-draft/모찌_기능_UseCase.xlsx"
wb.save(out)
print("saved:", out)
print(f"UC rows: {len(rows)} / 화면: {len(inv)} / Intent: {len(li)} / 계약상태: {len(st)}")
