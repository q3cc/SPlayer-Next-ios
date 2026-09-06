import type { Platform } from "@shared/types/platform";

const keyFor = (platform: Platform): string => `splayer.mobile.session.${platform}`;

export const getSessionCookies = (platform: Platform): Record<string, string> => {
  try {
    const value: unknown = JSON.parse(localStorage.getItem(keyFor(platform)) ?? "{}");
    if (!value || typeof value !== "object" || Array.isArray(value)) return {};
    return Object.fromEntries(
      Object.entries(value).filter(([, entry]) => typeof entry === "string"),
    );
  } catch {
    return {};
  }
};

export const saveSessionCookies = (platform: Platform, cookies: Record<string, string>): void => {
  localStorage.setItem(keyFor(platform), JSON.stringify(cookies));
  window.dispatchEvent(new Event("splayer:siri-data-changed"));
};

export const clearSessionCookies = (platform: Platform): void => {
  localStorage.removeItem(keyFor(platform));
  window.dispatchEvent(new Event("splayer:siri-data-changed"));
};
