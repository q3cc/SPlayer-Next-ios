/** 原生后台请求保留平台需要的请求头和二进制响应，不经过 WebView。 */
export const fetchWithProxy = (input: string | URL, init?: RequestInit): Promise<Response> =>
  fetch(String(input), init);
export const getNetworkProxyUrl = (): null => null;
