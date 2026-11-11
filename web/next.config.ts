import path from "node:path";
import type { NextConfig } from "next";

// The app imports ../deployments/*.json, so the bundler root is the repo root.
const root = path.join(__dirname, "..");

const nextConfig: NextConfig = {
  turbopack: { root },
  outputFileTracingRoot: root,
};

export default nextConfig;
