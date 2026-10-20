import { fetchWithProxy } from "../shims/proxy";
import {
  INSTALL_URL_TIMEOUT,
  REQUEST_DEFAULT_TIMEOUT,
  REQUEST_MAX_RESPONSE_SIZE,
  REQUEST_MAX_TIMEOUT,
} from "@shared/defaults/plugin-api";
import type { HostRequestOptions, HostRequestResult } from "@shared/types/plugin";

/** 插件下载与请求仅接受网页协议，响应体限量读取以保护移动端内存。 */
export const requestPlugin = async (
  url: string,
  options: HostRequestOptions = {},
  signal?: AbortSignal,
): Promise<HostRequestResult> => {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new Error("链接格式无效");
  }
  if (!["https:", "http:"].includes(parsed.protocol)) throw new Error("不支持此链接协议");
  const method = (options.method ?? "GET").toUpperCase();
  if (method !== "GET" && method !== "POST") throw new Error("不支持此请求方法");
  const timeout = Math.min(
    Math.max(options.timeout ?? REQUEST_DEFAULT_TIMEOUT, 1_000),
    REQUEST_MAX_TIMEOUT,
  );
  const response = await fetchWithProxy(url, {
    method,
    headers: options.headers,
    body: options.body instanceof Uint8Array ? options.body.slice().buffer : options.body,
    signal: signal ?? AbortSignal.timeout(timeout),
  });
  const reader = response.body?.getReader();
  if (!reader) throw new Error("服务器未返回内容");
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > REQUEST_MAX_RESPONSE_SIZE) throw new Error("插件响应超过大小限制");
      chunks.push(value);
    }
  } finally {
    await reader.cancel();
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let body: unknown =
    options.responseType === "arraybuffer" ? bytes : new TextDecoder().decode(bytes);
  if (options.responseType === "json") {
    try {
      body = JSON.parse(body as string);
    } catch {
      /* 兼容返回非 JSON 错误页的音源。 */
    }
  }
  return { status: response.status, headers: Object.fromEntries(response.headers), body };
};

/** 在线脚本导入与更新使用相同的大小和超时限制。 */
export const fetchPluginScript = async (url: string): Promise<string> => {
  const parsed = new URL(url);
  if (
    parsed.protocol !== "https:" &&
    !(parsed.protocol === "http:" && ["localhost", "127.0.0.1"].includes(parsed.hostname))
  ) {
    throw new Error("请使用 HTTPS 插件链接");
  }
  const result = await requestPlugin(url, { timeout: INSTALL_URL_TIMEOUT });
  if (result.status < 200 || result.status >= 300) throw new Error(`HTTP ${result.status}`);
  return result.body as string;
};
