import type { HostCallMethod, PluginGrant } from "@shared/types/plugin";
const AUTH_RESPONSE_FIELDS = new Set([
  "cookie",
  "cookies",
  "setcookie",
  "authorization",
  "token",
  "accesstoken",
  "refreshtoken",
  "idtoken",
  "viptoken",
  "musicu",
  "musica",
  "musickey",
  "skey",
  "pskey",
  "pt4token",
  "sessionkey",
]);

/** 递归过滤业务响应中的登录凭据 */
export const omitCredentials = (value: unknown): unknown => {
  if (Array.isArray(value)) return value.map(omitCredentials);
  if (value === null || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.entries(value)
      .filter(([key]) => !AUTH_RESPONSE_FIELDS.has(key.replace(/[-_]/g, "").toLowerCase()))
      .map(([key, item]) => [key, omitCredentials(item)]),
  );
};

/** 根据宿主方法确定用户必须允许的权限 */
export const requiredPluginGrant = (method: HostCallMethod): PluginGrant | undefined =>
  method === "request" || method === "music.searchOnline"
    ? "network"
    : method === "music.searchLibrary"
      ? "library"
      : method === "api.call"
        ? "api"
        : method === "notify"
          ? "ui"
          : method.startsWith("player.")
            ? "control"
            : undefined;
