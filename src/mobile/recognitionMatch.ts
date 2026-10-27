import type { RecognitionCandidate } from "@shared/types/recognition";
import { mobileProviders } from "./providers";

/**
 * 用 AFP 指纹匹配 NCM 曲库
 * @param fingerprint - Base64 编码的音频指纹
 * @param duration - 采样时长（秒）
 * @returns 最多三个候选歌曲
 */
export const matchFingerprint = async (
  fingerprint: string,
  duration: number,
): Promise<RecognitionCandidate[]> => {
  const response = await mobileProviders.call("netease", "audio_match", {
    audioFP: fingerprint,
    duration,
  });
  const body = response.body as {
    code?: number;
    data?: {
      result?: Array<{
        startTime?: number;
        song?: {
          id: number;
          name: string;
          artists: { name: string }[];
          album?: { name: string; picUrl?: string };
        };
      }>;
    };
  };
  if (!response.ok || body?.code !== 200) throw new Error("识曲服务请求失败");
  return (body.data?.result ?? [])
    .filter((item) => item.song)
    .slice(0, 3)
    .map(({ song, startTime }) => ({
      songId: String(song!.id),
      title: song!.name,
      artists: song!.artists.map((artist) => artist.name),
      album: song!.album?.name,
      cover: song!.album?.picUrl,
      startTime,
    }));
};
