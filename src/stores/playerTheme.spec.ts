import { createApp, nextTick } from "vue";
import { createPinia } from "pinia";
import persistedstate from "pinia-plugin-persistedstate";
import { beforeEach, afterEach, expect, it, vi } from "vitest";
import { useSettingsStore } from "./settings";

beforeEach(() => {
  localStorage.clear();
  const events = { onConfigChange: () => () => {} };
  vi.stubGlobal("api", undefined);
  window.api = {
    desktopLyric: events,
    dynamicIsland: events,
    window: {
      onDesktopLyricVisibilityChange: () => () => {},
      onDynamicIslandVisibilityChange: () => () => {},
      onTaskbarLyricVisibilityChange: () => () => {},
      isDesktopLyricOpen: async () => false,
      isDynamicIslandOpen: async () => false,
      isTaskbarLyricOpen: async () => false,
    },
  } as unknown as typeof window.api;
});
afterEach(() => vi.unstubAllGlobals());
const createSettings = () => {
  const pinia = createPinia().use(persistedstate);
  createApp({}).use(pinia);
  return useSettingsStore(pinia);
};

it("新安装默认原版", () => {
  const settings = createSettings();
  expect(settings.player.theme).toBe("original");
  settings.$dispose();
});
it("旧配置补回默认主题，保留歌词与背景偏好", () => {
  localStorage.setItem(
    "settings",
    JSON.stringify({ player: { playerBgType: "solid" }, lyric: { engine: "custom" } }),
  );
  const settings = createSettings();
  expect(settings.player.theme).toBe("original");
  expect(settings.player.playerBgType).toBe("solid");
  expect(settings.lyric.engine).toBe("custom");
  settings.$dispose();
});
it("Apple Music 选择持久化，切换不覆盖其他偏好", async () => {
  const settings = createSettings();
  const previousEngine = settings.lyric.engine;
  settings.player.theme = "apple-music";
  await nextTick();
  settings.$dispose();
  const restored = createSettings();
  expect(restored.player.theme).toBe("apple-music");
  expect(restored.lyric.engine).toBe(previousEngine);
  expect(restored.player.playerBgType).toBe("blur");
  restored.$dispose();
});
it("无效主题安全回退原版", () => {
  localStorage.setItem("settings", JSON.stringify({ player: { theme: "removed-theme" } }));
  const settings = createSettings();
  expect(settings.player.theme).toBe("original");
  settings.$dispose();
});
