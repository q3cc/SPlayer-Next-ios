import { addPluginListener, invoke } from "@tauri-apps/api/core";
import { openUrl } from "@tauri-apps/plugin-opener";
import type { UpdateApi, UpdateEvent, UpdateMeta } from "@shared/types/update";
import { fetchWithProxy } from "./shims/proxy";
import { store } from "./shims/store";

type Asset = {
  name: string;
  size: number;
  state: string;
  browser_download_url: string;
  digest?: string;
};
type Release = {
  tag_name: string;
  draft: boolean;
  prerelease: boolean;
  body: string | null;
  published_at: string | null;
  assets: Asset[];
};

const repository = new URL(__APP_REPO_URL__);
const repoUrl = `${repository.origin}${repository.pathname.replace(/\/$/, "")}`;
const listeners = new Set<(event: UpdateEvent) => void>();
let downloadPage = `${repoUrl}/releases`;
let checking: Promise<void> | undefined;
let checkingChannel: string | undefined;
let manualCheck = false;
let selected: { url: string; size: number; digest?: string; meta: UpdateMeta } | undefined;
let downloadedPath: string | undefined;
let downloading = false;

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

const matchingAsset = (release: Release, arch: string, commit?: string): Asset | undefined =>
  release.assets.find(
    (asset) =>
      asset.state === "uploaded" &&
      asset.size > 0 &&
      (commit
        ? asset.name === `SPlayer-Next-Android-${arch}-${commit.slice(0, 7)}.apk`
        : new RegExp(`^SPlayer-Next-Android-${arch}(?:-[a-f0-9]{7})?\\.apk$`).test(asset.name)),
  );

export const androidUpdate: UpdateApi = {
  check(manual) {
    if (downloading) return Promise.resolve();
    if (!manual && !store.get("update.autoCheck")) return Promise.resolve();
    manualCheck ||= manual;
    const channel = store.get("update.channel");
    if (checking)
      return checkingChannel === channel
        ? checking
        : checking.then(() => androidUpdate.check(manual));
    checkingChannel = channel;
    selected = undefined;
    downloadedPath = undefined;
    emit({ type: "checking" });
    checking = (async () => {
      try {
        if (repository.hostname !== "github.com") throw new Error("更新仓库必须位于 GitHub");
        const abi = await invoke<string>("plugin:native-audio|device_abi");
        const arch = { "arm64-v8a": "arm64", "armeabi-v7a": "arm32", x86_64: "x64" }[abi];
        if (!arch) throw new Error("此设备架构暂无更新包");
        const response = await fetchWithProxy(
          `https://api.github.com/repos${repository.pathname}/releases${channel === "action" ? "/tags/android-action-latest" : "?per_page=100"}`,
          {
            headers: {
              Accept: "application/vnd.github+json",
              "User-Agent": "SPlayer-Next-Android",
            },
            signal: AbortSignal.timeout(15000),
          },
        );
        if (response.status === 404 && channel === "action") {
          emit({ type: "notAvailable", manual: manualCheck });
          return;
        }
        if (!response.ok) {
          if (
            response.status === 429 ||
            (response.status === 403 && response.headers.get("x-ratelimit-remaining") === "0")
          )
            throw new Error("GitHub 请求次数已用完，请稍后重试或前往下载页");
          throw new Error(`GitHub HTTP ${response.status}`);
        }
        const payload = await response.json();
        if (channel !== store.get("update.channel")) return;
        const releases = (channel === "action" ? [payload] : payload) as Release[];
        const current = parts(__APP_VERSION__);
        if (!current || !Array.isArray(releases)) throw new Error("更新信息无效");
        let action: { commit: string; version: string; date: string } | undefined;
        if (channel === "action") {
          const metadata = /<!-- splayer-android-action:(.*?) -->/.exec(releases[0]?.body ?? "");
          if (!metadata) throw new Error("构建信息不完整，请稍后重试");
          action = JSON.parse(metadata[1]);
          if (
            !action ||
            !/^[a-f0-9]{40}$/.test(action.commit) ||
            !parts(action.version) ||
            !Number.isFinite(Date.parse(action.date))
          )
            throw new Error("构建信息无效，请稍后重试");
        }
        const candidates = releases.flatMap((release) => {
          const version = parts(action?.version ?? release.tag_name);
          const asset = matchingAsset(release, arch, action?.commit);
          if (release.draft || !version || !asset) return [];
          if (channel === "stable" && (release.prerelease || version[3] < 0)) return [];
          if (channel === "beta" && version[3] === -2) return [];
          return [{ release, asset, version }];
        });
        candidates.sort((a, b) => compare(b.version, a.version));
        const latest = candidates[0];
        const isNew =
          channel === "action"
            ? Boolean(
                latest &&
                action &&
                !action.commit.startsWith(__COMMIT_HASH__) &&
                Date.parse(action.date) > Date.parse(__COMMIT_DATE__),
              )
            : Boolean(latest && compare(latest.version, current) > 0);
        if (!latest || !isNew) {
          selected = undefined;
          emit({ type: "notAvailable", manual: manualCheck });
          return;
        }
        downloadPage = `${repoUrl}/releases/tag/${encodeURIComponent(latest.release.tag_name)}`;
        const assetUrl = new URL(latest.asset.browser_download_url);
        if (
          assetUrl.origin !== repository.origin ||
          !assetUrl.pathname.startsWith(`${repository.pathname}/releases/download/`) ||
          !assetUrl.pathname.endsWith(`/${latest.asset.name}`)
        )
          throw new Error("APK 附件不属于当前仓库");
        const meta: UpdateMeta = {
          version: action
            ? `${action.version} · ${action.commit.slice(0, 7)}`
            : latest.release.tag_name.replace(/^(?:android-)?v?/, ""),
          releaseNotes: (latest.release.body ?? "")
            .replace(/<!-- splayer-android-action:.*? -->/, "")
            .trim(),
          releaseDate: action?.date ?? latest.release.published_at ?? "",
          size: latest.asset.size,
        };
        selected = {
          url: assetUrl.href,
          size: latest.asset.size,
          digest: latest.asset.digest,
          meta,
        };
        downloadedPath = undefined;
        emit({ type: "available", manual: manualCheck, canInstall: true, meta });
      } catch (error) {
        console.warn("[android-update] check-failed", error);
        emit({ type: "error", manual: manualCheck, message: String(error) });
      } finally {
        checking = undefined;
        manualCheck = false;
      }
    })();
    return checking;
  },
  async download() {
    if (downloading) return;
    downloading = true;
    let subscription: Awaited<ReturnType<typeof addPluginListener>> | undefined;
    try {
      if (!selected) throw new Error("请先检查更新");
      const update = selected;
      subscription = await addPluginListener<
        Omit<Extract<UpdateEvent, { type: "progress" }>, "type">
      >("native-audio", "updateProgress", (progress) => emit({ ...progress, type: "progress" }));
      downloadedPath = await invoke<string>("plugin:native-audio|download_update", {
        url: update.url,
        size: update.size,
        digest: update.digest ?? null,
      });
      emit({ type: "downloaded", meta: update.meta });
    } catch (error) {
      console.warn("[android-update] download-failed", error);
      emit({ type: "error", manual: true, message: String(error) });
    } finally {
      downloading = false;
      await subscription?.unregister();
    }
  },
  async install() {
    try {
      if (!downloadedPath) throw new Error("更新包已丢失，请重新下载");
      await invoke("plugin:native-audio|install_update", { path: downloadedPath });
    } catch (error) {
      console.warn("[android-update] install-failed", error);
      emit({ type: "error", stage: "install", manual: true, message: String(error) });
    }
  },
  openDownloadPage: async () => openUrl(downloadPage),
  onEvent(callback) {
    listeners.add(callback);
    return () => listeners.delete(callback);
  },
};

export { androidUpdate as mobileUpdate };
