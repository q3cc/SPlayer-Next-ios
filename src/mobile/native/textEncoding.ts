import { Buffer } from "buffer";

/** JavaScriptCore 无浏览器 TextEncoder，原生宿主补齐标准 UTF-8 编码契约 */
export class NativeTextEncoder implements TextEncoder {
  readonly encoding = "utf-8";

  /**
   * 使用项目已有 Buffer 实现编码，包含孤立代理项的替换语义
   * @param input - 待编码文本
   * @returns UTF-8 字节
   */
  encode(input = ""): Uint8Array<ArrayBuffer> {
    return new Uint8Array(Buffer.from(input, "utf8"));
  }

  /**
   * 有界写入，不把多字节字符截断在目标缓冲区末尾
   * @param source - 待编码文本
   * @param destination - 调用方提供的缓冲区
   * @returns 已读取 UTF-16 码元数与已写入字节数
   */
  encodeInto(source: string, destination: Uint8Array): TextEncoderEncodeIntoResult {
    let read = 0;
    let written = 0;
    for (const character of source) {
      const bytes = this.encode(character);
      if (written + bytes.length > destination.length) break;
      destination.set(bytes, written);
      read += character.length;
      written += bytes.length;
    }
    return { read, written };
  }
}

globalThis.TextEncoder ??= NativeTextEncoder;
