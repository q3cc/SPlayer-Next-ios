/* JavaScriptCore 的宿主适配；不创建 WebView，也不注入浏览器登录页面。 */
globalThis.window = globalThis;
globalThis.self = globalThis;
globalThis.Event = class {
  constructor(type) {
    this.type = type;
  }
};
globalThis.dispatchEvent = () => true;
globalThis.performance = { now: () => Date.now() };
globalThis.console = Object.fromEntries(
  ["log", "info", "warn", "error", "debug"].map((key) => [key, () => {}]),
);
globalThis.structuredClone = (value) => JSON.parse(JSON.stringify(value));
globalThis.localStorage = {
  getItem: (key) => __siriStorage[key] ?? null,
  setItem: (key, value) => {
    __siriStorage[key] = String(value);
  },
  removeItem: (key) => {
    delete __siriStorage[key];
  },
};
globalThis.crypto = {
  getRandomValues: (array) => {
    array.set(__siriRandom(array.length));
    return array;
  },
};
globalThis.setTimeout = (callback, ms = 0) => __siriTimer(callback, ms);
globalThis.clearTimeout = (id) => __siriClearTimer(id);
globalThis.AbortSignal = { timeout: (ms) => ({ timeoutMs: ms }) };
globalThis.URLSearchParams = class {
  constructor(value = {}) {
    this.values =
      typeof value === "string"
        ? value
            .replace(/^\?/, "")
            .split("&")
            .filter(Boolean)
            .map((part) => {
              const index = part.indexOf("=");
              return [
                index < 0 ? part : part.slice(0, index),
                index < 0 ? "" : part.slice(index + 1),
              ].map((text) => decodeURIComponent(text.replace(/\+/g, " ")));
            })
        : Array.isArray(value)
          ? value.map(([key, item]) => [String(key), String(item)])
          : Object.entries(value).map(([key, item]) => [key, String(item)]);
  }
  append(key, value) {
    this.values.push([String(key), String(value)]);
  }
  get(key) {
    return this.values.find((item) => item[0] === key)?.[1] ?? null;
  }
  set(key, value) {
    this.values = this.values.filter((item) => item[0] !== key);
    this.append(key, value);
  }
  toString() {
    return this.values
      .map((entry) =>
        entry
          .map((value) =>
            encodeURIComponent(value)
              .replace(/%20/g, "+")
              .replace(/[!'()~]/g, (char) => `%${char.charCodeAt(0).toString(16).toUpperCase()}`),
          )
          .join("="),
      )
      .join("&");
  }
};
globalThis.URL = class {
  constructor(value, base) {
    Object.assign(this, JSON.parse(__siriURL(String(value), base ?? "")));
    this.searchParams = new URLSearchParams(this.search);
  }
  toString() {
    return this.href;
  }
};
globalThis.fetch = (url, init = {}) =>
  new Promise((resolve, reject) => {
    __siriHttp(
      String(url),
      init.method ?? "GET",
      JSON.stringify(init.headers ?? {}),
      String(init.body ?? ""),
      init.signal?.timeoutMs ?? 8000,
      (status, headersJSON, base64) => {
        const headers = JSON.parse(headersJSON);
        resolve({
          status,
          ok: status >= 200 && status < 300,
          headers: {
            get: (key) => headers[key.toLowerCase()] ?? null,
            getSetCookie: () => (headers["set-cookie"] ? [headers["set-cookie"]] : []),
          },
          text: async () => __siriUTF8(base64),
          json: async () => JSON.parse(__siriUTF8(base64)),
          arrayBuffer: async () => new Uint8Array(__siriBytes(base64)).buffer,
        });
      },
      (message) => reject(new Error(message)),
    );
  });
