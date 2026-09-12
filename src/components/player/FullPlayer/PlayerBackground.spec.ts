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
const media = reactive({
  parsedLyric: [],
  track: { cover: "cover.jpg", coverOriginal: "large.jpg" },
});
vi.mock("@/stores/settings", () => ({ useSettingsStore: () => settings }));
vi.mock("@/stores/status", () => ({ useStatusStore: () => status }));
vi.mock("@/stores/media", () => ({
  useMediaStore: () => media,
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

it("只为可见模糊背景解码缩略图，模式切换使旧解码失效", async () => {
  settings.player.playerBgType = "animation";
  status.isPlayerExpanded = true;
  const images: Array<{ src: string; finish: () => void }> = [];
  vi.stubGlobal(
    "Image",
    class {
      src = "";
      finish!: () => void;
      constructor() {
        images.push(this);
      }
      decode() {
        return new Promise<void>((resolve) => {
          this.finish = resolve;
        });
      }
    },
  );
  vi.useFakeTimers();
  const wrapper = mount(PlayerBackground, { global: { stubs: { transition: false } } });
  try {
    media.track.cover = "next-small.jpg";
    await nextTick();
    expect(images).toHaveLength(0);
    settings.player.playerBgType = "blur";
    await nextTick();
    expect(images).toHaveLength(1);
    expect(images[0].src).toBe("next-small.jpg");
    settings.player.playerBgType = "solid";
    await nextTick();
    expect(images[0].src).toBe("");
    images[0].finish();
    await vi.advanceTimersByTimeAsync(600);
    expect(wrapper.find(".bg-img").exists()).toBe(false);
    await wrapper.setProps({ active: false });
    settings.player.playerBgType = "blur";
    media.track.cover = "latest-small.jpg";
    await nextTick();
    expect(images).toHaveLength(1);
    await wrapper.setProps({ active: true });
    expect(images).toHaveLength(2);
    expect(images[1].src).toBe("latest-small.jpg");
    images[1].finish();
    await vi.advanceTimersByTimeAsync(100);
    expect(wrapper.get(".bg-img.active").attributes("src")).toBe("latest-small.jpg");
  } finally {
    wrapper.unmount();
    vi.useRealTimers();
    vi.unstubAllGlobals();
  }
});
