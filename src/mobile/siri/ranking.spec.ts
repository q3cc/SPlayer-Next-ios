import { expect, it } from "vitest";
import type { Track } from "@shared/types/player";
import { mergeSiriResults, siriSongKey } from "./ranking";
const song = (source: Track["source"], artist: string, title = "晴天", id = artist): Track => ({
  source,
  id,
  title,
  artists: [{ name: artist }],
  duration: 200000,
});

it("晴天按跨平台证据排序，VIP 翻唱不能压过两平台首位的周杰伦", () => {
  const pages = [
    [song("netease", "翻唱者")],
    [song("qqmusic", "周杰伦")],
    [song("kugou", "周杰伦")],
  ];
  const result = mergeSiriResults(pages, "晴天", "", "netease", ["netease"]);
  expect(result.tracks[0].artists[0].name).toBe("周杰伦");
  expect(result.needsConfirmation).toBe(false);
  const vipChanged = mergeSiriResults(pages, "晴天", "", "netease", ["kugou"]);
  expect(vipChanged.tracks[0].artists[0].name).toBe("周杰伦");
  expect(vipChanged.tracks[0].source).toBe("kugou");
});
it("同名不同歌手证据相同才询问，显式歌手消除歧义", () => {
  const pages = [[song("qqmusic", "甲")], [song("kugou", "乙")]];
  expect(mergeSiriResults(pages, "晴天", "", "netease").needsConfirmation).toBe(true);
  expect(mergeSiriResults(pages, "晴天", "乙", "netease").needsConfirmation).toBe(false);
});
it("同曲只保留一个选项，同平台重复不能刷高分", () => {
  const one = song("netease", "甲");
  const result = mergeSiriResults(
    [[one, { ...one, id: "duplicate" }], [song("qqmusic", "乙")]],
    "晴天",
    "",
    "netease",
  );
  expect(result.tracks).toHaveLength(2);
  expect(result.needsConfirmation).toBe(true);
});
it("现场、混音、伴奏保留独立版本，歌手次序不造成同曲重复", () => {
  const normal = song("qqmusic", "甲");
  expect(siriSongKey(normal)).not.toBe(siriSongKey(song("kugou", "甲", "晴天（Live）")));
  const duet = { ...normal, artists: [{ name: "甲" }, { name: "乙" }] };
  expect(siriSongKey(duet)).toBe(siriSongKey({ ...duet, artists: [...duet.artists].reverse() }));
});
