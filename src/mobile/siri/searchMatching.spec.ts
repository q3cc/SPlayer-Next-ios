import { describe, expect, it } from "vitest";
import type { Track } from "@shared/types/player";
import { rankSiriTracks } from "./searchMatching";

const track = (id: string, title: string, artist: string): Track => ({
  id,
  title,
  artists: [{ name: artist }],
  source: "netease",
  duration: 180000,
});
const original = track("original", "特别的人", "方大同");
const misleading = track("wrong", "方大同_特别的人", "其他歌手");

describe("Siri 歌名和歌手匹配", () => {
  it("‘歌手的歌’按歌手搜索，不把‘歌’当成歌名", () => {
    expect(rankSiriTracks([misleading, original], "方大同的歌", "")).toEqual([original]);
  });
  it("歌手的歌名保留歌名中后续的‘的’，并排除标题冒充歌手的结果", () => {
    expect(rankSiriTracks([misleading, original], "方大同的特别的人", "")).toEqual([original]);
  });
  it("Siri 已拆分歌手时按真实歌手字段过滤，不使用歌手子串", () => {
    expect(
      rankSiriTracks(
        [misleading, track("tribute", "特别的人", "方大同歌迷"), original],
        "特别的人",
        "方大同",
      ),
    ).toEqual([original]);
  });
  it("无匹配歌手时不退回翻唱或未知歌手", () => {
    expect(
      rankSiriTracks([misleading, track("unknown", "特别的人", "")], "特别的人", "方大同"),
    ).toEqual([]);
  });
  it("精确歌名排在现场版和标题包含匹配前面", () => {
    const live = track("live", "特别的人（Live）", "方大同");
    const partial = track("partial", "特别的人串烧", "方大同");
    expect(rankSiriTracks([partial, live, original], "特别的人", "方大同")).toEqual([
      original,
      live,
      partial,
    ]);
    expect(rankSiriTracks([original, live], "特别的人（Live）", "方大同")).toEqual([live]);
  });
  it("没有歌手依据时不误拆本身含‘的’的歌名", () => {
    const song = track("sky", "我的天空", "南征北战");
    expect(rankSiriTracks([song], "我的天空", "")).toEqual([song]);
  });
  it("允许多歌手歌曲中的准确匹配，并支持只按歌手搜索", () => {
    const duet = { ...original, artists: [{ name: "另一位" }, { name: "方大同" }] };
    expect(rankSiriTracks([misleading, duet], "", "方大同")).toEqual([duet]);
  });
});
