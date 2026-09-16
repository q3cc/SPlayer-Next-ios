import { createApp } from "vue";
import { createPinia, disposePinia, setActivePinia } from "pinia";
import persistedstate from "pinia-plugin-persistedstate";
import { beforeEach, expect, it } from "vitest";
import { useSettingsStore } from "./settings";

beforeEach(() => {
  localStorage.clear();
  Object.defineProperty(window, "api", {
    configurable: true,
    value: {
      desktopLyric: { onConfigChange: () => () => {} },
      taskbarLyric: { onConfigChange: () => () => {} },
      dynamicIsland: { onConfigChange: () => () => {} },
      window: {
        onDesktopLyricVisibilityChange: () => () => {},
        onDynamicIslandVisibilityChange: () => () => {},
        onTaskbarLyricVisibilityChange: () => () => {},
        isDesktopLyricOpen: async () => false,
        isDynamicIslandOpen: async () => false,
        isTaskbarLyricOpen: async () => false,
      },
    },
  });
});

it.each(["original", "apple-music"])("%s 主题升级保留 AMLL 音译偏好", (theme) => {
  localStorage.setItem(
    "settings",
    JSON.stringify({
      player: { theme },
      lyric: {
        engine: "amll",
        showRomanization: true,
        amllShowLineRomanization: false,
        amllShowWordRomanization: false,
      },
    }),
  );
  const pinia = createPinia().use(persistedstate);
  createApp({}).use(pinia);
  setActivePinia(pinia);
  const settings = useSettingsStore();
  expect(settings.lyric.showRomanization).toBe(false);
  expect(settings.lyric.showWordRomanization).toBe(false);
  expect(settings.lyric).not.toHaveProperty("amllShowLineRomanization");
  expect(settings.lyric).not.toHaveProperty("amllShowWordRomanization");
  disposePinia(pinia);
});
