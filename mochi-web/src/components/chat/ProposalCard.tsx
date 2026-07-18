"use client";

import { AnimatePresence, motion } from "framer-motion";
import {
  Calendar,
  Check,
  BellRing,
  FileText,
  PencilLine,
  Trash2,
  Loader2,
  AlertCircle,
  Smartphone,
} from "lucide-react";
import type { ProposalType } from "@/lib/api/wire";
import type { ChatProposal } from "@/lib/hooks/useChatStream";
import { cn } from "@/lib/cn";

/*
 * iOS ProposalCardView 이식 — LLM 은 read-only, 이 카드의 확정 탭이 유일한 쓰기.
 * pending → confirming("하고 있어요…") → confirmed("완료했어요") / cancelled.
 */

const META: Record<ProposalType, { label: string; Icon: typeof Calendar; danger?: boolean }> = {
  create_schedule: { label: "캘린더에 등록", Icon: Calendar },
  reminder: { label: "알림 만들기", Icon: BellRing },
  create_memo: { label: "메모로 저장", Icon: FileText },
  item_update: { label: "기록 수정", Icon: PencilLine },
  item_delete: { label: "기록 삭제", Icon: Trash2, danger: true },
};

function payloadSummary(p: ChatProposal): string {
  const { title, note, date, time, text } = p.payload as Record<string, string | undefined>;
  const display = p.payload.display && typeof p.payload.display === "object"
    ? (p.payload.display as Record<string, string | undefined>)
    : {};
  return [display.title, title, [date, time].filter(Boolean).join(" "), note, text]
    .filter(Boolean)
    .join(" · ");
}

export function ProposalCard({
  proposal,
  onConfirm,
  onCancel,
}: {
  proposal: ChatProposal;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  const meta = META[proposal.type];
  const done = proposal.status === "confirmed";
  const preview = proposal.status === "preview";
  const cancelled = proposal.status === "cancelled";

  return (
    <div
      className={cn(
        "overflow-hidden rounded-2xl border transition-colors duration-300",
        meta.danger
          ? "border-blush-100 bg-blush-100/40"
          : done
            ? "border-mint-100 bg-mint-100/40"
            : preview
              ? "border-sky-100 bg-sky-100/40"
            : "border-purple-100 bg-purple-50/70",
        cancelled && "opacity-55",
      )}
    >
      <div className="flex items-center gap-3 p-3.5">
        <span
          className={cn(
            "flex size-10 flex-none items-center justify-center rounded-xl",
            meta.danger ? "bg-blush-100 text-blush-400" : "bg-surface text-purple-500 shadow-card",
          )}
        >
          <meta.Icon className="size-4.5" aria-hidden />
        </span>
        <div className="min-w-0 flex-1">
          <p className="text-[13.5px] font-bold text-ink-900">{meta.label}</p>
          <p className="mt-0.5 truncate text-[12.5px] text-ink-500">
            {payloadSummary(proposal)}
          </p>
        </div>

        <AnimatePresence mode="wait" initial={false}>
          {(proposal.status === "pending" || proposal.status === "failed") && (
            <motion.div
                key={proposal.status}
              className="flex gap-1.5"
              exit={{ opacity: 0, scale: 0.96 }}
              transition={{ duration: 0.15 }}
            >
              <button
                onClick={onCancel}
                aria-label={`${meta.label} 취소: ${payloadSummary(proposal)}`}
                className="h-9 rounded-full border border-ink-100 bg-surface px-3.5 text-[12.5px] font-semibold text-ink-500"
              >
                다음에
              </button>
              <button
                onClick={onConfirm}
                aria-label={`${meta.label} 확정: ${payloadSummary(proposal)}`}
                className={cn(
                  "h-9 rounded-full px-4 text-[12.5px] font-bold text-white transition-transform active:scale-[0.97]",
                  meta.danger
                    ? "bg-blush-400"
                    : "bg-gradient-to-r from-purple-400 to-purple-600 shadow-fab",
                )}
              >
                  {proposal.status === "failed"
                    ? "다시 시도"
                    : meta.danger
                      ? "삭제할게요"
                      : "해주세요"}
              </button>
            </motion.div>
          )}
          {proposal.status === "confirming" && (
            <motion.span
              key="confirming"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              className="inline-flex items-center gap-1.5 text-[12.5px] font-semibold text-purple-600"
            >
              <Loader2 className="size-3.5 animate-spin" aria-hidden /> 하고 있어요…
            </motion.span>
          )}
          {done && (
            <motion.span
              key="done"
              initial={{ opacity: 0, scale: 0.7 }}
              animate={{ opacity: 1, scale: 1 }}
              transition={{ type: "spring", duration: 0.4, bounce: 0.4 }}
              className="inline-flex items-center gap-1.5 text-[12.5px] font-bold text-[#187A4E]"
            >
              <Check className="size-4" strokeWidth={3} aria-hidden /> 완료했어요
            </motion.span>
          )}
          {preview && (
            <motion.span
              key="preview"
              initial={{ opacity: 0, scale: 0.8 }}
              animate={{ opacity: 1, scale: 1 }}
              className="inline-flex items-center gap-1.5 text-[12.5px] font-bold text-sky-700"
            >
              <Smartphone className="size-4" aria-hidden /> 앱에서 확정
            </motion.span>
          )}
          {proposal.status === "expired" && (
            <span className="inline-flex items-center gap-1.5 text-[12.5px] font-semibold text-ink-500">
              <AlertCircle className="size-4" aria-hidden /> 대상이 바뀌었어요
            </span>
          )}
          {cancelled && (
            <span key="cancelled" className="text-[12.5px] font-semibold text-ink-300">
              다음에 할게요
            </span>
          )}
        </AnimatePresence>
      </div>
      {proposal.status === "failed" && proposal.error && (
        <p className="border-t border-blush-100 px-3.5 py-2 text-[11.5px] font-medium text-blush-400">
          {proposal.error}
        </p>
      )}
      {preview && (
        <p className="border-t border-sky-100 px-3.5 py-2 text-[11.5px] font-medium text-ink-500">
          {proposal.type === "reminder"
            ? "기기 알림은 iOS 앱 권한이 필요해 웹에서는 미리보기만 제공해요."
            : "공유 시드 기록 변경은 iOS 앱에서 확정할 수 있어요."}
        </p>
      )}
    </div>
  );
}
