import type { SeedPersona } from "../schema";

/*
 * 박도현 — 29, 3년차 백엔드 개발자.
 * 페인포인트: 카톡으로 받은 기술 링크를 다시 못 찾는다 (PRODUCT.md §2.1).
 * intent 무게중심: 지식. 서사 축:
 *  1) 검색 개선 클러스터 — pgvector·하이브리드 검색·리랭커 3건 → 사내 스터디 발표로 이어짐
 *  2) k8s 치트시트 — 자주 다시 보는 기록 (revisitedOften)
 *  3) 회사 일 — 슬랙 리뷰 요청, 배포 일정, 장애 회고
 * 이미지: 목업 캡처 6장.
 */
const dohyun: SeedPersona = {
  slug: "dohyun",
  name: "박도현",
  age: 29,
  job: "백엔드 개발자 · 3년차",
  tagline: "카톡으로 받은 링크는 다시 찾으면 없다",
  intro:
    "아티클은 열심히 담아두는데, 정작 필요할 때는 어느 채팅방이었는지부터 뒤진다.",
  uuidEnvKey: "MOCHI_PERSONA_UUID_DOHYUN",
  accent: "mint",
  heroSlugs: ["blog-pgvector", "k8s-cheatsheet", "slack-api-migration"],
  suggestedSearch: [
    "검색 개선 관련해서 모아둔 자료",
    "카톡으로 받은 모니터링 글",
    "다음 주 일정",
  ],
  suggestedChat: [
    "검색 성능 개선 자료 모아서 발표 목차 잡아줘",
    "카톡으로 받았던 모니터링 아티클 찾아줘",
  ],
  items: [
    // ── 검색 개선 클러스터 (스터디 발표의 근거) ──────────
    {
      slug: "blog-pgvector",
      kind: "url",
      channel: "safari",
      source: "Safari",
      title: "pgvector HNSW 인덱스 튜닝기",
      url: "https://github.com/pgvector/pgvector#hnsw",
      text: "m·ef_construction 조합별 recall/latency 트레이드오프 실측",
      userMemo: "우리 검색 느린 거 이걸로 잡아보자",
      category: "개발·검색",
      summary:
        "pgvector HNSW 튜닝 — m·ef_construction 조합별 recall/latency 실측. 검색 지연 개선 후보 1순위.",
      instances: [
        {
          intentType: "knowledge",
          label: "pgvector 튜닝",
          payload: { topic: "검색 개선", url: "https://github.com/pgvector/pgvector#hnsw" },
        },
      ],
      capturedDaysAgo: 6,
      relatedSlugs: ["blog-hybrid-search", "blog-reranker", "study-presentation"],
      favorite: true,
    },
    {
      slug: "blog-hybrid-search",
      kind: "url",
      channel: "appShareSheet",
      source: "공유",
      title: "BM25 + 벡터, 하이브리드 검색 설계",
      url: "https://opensearch.org/docs/latest/search-plugins/hybrid-search/",
      text: "키워드 정확도와 의미 검색을 RRF로 합치는 구조",
      category: "개발·검색",
      summary:
        "하이브리드 검색 설계 — BM25와 벡터 결과를 RRF로 융합. 정확 일치 질의가 무너지는 문제의 해법.",
      instances: [
        {
          intentType: "knowledge",
          label: "하이브리드 검색",
          payload: { topic: "검색 개선" },
        },
      ],
      capturedDaysAgo: 8,
      relatedSlugs: ["blog-pgvector", "blog-reranker"],
    },
    {
      slug: "blog-reranker",
      kind: "url",
      channel: "safari",
      source: "Safari",
      title: "리랭커 붙이면 뭐가 달라지나",
      url: "https://www.sbert.net/examples/applications/retrieve_rerank/README.html",
      text: "cross-encoder 리랭킹으로 top-k 품질 올리기 — 비용은 얼마나 드는지",
      category: "개발·검색",
      summary:
        "cross-encoder 리랭킹 정리 — top-k 품질 향상 폭과 추가 지연 비용. 2차 개선 후보.",
      instances: [
        {
          intentType: "knowledge",
          label: "리랭커",
          payload: { topic: "검색 개선" },
        },
      ],
      capturedDaysAgo: 4,
      relatedSlugs: ["blog-pgvector", "blog-hybrid-search"],
    },
    {
      slug: "kakao-monitoring-link",
      kind: "url",
      channel: "kakaoTalk",
      source: "카카오톡",
      title: "Grafana로 API 지연 잡아낸 이야기",
      url: "https://grafana.com/blog/",
      text: "선배가 보내준 글 — p99 지연 원인을 대시보드로 좁혀가는 과정",
      userMemo: "선배가 준 링크. 나중에 정독",
      category: "개발·모니터링",
      summary:
        "Grafana 대시보드로 p99 지연 원인을 좁혀가는 실전기 — 카톡으로 받아서 저장.",
      instances: [
        {
          intentType: "knowledge",
          label: "모니터링 실전기",
          payload: { topic: "모니터링" },
        },
      ],
      capturedDaysAgo: 9,
    },
    // ── 자주 보는 레퍼런스 ──────────
    {
      slug: "k8s-cheatsheet",
      kind: "screenshot",
      channel: "screenshot",
      source: "스크린샷",
      title: "kubectl 치트시트",
      ocrText:
        "kubectl get pods -A / logs -f --tail=100 / describe pod / rollout restart deploy / exec -it -- sh / top pods",
      category: "개발·인프라",
      summary: "자주 쓰는 kubectl 명령 모음 — 로그, 롤아웃 재시작, 리소스 확인.",
      instances: [
        {
          intentType: "knowledge",
          label: "kubectl 치트시트",
          payload: { topic: "쿠버네티스" },
        },
      ],
      image: { file: "/seed/caps/dohyun-k8s.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 30,
      favorite: true,
    },
    {
      slug: "error-oom",
      kind: "screenshot",
      channel: "screenshot",
      source: "스크린샷",
      title: "OOMKilled 트러블슈팅",
      ocrText:
        "Last State: Terminated, Reason: OOMKilled — requests/limits 재계산, 힙 덤프 확보, JVM Xmx는 limit의 75%",
      category: "개발·인프라",
      summary:
        "파드 OOMKilled 대응 절차 — 메모리 limit 재계산과 힙 덤프 확보 순서.",
      instances: [
        {
          intentType: "knowledge",
          label: "OOM 트러블슈팅",
          payload: { topic: "쿠버네티스" },
        },
      ],
      image: { file: "/seed/caps/dohyun-oom.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 14,
      relatedSlugs: ["k8s-cheatsheet"],
    },
    {
      slug: "yt-system-design",
      kind: "url",
      channel: "youtube",
      source: "YouTube",
      title: "URL 단축기 시스템 디자인 풀이",
      url: "https://www.youtube.com/results?search_query=system+design+url+shortener",
      text: "해싱 충돌·캐시 전략·읽기 폭주 대응을 30분에 정리",
      category: "개발·학습",
      summary: "시스템 디자인 연습 — URL 단축기 사례로 캐시·샤딩 전략 정리.",
      instances: [
        {
          intentType: "knowledge",
          label: "시스템 디자인",
          payload: { topic: "시스템 디자인" },
        },
      ],
      capturedDaysAgo: 11,
    },
    {
      slug: "book-ddia",
      kind: "screenshot",
      channel: "screenshot",
      source: "스크린샷",
      title: "DDIA — 파티셔닝 챕터",
      ocrText:
        "키 범위 파티셔닝은 스캔에 유리하지만 핫스팟 위험. 해시 파티셔닝은 균등하지만 범위 질의를 잃는다.",
      category: "개발·학습",
      summary:
        "『데이터 중심 애플리케이션 설계』 파티셔닝 — 키 범위 vs 해시의 트레이드오프.",
      instances: [
        {
          intentType: "knowledge",
          label: "DDIA 파티셔닝",
          payload: { topic: "데이터베이스" },
        },
      ],
      image: { file: "/seed/caps/dohyun-ddia.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 17,
    },
    // ── 회사 일 ──────────
    {
      slug: "slack-api-migration",
      kind: "screenshot",
      channel: "screenshot",
      source: "스크린샷",
      title: "결제 API v2 마이그레이션 리뷰 요청",
      ocrText:
        "#backend 지현: 결제 API v2 마이그레이션 PR 올렸습니다. 도현님 이번 주 안에 리뷰 부탁드려요! 스키마 변경 포함이라 꼼꼼히 봐주세요.",
      category: "회사·업무",
      summary:
        "결제 API v2 마이그레이션 PR 리뷰 요청 — 스키마 변경 포함, 이번 주 내 리뷰 필요.",
      instances: [
        {
          intentType: "todo",
          label: "마이그레이션 PR 리뷰",
          payload: { title: "결제 API v2 PR 리뷰", deadlineInDays: 4, person: "지현" },
        },
      ],
      image: { file: "/seed/caps/dohyun-slack.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 1,
    },
    {
      slug: "deploy-schedule",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "정기 배포",
      text: "이번 스프린트 정기 배포 금요일 11시. 배포 전 마이그레이션 리허설 목요일에.",
      category: "회사·업무",
      summary: "정기 배포 금요일 11:00 — 목요일에 마이그레이션 리허설 선행.",
      instances: [
        {
          intentType: "schedule",
          label: "정기 배포",
          payload: { title: "정기 배포", dateInDays: 4, time: "11:00" },
        },
        {
          intentType: "todo",
          label: "마이그레이션 리허설",
          payload: { title: "배포 리허설", deadlineInDays: 3 },
        },
      ],
      capturedDaysAgo: 2,
    },
    {
      slug: "study-presentation",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "사내 스터디 발표",
      text: "다다음주 수요일 사내 스터디에서 '우리 팀 검색 개선기' 발표. 모아둔 자료로 목차부터.",
      category: "회사·스터디",
      summary:
        "사내 스터디 발표 '검색 개선기' — 다다음주 수요일. 저장해둔 검색 자료 3건이 재료.",
      instances: [
        {
          intentType: "schedule",
          label: "스터디 발표",
          payload: { title: "사내 스터디 발표", dateInDays: 9, time: "19:00" },
        },
        {
          intentType: "todo",
          label: "발표 목차 잡기",
          payload: { title: "발표 목차 초안", deadlineInDays: 5 },
        },
      ],
      capturedDaysAgo: 3,
      relatedSlugs: ["blog-pgvector", "blog-hybrid-search", "blog-reranker"],
    },
    {
      slug: "postmortem-notes",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "6월 장애 회고 메모",
      text: "커넥션 풀 고갈 원인은 재시도 폭주. 백오프 없는 재시도가 문제였고, 서킷브레이커 도입 논의로 마무리.",
      category: "회사·업무",
      summary:
        "6월 장애 회고 — 백오프 없는 재시도가 커넥션 풀 고갈 유발. 서킷브레이커 도입 논의.",
      instances: [{ intentType: "memo", label: "장애 회고" }],
      capturedDaysAgo: 13,
    },
    {
      slug: "code-review-checklist",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "코드리뷰 체크리스트",
      text: "1) 롤백 가능한가 2) 인덱스 타는가 3) 트랜잭션 경계 4) 에러 메시지에 컨텍스트 5) 테스트가 실패를 증명하는가",
      category: "개발·습관",
      summary: "리뷰 때 매번 확인하는 5가지 — 롤백·인덱스·트랜잭션·에러 컨텍스트·테스트.",
      instances: [
        {
          intentType: "knowledge",
          label: "리뷰 체크리스트",
          payload: { topic: "코드리뷰" },
        },
      ],
      capturedDaysAgo: 21,
    },
    {
      slug: "gpu-pricing",
      kind: "screenshot",
      channel: "screenshot",
      source: "스크린샷",
      title: "GPU 인스턴스 가격 비교",
      ocrText:
        "L4 시간당 $0.71 / A100 40GB $2.93 / spot 적용 시 60% 절감 — 배치 추론은 spot + 체크포인트 조합 추천",
      category: "개발·인프라",
      summary:
        "GPU 인스턴스 가격 비교 — 배치 추론은 spot(60% 절감)+체크포인트 조합이 유리.",
      instances: [
        {
          intentType: "knowledge",
          label: "GPU 가격",
          payload: { topic: "인프라 비용" },
        },
      ],
      image: { file: "/seed/caps/dohyun-gpu.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 10,
    },
    // ── 커뮤니티·생활 ──────────
    {
      slug: "pycon-ticket",
      kind: "url",
      channel: "safari",
      source: "Safari",
      title: "파이콘 한국 2026 티켓 오픈",
      url: "https://pycon.kr/",
      text: "얼리버드 티켓 7/10(금) 오전 10시 오픈 — 작년엔 이틀 만에 마감",
      category: "커뮤니티",
      summary: "파이콘 얼리버드 티켓 — 7/10(금) 10:00 오픈. 작년 이틀 만에 마감.",
      instances: [
        {
          intentType: "schedule",
          label: "파이콘 티켓 오픈",
          payload: { title: "파이콘 얼리버드 티켓팅", dateInDays: 3, time: "10:00" },
        },
      ],
      capturedDaysAgo: 5,
    },
    {
      slug: "team-dinner",
      kind: "screenshot",
      channel: "kakaoTalk",
      source: "카카오톡",
      title: "팀 회식 공지",
      ocrText:
        "팀장: 다음 주 금요일 저녁 팀 회식입니다. 장소는 회사 앞 양꼬치, 7시! 불참자는 미리 알려주세요.",
      category: "회사·모임",
      summary: "팀 회식 — 다음 주 금요일 19:00, 회사 앞 양꼬치.",
      instances: [
        {
          intentType: "schedule",
          label: "팀 회식",
          payload: { title: "팀 회식 (양꼬치)", dateInDays: 11, time: "19:00" },
        },
      ],
      image: { file: "/seed/caps/dohyun-kakao.jpg", width: 780, height: 1688 },
      capturedDaysAgo: 2,
    },
    {
      slug: "side-project-idea",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "사이드 프로젝트 아이디어",
      text: "러닝 기록을 주간 리포트로 만들어주는 봇. 스트라바 API + 주 1회 요약 메일. 주말에 프로토타입.",
      category: "사이드 프로젝트",
      summary:
        "러닝 주간 리포트 봇 아이디어 — 스트라바 API 연동, 주 1회 요약. 주말 프로토타입 목표.",
      instances: [{ intentType: "memo", label: "아이디어 기록" }],
      capturedDaysAgo: 8,
    },
    {
      slug: "dentist",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "치과 스케일링",
      text: "다음 주 월요일 저녁 6시 반 치과 스케일링. 미루면 또 반년 밀린다.",
      category: "생활·건강",
      summary: "치과 스케일링 — 다음 주 월요일 18:30.",
      instances: [
        {
          intentType: "schedule",
          label: "치과 예약",
          payload: { title: "치과 스케일링", dateInDays: 7, time: "18:30" },
        },
      ],
      capturedDaysAgo: 3,
    },
    {
      slug: "moving-checklist",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "이사 준비",
      text: "이사 8월 초 확정. 전입신고, 인터넷 이전 신청, 입주 청소 견적 2곳 비교까지 이번 달 안에.",
      category: "생활",
      summary: "8월 초 이사 — 전입신고·인터넷 이전·청소 견적을 이번 달 내 처리.",
      instances: [
        {
          intentType: "todo",
          label: "이사 준비",
          payload: { title: "인터넷 이전 신청", deadlineInDays: 16 },
        },
      ],
      capturedDaysAgo: 6,
    },
    {
      slug: "gym-pt",
      kind: "memo",
      channel: "appDirectInput",
      source: "직접 입력",
      title: "PT 재개",
      text: "수요일 저녁 8시 PT 재개. 이번엔 3개월 끊었으니 최소 주 1회는 지키기.",
      category: "생활·건강",
      summary: "PT 수요일 20:00 재개 — 주 1회 최소 유지 목표.",
      instances: [
        {
          intentType: "schedule",
          label: "PT",
          payload: { title: "PT", dateInDays: 2, time: "20:00" },
        },
      ],
      capturedDaysAgo: 4,
    },
  ],
  recall: [
    {
      itemSlug: "blog-pgvector",
      kind: "relatedCluster",
      oneline: "검색 개선 기록이 두 주 새 세 개 모였어요",
      gist: ["pgvector 튜닝 + 하이브리드 + 리랭커", "스터디 발표 재료로 묶기 좋아요"],
    },
    {
      itemSlug: "k8s-cheatsheet",
      kind: "revisitedOften",
      oneline: "이번 달에만 다섯 번 열어보셨어요",
      gist: ["자주 쓰는 kubectl 명령 모음", "즐겨찾기에 있어요"],
    },
    {
      itemSlug: "kakao-monitoring-link",
      kind: "fadingValue",
      oneline: "카톡에서 받고 9일째, 아직 안 읽으셨어요",
      gist: ["p99 지연을 대시보드로 좁혀가는 실전기", "'나중에 정독'이라고 메모하셨어요"],
    },
    {
      itemSlug: "study-presentation",
      kind: "linkedToRecent",
      oneline: "요즘 보시는 검색 자료와 이어지는 발표예요",
      gist: ["발표 목차 초안 마감이 다가와요", "재료 3건이 이미 모여 있어요"],
    },
  ],
  cannedChat: [],
  cannedSearch: [],
};

export default dohyun;
