import { openUrl } from "@tauri-apps/plugin-opener";
import { addPluginListener, invoke } from "@tauri-apps/api/core";
import type { UpdateApi, UpdateEvent, UpdateMeta } from "@shared/types/update";
import { fetchWithProxy } from "./shims/proxy";
import { store } from "./shims/store";

interface Release {
  tag_name: string;
  draft: boolean;
  prerelease: boolean;
  body: string | null;
  published_at: string | null;
  assets: {
    name: string;
    size: number;
    state: string;
    browser_download_url: string;
    digest?: string;
  }[];
}

const repoUrl = __APP_REPO_URL__.replace(/\/$/, "");
const listeners = new Set<(event: UpdateEvent) => void>();
let downloadPage = `${repoUrl}/releases`;
let checking: Promise<void> | undefined;
let checkingChannel: string | undefined;
let manualCheck = false;
let selected: { url: string; size: number; digest?: string; meta: UpdateMeta } | undefined;
let downloading = false;
let sharing = false;

/** 识别本仓库的 iOS 标签及正式、alpha、beta 版本。 */
const versionParts = (version: string): number[] | null => {
  const match = /^(?:ios-)?v?(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta)(?:\.(\d+))?)?(?:\+[\w.-]+)?$/.exec(
    version,
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

/** 复用更新弹窗和设置；IPA 下载后交给系统分享面板，不执行应用内安装。 */
export const mobileUpdate: UpdateApi = {
  check(manual) {
    if (downloading) return Promise.resolve();
    if (!manual && !store.get("update.autoCheck")) return Promise.resolve();
    manualCheck ||= manual;
    const channel = store.get("update.channel");
    if (checking)
      return checkingChannel === channel
        ? checking
        : checking.then(() => mobileUpdate.check(manual));
    checkingChannel = channel;
    console.info("[update] check-start", {
      channel,
      version: __APP_VERSION__,
      commit: __COMMIT_HASH__,
    });
    listeners.forEach((listener) => listener({ type: "checking" }));
    checking = (async () => {
      try {
        const repository = new URL(repoUrl);
        if (repository.hostname !== "github.com") throw new Error("更新仓库必须位于 GitHub");
        const response = await fetchWithProxy(
          `https://api.github.com/repos${repository.pathname}/releases${channel === "action" ? "/tags/action-latest" : "?per_page=100"}`,
          {
            headers: { Accept: "application/vnd.github+json", "User-Agent": "SPlayer-Next-ios" },
            signal: AbortSignal.timeout(15000),
          },
        );
        if (response.status === 404 && channel === "action") {
          listeners.forEach((listener) => listener({ type: "notAvailable", manual: manualCheck }));
          return;
        }
        console.info("[update] response", {
          channel,
          status: response.status,
          contentType: response.headers.get("content-type"),
          contentEncoding: response.headers.get("content-encoding"),
          rateRemaining: response.headers.get("x-ratelimit-remaining"),
        });
        if (!response.ok) {
          if (
            response.status === 429 ||
            (response.status === 403 && response.headers.get("x-ratelimit-remaining") === "0")
          ) {
            throw new Error("GitHub 请求次数已用完，请稍后重试或前往下载页");
          }
          throw new Error(`GitHub HTTP ${response.status}`);
        }
        const payload = await response.json();
        if (channel !== store.get("update.channel")) return;
        const releases: Release[] = channel === "action" ? [payload] : payload;
        const current = versionParts(__APP_VERSION__);
        if (!current || !Array.isArray(releases)) throw new Error("无法识别更新版本");
        let action: { commit: string; version: string; date: string; asset: string } | undefined;
        if (channel === "action") {
          const metadata = /<!-- splayer-action:(.*?) -->/.exec(releases[0]?.body ?? "");
          if (!metadata) throw new Error("Action 构建信息不完整");
          action = JSON.parse(metadata[1]);
          if (
            !action ||
            !/^[a-f0-9]{40}$/.test(action.commit) ||
            !versionParts(action.version) ||
            !Number.isFinite(Date.parse(action.date)) ||
            !action.asset?.endsWith(".ipa")
          ) {
            throw new Error("Action 构建信息无效");
          }
        }
        const candidates = releases
          .flatMap((release) => {
            const version = versionParts(action?.version ?? release.tag_name);
            const asset = release.assets?.find(
              (item) =>
                item.name.endsWith(".ipa") &&
                (!action || item.name === action.asset) &&
                item.state === "uploaded" &&
                item.size > 0,
            );
            if (release.draft || !version || !asset) return [];
            if (channel === "stable" && (release.prerelease || version[3] < 0)) return [];
            if (channel === "beta" && version[3] === -2) return [];
            return [{ release, version, asset }];
          })
          .sort((a, b) => {
            for (let i = 0; i < a.version.length; i++) {
              if (a.version[i] !== b.version[i]) return b.version[i] - a.version[i];
            }
            return 0;
          });
        const latest = candidates[0];
        const difference =
          latest?.version.findIndex((part, index) => part !== current[index]) ?? -1;
        const isNew = action
          ? !action.commit.startsWith(__COMMIT_HASH__) &&
            Date.parse(action.date) > Date.parse(__COMMIT_DATE__)
          : difference >= 0 && Boolean(latest && latest.version[difference] > current[difference]);
        console.info("[update] check-result", {
          channel,
          hasCandidate: Boolean(latest),
          isNew,
          commit: action?.commit,
        });
        if (!latest || !isNew) {
          selected = undefined;
          listeners.forEach((listener) => listener({ type: "notAvailable", manual: manualCheck }));
          return;
        }
        downloadPage = `${repoUrl}/releases/tag/${encodeURIComponent(latest.release.tag_name)}`;
        const assetUrl = new URL(latest.asset.browser_download_url);
        if (
          assetUrl.origin !== repository.origin ||
          !assetUrl.pathname.startsWith(`${repository.pathname}/releases/download/`) ||
          !assetUrl.pathname.endsWith(".ipa")
        ) {
          throw new Error("IPA 附件不属于当前仓库");
        }
        const meta: UpdateMeta = {
          version: action
            ? `${action.version} · ${action.commit.slice(0, 7)}`
            : latest.release.tag_name.replace(/^(?:ios-)?v?/, ""),
          releaseNotes: (latest.release.body ?? "")
            .replace(/<!-- splayer-action:.*? -->/, "")
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
        listeners.forEach((listener) =>
          listener({
            type: "available",
            manual: manualCheck,
            canInstall: true,
            meta,
          }),
        );
      } catch (error) {
        console.warn("[update] check-failed", { channel }, error);
        listeners.forEach((listener) =>
          listener({ type: "error", manual: manualCheck, message: String(error) }),
        );
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
      >("ipa-update", "progress", (progress) => {
        listeners.forEach((listener) => listener({ ...progress, type: "progress" }));
      });
      await invoke("plugin:ipa-update|download", {
        url: update.url,
        size: update.size,
        digest: update.digest ?? null,
      });
      listeners.forEach((listener) => listener({ type: "downloaded", meta: update.meta }));
      await mobileUpdate.install();
    } catch (error) {
      console.warn("[update] download-failed", error);
      listeners.forEach((listener) =>
        listener({ type: "error", manual: true, message: String(error) }),
      );
    } finally {
      downloading = false;
      await subscription?.unregister();
    }
  },
  async install() {
    if (sharing) return;
    sharing = true;
    let timeout: ReturnType<typeof setTimeout> | undefined;
    try {
      console.info("[update] share-start");
      await Promise.race([
        invoke("plugin:ipa-update|share"),
        new Promise<never>((_, reject) => {
          timeout = setTimeout(() => reject(new Error("分享面板未响应，请返回前台后重试")), 10000);
        }),
      ]);
      console.info("[update] share-presented");
    } catch (error) {
      const detail = error as { code?: string; message?: string } | null;
      const missing = detail?.code === "IPA_MISSING";
      // 文件丢失时恢复下载入口；窗口切换等分享失败仍可直接重试。
      console.warn("[update] share-failed", error);
      listeners.forEach((listener) =>
        listener({
          type: "error",
          ...(missing ? {} : { stage: "share" as const }),
          manual: true,
          message: detail?.message ?? String(error),
        }),
      );
    } finally {
      clearTimeout(timeout);
      sharing = false;
    }
  },
  openDownloadPage: async () => openUrl(downloadPage),
  onEvent(callback) {
    listeners.add(callback);
    return () => {
      listeners.delete(callback);
    };
  },
};
