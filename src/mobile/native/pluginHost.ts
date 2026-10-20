import { z } from "zod/v4";
import { mobileProviders } from "../providers";
import { searchSongs } from "@/apis/search";
import { trackSchema, queueQuerySchema, onlineSearchSchema } from "@shared/utils/musicValidation";
import { omitCredentials } from "@shared/utils/pluginSecurity";
import { normalizePluginSearch, pluginSearchSchema } from "@shared/utils/pluginSearch";
import type { ActionIO } from "@shared/types/plugin";

/** 在应用自有服务中校验插件输入，平台凭据不会进入插件解释器
 * @param method - 经原生权限检查的宿主方法
 * @param args - 待校验参数
 * @returns 无凭据的结果或已校验的原生操作参数
 */
export const dispatchNativePluginRequest = async (
  method: string,
  args: unknown[],
): Promise<unknown> => {
  switch (method) {
    case "api.call": {
      const platform = z.enum(["netease", "qqmusic", "kugou"]).parse(args[0]);
      const name = z.string().min(1).max(256).parse(args[1]);
      const params = z.record(z.string(), z.unknown()).parse(args[2] ?? {});
      for (const key of ["cookie", "domain", "proxy", "headers"]) {
        if (Object.hasOwn(params, key)) throw new Error(`Host API does not accept ${key}`);
      }
      return omitCredentials(await mobileProviders.call(platform, name, params));
    }
    case "music.searchOnline": {
      const { platform, query, page, limit } = onlineSearchSchema.parse(args[0]);
      const result = await searchSongs(platform, query, (page - 1) * limit, limit);
      return { platform, page, tracks: result.items, total: result.total, hasMore: result.hasMore };
    }
    case "normalizeSearch":
      return normalizePluginSearch(
        pluginSearchSchema.parse(args[0]),
        args[1] as ActionIO["musicSearch"]["res"],
      );
    case "player.playTrack":
      return [trackSchema.parse(args[0])];
    case "player.addToQueue":
      return [
        z.array(trackSchema).min(1).max(50).parse(args[0]),
        z.enum(["next", "end"]).parse(args[1] ?? "next"),
      ];
    case "player.getQueue":
      return [queueQuerySchema.parse(args[0] ?? {})];
    case "player.seek":
      return [z.number().finite().nonnegative().parse(args[0])];
    case "player.setVolume":
      return [z.number().min(0).max(1).parse(args[0])];
    case "player.setPlayMode":
      return [
        z
          .strictObject({
            repeat: z.enum(["list", "one"]).optional(),
            shuffle: z.enum(["on", "off"]).optional(),
          })
          .refine((value) => value.repeat || value.shuffle, "Empty play mode")
          .parse(args[0]),
      ];
    case "music.searchLibrary":
      return [
        z.string().trim().min(1).max(200).parse(args[0]),
        z
          .number()
          .int()
          .min(1)
          .max(100)
          .parse(args[1] ?? 20),
      ];
    case "notify":
      return [z.string().trim().min(1).max(1000).parse(args[0])];
    default:
      throw new Error("未知插件操作：" + method);
  }
};
