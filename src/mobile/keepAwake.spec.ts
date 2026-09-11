import { mount, flushPromises } from "@vue/test-utils";
import { reactive, ref } from "vue";
import { describe, expect, it, vi, beforeEach } from "vitest";
import PlayerSurface from "@/components/player/PlayerSurface.vue";

const mocks = vi.hoisted(() => ({
  invoke: vi.fn(),
  status: {} as Record<string, unknown>,
  settings: {} as Record<string, unknown>,
  media: {} as Record<string, unknown>,
}));
const visibility = ref("visible");
vi.mock("@/utils/config", () => ({ isIOS: true }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: mocks.invoke }));
vi.mock("@/stores/settings", () => ({ useSettingsStore: () => mocks.settings }));
vi.mock("@/stores/status", () => ({ useStatusStore: () => mocks.status }));
vi.mock("@/stores/media", () => ({ useMediaStore: () => mocks.media }));
vi.mock("@vueuse/core", () => ({ useDocumentVisibility: () => visibility }));
vi.mock("@/components/player/FullPlayer/index.vue", () => ({
  default: { template: "<div data-original />" },
}));
vi.mock("@/components/player/AppleMusicPlayer/index.vue", () => ({
  __esModule: true,
  default: {
    emits: ["lyricsVisible"],
    template: "<button data-apple @click=\"$emit('lyricsVisible', true)\" />",
  },
}));

beforeEach(() => {
  mocks.invoke.mockReset().mockResolvedValue(undefined);
  mocks.status = reactive({ isPlayerExpanded: false, showLyric: true, fullQueueOpen: false });
  mocks.settings = reactive({ player: { theme: "original", coverLayout: "default" } });
  mocks.media = reactive({ parsedLyric: [{}], lyricLoading: false });
  visibility.value = "visible";
});

describe("播放页歌词常亮", () => {
  it("仅在前台显示歌词时开启，收起、隐藏、后台及卸载时释放", async () => {
    const wrapper = mount(PlayerSurface);
    const check = async (enabled: boolean) => {
      await flushPromises();
      await vi.waitFor(() =>
        expect(mocks.invoke).toHaveBeenLastCalledWith("plugin:lyric-pip|keepawake", { enabled }),
      );
    };
    await check(false);
    mocks.status.isPlayerExpanded = true;
    await check(true);
    mocks.status.showLyric = false;
    await check(false);
    mocks.status.showLyric = true;
    await check(true);
    visibility.value = "hidden";
    await check(false);
    visibility.value = "visible";
    await check(true);
    mocks.status.isPlayerExpanded = false;
    await check(false);
    mocks.status.isPlayerExpanded = true;
    await check(true);
    wrapper.unmount();
    await check(false);
  });
  it("主题互斥挂载，Apple Music 根据实际歌词视图申请常亮", async () => {
    const wrapper = mount(PlayerSurface);
    expect(wrapper.find("[data-original]").exists()).toBe(true);
    expect(wrapper.find("[data-apple]").exists()).toBe(false);
    (mocks.settings.player as { theme: string }).theme = "apple-music";
    mocks.status.isPlayerExpanded = true;
    await flushPromises();
    expect(wrapper.find("[data-original]").exists()).toBe(false);
    expect(mocks.invoke).toHaveBeenLastCalledWith("plugin:lyric-pip|keepawake", { enabled: false });
    await wrapper.get("[data-apple]").trigger("click");
    await flushPromises();
    expect(mocks.invoke).toHaveBeenLastCalledWith("plugin:lyric-pip|keepawake", { enabled: true });
    (mocks.settings.player as { theme: string }).theme = "original";
    await flushPromises();
    expect(wrapper.find("[data-apple]").exists()).toBe(false);
    expect(wrapper.find("[data-original]").exists()).toBe(true);
    wrapper.unmount();
  });
});
