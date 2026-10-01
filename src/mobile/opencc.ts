import { invoke } from "@tauri-apps/api/core";
import type { OpenccApi } from "@shared/types/opencc";

export const mobileOpencc: OpenccApi = {
  convert: async (text, config) => {
    if (!text || config === "none") return text;
    const result = await invoke<string[]>("convert_lyrics", { texts: [text], config });
    return result[0];
  },
  convertBatch: async (texts, config) =>
    !texts.length || config === "none"
      ? texts
      : invoke<string[]>("convert_lyrics", { texts, config }),
};
