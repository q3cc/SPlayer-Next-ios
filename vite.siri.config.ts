import { resolve } from "node:path";
import { defineConfig, type UserConfig, type ConfigEnv } from "vite";
import { nodePolyfills } from "vite-plugin-node-polyfills";
import mobileConfig from "./vite.config";

export default defineConfig(async (env) => {
  const base = await (mobileConfig as (env: ConfigEnv) => UserConfig)(env);
  return {
    define: base.define,
    publicDir: false,
    resolve: {
      alias: [
        { find: "@main/utils/proxy", replacement: resolve("src/mobile/siri/proxy.ts") },
        ...(base.resolve?.alias as { find: string; replacement: string }[]),
      ],
    },
    plugins: [
      nodePolyfills({
        include: ["buffer", "crypto", "events", "process", "stream", "util", "vm", "zlib"],
        globals: { Buffer: true, global: true, process: true },
        protocolImports: true,
      }),
    ],
    build: {
      outDir: "src-tauri/plugins/native-audio/ios/Sources/Resources",
      emptyOutDir: false,
      lib: {
        entry: resolve("src/mobile/siri/background.ts"),
        name: "SPlayerSiri",
        formats: ["iife"],
        fileName: () => "siri-background.js",
      },
      target: "es2020",
    },
  };
});
