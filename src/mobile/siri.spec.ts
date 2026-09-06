import { expect, it, vi } from "vitest";
import { reactive, shallowRef, nextTick } from "vue";

const mocks = vi.hoisted(() => ({
  invoke: vi.fn(),
  listener: vi.fn(),
  status: null as any,
  settings: null as any,
  entries: null as any,
  queue: null as any,
  setQueue: vi.fn(),
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
vi.mock("@/stores/media", () => ({
  useMediaStore: () => ({ setTrack: vi.fn(), setPlaybackContext: vi.fn() }),
}));
vi.mock("@/services/lyric/loader", () => ({ loadForTrack: vi.fn() }));
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
  const second = { ...first, id: "two", title: "第二首" };
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
  const received = mocks.listener.mock.calls[0][2];
  mocks.setQueue.mockClear();
  received({ json: JSON.stringify(original) });
  await nextTick();
  expect(mocks.setQueue).not.toHaveBeenCalled();
});
