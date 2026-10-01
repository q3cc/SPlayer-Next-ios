import { expect, it, vi } from "vitest";

it("移动端控制中心歌词默认开启，用户关闭后仍保持关闭", async () => {
  localStorage.removeItem("splayer.mobile.settings");
  vi.resetModules();
  const { store } = await import("./store");
  expect(store.get("media.dynamicLyrics")).toBe(true);
  store.set("media.dynamicLyrics", false);
  vi.resetModules();
  const restored = (await import("./store")).store;
  expect(restored.get("media.dynamicLyrics")).toBe(false);
  localStorage.removeItem("splayer.mobile.settings");
});
