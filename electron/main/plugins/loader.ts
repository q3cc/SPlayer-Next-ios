import fs from "node:fs";
import path from "node:path";
import { parsePluginScript } from "@shared/utils/pluginScript";
export { decompressIfNeeded, type LoadedScript } from "@shared/utils/pluginScript";

/** 读取本地脚本后使用各平台共用的元数据解析器。 */
export const loadScript = (rawOrPath: string, isPath: boolean, fileName?: string) =>
  parsePluginScript(
    isPath ? fs.readFileSync(rawOrPath, "utf-8") : rawOrPath,
    fileName ?? (isPath ? path.basename(rawOrPath) : undefined),
  );
