const PREFIXES = ["splayer.mobile.lyric.", "splayer.mobile.lyric-match.", "splayer.mobile.ttml."];
const MAX_ENTRIES = 256;
const MAX_CHARACTERS = 512 * 1024;

/**
 * 缓存不可用时按未命中处理，不阻断在线歌词获取。
 * @param key - 歌词缓存键
 * @returns 缓存内容，未命中或存储不可用时返回 null
 */
export const readLyricStorage = (key: string): string | null => {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
};

/**
 * 限制歌词缓存总量；配额不足只淘汰可重新下载的歌词，不触碰账号和用户数据。
 * @param key - 歌词缓存键
 * @param value - 序列化后的缓存内容
 */
export const writeLyricStorage = (key: string, value: string): void => {
  try {
    const entries: { key: string; size: number }[] = [];
    let size = key.length + value.length;
    if (size > MAX_CHARACTERS) {
      localStorage.removeItem(key);
      return;
    }
    for (let index = 0; index < localStorage.length; index++) {
      const storedKey = localStorage.key(index);
      if (!storedKey || storedKey === key || !PREFIXES.some((p) => storedKey.startsWith(p)))
        continue;
      const entrySize = storedKey.length + (localStorage.getItem(storedKey)?.length ?? 0);
      entries.push({ key: storedKey, size: entrySize });
      size += entrySize;
    }
    while (entries.length >= MAX_ENTRIES || size > MAX_CHARACTERS) {
      const entry = entries.shift()!;
      localStorage.removeItem(entry.key);
      size -= entry.size;
    }
    try {
      localStorage.setItem(key, value);
    } catch (error) {
      if (!(error instanceof DOMException) || error.name !== "QuotaExceededError") return;
      for (const entry of entries) localStorage.removeItem(entry.key);
      localStorage.removeItem(key);
      localStorage.setItem(key, value);
    }
  } catch {
    // 缓存是可选副作用，存储受限时仍返回已获取的歌词。
  }
};

/**
 * 清理指定种类的歌词缓存，兼容存储访问被禁用的环境。
 * @param prefix - 歌词缓存前缀
 */
export const clearLyricStorage = (prefix: string): void => {
  try {
    for (let index = localStorage.length - 1; index >= 0; index--) {
      const key = localStorage.key(index);
      if (key?.startsWith(prefix)) localStorage.removeItem(key);
    }
  } catch {
    // 禁用存储时无需清理，也不能让设置操作抛错。
  }
};
