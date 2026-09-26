/** 网易云 CDN 的明文地址在新版 Android WebView 中无法加载，统一使用 HTTPS。 */
export const neteaseCdnUrl = (value: string): string => {
  if (!value.startsWith("http://")) return value;
  try {
    const host = new URL(value).hostname;
    if (host === "music.126.net" || host.endsWith(".music.126.net")) {
      return `https://${value.slice("http://".length)}`;
    }
  } catch {
    // 无效 URL 原样交给调用方处理。
  }
  return value;
};
