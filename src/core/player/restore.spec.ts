import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Track } from "@shared/types/player";

const mocks = vi.hoisted(() => ({
  status: {
    state: "idle",
    position: 25000,
    duration: 180000,
    currentTrack: null as Track | null,
    currentPlaybackContext: undefined,
    trackLoading: false,
    get isPlaying() {
      return this.state === "playing";
    },
  },
  media: {
    track: null as Track | null,
    setTrack: vi.fn(),
    setPlaybackContext: vi.fn(),
    enrichTrack: vi.fn(),
  },
  resolve: vi.fn(),
  load: vi.fn(),
  play: vi.fn(),
  seek: vi.fn(),
  record: vi.fn(),
}));
vi.mock("./events", () => ({ handleEvent: vi.fn() }));
vi.mock("./seek", () => ({ resetSeek: vi.fn(), seek: mocks.seek }));
vi.mock("@/stores/status", () => ({ useStatusStore: () => mocks.status }));
vi.mock("@/stores/media", () => ({ useMediaStore: () => mocks.media }));
vi.mock("@/stores/settings", () => ({
  useSettingsStore: () => ({
    system: { player: { autoPlay: false, rememberLastTrack: true } },
    preset: {},
  }),
}));
vi.mock("@/stores/streaming", () => ({ useStreamingStore: vi.fn() }));
vi.mock("@/stores/plugins", () => ({ usePluginsStore: vi.fn() }));
vi.mock("@/stores/history", () => ({ useHistoryStore: () => ({ record: mocks.record }) }));
vi.mock("@/stores/library", () => ({ useLibraryStore: vi.fn() }));
vi.mock("@/stores/queue", () => ({ updateQueueTracks: vi.fn() }));
vi.mock("./fm", () => ({}));
vi.mock("@/services/lyric/loader", () => ({ beginLoad: vi.fn(), loadForTrack: vi.fn() }));
vi.mock("@/services/coverLoader", () => ({ loadCoverForTrack: vi.fn() }));
vi.mock("@/services/abLoop", () => ({ reset: vi.fn() }));
vi.mock("@/services/cacheScheduler", () => ({ cancel: vi.fn(), schedule: vi.fn() }));
vi.mock("@/services/audioSource", () => ({ resolveTrackSource: mocks.resolve }));
vi.mock("@/services/nextTrackPreloader", () => ({
  consumePreloadedTrack: vi.fn(),
  scheduleNextTrackPreload: vi.fn(),
}));
vi.mock("./stats", () => ({ installPlayStats: vi.fn() }));
vi.mock("@/composables/useFavorite", () => ({ useFavorite: vi.fn() }));
vi.mock("@/utils/color", () => ({ extractColorFromUrl: vi.fn() }));
vi.mock("@/utils/errors", () => ({ handleError: vi.fn(), isSkippableError: () => false }));
vi.mock("@/composables/useToast", () => ({ toast: {} }));
vi.mock("@/i18n", () => ({ default: {} }));

beforeEach(() => {
  vi.resetModules();
  mocks.status.currentTrack = {
    id: "1",
    source: "netease",
    title: "歌曲",
    artists: [],
    duration: 180000,
  };
  mocks.status.position = 25000;
  mocks.status.state = "idle";
  mocks.status.trackLoading = false;
  mocks.media.track = mocks.status.currentTrack;
  mocks.resolve
    .mockReset()
    .mockResolvedValue({ source: "https://example.test/song.mp3", provider: "official" });
  mocks.load
    .mockReset()
    .mockResolvedValue({ success: true, data: { detail: {}, mediaInfo: { duration: 180000 } } });
  mocks.play.mockResolvedValue({ success: true });
  Object.defineProperty(window, "api", {
    configurable: true,
    value: {
      player: {
        load: mocks.load,
        play: mocks.play,
        stop: vi.fn().mockResolvedValue({ success: true }),
      },
    },
  });
});

describe("冷启动恢复", () => {
  it("恢复期间点击播放不会重复加载，恢复后真正播放并保留位置", async () => {
    const player = await import("./index");
    let finish!: (value: unknown) => void;
    mocks.resolve.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
    );
    const restoring = player.restoreLastTrack();
    await player.play();
    expect(mocks.play).not.toHaveBeenCalled();
    finish({ source: "https://example.test/song.mp3", provider: "official" });
    await restoring;
    expect(mocks.load).toHaveBeenCalledOnce();
    expect(mocks.seek).toHaveBeenCalledWith(25000);
    expect(mocks.play).toHaveBeenCalledOnce();
    expect(mocks.status.state).toBe("playing");
  });

  it("恢复期间再次切换播放按钮可以取消待播放请求", async () => {
    const player = await import("./index");
    let finish!: (value: unknown) => void;
    mocks.resolve.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
    );
    const restoring = player.restoreLastTrack();
    player.togglePlay();
    player.togglePlay();
    finish({ source: "https://example.test/song.mp3", provider: "official" });
    await restoring;
    expect(mocks.play).not.toHaveBeenCalled();
    expect(mocks.status.state).toBe("paused");
  });

  it("恢复失败保留记忆位置，用户再次播放时重新解析", async () => {
    const player = await import("./index");
    mocks.load.mockResolvedValueOnce({ success: false });
    await player.restoreLastTrack();
    expect(mocks.status.position).toBe(25000);
    expect(mocks.status.state).toBe("idle");
    await player.play();
    expect(mocks.load).toHaveBeenCalledTimes(2);
    expect(mocks.seek).toHaveBeenCalledWith(25000);
    expect(mocks.status.state).toBe("playing");
  });
});
