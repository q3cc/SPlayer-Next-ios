import { mount } from "@vue/test-utils";
import { reactive, ref } from "vue";
import { beforeEach, describe, expect, it, vi } from "vitest";
import FullPlayer from "./index.vue";

const mocks = vi.hoisted(() => ({
  status: {} as Record<string, unknown>,
  media: {} as Record<string, unknown>,
  settings: {} as Record<string, unknown>,
  seek: vi.fn(),
  toggle: vi.fn(),
}));

vi.mock("@vueuse/core", () => ({ useMediaQuery: () => ref(true) }));
vi.mock("vue-i18n", () => ({ useI18n: () => ({ t: (key: string) => key }) }));
vi.mock("@/utils/config", () => ({ isMobile: true }));
vi.mock("@/stores/status", () => ({ useStatusStore: () => mocks.status }));
vi.mock("@/stores/media", () => ({ useMediaStore: () => mocks.media }));
vi.mock("@/stores/settings", () => ({ useSettingsStore: () => mocks.settings }));
vi.mock("@/services/playback", () => ({ getCurrentTime: () => 30000 }));
vi.mock("@/composables/usePlaybackTime", () => ({
  usePlaybackTime: () => ({ start: vi.fn(), stop: vi.fn() }),
}));
vi.mock("@/composables/useImmersiveMode", () => ({
  useImmersiveMode: () => ({
    immersive: ref(false),
    onActivity: vi.fn(),
    onPointerDown: vi.fn(),
    onPointerUp: vi.fn(),
  }),
}));
vi.mock("@/composables/useWindowControls", () => ({
  useWindowControls: () => ({ isFullscreen: ref(false), toggleFullscreen: vi.fn() }),
}));
vi.mock("@/composables/useTimeFormat", () => ({
  useTimeFormat: () => ({ timeDisplay: ref(["0:30", "2:00"]), toggleTimeFormat: vi.fn() }),
}));
vi.mock("@/composables/useProgressLyric", () => ({
  useProgressLyric: () => ({ snapToNearestLyric: (value: number) => value }),
}));
vi.mock("@/composables/useFavorite", () => ({
  useFavorite: () => ({ isLiked: () => false, toggle: vi.fn() }),
}));
vi.mock("@/composables/useDownload", () => ({
  useDownload: () => ({ enqueue: vi.fn() }),
  buildDownloadQualityItems: () => [],
}));
vi.mock("@/composables/usePlaylistPicker", () => ({
  usePlaylistPicker: () => ({
    open: ref(false),
    tracks: ref([]),
    mode: ref("local"),
    openPicker: vi.fn(),
  }),
}));
vi.mock("@/core/player", () => ({
  isSeeking: () => false,
  seek: mocks.seek,
  togglePlay: mocks.toggle,
}));
vi.mock("./PlayerBackground.vue", () => ({ default: { template: "<div />" } }));
vi.mock("./PlayerCover.vue", () => ({ default: { template: "<div />" } }));
vi.mock("../Lyrics/index.vue", () => ({ default: { template: "<div />" } }));
vi.mock("../AirPlayControl.vue", () => ({ default: { template: "<div />" } }));
vi.mock("@/components/modals/PlaylistPickerDialog.vue", () => ({
  default: { template: "<div />" },
}));

const createPlayer = () =>
  mount(FullPlayer, {
    global: {
      stubs: {
        teleport: true,
        transition: false,
        SButton: {
          emits: ["click"],
          template: "<button @click=\"$emit('click')\"><slot name='icon' /></button>",
        },
        SSlider: true,
        PlayerBackground: true,
        PlayerCover: true,
        VolumeControl: true,
        PlayerData: true,
        LyricActions: true,
        QueuePanel: true,
        WindowControls: true,
        BottomSpectrum: true,
        SIconSwap: true,
        Toolbar: true,
        SDropdownMenu: true,
        ...Object.fromEntries(
          [
            "ChevronDown",
            "TextQuote",
            "Minimize",
            "Maximize",
            "MessageCircle",
            "HeartOff",
            "Shuffle",
            "SkipBack",
            "Pause",
            "Play",
            "SkipForward",
            "Infinity",
            "Repeat1",
            "Repeat",
          ].map((name) => [`IconLucide${name}`, true]),
        ),
        IconSpHeartMode: true,
        IconSpPlayOrder: true,
      },
    },
  });

beforeEach(() => {
  mocks.status = reactive({
    isPlayerExpanded: ref(true),
    isPlaying: ref(true),
    isLoading: ref(false),
    position: ref(30000),
    duration: ref(120000),
    repeatMode: ref("all"),
    shuffleMode: ref("off"),
    heartMode: ref(false),
    fmMode: ref(false),
    showLyric: ref(false),
    fullQueueOpen: false,
    currentTrack: { id: 1, source: "local", title: "测试歌曲" },
    trackLoading: false,
    lyricOffsetMs: 0,
  });
  mocks.media = reactive({
    track: mocks.status.currentTrack,
    parsedLyric: [],
    lyricLoading: false,
  });
  mocks.settings = reactive({
    player: {
      coverLayout: "default",
      coverLyricRatio: 0.5,
      autoCenterCover: false,
      enableSpectrum: false,
    },
    lyric: { adaptiveFontSize: false, fontSize: 28, fontWeight: 400, engine: "default" },
    system: { download: { enabled: false } },
  });
});

describe("传统全屏播放器触摸手势", () => {
  it("顶部下滑收起，其他区域滑动和鼠标拖动不触发收起", async () => {
    const wrapper = createPlayer();
    const header = wrapper.get(".full-player-header");
    Object.defineProperty(header.element, "setPointerCapture", { value: vi.fn() });
    const touch = { pointerId: 1, pointerType: "touch", isPrimary: true, button: 0, clientX: 20 };

    await header.trigger("pointerdown", { ...touch, pointerType: "mouse", clientY: 0 });
    await header.trigger("pointermove", { ...touch, pointerType: "mouse", clientY: 100 });
    await header.trigger("pointerup", { ...touch, pointerType: "mouse", clientY: 100 });
    expect(mocks.status.isPlayerExpanded).toBe(true);

    const main = wrapper.get(".mobile-full-player-main");
    await main.trigger("pointerdown", { ...touch, clientY: 0 });
    await main.trigger("pointermove", { ...touch, clientY: 100 });
    await main.trigger("pointerup", { ...touch, clientY: 100 });
    expect(mocks.status.isPlayerExpanded).toBe(true);

    await header.trigger("pointerdown", { ...touch, clientY: 0 });
    await header.trigger("pointermove", { ...touch, clientY: 100 });
    expect(wrapper.get(".full-player").attributes("style")).toContain("100px");
    await header.trigger("pointerup", { ...touch, clientY: 100 });
    expect(mocks.status.isPlayerExpanded).toBe(false);
    expect(mocks.toggle).not.toHaveBeenCalled();
    wrapper.unmount();
  });

  it("短距离下滑回弹，并阻止随后误触按钮", async () => {
    const wrapper = createPlayer();
    const header = wrapper.get(".full-player-header");
    Object.defineProperty(header.element, "setPointerCapture", { value: vi.fn() });
    const touch = { pointerId: 1, pointerType: "touch", isPrimary: true, button: 0, clientX: 20 };
    await header.trigger("pointerdown", { ...touch, clientY: 0 });
    await header.trigger("pointermove", { ...touch, clientY: 15 });
    await header.trigger("pointerup", { ...touch, clientY: 15 });
    expect(wrapper.get(".full-player").attributes("style")).toContain("0px");
    await header.get("button").trigger("click", { detail: 1 });
    expect(mocks.status.isPlayerExpanded).toBe(true);
    wrapper.unmount();
  });
});
