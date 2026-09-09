import { expect, it } from "vitest";
import { playbackDuration } from "@shared/utils/playbackDuration";

it.each(["qqmusic", "kugou"])("%s 试听使用实际 30 秒，不使用曲库四分钟", () => {
  expect(playbackDuration(30000, 240000)).toBe(30000);
});
it.each([0, undefined, NaN, Infinity])("音源时长 %s 未就绪时使用曲库兜底", (duration) => {
  expect(playbackDuration(duration, 240000)).toBe(240000);
});
it("完整版按实际时长展示，不把所有歌曲限制到试听时长", () => {
  expect(playbackDuration(246000, 240000)).toBe(246000);
});
