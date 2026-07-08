import { ChatScene } from "@/components/chat/ChatScene";

/* S5 질문 — 근거 인용 + proposal 확정 (읽기는 자유, 쓰기는 사용자 확정) */
export default async function ChatPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const { q } = await searchParams;
  return <ChatScene initialQuery={q} />;
}
