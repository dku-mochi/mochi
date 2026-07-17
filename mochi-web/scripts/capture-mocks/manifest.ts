import * as t from "./templates";

/* 촬영 매니페스트 — 파일명은 seed/personas/* 의 image.file 과 1:1 대응 */
export const SHOTS: Array<{ out: string; html: string }> = [
  /* ── sena ── */
  {
    out: "sena-lms-os.jpg",
    html: t.lms({
      course: "운영체제 (김정민)",
      title: "[과제 4] 페이지 교체 알고리즘 시뮬레이터 구현",
      author: "김정민 교수",
      date: "8월 3일 14:22",
      body: [
        "FIFO, LRU, Clock 세 가지 페이지 교체 알고리즘을 구현하고, 참조 문자열에 대한 페이지 폴트 횟수를 비교 분석하시오.",
        "보고서에는 알고리즘별 시간 복잡도와 실험 결과 그래프를 반드시 포함해야 합니다.",
        "지연 제출 시 일당 10% 감점됩니다.",
      ],
      due: "8월 12일 (수) 23:59 · LMS 업로드",
    }),
  },
  {
    out: "sena-dacon.jpg",
    html: t.poster({
      kicker: "2026 DATA CHALLENGE",
      title: "데이콘 AI<br/>경진대회",
      lines: ["기획서 — 8월 7일(금) 마감", "최종 산출물 — 8월 21일(금) 마감", "팀 단위 1~4인 · 온라인 제출"],
      footer: "주최 · 데이콘",
    }),
  },
  {
    out: "sena-kakao-team.jpg",
    html: t.kakao({
      room: "캡스톤 3조",
      count: 4,
      messages: [
        { from: "지우", text: "그럼 세나가 발표, 내가 슬라이드, 현우가 데모 영상 맡는 걸로!", time: "오후 9:12" },
        { from: "현우", text: "ㅇㅋ 목요일까지 데모 초안 올릴게", time: "오후 9:13" },
        { mine: true, text: "좋아, 대본은 내가 이번 주에 정리할게", time: "오후 9:13" },
        { from: "지우", text: "발표는 다음 주 화요일 3시 확정! 늦지 말기 🙅", time: "오후 9:15" },
      ],
    }),
  },
  {
    out: "sena-youtube-langchain.jpg",
    html: t.youtube({
      title: "LangChain으로 AI 에이전트 만들기 — 40분 완성 입문",
      channel: "코드랩",
      meta: "조회수 21만회 · 3주 전",
      duration: "41:07",
      progress: 8,
      next: [
        { t: "RAG 파이프라인 실전 구축 — 임베딩부터 평가까지", c: "코드랩", d: "28:44" },
        { t: "에이전트 도구 호출, 어디까지 믿어도 될까", c: "AI 위클리", d: "16:02" },
      ],
    }),
  },
  {
    out: "sena-contest.jpg",
    html: t.poster({
      kicker: "제 10 회",
      title: "교내 창업<br/>아이디어 공모전",
      lines: ["접수 — 8월 7일(금)까지", "팀 단위 1~4인 · 총상금 500만원", "본선 발표 — 8월 28일(금)"],
      footer: "주최 · 창업지원단",
    }),
  },
  {
    out: "sena-student-loan.jpg",
    html: t.article({
      outlet: "한국장학재단 · 학자금 지원 안내",
      title: "학자금 대출 이자 납부 안내",
      paras: [
        "납부 기한은 8월 19일(수) 18:00까지입니다.",
        "자동이체 계좌의 잔액과 등록 계좌 정보를 미리 확인해 주세요.",
        "납부 결과는 홈페이지의 대출 내역에서 확인할 수 있습니다.",
      ],
    }),
  },
  {
    out: "sena-python-error.jpg",
    html: t.code({
      title: "notebook.ipynb — Jupyter",
      theme: "light",
      lines: [
        { text: "asyncio.run(agent.invoke(query))", kind: "cmd" },
        { text: "" },
        { text: "RuntimeError: This event loop is already running", kind: "err" },
        { text: "  File \"<cell line: 1>\", line 1, in <module>", kind: "out" },
        { text: "" },
        { text: "# 해결 1 — Jupyter는 이미 루프가 돈다. await 직접 사용", kind: "cmt" },
        { text: "await agent.invoke(query)", kind: "hl" },
        { text: "" },
        { text: "# 해결 2 — 스크립트 호환이 필요하면", kind: "cmt" },
        { text: "import nest_asyncio", kind: "cmd" },
        { text: "nest_asyncio.apply()", kind: "cmd" },
      ],
    }),
  },
  {
    out: "sena-ticketing.jpg",
    html: t.booking({
      site: "티켓콘",
      title: "SUMMER SOUND 2026",
      subtitle: "여름 야외 페스티벌 · 난지한강공원",
      openLabel: "1차 티켓 오픈",
      openValue: "7/9 (목) 20:00",
      notice: ["1인 4매 한정, 취소표는 매주 수요일 오후 풀립니다.", "오픈 10분 전 대기열 입장을 권장합니다."],
      heroCss: "linear-gradient(160deg,#FF9A6C 0%,#F0567A 45%,#5B3FD1 100%)",
      cta: "오픈 알림 받기",
    }),
  },
  {
    out: "sena-kakao-mt.jpg",
    html: t.kakao({
      room: "중앙동아리 공지",
      count: 42,
      messages: [
        {
          card: {
            title: "여름 MT 공지 🏕",
            lines: ["8/22(토) ~ 23(일) · 가평", "회비 45,000원 (버스 포함)", "참석 투표는 8/7(금)까지!"],
            deco: "SUMMER MT",
          },
        },
        { from: "회장", text: "투표 안 하면 자리 없어요~ 서둘러주세요", time: "오후 6:02" },
      ],
    }),
  },
  /* ── dohyun ── */
  {
    out: "dohyun-k8s.jpg",
    html: t.code({
      title: "kubectl-cheatsheet.md",
      theme: "dark",
      lines: [
        { text: "# 파드 상태 한눈에", kind: "cmt" },
        { text: "kubectl get pods -A -o wide", kind: "cmd" },
        { text: "" },
        { text: "# 로그 스트리밍 (최근 100줄부터)", kind: "cmt" },
        { text: "kubectl logs -f deploy/api --tail=100", kind: "cmd" },
        { text: "" },
        { text: "# 왜 죽었는지 — Events 섹션부터 본다", kind: "cmt" },
        { text: "kubectl describe pod api-7d4b9c", kind: "cmd" },
        { text: "" },
        { text: "# 재배포 없이 롤링 재시작", kind: "cmt" },
        { text: "kubectl rollout restart deploy/api", kind: "hl" },
        { text: "" },
        { text: "# 컨테이너 안으로", kind: "cmt" },
        { text: "kubectl exec -it api-7d4b9c -- sh", kind: "cmd" },
        { text: "" },
        { text: "# 리소스 사용량 정렬", kind: "cmt" },
        { text: "kubectl top pods --sort-by=memory", kind: "cmd" },
      ],
    }),
  },
  {
    out: "dohyun-oom.jpg",
    html: t.code({
      title: "k9s — pod/api-7d4b9c",
      theme: "dark",
      lines: [
        { text: "Last State:   Terminated", kind: "out" },
        { text: "  Reason:     OOMKilled", kind: "err" },
        { text: "  Exit Code:  137", kind: "err" },
        { text: "" },
        { text: "# 대응 순서 메모", kind: "cmt" },
        { text: "1. requests/limits 재계산 — 피크 기준 x1.4", kind: "hl" },
        { text: "2. 죽기 전 힙 덤프 확보 (preStop hook)", kind: "out" },
        { text: "3. JVM 이면 Xmx 는 limit 의 75% 로", kind: "out" },
        { text: "4. 재발 시 메모리 프로파일링 티켓 발행", kind: "out" },
      ],
    }),
  },
  {
    out: "dohyun-ddia.jpg",
    html: t.article({
      outlet: "데이터 중심 애플리케이션 설계 · 6장",
      title: "파티셔닝",
      serif: true,
      paras: [
        "키 범위 파티셔닝은 범위 스캔에 유리하지만, 접근이 몰리는 키 구간이 생기면 특정 파티션만 뜨거워지는 핫스팟 위험이 있다.",
        "해시 파티셔닝은 부하를 균등하게 흩뿌리지만, 그 대가로 범위 질의 능력을 잃는다. 인접한 키가 서로 다른 파티션에 흩어지기 때문이다.",
        "결국 워크로드의 질의 패턴이 선택을 결정한다 — 균등함과 지역성은 동시에 가질 수 없다.",
      ],
    }),
  },
  {
    out: "dohyun-slack.jpg",
    html: t.slack({
      channel: "backend",
      messages: [
        {
          name: "지현",
          color: "#2E7D6B",
          time: "오전 10:24",
          html: '결제 API v2 마이그레이션 PR 올렸습니다. <span class="mention">@도현</span> 이번 주 안에 리뷰 부탁드려요!',
        },
        {
          name: "지현",
          color: "#2E7D6B",
          time: "오전 10:25",
          html: '스키마 변경 포함이라 <span class="code">payments_v2</span> 테이블 인덱스 쪽 꼼꼼히 봐주세요 🙏',
        },
        { name: "도현", color: "#4A5FC1", time: "오전 10:31", html: "넵, 목요일 리허설 전까지 볼게요" },
      ],
    }),
  },
  {
    out: "dohyun-gpu.jpg",
    html: t.article({
      outlet: "인프라 비용 노트",
      title: "GPU 인스턴스 가격 비교 (시간당)",
      paras: ["배치 추론은 spot + 체크포인트 조합이 정답에 가깝다. 중단 내성만 확보되면 60%가 그냥 굳는다."],
      table: {
        headers: ["인스턴스", "온디맨드", "Spot", "절감"],
        rows: [
          ["L4 24GB", "$0.71", "$0.28", "-61%"],
          ["A100 40GB", "$2.93", "$1.15", "-61%"],
          ["A100 80GB", "$4.10", "$1.71", "-58%"],
          ["H100 80GB", "$6.98", "$2.85", "-59%"],
        ],
      },
    }),
  },
  {
    out: "dohyun-kakao.jpg",
    html: t.kakao({
      room: "우리팀",
      count: 8,
      messages: [
        { from: "팀장", text: "다음 주 금요일 저녁 팀 회식입니다. 장소는 회사 앞 양꼬치, 7시!", time: "오후 5:40" },
        { from: "팀장", text: "불참자는 미리 알려주세요~", time: "오후 5:40" },
        { mine: true, text: "참석이요 🙋", time: "오후 5:52" },
      ],
    }),
  },
  /* ── yuna ── */
  {
    out: "yuna-cafe-bakery.jpg",
    html: t.insta({
      handle: "seongsu.bakery",
      location: "서울 성동구 성수동",
      photo: {
        css: "radial-gradient(120% 90% at 20% 15%, #F7E3C2 0%, transparent 55%), radial-gradient(100% 100% at 80% 90%, #C89B6D 0%, transparent 60%), linear-gradient(160deg, #EAD3AE, #A9784C)",
        label: "오전에만 굽는 소금빵",
        sub: "11시 전 방문 추천",
      },
      likes: "2,481",
      caption: "성수역 3번 출구 도보 5분. 소금빵은 오전 소진이 기본입니다 🥐",
      time: "3일 전",
    }),
  },
  {
    out: "yuna-cafe-window.jpg",
    html: t.insta({
      handle: "cafe.windowseat",
      location: "서울숲 카페거리",
      photo: {
        css: "radial-gradient(110% 80% at 75% 20%, #DCEBDD 0%, transparent 60%), radial-gradient(90% 90% at 20% 85%, #90A98F 0%, transparent 55%), linear-gradient(150deg, #C7D8C3, #6E8A6B)",
        label: "통창으로 서울숲 뷰",
        sub: "평일 오후가 한산해요 · 라떼 맛집",
      },
      likes: "1,904",
      caption: "창가 자리는 오픈런이 답. 평일 2-4시가 제일 여유로워요",
      time: "6일 전",
    }),
  },
  {
    out: "yuna-cafe-brunch.jpg",
    html: t.insta({
      handle: "brunch.seongsu",
      location: "성수동 카페거리",
      photo: {
        css: "radial-gradient(120% 90% at 25% 20%, #FBE7D4 0%, transparent 55%), radial-gradient(100% 90% at 80% 85%, #E2A17A 0%, transparent 60%), linear-gradient(155deg, #F3CDA8, #C97B4E)",
        label: "리코타 토스트",
        sub: "주말 브런치 11:00–15:00",
      },
      likes: "3,112",
      caption: "주말 웨이팅 30분 각오. 리코타 토스트가 시그니처 🍞",
      time: "1주 전",
    }),
  },
  {
    out: "yuna-dress.jpg",
    html: t.shop({
      brand: "린앤코",
      name: "린넨 라이크 미디 원피스",
      price: "89,000원",
      coupon: "여름 프리오더 10% 쿠폰 · 7/10까지",
      colors: ["크림", "세이지"],
      photoCss: "linear-gradient(165deg,#F4EFE6 0%,#E9DFCC 60%,#DCCFB4 100%)",
    }),
  },
  {
    out: "yuna-exhibition.jpg",
    html: t.booking({
      site: "아트티켓",
      title: "빛의 정원 — 미디어아트展",
      subtitle: "몰입형 미디어아트 · 성수 언더스탠드",
      openLabel: "2차 예매 오픈",
      openValue: "7/10 (금) 14:00",
      notice: ["주말 회차는 조기 매진이 예상됩니다.", "회차당 입장 인원 80명 제한."],
      heroCss: "radial-gradient(130% 100% at 20% 10%, #7C5CFF 0%, transparent 60%), radial-gradient(120% 100% at 85% 90%, #21C08B 0%, transparent 55%), linear-gradient(160deg,#141235,#0B0A1E)",
      cta: "예매 알림 신청",
    }),
  },
  {
    out: "yuna-popup.jpg",
    html: t.article({
      outlet: "캠페인 레퍼런스",
      title: "F/W 팝업 '방의 기록' 공간 노트",
      paras: [
        "입장 동선 초입에 향 경험을 배치 — 브랜드 기억을 후각으로 먼저 연다.",
        "아카이브 선반 연출: 제품이 아니라 '수집된 기록'처럼 보이게. 관람객 평균 체류시간 23분.",
        "포토 스팟은 출구 직전 하나만. 동선 정체가 사라지고 마지막 인상이 남는다.",
      ],
    }),
  },
  {
    out: "yuna-book.jpg",
    html: t.article({
      outlet: "기록의 쓸모 · p.87",
      title: "",
      serif: true,
      quote: "기록은 기억을 대신하지 않는다. 기억이 돌아올 자리를 마련해 둘 뿐이다.",
      paras: [
        "우리는 잊기 위해 기록한다는 말을 오해해왔다. 잊어도 괜찮아지기 위해 기록하는 것이다.",
        "그러니 좋은 기록 도구는 저장을 돕는 것이 아니라, 돌아오는 길을 만들어 준다.",
      ],
    }),
  },
  {
    out: "yuna-wedding.jpg",
    html: t.kakao({
      room: "수민",
      messages: [
        {
          card: {
            title: "김수민 ♥ 이준호",
            lines: ["8월 30일 (일) 12:30", "더채플앳청담 3F 아모리스홀", "마음 편히 오셔서 축하해 주세요"],
            deco: "INVITATION",
          },
        },
        { from: "수민", text: "유나야 꼭 와야 해!! 🤍", time: "오후 2:11" },
        { mine: true, text: "당연하지, 벌써 설렌다 👰", time: "오후 2:13" },
      ],
    }),
  },
  {
    out: "yuna-flower.jpg",
    html: t.insta({
      handle: "flower.atelier",
      location: "연희동 작업실",
      photo: {
        css: "radial-gradient(110% 85% at 25% 20%, #F9D9E0 0%, transparent 55%), radial-gradient(95% 95% at 78% 80%, #D98BA4 0%, transparent 60%), linear-gradient(150deg, #F2C4CF, #A5586F)",
        label: "7월 원데이클래스",
        sub: "여름 꽃다발 · 4인 소규모",
      },
      likes: "864",
      caption: "7/16(목) 19:30 여름 꽃다발 클래스. 자리 얼마 없어요, DM 주세요 🌷",
      time: "2일 전",
    }),
  },
  {
    out: "yuna-namyangju.jpg",
    html: t.kakao({
      room: "주말 나들이",
      count: 4,
      messages: [
        {
          card: {
            title: "남양주 당일치기 코스",
            lines: ["8월 29일(토) · 친구들과", "물의정원 → 카페거리", "정약용 유적지에서 마무리"],
            deco: "DAY TRIP",
          },
        },
        { from: "유나", text: "오전 10시에 물의정원 입구에서 만나자!", time: "오후 8:42" },
      ],
    }),
  },
];
