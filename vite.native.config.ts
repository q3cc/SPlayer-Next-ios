import { resolve } from "node:path";
import { defineConfig, type UserConfig, type ConfigEnv } from "vite";
import siriConfig from "./vite.siri.config";

/** 原生应用只打包后台服务，不打包 Vue 页面 */
export default defineConfig(async (env) => {
  const base = await (siriConfig as (env: ConfigEnv) => Promise<UserConfig>)(env);
  return {
    ...base,
    build: {
      ...base.build,
      outDir: "src-tauri/ios-native/Sources/SPlayerNativeUI/Resources",
      lib: {
        entry: resolve("src/mobile/native/background.ts"),
        name: "SPlayerSiri",
        formats: ["iife"],
        fileName: () => "siri-background.js",
      },
    },
  };
});
