import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  images: {
    remotePatterns: [
      { protocol: "https", hostname: "storage.googleapis.com" },
      { protocol: "https", hostname: "34-64-104-136.nip.io" },
    ],
  },
  productionBrowserSourceMaps: false,
};

export default nextConfig;
