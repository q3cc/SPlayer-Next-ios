import { shallowMount } from "@vue/test-utils";
import { beforeEach, describe, expect, it, vi } from "vitest";
import Lyrics from "./index.vue";

const mocks = vi.hoisted(() => ({
  settings: { lyric: { engine: "default" } },
  status: { lyricOffsetMs: 0 },
}));
vi.mock("@/stores/settings", () => ({ useSettingsStore: () => mocks.settings }));
vi.mock("@/stores/status", () => ({ useStatusStore: () => mocks.status }));
vi.mock("./DefaultLyrics.vue", () => ({ default: { name: "DefaultLyrics", template: "<div />" } }));
vi.mock("./AMLLLyrics.vue", () => ({ default: { name: "AMLLLyrics", template: "<div />" } }));
vi.mock("./LyricCredit.vue", () => ({ default: { template: "<div />" } }));

beforeEach(() => {
  mocks.status.lyricOffsetMs = 0;
});

describe.each(["default", "amll"])("%s 歌词点击时间", (engine) => {
  it.each([0, 3500, -3500, 50000])("减去歌词偏移 %s 后才作为音频跳转时间", (offset) => {
    mocks.settings.lyric.engine = engine;
    mocks.status.lyricOffsetMs = offset;
    const wrapper = shallowMount(Lyrics, { props: { lyricLines: [] } });
    const child = wrapper.findComponent({
      name: engine === "amll" ? "AMLLLyrics" : "DefaultLyrics",
    });
    child.vm.$emit("seek", 42000);
    expect(wrapper.emitted("seek")).toEqual([[Math.max(0, 42000 - offset)]]);
    wrapper.unmount();
  });
});
