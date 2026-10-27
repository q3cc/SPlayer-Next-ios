/** 从锁定的 AMLL 版本提取原始网格和图像算法，供原生 Metal 渲染器使用 */
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const root = path.resolve("node_modules/@applemusic-like-lyrics/core");
const actual = fs.realpathSync(root);
const upstream = fs.readFileSync(path.join(root, "dist/amll-core.mjs"), "utf8");
const resources = "src-tauri/ios-native/Sources/SPlayerNativeUI/Resources";
const { build } = require(
  require.resolve("esbuild", { paths: [path.dirname(require.resolve("vite/package.json"))] }),
);
const version = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8")).version;
if (version !== "0.5.2")
  throw new Error(`AMLL ${version} 尚未验证 Metal 着色器兼容性，请先核对上游算法`);
for (const marker of ["function blurImage(", "var Mesh = class", "var GLTexture = class"]) {
  if (!upstream.includes(marker)) throw new Error(`AMLL 源码缺少 ${marker}`);
}
const source =
  `import { Mat4, Vec2, Vec3, Vec4 } from ${JSON.stringify(require.resolve("gl-matrix", { paths: [actual] }))};\n` +
  upstream.slice(upstream.indexOf("function blurImage("), upstream.indexOf("//#region \\0raw:")) +
  upstream.slice(upstream.indexOf("var Mesh = class"), upstream.indexOf("var GLTexture = class")) +
  `\n/** 仅收集原算法的顶点缓冲，不创建浏览器或 WebGL 上下文 */
export function mesh(presetIndex = -1) {
 const gl = { ARRAY_BUFFER:1, ELEMENT_ARRAY_BUFFER:2, createBuffer:()=>({}), bindBuffer:()=>{}, bufferData:()=>{}, vertexAttribPointer:()=>{}, enableVertexAttribArray:()=>{} };
 const mesh = new BHPMesh(gl, 0, 1, 2);
 mesh.resetSubdivition(50);
 const preset = presetIndex >= 0 ? CONTROL_POINT_PRESETS[presetIndex] : Math.random() > .8 ? generateControlPoints(6,6) : CONTROL_POINT_PRESETS[Math.floor(Math.random()*CONTROL_POINT_PRESETS.length)];
 mesh.resizeControlPoints(preset.width,preset.height);
 for(const cp of preset.conf) {const p=mesh.getControlPoint(cp.cx,cp.cy); p.location.x=cp.x;p.location.y=cp.y;p.uRot=cp.ur*Math.PI/180;p.vRot=cp.vr*Math.PI/180;p.uScale=2/(preset.width-1)*cp.up;p.vScale=2/(preset.height-1)*cp.vp;}
 mesh.updateMesh();
 return {vertices:Array.from(mesh.vertexData),indices:Array.from(mesh.indexData)};
}
/** 原版 32px 图像调色与四轮半径 2 的模糊 */
export function texture(bytes) {
 const pixels = new Uint8ClampedArray(bytes);
 for(let i=0;i<pixels.length;i+=4) {
 let r=(pixels[i]-128)*.4+128,g=(pixels[i+1]-128)*.4+128,b=(pixels[i+2]-128)*.4+128;
 const gray=r*.3+g*.59+b*.11;
 pixels[i]=((gray*-2+r*3-128)*1.7+128)*.75;
 pixels[i+1]=((gray*-2+g*3-128)*1.7+128)*.75;
 pixels[i+2]=((gray*-2+b*3-128)*1.7+128)*.75;
 }
 blurImage({data:pixels,width:32,height:32},2,4);
 return Array.from(pixels);
}`;
await build({
  stdin: { contents: source, resolveDir: process.cwd(), loader: "js" },
  bundle: true,
  format: "iife",
  globalName: "NativeAMLL",
  platform: "neutral",
  target: "es2020",
  outfile: path.join(resources, "AMLLMesh.js"),
  banner: {
    js: "// Generated from @applemusic-like-lyrics/core 0.5.2; AGPL-3.0-only; see AMLL-LICENSE.txt",
  },
});
fs.copyFileSync(path.join(root, "LICENSE"), path.join(resources, "AMLL-LICENSE.txt"));

// 直接复用 Next 的 HCT 代表色评分，不用平均色替代。
const colorSource = fs.readFileSync("src/utils/color.ts", "utf8");
const helpers = colorSource.slice(
  colorSource.indexOf("const COVER_SAMPLE_SIZE"),
  colorSource.indexOf("/** 将 HEX 字符串"),
);
const algorithm = colorSource.slice(
  colorSource.indexOf("  // RGBA → ARGB int"),
  colorSource.indexOf("  // 释放 canvas GPU 资源"),
);
await build({
  stdin: {
    contents: `import { Hct, QuantizerCelebi, argbFromHex } from "@material/material-color-utilities";
${helpers}
export function colors(data: number[]) {
${algorithm}
const base=toCoverBaseColor(picked); return {base,foreground:toCoverUiColor(base)};
}`,
    resolveDir: process.cwd(),
    loader: "ts",
  },
  bundle: true,
  format: "iife",
  globalName: "NativeCoverColors",
  platform: "neutral",
  target: "es2020",
  outfile: path.join(resources, "NextCoverColors.js"),
});

fs.copyFileSync(
  "src-tauri/vendor/AudioStreaming/LICENSE",
  path.join(resources, "AudioStreaming-LICENSE.txt"),
);
fs.copyFileSync(
  "node_modules/@material/material-color-utilities/LICENSE",
  path.join(resources, "MaterialColors-LICENSE.txt"),
);
fs.copyFileSync(
  path.join(fs.realpathSync(path.resolve(actual, "..", "..", "gl-matrix")), "LICENSE.md"),
  path.join(resources, "GLMatrix-LICENSE.txt"),
);
