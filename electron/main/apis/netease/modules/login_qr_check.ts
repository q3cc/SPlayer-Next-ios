/**
 * 轮询二维码扫码状态
 * - 801 待扫码、802 待确认、800 已过期、803 已确认（此时 cookie 里有 MUSIC_U）
 */

import type { NeteaseModule } from "../core/types";
import type { NeteaseRequestError } from "../core/response";
import { cookieHeaderToList, createWebQrRequest, mergeCookieLists } from "../core/webQrLogin";
import { forgetQrLoginChain, takeQrLoginChain } from "./login_qr_create";

const loginQrCheck: NeteaseModule = async (query, request) => {
  const key = String(query.key ?? "");
  const chainId =
    (typeof query.chainId === "string" && query.chainId) || takeQrLoginChain(key) || "";
  const web = createWebQrRequest(query, {
    "X-loginMethod": "QrCode",
    "x-login-chain-id": chainId,
  });
  const data = {
    key,
    type: 1,
    noCheckToken: true,
    ydDeviceToken: query.ydDeviceToken || "",
    ...(query.secureCaptcha ? { secureCaptcha: query.secureCaptcha } : {}),
  };
  try {
    const result = await request("/api/login/qrcode/client/login", data, web.options);
    const bodyCookie = (result.body as { cookie?: unknown }).cookie;
    const cookies = mergeCookieLists(web.cookies, result.cookie, cookieHeaderToList(bodyCookie));
    const code = Number((result.body as { code?: unknown }).code);
    if (code === 800 || code === 803) forgetQrLoginChain(key);
    return {
      status: 200,
      body: { ...result.body, cookie: bodyCookie || cookies.join(";") },
      cookie: cookies,
    };
  } catch (err) {
    const response = (err as NeteaseRequestError).response;
    if (!response) throw err;
    const bodyCookie = (response.body as { cookie?: unknown }).cookie;
    const cookies = mergeCookieLists(web.cookies, response.cookie, cookieHeaderToList(bodyCookie));
    const code = Number((response.body as { code?: unknown }).code);
    if (code === 800 || code === 803) forgetQrLoginChain(key);
    return {
      status: 200,
      body: { ...response.body, cookie: bodyCookie || cookies.join(";") },
      cookie: cookies,
    };
  }
};

export default loginQrCheck;
