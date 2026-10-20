import { readFile, writeFile, copyFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve, dirname } from "node:path";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const source = resolve(root, "src-tauri/plugins/native-audio/ios/Sources");
const target = resolve(root, "src-tauri/ios-native/Sources/SPlayerNativeUI");
// 构建时复用同一份已验证运行时，避免原生 UI 维护另一套网络与加密宿主。
const runtime = await readFile(resolve(source, "SiriRuntime.swift"), "utf8");
await writeFile(
  resolve(target, "GeneratedSiriRuntime.swift"),
  "// 由 prepare-services.mjs 生成，请修改共享 SiriRuntime.swift\n" + runtime,
);
await copyFile(
  resolve(source, "Resources/siri-bootstrap.js"),
  resolve(target, "Resources/siri-bootstrap.js"),
);

// 运行时许可证随应用分发，源文件仍以 vendor/LICENSE 为准
await copyFile(
  resolve(target, "../CQuickJS/vendor/LICENSE"),
  resolve(target, "Resources/QuickJS-LICENSE.txt"),
);
await copyFile(resolve(root, "LICENSE"), resolve(target, "Resources/SPlayer-LICENSE.txt"));
