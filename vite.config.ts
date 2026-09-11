import { execSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import UnoCSS from "unocss/vite";
import AutoImport from "unplugin-auto-import/vite";
import Icons from "unplugin-icons/vite";
import IconsResolver from "unplugin-icons/resolver";
import { FileSystemIconLoader } from "unplugin-icons/loaders";
import Components from "unplugin-vue-components/vite";
import RekaResolver from "reka-ui/resolver";
import { nodePolyfills } from "vite-plugin-node-polyfills";
import pkg from "./package.json" with { type: "json" };

const gitValue = (command: string): string => {
  try {
    return execSync(command).toString().trim() || "unknown";
  } catch {
    return "unknown";
  }
};

export default defineConfig(({ mode }) => ({
  base: "./",
  define: {
    __APP_VERSION__: JSON.stringify(pkg.version),
    __APP_REPO_URL__: JSON.stringify(pkg.repository.url),
    __APP_REPO_NAME__: JSON.stringify(pkg.productName),
    __APP_AUTHOR__: JSON.stringify(pkg.author.name),
    __APP_HOMEPAGE__: JSON.stringify(pkg.homepage),
    __APP_AUTHOR_URL__: JSON.stringify(pkg.author.url),
    __COMMIT_HASH__: JSON.stringify(gitValue("git rev-parse --short=7 HEAD")),
    __COMMIT_DATE__: JSON.stringify(gitValue("git log -1 --format=%cI")),
  },
  server: {
    host: "0.0.0.0",
    port: 14558,
    strictPort: true,
  },
  publicDir: mode === "mobile" ? false : resolve(__dirname, "public"),
  build: {
    outDir: "dist-mobile",
    emptyOutDir: true,
    rollupOptions: { input: resolve(__dirname, "index.html") },
  },
  resolve: {
    alias: [
      { find: "/fonts", replacement: resolve(__dirname, "public/fonts") },
      {
        find: "@main/database/sessions",
        replacement: resolve(__dirname, "src/mobile/shims/sessions.ts"),
      },
      {
        find: "@main/database/lyricCache",
        replacement: resolve(__dirname, "src/mobile/shims/lyricCache.ts"),
      },
      {
        find: "@main/database/lyricMatchCache",
        replacement: resolve(__dirname, "src/mobile/shims/lyricMatchCache.ts"),
      },
      {
        find: "@main/database/lyricTtmlCache",
        replacement: resolve(__dirname, "src/mobile/shims/lyricTtmlCache.ts"),
      },
      { find: "@main/utils/logger", replacement: resolve(__dirname, "src/mobile/shims/logger.ts") },
      { find: "@main/utils/proxy", replacement: resolve(__dirname, "src/mobile/shims/proxy.ts") },
      { find: "@main/store", replacement: resolve(__dirname, "src/mobile/shims/store.ts") },
      { find: "@main", replacement: resolve(__dirname, "electron/main") },
      { find: "@", replacement: resolve(__dirname, "src") },
      { find: "@shared", replacement: resolve(__dirname, "shared") },
      { find: "@windows", replacement: resolve(__dirname, "windows") },
      { find: "@root", replacement: resolve(__dirname) },
    ],
  },
  plugins: [
    {
      name: "splayer-mobile-public-assets",
      generateBundle() {
        if (mode !== "mobile") return;
        const root = resolve(__dirname, "public");
        for (const relative of readdirSync(root, { recursive: true }) as string[]) {
          // iOS 图标由 Asset Catalog 提供，不嵌入 Windows 安装器、托盘和 macOS 图标。
          if (
            !/^(fonts\/|licenses\/|images\/avatar\.jpg$|icons\/(favicon\.png|logo\.svg)$)/.test(
              relative,
            )
          )
            continue;
          if (!/\.[a-z0-9]+$/i.test(relative)) continue;
          this.emitFile({
            type: "asset",
            fileName: relative,
            source: readFileSync(resolve(root, relative)),
          });
        }
      },
    },
    {
      name: "splayer-mobile-entry",
      transformIndexHtml: {
        order: "pre",
        handler(html) {
          if (mode !== "mobile") return html;
          return html
            .replace("/src/entry.ts", "/src/mobile-entry.ts")
            .replace(
              'type="image/icon" href="/icons/favicon.ico"',
              'type="image/png" href="/icons/favicon.png"',
            );
        },
      },
    },
    nodePolyfills({
      include: ["buffer", "crypto", "events", "process", "stream", "util", "vm", "zlib"],
      globals: { Buffer: true, global: true, process: true },
      protocolImports: true,
      overrides: { crypto: resolve(__dirname, "src/mobile/shims/crypto.ts") },
    }),
    vue(),
    UnoCSS(),
    AutoImport({ imports: ["vue", "pinia", "vue-router", "@vueuse/core", "vue-i18n"] }),
    Icons({
      compiler: "vue3",
      scale: 1,
      customCollections: { sp: FileSystemIconLoader("./src/assets/icons") },
    }),
    Components({
      dirs: ["src/components"],
      resolvers: [RekaResolver(), IconsResolver({ prefix: "icon", customCollections: ["sp"] })],
    }),
  ],
}));
