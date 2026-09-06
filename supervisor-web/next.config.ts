import type { NextConfig } from "next";
import {
  isLanLabEnabled,
  supervisorRewrites,
} from "./src/lib/lan-lab/config";

const nextConfig: NextConfig = {
  ...(isLanLabEnabled(process.env) ? {
    output: "standalone" as const,
    generateBuildId: async () => {
      const playerIdentity = process.env.TEREMOQ_LAN_PLAYER_IDENTITY;
      if (!playerIdentity || !/^sha256:[0-9a-f]{64}$/.test(playerIdentity)) {
        throw new Error("LAN build requires an exact player identity");
      }
      return playerIdentity.replace(":", "-");
    },
  } : {}),
  allowedDevOrigins: ["127.0.0.1", "localhost"],
  skipTrailingSlashRedirect: true,
  async rewrites() {
    return supervisorRewrites(process.env);
  },
};

export default nextConfig;
