import { mount } from "@vue/test-utils";
import { describe, expect, it } from "vitest";
import DefaultLyrics from "./DefaultLyrics.vue";

describe("逐行歌词遮罩", () => {
  it("为没有逐字片段的歌词行设置 Android WebView 可识别的遮罩", () => {
    const wrapper = mount(DefaultLyrics, {
      props: {
        lyricLines: [
          {
            startTime: 0,
            endTime: 3000,
            words: [{ word: "第一句", startTime: 0, endTime: 3000 }],
            translatedLyric: "",
            romanLyric: "",
            isBG: false,
            isDuet: false,
          },
          {
            startTime: 3000,
            endTime: 6000,
            words: [{ word: "第二句", startTime: 3000, endTime: 6000 }],
            translatedLyric: "",
            romanLyric: "",
            isBG: false,
            isDuet: false,
          },
        ],
      },
      attachTo: document.body,
    });
    try {
      const lines = wrapper.findAll(".lp-main");
      expect(lines).toHaveLength(2);
      for (const line of lines) {
        expect(
          (line.element as HTMLElement).style.getPropertyValue("-webkit-mask-image"),
        ).toContain("var(--ba)");
      }
    } finally {
      wrapper.unmount();
    }
  });
});
