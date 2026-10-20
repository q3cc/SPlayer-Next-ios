import { resolve } from "node:path";
import { defineConfig, type UserConfig, type ConfigEnv } from "vite";
import siriConfig from "./vite.siri.config";
/** 原生音源执行器复用同一套插件协议和 LX 兼容层 */
export default defineConfig(async (env) => {
  const base = await (siriConfig as (env: ConfigEnv) => Promise<UserConfig>)(env);
  return {
    ...base,
    build: {
      ...base.build,
      outDir: "src-tauri/ios-native/Sources/SPlayerNativeUI/Resources",
      lib: {
        entry: resolve("src/mobile/native/plugin.ts"),
        name: "SPlayerNativePlugin",
        formats: ["iife"],
        fileName: () => "native-plugin.js",
      },
    },
  };
});
