import { clearLyricStorage } from "./shims/lyricStorage";

const categories = [
  { id: "lyric", prefix: "splayer.mobile.lyric." },
  { id: "lyricTTML", prefix: "splayer.mobile.ttml." },
  { id: "lyricMatch", prefix: "splayer.mobile.lyric-match." },
];

/** 只统计可重新获取的歌词缓存，不包含账号、歌单与已下载歌曲。 */
export const mobileCache = {
  getStats: async () =>
    categories.map(({ id, prefix }) => {
      let size = 0;
      for (let index = 0; index < localStorage.length; index++) {
        const key = localStorage.key(index);
        if (key?.startsWith(prefix))
          size += (key.length + (localStorage.getItem(key)?.length ?? 0)) * 2;
      }
      return { id, kind: "db" as const, path: "", size };
    }),
  clear: async (id: string) => {
    const category = categories.find((item) => item.id === id);
    if (!category) throw new Error("未知的缓存分类");
    clearLyricStorage(category.prefix);
  },
  clearAllByKind: async (kind: "file" | "db") => {
    if (kind === "db") categories.forEach(({ prefix }) => clearLyricStorage(prefix));
  },
  getDir: async () => "",
  pickDir: async () => ({ ok: false as const, reason: "canceled" as const }),
  resetDir: async () => "",
  song: { lookup: async () => null, fetch: async () => null, cancel: async () => undefined },
};
