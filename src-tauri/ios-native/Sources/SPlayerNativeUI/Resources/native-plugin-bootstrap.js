/* 原生音源线程只提供计时、随机数与消息通道，不提供文件、账号或进程 API */
globalThis.window = globalThis;
globalThis.self = globalThis;
globalThis.performance = { now: () => Date.now() };
globalThis.console = Object.fromEntries(
  ["log", "info", "warn", "error", "debug"].map((key) => [key, () => {}]),
);
globalThis.crypto = {
  getRandomValues: (array) => {
    array.set(__nativeRandom(array.length));
    return array;
  },
};
let timerID = 0;
const timers = new Map();
globalThis.setTimeout = (callback, delay = 0, ...args) => {
  if (timers.size >= 128) throw new Error("插件定时器超出上限");
  const id = ++timerID;
  timers.set(id, { callback, args, due: Date.now() + Math.max(0, delay) });
  return id;
};
globalThis.clearTimeout = (id) => timers.delete(id);
globalThis.setInterval = (callback, delay = 0) => {
  if (timers.size >= 128) throw new Error("插件定时器超出上限");
  const id = ++timerID;
  const run = () => {
    callback();
    if (timers.has(id))
      timers.set(id, {
        callback: run,
        args: [],
        due: Date.now() + Math.max(16, delay),
        repeating: true,
      });
  };
  timers.set(id, {
    callback: run,
    args: [],
    due: Date.now() + Math.max(16, delay),
    repeating: true,
  });
  return id;
};
globalThis.clearInterval = clearTimeout;
globalThis.__tick = () => {
  for (const [id, timer] of Array.from(timers)) {
    if (timer.due <= Date.now()) {
      if (!timer.repeating) timers.delete(id);
      timer.callback(...timer.args);
    }
  }
};
globalThis.queueMicrotask = (callback) => Promise.resolve().then(callback);
globalThis.structuredClone = (value) => JSON.parse(JSON.stringify(value));
globalThis.TextEncoder = class {
  encode(text) {
    return new Uint8Array(Buffer.from(text, "utf8"));
  }
};
globalThis.TextDecoder = class {
  decode(bytes) {
    return Buffer.from(bytes ?? []).toString("utf8");
  }
};
globalThis.AbortController = class {
  constructor() {
    const listeners = new Set();
    this.signal = {
      aborted: false,
      addEventListener: (_, callback) => listeners.add(callback),
      removeEventListener: (_, callback) => listeners.delete(callback),
    };
    this.listeners = listeners;
  }
  abort() {
    this.signal.aborted = true;
    for (const callback of this.listeners) callback();
    this.listeners.clear();
  }
};
globalThis.__deliver = (text) =>
  __receive(
    JSON.parse(text, (_key, value) =>
      value && Array.isArray(value.__nativeBytes) ? new Uint8Array(value.__nativeBytes) : value,
    ),
  );

globalThis.URLSearchParams = class {
  constructor(value = "") {
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
              ].map((x) => decodeURIComponent(x.replace(/\+/g, " ")));
            })
        : Object.entries(value).map(([key, value]) => [key, String(value)]);
  }
  append(key, value) {
    this.values.push([key, String(value)]);
  }
  get(key) {
    return this.values.find((item) => item[0] === key)?.[1] ?? null;
  }
  set(key, value) {
    this.values = this.values.filter((item) => item[0] !== key);
    this.append(key, value);
  }
  toString() {
    return this.values.map((pair) => pair.map(encodeURIComponent).join("=")).join("&");
  }
};
globalThis.URL = class {
  constructor(value, base = "") {
    Object.assign(this, __nativeURL(String(value), String(base)));
    this.protocol = this.scheme + ":";
    this.search = this.query ? "?" + this.query : "";
    this.host = this.hostname + (this.port >= 0 ? ":" + this.port : "");
    this.origin = this.protocol + "//" + this.host;
    this.searchParams = new URLSearchParams(this.search);
  }
  toString() {
    return this.href;
  }
};
