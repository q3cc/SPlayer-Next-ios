import { createRequest, type RequestOptions } from "@main/apis/netease/core/request";
import type { RequestResponse } from "@main/apis/netease/core/response";

let generation = 0;

/** 账号切换后丢弃旧账号请求的返回结果 */
export const resetWebClientSession = (): void => {
  generation++;
};

/**
 * 移动端沿用原生 HTTP 客户端协议，不依赖 Electron 的隔离网页会话
 * @param uri - 平台接口路径
 * @param data - 业务参数
 * @param options - 当前账号与请求选项
 * @returns 当前账号对应的业务结果
 */
export const requestWithWebClient = async (
  uri: string,
  data: Record<string, unknown>,
  options: RequestOptions,
): Promise<RequestResponse> => {
  const token = generation;
  const nativePlaylist = uri.startsWith("/api/playlist/");
  const like = uri === "/api/song/like";
  const result = await createRequest(
    like ? "/api/radio/like" : uri,
    like
      ? { alg: "itembased", trackId: data.trackId, like: data.like === "true", time: "3" }
      : data,
    { ...options, client: undefined, crypto: nativePlaylist ? "eapi" : "weapi" },
  );
  if (token !== generation) throw new Error("平台会话已变更，请求已取消");
  return result;
};
