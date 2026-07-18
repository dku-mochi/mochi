import type { ResolvedItem } from "@/lib/seedRuntime";

export interface PurchaseSearchFallback {
  url: string;
  label: string;
  query: string;
}

function isHttpUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

/** 정확한 구매 링크를 못 찾았을 때만 서버가 추출한 상품명으로 검색 행동을 보존한다. */
export function purchaseSearchFallback(item: ResolvedItem): PurchaseSearchFallback | null {
  const query = item.shoppingProductQuery?.trim();
  if (!query) return null;

  const hasPurchaseLink = (item.referenceLinks ?? []).some(
    (reference) => reference.role === "buy" && isHttpUrl(reference.url),
  );
  if (hasPurchaseLink) return null;

  const url = new URL("https://search.naver.com/search.naver");
  url.searchParams.set("query", query);
  return {
    url: url.toString(),
    label: "네이버에서 상품 찾기",
    query,
  };
}
