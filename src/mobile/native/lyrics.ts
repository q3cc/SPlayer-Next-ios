import {
  applyLyricLanguages,
  parseLyric,
  toEnhancedLRC,
  toLRC,
  toTTML,
  type LyricInput,
} from "lyric-kit";
import type { Track } from "@shared/types/player";
import { mobileProviders } from "../providers";

/**
 * 使用共享平台接口读取歌词，只向 Swift 返回当前歌曲的时间轴，不写入登录存储
 * @param track - 当前平台曲目，QQ 使用数字 extId，酷狗时长在接口边界转秒
 * @returns 原生歌词行与真实逐字毫秒时间戳
 */
export async function loadNativeLyrics(track?: Track) {
  const input = await loadLyricInput(track);
  return input ? parseNativeLyrics(input) : { raw: "", lines: [] };
}

/**
 * 读取平台歌词原始输入，播放与下载共用同一来源
 * @param track - 当前平台曲目
 * @returns 歌词输入；非在线平台曲目返回 undefined
 */
async function loadLyricInput(track?: Track): Promise<LyricInput | undefined> {
  if (!track || !["netease", "qqmusic", "kugou"].includes(track.source)) return undefined;
  let input: LyricInput;
  if (track.source === "netease") {
    const result = await mobileProviders.call("netease", "lyric_new", { id: track.id });
    if (!result.ok) throw new Error(result.error);
    const body = result.body as {
      yrc?: { lyric?: string };
      lrc?: { lyric?: string };
      ytlrc?: { lyric?: string };
      tlyric?: { lyric?: string };
      romalrc?: { lyric?: string };
      yromalrc?: { lyric?: string };
    };
    input = {
      content: body.yrc?.lyric?.trim() || body.lrc?.lyric || "",
      format: body.yrc?.lyric?.trim() ? "yrc" : "lrc",
      translation: body.ytlrc?.lyric || body.tlyric?.lyric,
      translationFormat: "lrc",
      romaji: body.yromalrc?.lyric || body.romalrc?.lyric,
      romajiFormat: "lrc",
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
  if (
    input.content.length + (input.translation?.length ?? 0) + (input.romaji?.length ?? 0) >
    2_000_000
  )
    throw new Error("歌词超过大小限制");
  return input;
}

/**
 * 下载时导出歌词文件：TTML 单文件保留原文、翻译与音译，供应用内曲库再次解析
 * @param track - 下载的平台曲目
 * @param format - 额外保存的 LRC 格式，逐行或逐字增强
 * @returns 无歌词时为空字符串
 */
export async function exportNativeLyrics(track: Track, format: "lrc" | "enhanced-lrc") {
  const input = await loadLyricInput(track);
  if (!input?.content.trim()) return { ttml: "", lrc: "" };
  const lines = parseLyric(input).lines;
  if (!lines.length) return { ttml: "", lrc: "" };
  return { ttml: toTTML(lines), lrc: format === "lrc" ? toLRC(lines) : toEnhancedLRC(lines) };
}

/** 原生导入与在线歌词共用同一解析器和数据字段。 */
export function parseNativeLyrics(input: LyricInput) {
  if (input.content.length > 2_000_000) throw new Error("歌词超过大小限制");
  const parsed = parseLyric(input);
  // 与原版一致按行识别语言，原生端据此选择分语言歌词字体
  applyLyricLanguages(parsed.lines);
  return {
    raw: input.content,
    lines: parsed.lines.map((line, id) => ({
      id,
      timeMs: line.startTime,
      endMs: line.endTime,
      text: line.words.map((word) => word.word).join(""),
      translation: line.translatedLyric,
      romanization: line.romanLyric,
      isDuet: line.isDuet,
      isBackground: line.isBG,
      language: line.language,
      words: line.words.map((word) => ({
        text: word.word,
        romanization: word.romanWord,
        ruby: word.ruby?.map((span) => ({
          text: span.word,
          startMs: span.startTime,
          endMs: span.endTime,
        })),
        startMs: word.startTime,
        endMs: word.endTime,
      })),
    })),
  };
}
