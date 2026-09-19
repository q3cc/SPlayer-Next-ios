import { beforeEach, describe, expect, it, vi } from "vitest";
import { parseLRC } from "lyric-kit";
import { useProgressLyric } from "./useProgressLyric";

const mocks = vi.hoisted(() => ({
  settings: { player: { snapToLyric: true, showProgressLyric: true } },
  status: { lyricOffsetMs: 0 },
  media: { parsedLyric: [] as ReturnType<typeof parseLRC>["lines"] },
}));
vi.mock("@/stores/settings", () => ({ useSettingsStore: () => mocks.settings }));
vi.mock("@/stores/status", () => ({ useStatusStore: () => mocks.status }));
vi.mock("@/stores/media", () => ({ useMediaStore: () => mocks.media }));

beforeEach(() => {
  mocks.settings.player.snapToLyric = true;
  mocks.settings.player.showProgressLyric = true;
  mocks.status.lyricOffsetMs = 0;
  mocks.media.parsedLyric = parseLRC("[00:10.00]第一句\n[00:30.00]第二句\n[00:50.00]第三句").lines;
});

describe("进度条歌词使用同一时间基准", () => {
  it.each([0, 3500, -3500])("偏移 %s 时，吸附后仍落在同一句音频位置", (offset) => {
    mocks.status.lyricOffsetMs = offset;
    const { snapToNearestLyric, formatTooltip } = useProgressLyric();
    expect(snapToNearestLyric(29000 - offset)).toBe(30000 - offset);
    expect(snapToNearestLyric(33000 - offset)).toBe(30000 - offset);
    expect(formatTooltip(33000 - offset)).toContain("第二句");
  });

  it("关闭吸附不改变音频时间", () => {
    mocks.settings.player.snapToLyric = false;
    mocks.status.lyricOffsetMs = 3500;
    expect(useProgressLyric().snapToNearestLyric(29000)).toBe(29000);
  });

  it("没有歌词时保留原进度", () => {
    mocks.media.parsedLyric = [];
    expect(useProgressLyric().snapToNearestLyric(29000)).toBe(29000);
  });

  it("歌词提前超过开头时不返回负时间", () => {
    mocks.status.lyricOffsetMs = 11000;
    expect(useProgressLyric().snapToNearestLyric(0)).toBe(0);
  });
});
