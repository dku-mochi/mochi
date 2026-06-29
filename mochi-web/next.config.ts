import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // 캡처 썸네일은 BFF(/api/seed/image)가 토큰을 붙여 프록시하므로
  // 브라우저는 same-origin만 보지만, 혹시 모를 직접 표시를 대비해 GCS·백엔드 호스트를 허용.
  images: {
    remotePatterns: [
      { protocol: "https", hostname: "storage.googleapis.com", pathname: "/**" },
      { protocol: "https", hostname: "34-64-104-136.nip.io", pathname: "/**" },
    ],
  },
  // 데모는 외부 텔레메트리/소스맵 노출 최소화
  productionBrowserSourceMaps: false,
};

export default nextConfig;
