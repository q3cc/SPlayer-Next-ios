import { openUrl } from "@tauri-apps/plugin-opener";
import type { UpdateApi, UpdateEvent, UpdateMeta } from "@shared/types/update";
import { fetchWithProxy } from "./shims/proxy";
import { store } from "./shims/store";

type Release = {
  tag_name: string;
  draft: boolean;
  prerelease: boolean;
  body: string | null;
  published_at: string | null;
  assets: Array<{ name: string; size: number; state: string }>;
};

const repository = new URL(__APP_REPO_URL__);
const releasesUrl = `${repository.origin}${repository.pathname.replace(/\/$/, "")}/releases`;
const listeners = new Set<(event: UpdateEvent) => void>();
let downloadPage = releasesUrl;

const parts = (value: string): number[] | null => {
  const match = /^(?:android-)?v?(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta)(?:\.(\d+))?)?(?:\+.*)?$/.exec(
    value,
  );
  return match
    ? [
        Number(match[1]),
        Number(match[2]),
        Number(match[3]),
        match[4] === "alpha" ? -2 : match[4] === "beta" ? -1 : 0,
        Number(match[5] ?? 0),
      ]
    : null;
};

const compare = (left: number[], right: number[]): number => {
  for (let index = 0; index < left.length; index++) {
    if (left[index] !== right[index]) return left[index] - right[index];
  }
  return 0;
};

const emit = (event: UpdateEvent): void => listeners.forEach((listener) => listener(event));

export const androidUpdate: UpdateApi = {
  async check(manual) {
    if (!manual && !store.get("update.autoCheck")) return;
    emit({ type: "checking" });
    try {
      const channel = store.get("update.channel");
      const response = await fetchWithProxy(
        `https://api.github.com/repos${repository.pathname}/releases?per_page=100`,
        {
          headers: { Accept: "application/vnd.github+json", "User-Agent": "SPlayer-Next-Android" },
          signal: AbortSignal.timeout(15000),
        },
      );
      if (!response.ok) throw new Error(`GitHub HTTP ${response.status}`);
      const current = parts(__APP_VERSION__);
      if (!current) throw new Error("无法识别当前版本");
      const releases = (await response.json()) as Release[];
      if (!Array.isArray(releases)) throw new Error("更新信息无效");
      const candidates = releases.flatMap((release) => {
        const version = parts(release.tag_name);
        const asset = release.assets.find(
          (item) => item.name.endsWith(".apk") && item.state === "uploaded" && item.size > 0,
        );
        if (release.draft || !version || !asset) return [];
        if (channel === "stable" && (release.prerelease || version[3] < 0)) return [];
        if (channel === "beta" && version[3] === -2) return [];
        return [{ release, asset, version }];
      });
      candidates.sort((a, b) => compare(b.version, a.version));
      const latest = candidates[0];
      if (!latest || compare(latest.version, current) <= 0) {
        emit({ type: "notAvailable", manual });
        return;
      }
      downloadPage = `${releasesUrl}/tag/${encodeURIComponent(latest.release.tag_name)}`;
      const meta: UpdateMeta = {
        version: latest.release.tag_name.replace(/^(?:android-)?v?/, ""),
        releaseNotes: latest.release.body ?? "",
        releaseDate: latest.release.published_at ?? "",
        size: latest.asset.size,
      };
      emit({ type: "available", manual, canInstall: false, meta });
    } catch (error) {
      emit({ type: "error", manual, message: String(error) });
    }
  },
  download: async () => openUrl(downloadPage),
  install: async () => openUrl(downloadPage),
  openDownloadPage: async () => openUrl(downloadPage),
  onEvent(callback) {
    listeners.add(callback);
    return () => listeners.delete(callback);
  },
};

export { androidUpdate as mobileUpdate };
