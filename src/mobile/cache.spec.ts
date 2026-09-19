import { beforeEach, expect, it } from "vitest";
import { mobileCache } from "./cache";

beforeEach(() => localStorage.clear());

it("统计三类歌词缓存并按分类清除，不删除账号、歌单和设置", async () => {
  localStorage.setItem("splayer.mobile.lyric.netease.1", "歌词");
  localStorage.setItem("splayer.mobile.ttml.netease.1", "<tt>歌词</tt>");
  localStorage.setItem("splayer.mobile.lyric-match.qqmusic.1", "匹配");
  localStorage.setItem("splayer.mobile.settings", "设置");
  localStorage.setItem("user", "账号");
  const stats = await mobileCache.getStats();
  expect(stats).toHaveLength(3);
  expect(stats.every((stat) => stat.size > 0)).toBe(true);
  await mobileCache.clear("lyric");
  expect((await mobileCache.getStats()).find((stat) => stat.id === "lyric")?.size).toBe(0);
  expect(localStorage.getItem("splayer.mobile.ttml.netease.1")).not.toBeNull();
  await mobileCache.clearAllByKind("db");
  expect((await mobileCache.getStats()).every((stat) => stat.size === 0)).toBe(true);
  expect(localStorage.getItem("user")).toBe("账号");
  expect(localStorage.getItem("splayer.mobile.settings")).toBe("设置");
});

it("拒绝未知分类，清理文件缓存不会误删歌词", async () => {
  localStorage.setItem("splayer.mobile.lyric.netease.1", "歌词");
  await expect(mobileCache.clear("user")).rejects.toThrow();
  await mobileCache.clearAllByKind("file");
  expect(localStorage.length).toBe(1);
});
