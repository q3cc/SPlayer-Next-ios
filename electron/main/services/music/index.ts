import { z } from "zod/v4";
import { searchTracks } from "@main/database";
import type { Track } from "@shared/types/player";
import type { OnlineSearchOptions, OnlineSearchResult } from "@shared/types/music";
import { searchOnlineTracks } from "./onlineSearch";

import { onlineSearchSchema } from "@shared/utils/musicValidation";
export { trackSchema, queueQuerySchema, onlineSearchSchema } from "@shared/utils/musicValidation";

/**
 * 插件与 MCP 共用的在线搜索入口
 * @param options - 平台与分页搜索参数
 * @returns 统一歌曲列表
 */
export const searchOnline = (options: OnlineSearchOptions): Promise<OnlineSearchResult> => {
  const { platform, query, page, limit } = onlineSearchSchema.parse(options);
  return searchOnlineTracks(platform, query, page, limit);
};

/**
 * 搜索本地曲库，返回完整 Track
 * @param query - 关键词
 * @param limit - 返回上限
 * @returns 搜索总数与轻量曲目
 */
export const searchLibrary = (query: string, limit = 20): { total: number; tracks: Track[] } => {
  const input = z
    .strictObject({
      query: z.string().trim().min(1).max(200),
      limit: z.number().int().min(1).max(100),
    })
    .parse({ query, limit });
  const matches = searchTracks(input.query);
  const tracks = matches.slice(0, input.limit);
  return { total: matches.length, tracks };
};
