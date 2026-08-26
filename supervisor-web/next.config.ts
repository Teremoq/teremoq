import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  allowedDevOrigins: ["127.0.0.1", "localhost"],
  skipTrailingSlashRedirect: true,
  async rewrites() {
    const gatewayOrigin =
      process.env.TEREMOQ_GATEWAY_HTTP_ORIGIN ?? "http://127.0.0.1:19080";
    const inputPreviewOrigin =
      process.env.TEREMOQ_INPUT_PREVIEW_ORIGIN ?? "http://127.0.0.1:8889";
    return [
      {
        source: "/gateway/:path*",
        destination: `${gatewayOrigin}/:path*`,
      },
      {
        source: "/input/",
        destination: `${inputPreviewOrigin}/input/`,
      },
      {
        source: "/input/:path*",
        destination: `${inputPreviewOrigin}/input/:path*`,
      },
    ];
  },
};

export default nextConfig;
