import { createCipheriv, createDecipheriv } from "browserify-aes/browser";
import createHash from "create-hash/browser";
import createHmac from "create-hmac/browser";
import publicEncrypt from "public-encrypt/publicEncrypt";
import randomBytes from "randombytes/browser";

// 只导出音乐平台使用的算法，避免完整 crypto-browserify 引入签名、DH 和另一套椭圆曲线实现。
export { createCipheriv, createDecipheriv, createHash, createHmac, publicEncrypt, randomBytes };

export const constants = {
  RSA_PKCS1_PADDING: 1,
  RSA_NO_PADDING: 3,
  RSA_PKCS1_OAEP_PADDING: 4,
} as const;

/** WKWebView 与 Siri 的 JavaScriptCore 都使用系统提供的安全随机数。 */
export const randomUUID = (): ReturnType<typeof crypto.randomUUID> => {
  const bytes = randomBytes(16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
};
