"""rag-topk-eval — 4V 코퍼스 설계 정본 (결정적 스펙).

rag-rerank-eval(391, @10 천장)의 한계 (a)(b)(c)를 겨냥해 코퍼스를 1000+ 로 확장한다:
  (a) 임베딩이 약한 쿼리(오타·영문 모델명·신조어) 포함 — S-tier 하드 쿼리
  (b) 정답↔hard negative 의미 거리 좁힘 — 배치별 hard_neg_note 로 명시 설계
  (c) Volume 1000+ — TOP_K 8 vs 25 가 갈리는 곳(정답 8개 초과 컬렉션 쿼리, L-tier)을 처음으로 측정

4V 매핑
  Volume   — 아이템 ≥1000, 쿼리 50 (S/M/L 계층)
  Variety  — 페르소나 6 × 도메인 12 × 타입(screenshot/link/memo) × 문체(구어/개조식/혼용)
  Velocity — captured_at 6개월 스프레드 + 배치 수집 창(사람은 주제를 몇 주에 걸쳐 모은다)
             + 재저장 근사중복(dup_of) ~4%
  Veracity — 생성(flash-lite)과 다른 모델(3.5-flash)의 qrels 전수 감사(verify_qrels.py)
             + 결정적 dedup/스키마 검증(build_corpus.py)

쿼리 계층 (TOP_K 측정의 핵심 설계)
  S (정답 1)    — 정밀 회상. hard_neg 5~6 을 의미거리 최소로.
  M (정답 3~7)  — 일반 회상. TOP_K=8 로도 대부분 담기는 구간(대조군).
  L (정답 8~16) — 컬렉션/브라우즈("…다 보여줘"). TOP_K=8 이 구조적으로 정답을 자르는 구간.
"""

GEN_MODEL = "gemini-3.1-flash-lite"   # 생성 — 프로덕션 동일 계열·비용 최우선
JUDGE_MODEL = "gemini-3.5-flash"      # 검증 — 생성과 다른 모델(독립성)
SEED = 414

DATE_MIN = "2026-01-15"   # captured_at 범위 (6개월)
DATE_MAX = "2026-07-14"

PERSONAS = {
    "student": "대학생 (학사·과제·동아리·알바)",
    "marketer": "직장인 마케터 (업무·외식·출장)",
    "newlywed": "신혼부부 (리빙·가전·재테크)",
    "parent": "육아 부모 (육아·건강·가족)",
    "jobseeker": "취준생 (채용·자격증·자기계발)",
    "freelancer": "프리랜서 크리에이터 (장비·카페·계약)",
}

# tier: S|M|L / n_answer, n_hard_neg / dup: 재저장 변형 1개 추가 여부
# hard_neg_note: "같은 토픽, 다른 타겟"을 어떻게 좁힐지 명시 (설계가 감사 가능해야 Veracity)
QUERY_SPECS = [
    # ── L-tier: 컬렉션/브라우즈 (정답 8~16) — TOP_K 승부처 ──────────────────────
    dict(qid="L01", query="성수 카페", tier="L", persona="freelancer", domain="장소",
         n_answer=12, n_hard_neg=6, dup=True,
         hard_neg_note="연남·망원 등 다른 동네 카페 + 성수의 카페 아닌 장소(편집숍·전시)"),
    dict(qid="L02", query="제주 여행 가볼 곳", tier="L", persona="newlywed", domain="여행",
         n_answer=10, n_hard_neg=5, dup=True,
         hard_neg_note="부산/강릉 여행지 + 제주 '이미 다녀온 기록'(가볼 곳 아님)"),
    dict(qid="L03", query="면접 준비 자료", tier="L", persona="jobseeker", domain="취업",
         n_answer=9, n_hard_neg=5, dup=True,
         hard_neg_note="자소서 첨삭·인적성 등 다른 채용 단계 자료"),
    dict(qid="L04", query="캠핑 용품", tier="L", persona="parent", domain="취미",
         n_answer=8, n_hard_neg=5, dup=False,
         hard_neg_note="등산·낚시 용품(아웃도어 인접) + 캠핑장 예약(용품 아님)"),
    dict(qid="L05", query="아기 이유식", tier="L", persona="parent", domain="육아",
         n_answer=10, n_hard_neg=5, dup=True,
         hard_neg_note="유아 간식·성인 건강식 레시피"),
    dict(qid="L06", query="집들이 선물", tier="L", persona="newlywed", domain="쇼핑",
         n_answer=8, n_hard_neg=4, dup=False,
         hard_neg_note="생일·돌잔치 선물(선물이지만 다른 행사)"),
    dict(qid="L07", query="노트북 비교", tier="L", persona="student", domain="전자기기",
         n_answer=9, n_hard_neg=5, dup=True,
         hard_neg_note="태블릿·모니터 비교(비교 글이지만 다른 기기)"),
    dict(qid="L08", query="운동 루틴", tier="L", persona="marketer", domain="건강",
         n_answer=8, n_hard_neg=4, dup=False,
         hard_neg_note="식단/보조제(건강이지만 루틴 아님)"),
    dict(qid="L09", query="청약 공고", tier="L", persona="newlywed", domain="금융",
         n_answer=8, n_hard_neg=4, dup=True,
         hard_neg_note="전세대출·적금 금리(주거 재테크 인접)"),
    dict(qid="L10", query="회사 근처 점심", tier="L", persona="marketer", domain="장소",
         n_answer=10, n_hard_neg=5, dup=True,
         hard_neg_note="저녁 회식 장소·카페(같은 상권 다른 용도)"),
    dict(qid="L11", query="영어 공부 자료", tier="L", persona="jobseeker", domain="교육",
         n_answer=9, n_hard_neg=4, dup=False,
         hard_neg_note="일본어·코딩 강의(공부 자료지만 다른 과목)"),
    dict(qid="L12", query="원피스", tier="L", persona="freelancer", domain="쇼핑",
         n_answer=10, n_hard_neg=5, dup=True,
         hard_neg_note="아우터·구두(패션 인접) + 애니메이션 원피스(동음이의)"),
    dict(qid="L13", query="전시회", tier="L", persona="freelancer", domain="문화",
         n_answer=8, n_hard_neg=4, dup=False,
         hard_neg_note="콘서트·페스티벌(공연이지만 전시 아님)"),
    dict(qid="L14", query="부업", tier="L", persona="marketer", domain="재테크",
         n_answer=8, n_hard_neg=4, dup=False,
         hard_neg_note="주식·코인 등 투자(수입 늘리기지만 부업 아님)"),
    dict(qid="L15", query="강아지 용품", tier="L", persona="parent", domain="반려",
         n_answer=9, n_hard_neg=5, dup=True,
         hard_neg_note="고양이 용품 + 강아지 동물병원(용품 아님)"),
    dict(qid="L16", query="자취 요리", tier="L", persona="student", domain="요리",
         n_answer=10, n_hard_neg=5, dup=True,
         hard_neg_note="배달 맛집·외식(먹는 건 같지만 요리 아님)"),
    # ── M-tier: 일반 회상 (정답 3~7) — 대조군 ────────────────────────────────
    dict(qid="M01", query="다이어트 보조제", tier="M", persona="marketer", domain="건강",
         n_answer=4, n_hard_neg=4, dup=False, hard_neg_note="운동 프로그램·건강식(보조제 아님)"),
    dict(qid="M02", query="겨울 코트", tier="M", persona="freelancer", domain="쇼핑",
         n_answer=5, n_hard_neg=4, dup=True, hard_neg_note="패딩·니트(겨울옷이지만 코트 아님)"),
    dict(qid="M03", query="동아리 엠티 장소", tier="M", persona="student", domain="장소",
         n_answer=4, n_hard_neg=4, dup=False, hard_neg_note="가족 여행 숙소·워크숍 장소"),
    dict(qid="M04", query="포트폴리오 레퍼런스", tier="M", persona="freelancer", domain="업무",
         n_answer=6, n_hard_neg=4, dup=True, hard_neg_note="이력서 양식·브랜딩 아티클"),
    dict(qid="M05", query="적금 금리", tier="M", persona="newlywed", domain="금융",
         n_answer=4, n_hard_neg=4, dup=False, hard_neg_note="파킹통장·주담대 금리(금리지만 다른 상품)"),
    dict(qid="M06", query="아이 예방접종", tier="M", persona="parent", domain="육아",
         n_answer=3, n_hard_neg=4, dup=False, hard_neg_note="성인 독감주사·소아과 일반 진료"),
    dict(qid="M07", query="홈카페 장비", tier="M", persona="newlywed", domain="취미",
         n_answer=5, n_hard_neg=4, dup=True, hard_neg_note="카페 방문 기록·원두 구독(장비 아님)"),
    dict(qid="M08", query="블로그 글감", tier="M", persona="freelancer", domain="업무",
         n_answer=4, n_hard_neg=3, dup=False, hard_neg_note="인스타 릴스 아이디어(콘텐츠지만 다른 채널)"),
    dict(qid="M09", query="명함 디자인", tier="M", persona="freelancer", domain="업무",
         n_answer=3, n_hard_neg=3, dup=False, hard_neg_note="로고·포스터 디자인"),
    dict(qid="M10", query="웨딩 스튜디오", tier="M", persona="newlywed", domain="행사",
         n_answer=5, n_hard_neg=4, dup=True, hard_neg_note="드레스·예식장(웨딩이지만 스튜디오 아님)"),
    dict(qid="M11", query="크리스마스 선물", tier="M", persona="parent", domain="쇼핑",
         n_answer=6, n_hard_neg=4, dup=False, hard_neg_note="어버이날·생일 선물"),
    dict(qid="M12", query="발표 템플릿", tier="M", persona="student", domain="교육",
         n_answer=4, n_hard_neg=3, dup=False, hard_neg_note="보고서 서식·노션 템플릿"),
    dict(qid="M13", query="베이킹 클래스", tier="M", persona="marketer", domain="취미",
         n_answer=3, n_hard_neg=3, dup=False, hard_neg_note="쿠킹(요리) 클래스·베이킹 도구 쇼핑"),
    dict(qid="M14", query="중고차 시세", tier="M", persona="jobseeker", domain="모빌리티",
         n_answer=4, n_hard_neg=4, dup=False, hard_neg_note="신차 프로모션·리스 견적"),
    dict(qid="M15", query="피부과 시술", tier="M", persona="marketer", domain="건강",
         n_answer=4, n_hard_neg=4, dup=True, hard_neg_note="홈케어 기기·화장품(피부지만 시술 아님)"),
    dict(qid="M16", query="책 추천", tier="M", persona="student", domain="문화",
         n_answer=6, n_hard_neg=4, dup=False, hard_neg_note="영화·팟캐스트 추천"),
    dict(qid="M17", query="일본 출장 준비물", tier="M", persona="marketer", domain="여행",
         n_answer=4, n_hard_neg=3, dup=False, hard_neg_note="일본 관광 코스(출장 준비 아님)"),
    dict(qid="M18", query="결혼식 축가", tier="M", persona="student", domain="행사",
         n_answer=3, n_hard_neg=3, dup=False, hard_neg_note="축의금·하객 코디"),
    dict(qid="M19", query="베란다 텃밭", tier="M", persona="parent", domain="취미",
         n_answer=4, n_hard_neg=3, dup=False, hard_neg_note="실내 화분 인테리어·주말농장 분양"),
    dict(qid="M20", query="아이패드 필기 앱", tier="M", persona="student", domain="전자기기",
         n_answer=5, n_hard_neg=4, dup=True, hard_neg_note="아이패드 액세서리·맥 필기 앱"),
    dict(qid="M21", query="한강 러닝", tier="M", persona="jobseeker", domain="건강",
         n_answer=4, n_hard_neg=3, dup=False, hard_neg_note="등산 코스·헬스장 PT"),
    dict(qid="M22", query="자격증 접수", tier="M", persona="jobseeker", domain="취업",
         n_answer=5, n_hard_neg=4, dup=True, hard_neg_note="자격증 공부법·시험 후기(접수 일정 아님)"),
    # ── S-tier: 정답 1 정밀 회상 + 하드 쿼리(오타·영문·신조어 — 한계 (a)) ──────
    dict(qid="S01", query="토스터 환불", tier="S", persona="newlywed", domain="쇼핑",
         n_answer=1, n_hard_neg=5, dup=False, hard_neg_note="같은 토스터의 구매평·다른 가전 환불 규정"),
    dict(qid="S02", query="치과 예약 변경", tier="S", persona="parent", domain="건강",
         n_answer=1, n_hard_neg=5, dup=False, hard_neg_note="치과 진료비 영수증·다른 병원 예약"),
    dict(qid="S03", query="공유기 비밀번호 바꾸는 법", tier="S", persona="student", domain="생활",
         n_answer=1, n_hard_neg=5, dup=False, hard_neg_note="와이파이 속도 측정·인터넷 요금제"),
    dict(qid="S04", query="회의실 예약 링크", tier="S", persona="marketer", domain="업무",
         n_answer=1, n_hard_neg=5, dup=False, hard_neg_note="화상회의 링크·장비 대여 신청"),
    dict(qid="S05", query="세탁기 에러코드 4C", tier="S", persona="newlywed", domain="생활",
         n_answer=1, n_hard_neg=5, dup=False, hard_neg_note="다른 에러코드(UE 등)·건조기 코드"),
    dict(qid="S06", query="맥북 M4 Pro 스펙", tier="S", persona="freelancer", domain="전자기기",
         n_answer=1, n_hard_neg=6, dup=False, hard_neg_note="M4(무印)·M3 Pro 스펙, 맥북 액세서리 — 영문 모델명 변별"),
    dict(qid="S07", query="에어팟 프로3 이어팁", tier="S", persona="student", domain="전자기기",
         n_answer=1, n_hard_neg=5, dup=False, hard_neg_note="에어팟 프로2 팁·다른 이어폰 폼팁 — 세대 변별"),
    dict(qid="S08", query="닌텐도 스위치2 예판", tier="S", persona="student", domain="취미",
         n_answer=1, n_hard_neg=5, dup=False, hard_neg_note="스위치1 중고 시세·PS5 예판 — 신조어(예판)+세대"),
    dict(qid="S09", query="챗지피티 팀 요금제", tier="S", persona="marketer", domain="업무",
         n_answer=1, n_hard_neg=5, dup=False, hard_neg_note="개인 Plus 요금제·다른 AI 구독 — 한/영 표기 변별"),
    dict(qid="S10", query="글램핑 위약금", tier="S", persona="parent", domain="여행",
         n_answer=1, n_hard_neg=5, dup=False, hard_neg_note="글램핑 예약 확정·펜션 위약금"),
    dict(qid="S11", query="자소서 항목별 글자수", tier="S", persona="jobseeker", domain="취업",
         n_answer=1, n_hard_neg=5, dup=False, hard_neg_note="자소서 첨삭 후기·다른 회사 공고"),
    dict(qid="S12", query="프리랜서 종소세 신고", tier="S", persona="freelancer", domain="금융",
         n_answer=1, n_hard_neg=5, dup=False, hard_neg_note="부가세·근로자 연말정산 — 세금 종류 변별"),
]

# filler 배치 — 쿼리와 무관한 자연 노이즈. 페르소나 일상을 넓게.
FILLER_SPECS = [
    dict(bid="F01", persona="student", domain="학사 일정·과제 공지", n=30),
    dict(bid="F02", persona="student", domain="알바·시간표·학식", n=30),
    dict(bid="F03", persona="student", domain="게임·유튜브·밈", n=30),
    dict(bid="F04", persona="marketer", domain="업무 문서·미팅 메모", n=30),
    dict(bid="F05", persona="marketer", domain="커피챗·업계 뉴스레터", n=30),
    dict(bid="F06", persona="marketer", domain="출퇴근·구내식당·경조사", n=30),
    dict(bid="F07", persona="newlywed", domain="인테리어·가구", n=30),
    dict(bid="F08", persona="newlywed", domain="신혼여행 후기·가계부", n=30),
    dict(bid="F09", persona="parent", domain="어린이집 알림장·키즈카페", n=30),
    dict(bid="F10", persona="parent", domain="가족 행사·건강검진", n=30),
    dict(bid="F11", persona="jobseeker", domain="채용 공고 스크랩(비면접)", n=30),
    dict(bid="F12", persona="jobseeker", domain="스터디·국비지원·멘토링", n=30),
    dict(bid="F13", persona="freelancer", domain="계약·세금계산서·클라이언트", n=30),
    dict(bid="F14", persona="freelancer", domain="장비 세팅·작업실", n=30),
    dict(bid="F15", persona="student", domain="여행 짠테크·기차표", n=30),
    dict(bid="F16", persona="parent", domain="마트 전단·생활용품", n=30),
    dict(bid="F17", persona="marketer", domain="운동 클래스·문화생활", n=30),
    dict(bid="F18", persona="freelancer", domain="레퍼런스 아카이브(디자인 외 분야)", n=30),
]

TYPE_MIX_NOTE = "screenshot 6 : link 2.5 : memo 1.5 비율을 배치 안에서 대략 지켜라"
STYLE_NOTE = (
    "문체를 섞어라 — 구어체 요약, 개조식(명사 나열) 요약, 한/영 혼용(브랜드·모델명), "
    "가끔 흔한 오타 1~2건(과하지 않게)"
)
