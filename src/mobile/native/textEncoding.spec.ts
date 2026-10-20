import { expect, it } from "vitest";
import { NativeTextEncoder } from "./textEncoding";
it("原生 UTF-8 编码保留中文与补充平面字符", () => {
  const encoder = new NativeTextEncoder();
  expect(encoder.encode("原生🎵")).toEqual(new TextEncoder().encode("原生🎵"));
  expect(encoder.encode("\ud800")).toEqual(new TextEncoder().encode("\ud800"));
});
it("encodeInto 不截断字符并按 UTF-16 返回读取长度", () => {
  const encoder = new NativeTextEncoder();
  const target = new Uint8Array(5);
  expect(encoder.encodeInto("🎵中文", target)).toEqual({ read: 2, written: 4 });
  expect(encoder.encodeInto("中文", new Uint8Array(2))).toEqual({ read: 0, written: 0 });
});
