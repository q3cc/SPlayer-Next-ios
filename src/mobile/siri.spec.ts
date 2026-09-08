import { expect, it, vi } from "vitest";
import * as playback from "@/services/playback";
import { reactive, shallowRef, nextTick } from "vue";

const mocks = vi.hoisted(() => ({
  invoke: vi.fn(),
  listener: vi.fn(),
  status: null as any,
  settings: null as any,
  entries: null as any,
  queue: null as any,
  setQueue: vi.fn(),
  media: null as any,
  lyrics: vi.fn().mockResolvedValue(undefined),
  adoptNative: vi.fn(),
  mediaTrack: vi.fn(),
  mediaPosition: vi.fn(),
}));
vi.mock("./mediaSession", () => ({
  mobileMediaSession: { setTrack: mocks.mediaTrack, setPosition: mocks.mediaPosition },
}));
vi.mock("@tauri-apps/api/core", () => ({
  invoke: mocks.invoke,
  addPluginListener: mocks.listener,
  isTauri: () => true,
}));
vi.mock("./shims/store", () => ({ store: { store: {}, get: () => true } }));
vi.mock("./shims/sessions", () => ({ getSessionCookies: () => ({}) }));
vi.mock("@/stores/settings", () => ({ useSettingsStore: () => mocks.settings }));
vi.mock("@/stores/status", () => ({ useStatusStore: () => mocks.status }));
vi.mock("@/stores/data", () => ({
  useDataStore: () => ({ getPlatformProfile: () => null, platformProfiles: {} }),
}));
vi.mock("@/stores/user", () => ({ useUserStore: () => ({ profile: null }) }));
vi.mock("@/stores/media", () => ({
  useMediaStore: () => mocks.media,
}));
vi.mock("@/services/lyric/loader", () => ({ loadForTrack: mocks.lyrics }));
vi.mock("@/core/player", () => ({ adoptNativePlayback: mocks.adoptNative }));
vi.mock("@/stores/queue", () => ({
  get queueEntries() {
    return mocks.entries;
  },
  get queue() {
    return mocks.queue;
  },
  setQueue: mocks.setQueue,
}));

it("原生切歌与网页同时更新时，明确拒绝旧快照并忽略乱序通知", async () => {
  const first = { source: "local", id: "one", title: "第一首", artists: [] };
  const second = { ...first, id: "two", title: "第二首", duration: 200000 };
  mocks.media = {
    track: first,
    detail: { old: true },
    setTrack: vi.fn((track) => {
      mocks.media.track = track;
    }),
    setPlaybackContext: vi.fn(),
    updateLyricIndex: vi.fn(),
  };
  mocks.entries = shallowRef([first]);
  mocks.queue = shallowRef([first]);
  mocks.status = reactive({
    currentTrack: first,
    playIndex: 0,
    position: 0,
    state: "paused",
    searchPlatform: "netease",
    repeatMode: "list",
    shuffleMode: "off",
  });
  mocks.settings = reactive({
    system: { siri: { enabled: true }, media: { systemMediaControls: true } },
    player: { songLevel: "hq", allowTrialPlay: false },
  });
  const original = {
    revision: 4,
    queue: [first],
    currentId: "local:one",
    position: 0,
    playing: false,
  };
  const advanced = {
    ...original,
    revision: 5,
    queue: [second],
    currentId: "local:two",
    playing: true,
    position: 42000,
  };
  mocks.invoke.mockImplementation(async (_command, { request }) => {
    const value = JSON.parse(request);
    if (value.action === "snapshot") return { json: JSON.stringify(original) };
    if (value.action === "syncQueue")
      return { json: JSON.stringify({ accepted: false, snapshot: advanced }) };
    return { json: "{}" };
  });
  mocks.listener.mockResolvedValue({ unregister: vi.fn() });
  Object.defineProperty(window, "api", {
    configurable: true,
    value: { player: { getStatus: async () => ({ data: { state: "idle" } }) } },
  });
  localStorage.removeItem("splayer.mobile.library");
  const { mobileSiri } = await import("./siri");
  expect(await mobileSiri.initialize()).toBe(false);
  expect(mocks.listener.mock.invocationCallOrder[0]).toBeLessThan(
    mocks.invoke.mock.invocationCallOrder[0],
  );
  expect(mocks.setQueue).toHaveBeenLastCalledWith([second]);
  expect(mocks.status.state).toBe("playing");
  expect(mocks.status.duration).toBe(200000);
  expect(mocks.status.position).toBe(42000);
  expect(mocks.mediaTrack).toHaveBeenLastCalledWith(second);
  expect(mocks.mediaPosition).toHaveBeenLastCalledWith(42000);
  expect(playback.getDuration()).toBe(200000);
  expect(playback.getCurrentTime()).toBeGreaterThanOrEqual(42000);
  expect(playback.isPlaying()).toBe(true);
  expect(mocks.media.detail).toBeNull();
  expect(mocks.adoptNative).toHaveBeenCalledTimes(1);
  expect(mocks.lyrics).toHaveBeenCalledWith(null);
  const received = mocks.listener.mock.calls[0][2];
  mocks.setQueue.mockClear();
  received({ json: JSON.stringify(original) });
  await nextTick();
  expect(mocks.setQueue).not.toHaveBeenCalled();
  // 同一首恢复到前台时用原生实际位置，不重新加载歌曲或重置歌词。
  window.api.player.getStatus = vi
    .fn()
    .mockResolvedValue({ data: { state: "paused", position: 78000, duration: 210000, speed: 1 } });
  received({ json: JSON.stringify(advanced) });
  await vi.waitFor(() => expect(mocks.status.position).toBe(78000));
  expect(playback.getCurrentTime()).toBe(78000);
  expect(playback.getDuration()).toBe(210000);
  expect(playback.isPlaying()).toBe(false);
  expect(mocks.lyrics).toHaveBeenCalledTimes(1);
  // 连续切歌时，后返回的旧原生状态不能盖过更新的队列。
  let finishOld!: (value: unknown) => void;
  window.api.player.getStatus = vi
    .fn()
    .mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finishOld = resolve;
        }),
    )
    .mockResolvedValue({ data: { state: "playing", position: 9000, duration: 210000 } });
  received({ json: JSON.stringify({ ...original, revision: 6 }) });
  received({ json: JSON.stringify({ ...advanced, revision: 7 }) });
  await vi.waitFor(() => expect(mocks.status.position).toBe(9000));
  finishOld({ data: { state: "paused", position: 1000, duration: 10000 } });
  await nextTick();
  expect(mocks.setQueue).toHaveBeenLastCalledWith([second]);
  expect(mocks.status.position).toBe(9000);
});

it("冷启动已存有同一首歌曲时仍加载歌词，并接管原生进度而不重播", async () => {
  vi.resetModules();
  mocks.invoke.mockClear();
  mocks.lyrics.mockClear();
  const track = {
    source: "netease",
    id: "cold",
    title: "特别的人",
    artists: [{ name: "方大同" }],
    duration: 250000,
  };
  mocks.media.track = track;
  mocks.media.detail = null;
  mocks.status.currentTrack = track;
  mocks.invoke.mockImplementation(async (_command, { request }) => {
    if (JSON.parse(request).action === "snapshot")
      return {
        json: JSON.stringify({
          revision: 10,
          queue: [track],
          currentId: "netease:cold",
          position: 0,
          playing: false,
        }),
      };
    return { json: "{}" };
  });
  window.api.player.getStatus = vi
    .fn()
    .mockResolvedValue({ data: { state: "playing", position: 65000, duration: 251000, speed: 1 } });
  const { mobileSiri } = await import("./siri");
  expect(await mobileSiri.initialize()).toBe(true);
  expect(mocks.lyrics).toHaveBeenCalledTimes(1);
  expect(mocks.status.position).toBe(65000);
  expect(mocks.status.duration).toBe(251000);
  expect(
    mocks.invoke.mock.calls.some(([, args]) => JSON.parse(args.request).action === "syncQueue"),
  ).toBe(false);
});
