import type { NextConfig } from "next";
import {
  isLanLabEnabled,
  supervisorRewrites,
} from "./src/lib/lan-lab/config";

const nextConfig: NextConfig = {
  ...(isLanLabEnabled(process.env) ? {
    output: "standalone" as const,
    generateBuildId: async () => {
      const sourceCommit = process.env.TEREMOQ_LAN_SOURCE_COMMIT;
      if (!sourceCommit || !/^[0-9a-f]{40}$/.test(sourceCommit)) {
        throw new Error("LAN build requires an exact source commit");
      }
      return sourceCommit;
    },
  } : {}),
  allowedDevOrigins: ["127.0.0.1", "localhost"],
  skipTrailingSlashRedirect: true,
  async rewrites() {
    return supervisorRewrites(process.env);
  },
};

export default nextConfig;
