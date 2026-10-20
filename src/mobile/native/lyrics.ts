import { parseLyric, type LyricInput } from "lyric-kit";
import type { Track } from "@shared/types/player";
import { mobileProviders } from "../providers";

/**
 * 使用共享平台接口读取歌词，只向 Swift 返回当前歌曲的时间轴，不写入登录存储
 * @param track - 当前平台曲目，QQ 使用数字 extId，酷狗时长在接口边界转秒
 * @returns 原生歌词行与真实逐字毫秒时间戳
 */
export async function loadNativeLyrics(track?: Track) {
  if (!track || !["netease", "qqmusic", "kugou"].includes(track.source)) return { lines: [] };
  let input: LyricInput;
  if (track.source === "netease") {
    const result = await mobileProviders.call("netease", "lyric_new", { id: track.id });
    if (!result.ok) throw new Error(result.error);
    const body = result.body as {
      yrc?: { lyric?: string };
      lrc?: { lyric?: string };
      ytlrc?: { lyric?: string };
      tlyric?: { lyric?: string };
    };
    input = {
      content: body.yrc?.lyric?.trim() || body.lrc?.lyric || "",
      format: body.yrc?.lyric?.trim() ? "yrc" : "lrc",
      translation: body.ytlrc?.lyric || body.tlyric?.lyric,
      translationFormat: "lrc",
    };
  } else {
    const source = track.source as "qqmusic" | "kugou";
    const args =
      source === "qqmusic"
        ? { id: track.extId ?? track.id }
        : { hash: track.id, name: track.title, duration: Math.round(track.duration / 1000) };
    const result = await mobileProviders.call(source, "lyric", args);
    if (!result.ok) throw new Error(result.error);
    const body = result.body as { qrc?: string; krc?: string; lrc?: string; trans?: string };
    const timed = source === "qqmusic" ? body.qrc?.trim() : body.krc?.trim();
    input = {
      content: timed || body.lrc || "",
      format: timed ? (source === "qqmusic" ? "qrc" : "krc") : "lrc",
      translation: body.trans,
      translationFormat: "lrc",
    };
  }
  if (input.content.length + (input.translation?.length ?? 0) > 2_000_000)
    throw new Error("歌词超过大小限制");
  const parsed = parseLyric(input);
  return {
    lines: parsed.lines.map((line, id) => ({
      id,
      timeMs: line.startTime,
      endMs: line.endTime,
      text: line.words.map((word) => word.word).join(""),
      translation: line.translatedLyric,
      words: line.words.map((word) => ({
        text: word.word,
        startMs: word.startTime,
        endMs: word.endTime,
      })),
    })),
  };
}
