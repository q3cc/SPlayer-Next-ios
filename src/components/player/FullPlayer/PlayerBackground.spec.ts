import { mount } from "@vue/test-utils";
import { nextTick, reactive } from "vue";
import { expect, it, vi } from "vitest";
import PlayerBackground from "./PlayerBackground.vue";

const settings = reactive({
  player: {
    theme: "apple-music",
    playerBgType: "animation",
    playerBgFps: 60,
    playerBgFlowSpeed: 2,
    playerBgRenderScale: 0.5,
    playerBgFreezeOnPause: false,
    playerBgBeat: true,
  },
});
const status = reactive({ isPlayerExpanded: true, isPlaying: false });
vi.mock("@/stores/settings", () => ({ useSettingsStore: () => settings }));
vi.mock("@/stores/status", () => ({ useStatusStore: () => status }));
vi.mock("@/stores/media", () => ({
  useMediaStore: () => ({ parsedLyric: [], track: { cover: "cover.jpg" } }),
}));
vi.mock("./BackgroundRender.vue", () => ({
  default: {
    name: "BackgroundRender",
    props: ["playing", "active", "fps", "flowSpeed", "renderScale", "enableBeat"],
    template: "<div />",
  },
}));

it("Apple Music 背景随设置切换模式和动画参数", async () => {
  vi.useFakeTimers();
  const wrapper = mount(PlayerBackground, { global: { stubs: { transition: false } } });
  try {
    await vi.advanceTimersByTimeAsync(500);
    const renderer = () => wrapper.findComponent({ name: "BackgroundRender" });
    expect(renderer().props()).toMatchObject({ playing: true, fps: 60, enableBeat: true });
    settings.player.playerBgFreezeOnPause = true;
    settings.player.playerBgFps = 30;
    await nextTick();
    expect(renderer().props()).toMatchObject({ playing: false, fps: 30 });
    status.isPlaying = true;
    await wrapper.setProps({ reducedMotion: true, active: false });
    expect(renderer().props()).toMatchObject({ playing: false, active: false });
    settings.player.playerBgType = "solid";
    await nextTick();
    expect(renderer().exists()).toBe(false);
    settings.player.playerBgType = "blur";
    await nextTick();
    expect(wrapper.find(".bg-blur-wrap").exists()).toBe(true);
    expect(renderer().exists()).toBe(false);
  } finally {
    wrapper.unmount();
    vi.useRealTimers();
  }
});
