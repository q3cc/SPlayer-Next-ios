import type { PluginSearchArgs, PluginSearchResult } from "@shared/types/plugin";
import { PluginErrorCodes } from "@shared/defaults/plugin-api";
import { pluginRegistry } from "./registry";
import { callMusicSearch } from "./router";

import { pluginSearchSchema, normalizePluginSearch } from "@shared/utils/pluginSearch";

/**
 * 搜索独立插件来源并转换为可持久化的曲目
 * @param args - 插件、来源、关键词与分页参数
 * @returns 曲目列表及分页信息
 */
export const searchPluginTracks = async (args: PluginSearchArgs): Promise<PluginSearchResult> => {
  const { pluginId, source, keyword, page, limit } = pluginSearchSchema.parse(args);
  const rt = pluginRegistry.getRuntime(pluginId);
  if (!rt?.enabled || rt.status.state !== "ready" || rt.hostSession?.signal.aborted) {
    throw Object.assign(new Error("Plugin source is not ready"), {
      code: PluginErrorCodes.NOT_READY,
    });
  }
  const capability = rt.status.sources[source];
  if (!capability?.actions.includes("musicSearch")) {
    throw Object.assign(new Error("Plugin source does not support searchable tracks"), {
      code: PluginErrorCodes.ACTION_UNSUPPORTED,
    });
  }
  const hostSession = rt.hostSession;
  const result = await callMusicSearch(rt, { source, keyword, page, limit });
  if (
    pluginRegistry.getRuntime(pluginId) !== rt ||
    rt.hostSession !== hostSession ||
    hostSession?.signal.aborted ||
    !rt.enabled ||
    rt.status.state !== "ready" ||
    !rt.status.sources[source]?.actions.includes("musicSearch")
  ) {
    throw Object.assign(new Error("Plugin search was cancelled"), {
      code: PluginErrorCodes.CANCELLED,
    });
  }
  return normalizePluginSearch({ pluginId, source, keyword, page, limit }, result);
};
