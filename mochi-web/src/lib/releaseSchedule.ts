export const CODE_REPOSITORY_VISIBLE_FROM = Date.parse("2026-07-20T00:00:00+09:00");

export function isCodeRepositoryVisible(now = Date.now()): boolean {
  return now >= CODE_REPOSITORY_VISIBLE_FROM;
}
