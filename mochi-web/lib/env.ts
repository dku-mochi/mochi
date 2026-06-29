import "server-only";

// ─────────────────────────────────────────────────────────────
// 서버 전용 환경변수 (BFF). 브라우저로 절대 노출 금지 — 'use client' 파일에서 import 금지.
// (server-only 가드: 클라 컴포넌트가 실수로 import 하면 빌드가 실패한다.)
// 모든 백엔드 호출은 app/api/* Route Handler를 통해서만 일어난다.
// ─────────────────────────────────────────────────────────────

export const serverEnv = {
  /** 배포된 모찌 백엔드 (INFRA.md). 끝 슬래시 없음. */
  backendBaseUrl: (process.env.MOCHI_BACKEND_URL ?? "https://34-64-104-136.nip.io").replace(/\/$/, ""),
  /** 데모 유저 refresh token (180일). svc에서 1회 발급해 Vercel env로 주입. */
  demoRefreshToken: process.env.MOCHI_DEMO_REFRESH_TOKEN ?? "",
  /** (선택) 미리 발급한 access token — refresh 실패 시 폴백. */
  demoAccessToken: process.env.MOCHI_DEMO_ACCESS_TOKEN ?? "",
  /** 백엔드 access JWT 자체발급용 시크릿 — AUTH_ACCESS_SECRET (서버 전용). */
  jwtSecret: process.env.MOCHI_JWT_SECRET ?? "",
  /** 데모 유저 id (자체발급 JWT의 subject). */
  demoUserId: process.env.MOCHI_DEMO_USER_ID ?? "",
  /** BFF rate-limit: 세션당 분당 ingest 허용 수. */
  ingestPerMinute: Number(process.env.MOCHI_INGEST_PER_MINUTE ?? "6"),
  /** 라이브 프록시 활성 여부. 토큰 없거나 OFF면 씨드 폴백으로 graceful degrade. */
  get liveEnabled(): boolean {
    return (
      process.env.MOCHI_LIVE_DISABLED !== "1" &&
      ((this.jwtSecret !== "" && this.demoUserId !== "") ||
        this.demoRefreshToken !== "" ||
        this.demoAccessToken !== "")
    );
  },
} as const;

/** 입력 검증 상한 (codex ISSUE-4 보안 표면 축소). */
export const limits = {
  textMaxLen: 2000,
  imageMaxBytes: 8 * 1024 * 1024, // 8MB
  imageMimeAllow: ["image/png", "image/jpeg", "image/webp", "image/heic"],
} as const;
