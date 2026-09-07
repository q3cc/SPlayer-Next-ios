import { fetchArtists, fetchNewAlbums, fetchRecommendPlaylists } from "@/apis/recommend/netease";
import { neteaseQrLoginAdapter } from "@/apis/login/netease";
import { searchSongs } from "@/apis/search";
import { resolveNeteaseUrl } from "@/apis/song/netease";
import { reportBootStage } from "@/boot";
import { useSettingsStore } from "@/stores/settings";
import { useStatusStore } from "@/stores/status";
import { useMediaStore } from "@/stores/media";
import { useLibraryStore } from "@/stores/library";
import { CURRENT_AGREEMENT_VERSION } from "@shared/constants/agreement";
import { appCacheDir, join } from "@tauri-apps/api/path";
import { mkdir, remove, writeFile } from "@tauri-apps/plugin-fs";
import { scanMobileDirectories } from "./library";
import { runSmokeChecks, waitForMediaMetadata } from "./smokeChecks";

const requireItems = (name: string, items: unknown[]): void => {
  if (!items.length) throw new Error(`${name} returned no items`);
};

const nextPaint = (): Promise<void> =>
  new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));

const testOnboardingVisible = async (): Promise<void> => {
  await nextPaint();
  const page = document.querySelector<HTMLElement>(".onboarding-page");
  const heading = page?.querySelector<HTMLElement>("h1");
  const splash = document.getElementById("app-loading");
  if (!page || !heading) throw new Error(`onboarding page missing at ${location.hash}`);

  const pageStyle = getComputedStyle(page);
  const headingStyle = getComputedStyle(heading);
  const rect = page.getBoundingClientRect();
  const headingRect = heading.getBoundingClientRect();
  const splashStyle = splash ? getComputedStyle(splash) : null;
  const splashHidden =
    !splash ||
    splash.classList.contains("hidden") ||
    splashStyle?.display === "none" ||
    Number(splashStyle?.opacity ?? 1) === 0;
  const visible =
    rect.width > 0 &&
    rect.height > 0 &&
    headingRect.width > 0 &&
    headingRect.height > 0 &&
    pageStyle.display !== "none" &&
    pageStyle.visibility === "visible" &&
    Number(pageStyle.opacity) > 0 &&
    headingStyle.visibility === "visible";

  reportBootStage(
    `onboarding-layout:${Math.round(rect.width)}x${Math.round(rect.height)}:${headingStyle.color}:${splashHidden ? "clear" : "covered"}`,
  );
  if (!visible) throw new Error("onboarding page is not visible");
  if (!splashHidden) throw new Error("startup splash still covers onboarding");
};

const testHomeRecommendationsVisible = async (): Promise<void> => {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    await new Promise((resolve) => window.setTimeout(resolve, 500));
    const page = document.querySelector<HTMLElement>("main");
    const mobileNav = document.querySelector<HTMLElement>(".mobile-nav");
    const sections = [
      document.querySelector<HTMLElement>("[data-home-recommend-playlists]"),
      document.querySelector<HTMLElement>("[data-home-recommend-artists]"),
      document.querySelector<HTMLElement>("[data-home-new-albums]"),
    ];
    if (
      location.hash === "#/" &&
      page?.getBoundingClientRect().height &&
      (matchMedia("(max-width: 900px)").matches
        ? mobileNav?.getBoundingClientRect().height
        : !mobileNav && document.querySelector(".app-viewport aside")) &&
      sections.every((section) => section && section.getBoundingClientRect().height > 0)
    ) {
      reportBootStage("home-recommendations-ready");
      return;
    }
  }
  throw new Error(`home recommendation sections missing at ${location.hash}`);
};

/** 布局测试入口不依赖外部推荐接口，否则网络故障会伪装成按钮丢失。 */
const installLayoutControls = (): void => {
  if (document.getElementById("smoke-player-button")) return;
  const playerButton = document.createElement("button");
  playerButton.id = "smoke-player-button";
  playerButton.textContent = "Open test player";
  playerButton.style.cssText =
    "position:fixed;right:40px;top:80px;z-index:9999;background:#fff;color:#000;padding:8px";
  playerButton.onclick = async () => {
    const status = useStatusStore();
    status.isPlayerExpanded = !status.isPlayerExpanded;
    if (!status.isPlayerExpanded) {
      playerButton.textContent = "Open test player";
      return;
    }
    useMediaStore().setTrack({
      id: "layout-test",
      source: "local",
      title: "SPlayer layout test",
      artists: [{ name: "SPlayer" }],
      duration: 120000,
    });
    await new Promise((resolve) => setTimeout(resolve, 700));
    const root = document.querySelector<HTMLElement>(".full-player");
    const background = root?.querySelector<HTMLElement>(".bg-solid-wrap");
    const fillsWindow = (node: HTMLElement | null | undefined): boolean => {
      const rect = node?.getBoundingClientRect();
      return (
        !!rect &&
        Math.abs(rect.top) < 1 &&
        Math.abs(rect.left) < 1 &&
        Math.abs(rect.width - innerWidth) < 1 &&
        Math.abs(rect.height - innerHeight) < 1
      );
    };
    if (!fillsWindow(root) || !fillsWindow(background)) {
      playerButton.textContent = "Player edge test failed";
      reportBootStage("player-edge-failed");
      return;
    }
    playerButton.textContent = "Close test player";
    reportBootStage("player-edge-ready");
  };
  document.body.append(playerButton);
  const folderButton = document.createElement("button");
  folderButton.textContent = "Open test folder picker";
  folderButton.style.cssText =
    "position:fixed;right:40px;top:125px;z-index:9998;background:#fff;color:#000;padding:8px";
  folderButton.onclick = async () => {
    const result = await useLibraryStore().addScanDir();
    if (result.success || result.error === "canceled") {
      folderButton.textContent = "Folder picker closed";
      reportBootStage("folder-picker-returned");
    } else {
      folderButton.textContent = `Folder picker failed: ${result.error}`;
      reportBootStage("folder-picker-failed");
    }
  };
  document.body.append(folderButton);
  const checkLayout = (): void => {
    requestAnimationFrame(() =>
      requestAnimationFrame(() => {
        const compact = matchMedia("(max-width: 900px)").matches;
        const nav = document.querySelector(".mobile-nav");
        const sidebar = document.querySelector(".app-viewport aside");
        if (compact ? nav && !sidebar : sidebar && !nav) {
          reportBootStage(compact ? "layout-mobile-ready" : "layout-desktop-ready");
        }
      }),
    );
  };
  window.addEventListener("resize", checkLayout);
  checkLayout();
};

const createSilentWav = (): Uint8Array => {
  const samples = 16000;
  const buffer = new ArrayBuffer(44 + samples * 2);
  const view = new DataView(buffer);
  const text = (offset: number, value: string): void => {
    for (const [index, character] of [...value].entries()) {
      view.setUint8(offset + index, character.charCodeAt(0));
    }
  };
  text(0, "RIFF");
  view.setUint32(4, 36 + samples * 2, true);
  text(8, "WAVEfmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, 8000, true);
  view.setUint32(28, 16000, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  text(36, "data");
  view.setUint32(40, samples * 2, true);
  return new Uint8Array(buffer);
};

const testLibraryScan = async (): Promise<void> => {
  const directory = await join(await appCacheDir(), "mobile-library-smoke");
  await remove(directory, { recursive: true }).catch(() => undefined);
  await mkdir(directory, { recursive: true });
  await writeFile(await join(directory, "smoke.wav"), createSilentWav());
  try {
    const tracks = await scanMobileDirectories([directory]);
    if (tracks.length !== 1 || tracks[0]?.title !== "smoke") {
      throw new Error("mobile directory scan returned invalid tracks");
    }
    const loaded = await window.api.player.load(`file://${await join(directory, "smoke.wav")}`, {
      autoPlay: false,
      meta: tracks[0],
    });
    if (!loaded.success) throw new Error(`local audio load: ${loaded.error}`);
    const dynamicLyrics = await window.api.config.get("media.dynamicLyrics");
    const mediaControls = await window.api.config.get("media.systemMediaControls");
    try {
      await window.api.config.set("media.systemMediaControls", true);
      await window.api.config.set("media.dynamicLyrics", true);
      window.api.nowPlaying.update({
        track: tracks[0],
        source: null,
        lyric: [
          {
            startTime: 100,
            endTime: 1000,
            words: [{ word: "测试动态歌词", startTime: 100, endTime: 1000 }],
            translatedLyric: "",
            romanLyric: "",
            isBG: false,
            isDuet: false,
          },
        ],
      });
      await window.api.player.seek(500);
      const artist = tracks[0].artists.map((item) => item.name).join(" / ");
      await waitForMediaMetadata({ title: "测试动态歌词", artist: `smoke - ${artist}` });
      await window.api.config.set("media.dynamicLyrics", false);
      await waitForMediaMetadata({ title: "smoke", artist });
      reportBootStage("dynamic-lyrics-ready");
    } finally {
      await window.api.config.set("media.dynamicLyrics", dynamicLyrics);
      await window.api.config.set("media.systemMediaControls", mediaControls);
      window.api.nowPlaying.update({ track: null, lyric: [], source: null });
    }
  } finally {
    await window.api.player.stop().catch(() => undefined);
    await remove(directory, { recursive: true }).catch(() => undefined);
  }
};

const testSearchPlayback = async (): Promise<void> => {
  try {
    // 覆盖游客会话初始化、搜索、播放地址与 WKWebView 音频解码，不能仅检查首页公开接口。
    const search = await searchSongs("netease", "纯音乐", 0, 5);
    requireItems("search songs", search.items);
    reportBootStage("search-ready");
    let played = false;
    for (const track of search.items) {
      const source = await resolveNeteaseUrl(track, "lq");
      if (!source.available) {
        reportBootStage(`playback-unavailable:${track.id}:${source.errorCode}`);
        continue;
      }
      const loaded = await window.api.player.load(source.url, { meta: track, autoPlay: true });
      if (!loaded.success) throw new Error(`playback load: ${loaded.error}`);
      for (let attempt = 0; attempt < 10; attempt += 1) {
        await new Promise((resolve) => window.setTimeout(resolve, 500));
        const status = await window.api.player.getStatus();
        if (status.success && status.data?.state === "playing" && status.data.position > 0) {
          played = true;
          break;
        }
      }
      await window.api.player.stop();
      if (!played) throw new Error("audio playback position did not advance");
      break;
    }
    if (!played) throw new Error("search returned no playable tracks");
    reportBootStage("search-playback-ready");
  } finally {
    await window.api.player.stop().catch(() => undefined);
  }
};

/** 分开报告本地、联网和布局结果，失败仍为第二次启动准备独立测试条件。 */
export const runMobileSmokeTest = async (): Promise<void> => {
  reportBootStage("smoke-start");
  const onboarding = !!document.querySelector(".onboarding-page");
  if (!onboarding) installLayoutControls();
  const checks = onboarding
    ? [
        {
          name: "onboarding",
          run: async () => {
            await new Promise((resolve) => window.setTimeout(resolve, 500));
            await testOnboardingVisible();
          },
        },
        { name: "local-media", run: testLibraryScan },
        {
          name: "recommendations",
          run: async () => {
            const [playlists, artists, albums] = await Promise.all([
              fetchRecommendPlaylists(false),
              fetchArtists(),
              fetchNewAlbums(),
            ]);
            requireItems("recommend playlists", playlists);
            requireItems("artists", artists);
            requireItems("albums", albums);
          },
        },
        { name: "online-playback", run: testSearchPlayback },
        {
          name: "qr-login",
          run: async () => {
            const qr = await neteaseQrLoginAdapter.create();
            if (!qr.key || !qr.content.includes("/st/platform/scanlogin"))
              throw new Error("web QR login URL missing");
          },
        },
        {
          name: "prepare-home",
          run: async () => {
            const settings = useSettingsStore();
            await settings.setSystem("system.onboardingCompleted", true);
            await settings.setSystem("system.agreedAgreementVersion", CURRENT_AGREEMENT_VERSION);
          },
        },
      ]
    : [{ name: "home-recommendations", run: testHomeRecommendationsVisible }];
  const passed = await runSmokeChecks(checks, reportBootStage);
  reportBootStage(`smoke-complete:${passed ? "passed" : "failed"}`);
};
