import { mount, flushPromises } from "@vue/test-utils";
import { reactive, ref } from "vue";
import { beforeEach, expect, it, vi } from "vitest";
import PlayerSurface from "@/components/player/PlayerSurface.vue";

const mocks = vi.hoisted(() => ({
  invoke: vi.fn(),
  status: {} as Record<string, unknown>,
  settings: {} as Record<string, unknown>,
  media: {} as Record<string, unknown>,
}));
const visibility = ref("visible");
vi.mock("@/utils/config", () => ({ isIOS: false, isAndroid: true }));
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
    template: `<div data-apple>
      <button data-show-lyrics @click="$emit('lyricsVisible', true)" />
      <button data-hide-lyrics @click="$emit('lyricsVisible', false)" />
    </div>`,
  },
}));

beforeEach(() => {
  mocks.invoke.mockReset().mockResolvedValue(undefined);
  mocks.status = reactive({ isPlayerExpanded: true, showLyric: false, fullQueueOpen: false });
  mocks.settings = reactive({ player: { theme: "apple-music", coverLayout: "default" } });
  mocks.media = reactive({ parsedLyric: [{}], lyricLoading: false });
  visibility.value = "visible";
});

it("安卓 AM 歌词只在前台可见时常亮，切换主题与卸载时释放", async () => {
  const wrapper = mount(PlayerSurface);
  const check = async (enabled: boolean) => {
    await flushPromises();
    expect(mocks.invoke).toHaveBeenLastCalledWith("plugin:native-audio|keep_awake", { enabled });
    expect(
      mocks.invoke.mock.calls.some(([command]) => command === "plugin:lyric-pip|keepawake"),
    ).toBe(false);
  };

  await check(false);
  await wrapper.get("[data-show-lyrics]").trigger("click");
  await check(true);
  visibility.value = "hidden";
  await check(false);
  visibility.value = "visible";
  await check(true);
  await wrapper.get("[data-hide-lyrics]").trigger("click");
  await check(false);
  await wrapper.get("[data-show-lyrics]").trigger("click");
  await check(true);
  (mocks.settings.player as { theme: string }).theme = "original";
  await check(false);
  wrapper.unmount();
  await check(false);
});
