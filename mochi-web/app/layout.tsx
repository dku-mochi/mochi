import type { Metadata, Viewport } from "next";
import localFont from "next/font/local";
import "./globals.css";

const pretendard = localFont({
  src: "./fonts/PretendardVariable.woff2",
  display: "swap",
  variable: "--font-pretendard",
  weight: "45 920",
});

export const metadata: Metadata = {
  metadataBase: new URL("https://mochi-demo.vercel.app"),
  title: "모찌(MOCHI) — 놓치기 쉬운 순간은, 알아서 떠오른다",
  description:
    "스크린샷·링크·기록을 한 번 남기면, 모찌가 알아서 정리하고 필요할 때 먼저 떠올려 줍니다. 멀티모달 AI 기억 에이전트 — 지금 웹에서 직접 체험해 보세요.",
  applicationName: "MOCHI",
  openGraph: {
    type: "website",
    locale: "ko_KR",
    title: "모찌(MOCHI) — 알아서 떠오르는 기억",
    description:
      "한 번 남기면 모찌가 정리하고, 필요할 때 먼저 떠올려 줍니다. 진짜 AI가 도는 데모를 지금 체험해 보세요.",
    images: ["/og.png"],
  },
  icons: { icon: "/mochi/mochi-hello.png", apple: "/mochi/mochi-hello.png" },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  themeColor: "#F2F4F7",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="ko" className={`${pretendard.variable} h-full`}>
      <body className="min-h-full antialiased">{children}</body>
    </html>
  );
}
