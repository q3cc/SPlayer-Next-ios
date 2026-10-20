/** 移动沙箱没有 Node 系统信息；设备标签只取公开平台标识，不读取用户账号 */
export const type = (): string =>
  import.meta.env.VITE_MOBILE_TARGET === "android" ? "Android" : "iOS";
/** 浏览器提供版本时用于客户端标识，后台 JavaScriptCore 不伪造系统版本 */
export const release = (): string =>
  typeof navigator === "undefined"
    ? "unknown"
    : (navigator.userAgent.match(/(?:OS |Android )([\d_.]+)/)?.[1]?.replaceAll("_", ".") ??
      "unknown");
/** 登录设备管理使用应用平台名，避免将桌面编译机器信息写入账号 */
export const hostname = (): string => `SPlayer ${type()}`;
/** 移动端不向音乐接口发送系统用户名 */
export const userInfo = (): { username: string } => ({ username: "" });
