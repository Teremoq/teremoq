import type { NextConfig } from "next";
import {
  isLanLabEnabled,
  supervisorRewrites,
} from "./src/lib/lan-lab/config";

const nextConfig: NextConfig = {
  ...(isLanLabEnabled(process.env) ? { output: "standalone" as const } : {}),
  allowedDevOrigins: ["127.0.0.1", "localhost"],
  skipTrailingSlashRedirect: true,
  async rewrites() {
    return supervisorRewrites(process.env);
  },
};

export default nextConfig;
