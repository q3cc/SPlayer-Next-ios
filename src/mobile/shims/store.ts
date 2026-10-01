import { defaultSystemConfig } from "@shared/defaults/settings";
import type { SystemConfig } from "@shared/types/settings";
import type { ConfigPath, PathValue } from "@root/electron/main/store/types";
import { deepMerge, getByPath, setByPath } from "@root/electron/main/store/utils";

const STORAGE_KEY = "splayer.mobile.settings";
const mobileDefaults: SystemConfig = {
  ...defaultSystemConfig,
  media: { ...defaultSystemConfig.media, dynamicLyrics: true },
  desktopLyric: { ...defaultSystemConfig.desktopLyric, doubleLine: false },
};

const read = (): SystemConfig => {
  try {
    const raw = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "{}") as Record<string, unknown>;
    return deepMerge(mobileDefaults, raw);
  } catch {
    return structuredClone(mobileDefaults);
  }
};

let data = read();

const flush = (): void => {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(data));
};

export const store = {
  get store(): SystemConfig {
    return data;
  },
  get<P extends ConfigPath>(keyPath: P): PathValue<SystemConfig, P> {
    return getByPath(data, keyPath) as PathValue<SystemConfig, P>;
  },
  set(keyPath: ConfigPath | (string & {}), value: unknown): void {
    setByPath(data, keyPath, value);
    flush();
  },
  clear(): void {
    data = structuredClone(mobileDefaults);
    flush();
  },
  replaceAll(input: unknown): void {
    const raw = (input && typeof input === "object" ? input : {}) as Record<string, unknown>;
    data = deepMerge(mobileDefaults, raw);
    flush();
  },
  flushImmediate: flush,
};
