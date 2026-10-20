import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { WASM_BINARY } from "../resources/afp/afp.wasm.mjs";

const directory = process.env.AFP_BUILD_DIR;
const compiler = process.env.WASM2JS;
if (!directory || !compiler)
  throw new Error("请指定 AFP_BUILD_DIR 和 Binaryen 123.0.0 的 WASM2JS 路径");
writeFileSync(`${directory}/afp.wasm`, Buffer.from(WASM_BINARY, "base64"));
execFileSync(process.execPath, [
  compiler,
  `${directory}/afp.wasm`,
  "--emscripten",
  "-O2",
  "-o",
  `${directory}/afp.js`,
]);
const original = readFileSync("resources/afp/afp.mjs", "utf8");
const glue = original
  .slice(0, original.indexOf("// XXX: With PythonMonkey"))
  .replace('import { WASM_BINARY } from "./afp.wasm.mjs";', 'const WASM_BINARY = "";')
  .replace(
    "o = void 0 !== o ? o : {},",
    "o = { instantiateWasm: function(imports, ready) { var exports = instantiate(imports); ready({exports: exports}); return exports; } },",
  );
if (!glue.includes("ready({exports: exports})"))
  throw new Error("AFP 胶水结构变化，需重新检查转换器");
const hash = createHash("sha256").update(WASM_BINARY).update(original).digest("hex");
writeFileSync(
  "src-tauri/ios-recognition/afp-runtime.js",
  `// 自动生成；Binaryen 123.0.0；AFP 源摘要 ${hash}\nvar WebAssembly = { RuntimeError: Error };\n${readFileSync(`${directory}/afp.js`, "utf8")}\n${glue}\nvar runtime = AudioFingerprintRuntime();\nfunction recognitionFingerprint(pcm) {\n var vector = runtime.ExtractQueryFP(Float32Array.from(pcm).buffer);\n try { var bytes = []; for (var i=0;i<vector.size();i++) bytes.push(vector.get(i)); return bytes; }\n finally { vector.delete(); }\n}\n`,
);
