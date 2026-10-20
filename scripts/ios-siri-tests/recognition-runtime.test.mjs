import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import vm from "node:vm";
import assert from "node:assert/strict";
import { GenerateFP } from "../../resources/afp/afp.mjs";
import { WASM_BINARY } from "../../resources/afp/afp.wasm.mjs";

const source = readFileSync("src-tauri/ios-recognition/afp-runtime.js", "utf8");
const hash = createHash("sha256")
  .update(WASM_BINARY)
  .update(readFileSync("resources/afp/afp.mjs", "utf8"))
  .digest("hex");
assert.ok(source.includes(hash));
const context = vm.createContext({ console });
vm.runInContext(source, context);
for (const seconds of [8, 12, 12]) {
  const pcm = Float32Array.from(
    { length: seconds * 8000 },
    (_, i) => 0.2 * Math.sin((2 * Math.PI * (440 + 60 * Math.sin(i / 8000)) * i) / 8000),
  );
  context.pcm = pcm;
  const actual = Buffer.from(vm.runInContext("recognitionFingerprint(pcm)", context)).toString(
    "base64",
  );
  assert.equal(actual, await GenerateFP(pcm));
}
console.log("PASS: 后台纯 JS 与原始 WASM 指纹逐字节一致，可重复运行");
