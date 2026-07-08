import type { Metadata, Viewport } from "next";
import localFont from "next/font/local";
import "./globals.css";

const pretendard = localFont({
  src: "../../public/fonts/PretendardVariable.woff2",
  display: "swap",
  weight: "45 920",
  variable: "--font-pretendard",
});

const cafe24 = localFont({
  src: "../../public/fonts/Cafe24Ssurround.woff",
  display: "swap",
  weight: "700",
  variable: "--font-cafe24",
});

export const metadata: Metadata = {
  title: {
    default: "모찌 — 필요한 기억은 쉽게 떠오른다",
    template: "%s · 모찌",
  },
  description:
    "스크린샷·링크·메모를 보내기만 하면 모찌가 정리하고, 필요할 때 먼저 떠올려주는 기억 에이전트. 심사위원용 체험 데모.",
};

export const viewport: Viewport = {
  themeColor: "#8b6cff",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="ko" className={`${pretendard.variable} ${cafe24.variable}`}>
      <body>{children}</body>
    </html>
  );
}
