import { mount, flushPromises } from "@vue/test-utils";
import { h, reactive, ref } from "vue";
import { beforeEach, afterEach, expect, it, vi } from "vitest";
import AppleMusicPlayer from "./index.vue";

const mocks = vi.hoisted(() => ({
  status: {} as Record<string, unknown>,
  media: {} as Record<string, unknown>,
  start: vi.fn(),
  stop: vi.fn(),
  seek: vi.fn(),
  play: vi.fn(),
  toggle: vi.fn(),
  previous: vi.fn(),
  next: vi.fn(),
  volume: vi.fn(),
  lyrics: { setCurrentTime: vi.fn(), resume: vi.fn(), freeze: vi.fn() },
}));
const visibility = ref("visible");
const wide = ref(false);
const reduceMotion = ref(false);
vi.mock("@vueuse/core", () => ({
  useDocumentVisibility: () => visibility,
  useMediaQuery: (query: string) => (query.includes("min-width") ? wide : reduceMotion),
}));
vi.mock("@/stores/status", () => ({ useStatusStore: () => mocks.status }));
vi.mock("@/stores/media", () => ({ useMediaStore: () => mocks.media }));
vi.mock("@/stores/settings", () => ({
  useSettingsStore: () => ({
    player: { playerBgFps: 30, playerBgRenderScale: 0.5, playerBgFlowSpeed: 4 },
    lyric: { engine: "custom", showTranslation: true },
  }),
}));
vi.mock("@/utils/config", () => ({ isIOS: true }));
vi.mock("vue-i18n", () => ({ useI18n: () => ({ t: (key: string) => key }) }));
vi.mock("@/services/playback", () => ({ getCurrentTime: () => 25000 }));
vi.mock("@/composables/usePlaybackTime", () => ({
  usePlaybackTime: () => ({ start: mocks.start, stop: mocks.stop }),
}));
vi.mock("@/composables/useProgressLyric", () => ({
  useProgressLyric: () => ({ snapToNearestLyric: (value: number) => value }),
}));
vi.mock("@/composables/useFavorite", () => ({
  useFavorite: () => ({ isLiked: () => false, isSupported: () => true, toggle: vi.fn() }),
}));
vi.mock("@/composables/usePlaylistPicker", () => ({
  usePlaylistPicker: () => ({ open: false, tracks: [], mode: "local", openPicker: vi.fn() }),
}));
vi.mock("@/composables/useDownload", () => ({ useDownload: () => ({ enqueue: vi.fn() }) }));
vi.mock("@/composables/useTrackMenu", () => ({
  useTrackMenu: () => ({ items: [], handleSelect: vi.fn() }),
}));
vi.mock("@/core/player", () => ({
  __v_isRef: false,
  seek: mocks.seek,
  play: mocks.play,
  togglePlay: mocks.toggle,
  prevTrack: mocks.previous,
  nextTrack: mocks.next,
  setVolume: mocks.volume,
  isSeeking: () => false,
  toggleShuffleMode: vi.fn(),
  cycleRepeatMode: vi.fn(),
}));
vi.mock("../Lyrics/AMLLLyrics.vue", () => ({
  default: {
    name: "AMLLLyrics",
    props: ["initialTime", "playing", "lyricLines"],
    emits: ["seek"],
    setup(
      _: unknown,
      {
        expose,
        emit,
      }: { expose: (value: unknown) => void; emit: (event: string, value: number) => void },
    ) {
      expose(mocks.lyrics);
      return () => h("button", { "data-lyrics": "", onClick: () => emit("seek", 42000) }, "歌词");
    },
  },
}));
vi.mock("../FullPlayer/PlayerBackground.vue", () => ({
  default: {
    name: "BackgroundRender",
    props: ["active", "reducedMotion"],
    template: "<div data-background />",
  },
}));
vi.mock("../FullPlayer/PlayerCover.vue", () => ({ default: { template: "<div data-cover />" } }));
vi.mock("../AirPlayControl.vue", () => ({ default: { template: "<div data-airplay />" } }));
vi.mock("../VolumeControl.vue", () => ({ default: { template: "<div data-volume />" } }));
vi.mock("./PlayingNext.vue", () => ({ default: { template: "<div data-queue />" } }));
vi.mock("@/components/modals/PlaylistPickerDialog.vue", () => ({
  default: { template: "<div />" },
}));

const wrappers: ReturnType<typeof mount>[] = [];
const create = () => {
  const wrapper = mount(AppleMusicPlayer, {
    global: {
      stubs: {
        teleport: true,
        transition: false,
        IconSpLossless: true,
        SDropdownMenu: {
          name: "SDropdownMenu",
          props: ["items"],
          emits: ["select"],
          template: "<div><slot name='trigger' /></div>",
        },
        ...Object.fromEntries(
          [
            "EqualizerDialog",
            "SpeedDialog",
            "AbLoopDialog",
            "AutoCloseDialog",
            "FmModeDialog",
            "CopyLyricsDialog",
          ].map((name) => [name, { name, props: ["open"], template: "<div />" }]),
        ),
        SSlider: {
          emits: ["dragEnd", "change"],
          template: "<button data-slider @click=\"$emit('dragEnd', 18000)\" />",
        },
        ...Object.fromEntries(
          [
            "ChevronDown",
            "ChevronUp",
            "Ellipsis",
            "Star",
            "Music2",
            "Shuffle",
            "LoaderCircle",
            "Repeat1",
            "Repeat2",
            "Volume2",
            "MessageSquareQuote",
            "Disc3",
            "ListMusic",
          ].map((name) => [`IconLucide${name}`, true]),
        ),
        ...Object.fromEntries(
          ["FastRewindRounded", "PauseRounded", "PlayArrowRounded", "FastForwardRounded"].map(
            (name) => [`IconMaterialSymbols${name}`, true],
          ),
        ),
      },
    },
  });
  wrappers.push(wrapper);
  return wrapper;
};
beforeEach(() => {
  mocks.status = reactive({
    isPlayerExpanded: true,
    isPlaying: false,
    position: 25000,
    duration: 200000,
    volume: 0.7,
    lyricOffsetMs: 500,
    shuffleMode: "off",
    repeatMode: "list",
  });
  mocks.media = reactive({
    track: {
      id: "one",
      title: "歌曲",
      source: "local",
      artists: [{ name: "歌手" }],
      cover: "small.jpg",
    },
    parsedLyric: [{}],
    lyricLoading: false,
  });
  visibility.value = "visible";
  wide.value = false;
  reduceMotion.value = false;
});
afterEach(() => {
  wrappers.splice(0).forEach((wrapper) => wrapper.unmount());
});

it("歌名同行显示平台标签，切换歌曲时更新云盘与平台来源", async () => {
  const wrapper = create();
  expect(wrapper.get("h1 .am-source").text()).toBe("LOCAL");
  mocks.media.track = { id: "two", title: "特别的人", source: "netease", artists: [] };
  await flushPromises();
  expect(wrapper.get("h1 .am-title").text()).toBe("特别的人");
  expect(wrapper.get("h1 .am-source").text()).toBe("NETEASE");
  mocks.media.track = {
    id: "three",
    title: "云盘歌曲",
    source: "netease",
    cloud: true,
    artists: [],
  };
  await flushPromises();
  expect(wrapper.get("h1 .am-source").text()).toBe("CLOUD");
});

it("三点菜单可打开播放器工具并调用桌面歌词", async () => {
  const toggleDesktopLyric = vi.fn().mockResolvedValue(undefined);
  vi.stubGlobal("api", undefined);
  Object.defineProperty(window, "api", {
    configurable: true,
    value: { window: { toggleDesktopLyric } },
  });
  const wrapper = create();
  for (const [key, name] of [
    ["am-equalizer", "EqualizerDialog"],
    ["am-speed", "SpeedDialog"],
    ["am-ab-loop", "AbLoopDialog"],
    ["am-auto-close", "AutoCloseDialog"],
    ["am-copy-lyrics", "CopyLyricsDialog"],
  ]) {
    wrapper.findComponent({ name: "SDropdownMenu" }).vm.$emit("select", key);
    await flushPromises();
    expect(wrapper.findComponent({ name }).exists(), name).toBe(true);
  }
  wrapper.findComponent({ name: "SDropdownMenu" }).vm.$emit("select", "am-desktop-lyric");
  await flushPromises();
  expect(toggleDesktopLyric).toHaveBeenCalledOnce();
  vi.unstubAllGlobals();
});

it("手机先显示封面，切换歌词始终使用 AMLL 并按当前进度对齐", async () => {
  const wrapper = create();
  expect(wrapper.find("[data-lyrics]").exists()).toBe(false);
  await wrapper.get('[aria-label="player.appleMusic.lyrics"]').trigger("click");
  await flushPromises();
  expect(wrapper.find("[data-lyrics]").exists()).toBe(true);
  expect(mocks.lyrics.setCurrentTime).toHaveBeenCalledWith(25500, true);
  expect(mocks.start).toHaveBeenCalled();
  expect(mocks.seek).not.toHaveBeenCalled();
  expect(mocks.play).not.toHaveBeenCalled();
});
it("手机沉浸歌词可展开和隐藏播放控制，横屏恢复完整控制", async () => {
  const wrapper = create();
  await wrapper.get('[aria-label="player.appleMusic.lyrics"]').trigger("click");
  expect(wrapper.get(".apple-music-player").classes()).toContain("am-immersive");
  expect(wrapper.get(".am-controls").attributes("style")).toContain("display: none");
  await wrapper.get('[aria-label="player.appleMusic.showControls"]').trigger("click");
  expect(wrapper.get(".apple-music-player").classes()).not.toContain("am-immersive");
  await wrapper.get('[aria-label="player.appleMusic.hideControls"]').trigger("click");
  wide.value = true;
  await flushPromises();
  expect(wrapper.get(".apple-music-player").classes()).not.toContain("am-immersive");
  expect(wrapper.find('[aria-label="player.appleMusic.showControls"]').exists()).toBe(false);
});
it("宽屏初始显示歌词，切换待播列表会停止歌词时钟", async () => {
  wide.value = true;
  const wrapper = create();
  await flushPromises();
  expect(wrapper.find("[data-lyrics]").exists()).toBe(true);
  mocks.stop.mockClear();
  await wrapper.get('[aria-label="player.appleMusic.queue"]').trigger("click");
  expect(wrapper.find("[data-queue]").exists()).toBe(true);
  expect(wrapper.find("[data-lyrics]").exists()).toBe(false);
  expect(mocks.stop).toHaveBeenCalled();
});
it("顶部横条是唯一的收起按钮，点击只收起界面而不中断播放", async () => {
  const wrapper = create();
  const handle = wrapper.get("button.am-handle");
  expect(handle.attributes("aria-label")).toBe("player.appleMusic.close");
  expect(wrapper.findAll('[aria-label="player.appleMusic.close"]')).toHaveLength(1);
  expect(handle.find("span[aria-hidden='true']").exists()).toBe(true);
  expect(handle.find("svg").exists()).toBe(false);
  await handle.trigger("click");
  expect(mocks.status.isPlayerExpanded).toBe(false);
  expect(mocks.toggle).not.toHaveBeenCalled();
});
it("顶部整行下拉跟手并关闭，不改变播放状态", async () => {
  const wrapper = create();
  const header = wrapper.get(".am-header");
  Object.defineProperty(header.element, "setPointerCapture", { value: vi.fn() });
  const pointer = { pointerId: 1, isPrimary: true, button: 0, clientX: 20 };
  await header.trigger("pointerdown", { ...pointer, clientY: 4 });
  await header.trigger("pointermove", { ...pointer, clientY: 104 });
  expect(wrapper.get(".apple-music-player").attributes("style")).toContain("100px");
  await header.trigger("pointerup", { ...pointer, clientY: 104 });
  expect(mocks.status.isPlayerExpanded).toBe(false);
  expect(mocks.toggle).not.toHaveBeenCalled();
});
it("短拖回弹并阻止误点击，横滑和歌词区域下滑不关闭", async () => {
  const wrapper = create();
  const header = wrapper.get(".am-header");
  Object.defineProperty(header.element, "setPointerCapture", { value: vi.fn() });
  const pointer = { pointerId: 1, isPrimary: true, button: 0, clientX: 20, clientY: 0 };
  await header.trigger("pointerdown", pointer);
  await header.trigger("pointermove", { ...pointer, clientY: 15 });
  await header.trigger("pointerup", { ...pointer, clientY: 15 });
  await wrapper.get(".am-handle").trigger("click", { detail: 1 });
  expect(mocks.status.isPlayerExpanded).toBe(true);
  expect(wrapper.get(".apple-music-player").attributes("style")).toContain("0px");
  await header.trigger("pointerdown", pointer);
  await header.trigger("pointermove", { ...pointer, clientX: 150, clientY: 10 });
  await header.trigger("pointerup", { ...pointer, clientY: 150 });
  expect(mocks.status.isPlayerExpanded).toBe(true);
  await wrapper.get(".am-body").trigger("pointerdown", pointer);
  await wrapper.get(".am-body").trigger("pointermove", { ...pointer, clientY: 150 });
  await wrapper.get(".am-body").trigger("pointerup", { ...pointer, clientY: 150 });
  expect(mocks.status.isPlayerExpanded).toBe(true);
});
it("系统取消下拉手势时回弹", async () => {
  const wrapper = create();
  const header = wrapper.get(".am-header");
  Object.defineProperty(header.element, "setPointerCapture", { value: vi.fn() });
  const pointer = { pointerId: 1, isPrimary: true, button: 0, clientX: 20, clientY: 0 };
  await header.trigger("pointerdown", pointer);
  await header.trigger("pointermove", { ...pointer, clientY: 100 });
  await header.trigger("pointercancel", pointer);
  expect(mocks.status.isPlayerExpanded).toBe(true);
  expect(wrapper.get(".apple-music-player").classes()).not.toContain("am-dragging");
});
it("歌词点击跳转并恢复播放，进度条不另起播放", async () => {
  wide.value = true;
  const wrapper = create();
  await wrapper.get("[data-lyrics]").trigger("click");
  await flushPromises();
  expect(mocks.seek).toHaveBeenLastCalledWith(42000);
  expect(mocks.play).toHaveBeenCalledTimes(1);
  await wrapper.get('[aria-label="player.appleMusic.progress"]').trigger("click");
  await flushPromises();
  expect(mocks.seek).toHaveBeenLastCalledWith(18000);
  expect(mocks.play).toHaveBeenCalledTimes(1);
});
it("播放按钮复用既有播放服务", async () => {
  const wrapper = create();
  await wrapper.get('[aria-label="player.appleMusic.play"]').trigger("click");
  await wrapper.get('[aria-label="player.prev"]').trigger("click");
  await wrapper.get('[aria-label="player.next"]').trigger("click");
  expect(mocks.toggle).toHaveBeenCalledTimes(1);
  expect(mocks.previous).toHaveBeenCalledTimes(1);
  expect(mocks.next).toHaveBeenCalledTimes(1);
});
it("后台停止背景和歌词，回前台按原进度恢复", async () => {
  wide.value = true;
  const wrapper = create();
  await flushPromises();
  visibility.value = "hidden";
  await flushPromises();
  expect(wrapper.findComponent({ name: "BackgroundRender" }).props("active")).toBe(false);
  expect(wrapper.find("[data-lyrics]").exists()).toBe(false);
  expect(mocks.stop).toHaveBeenCalled();
  visibility.value = "visible";
  await flushPromises();
  expect(mocks.lyrics.setCurrentTime).toHaveBeenLastCalledWith(25500, true);
  expect(wrapper.find("[data-lyrics]").exists()).toBe(true);
});
it("减少动态效果时背景静止，收起后释放背景组件", async () => {
  reduceMotion.value = true;
  mocks.status.isPlaying = true;
  const wrapper = create();
  expect(wrapper.findComponent({ name: "BackgroundRender" }).props("reducedMotion")).toBe(true);
  await wrapper.get('[aria-label="player.appleMusic.close"]').trigger("click");
  await flushPromises();
  expect(mocks.status.isPlayerExpanded).toBe(false);
  expect(mocks.stop).toHaveBeenCalled();
});
