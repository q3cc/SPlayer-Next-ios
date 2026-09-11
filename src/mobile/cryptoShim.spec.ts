import * as native from "node:crypto";
import { describe, expect, it } from "vitest";
import * as mobile from "./shims/crypto";

describe("移动端加密适配与平台协议兼容", () => {
  it.each(["aes-128-cbc", "aes-128-ecb", "aes-256-ecb", "aes-128-gcm"])(
    "%s 的加密结果与 Node 相同，且可相互解密",
    (algorithm) => {
      const key = Buffer.alloc(algorithm.includes("256") ? 32 : 16, 7);
      const iv = Buffer.alloc(
        algorithm.endsWith("ecb") ? 0 : algorithm.endsWith("gcm") ? 12 : 16,
        3,
      );
      const input = Buffer.from("测试中文歌曲与登录参数：SPlayer");
      const expected = native.createCipheriv(algorithm, key, iv);
      const actual = mobile.createCipheriv(algorithm, key, iv);
      const encrypt = (cipher: ReturnType<typeof native.createCipheriv>) =>
        Buffer.concat([cipher.update(input), cipher.final()]);
      const encrypted = encrypt(actual);
      expect(encrypted).toEqual(encrypt(expected));
      const decipher = mobile.createDecipheriv(algorithm, key, iv);
      if (algorithm.endsWith("gcm")) {
        const tag = (actual as native.CipherGCM).getAuthTag();
        expect(tag).toEqual((expected as native.CipherGCM).getAuthTag());
        (decipher as native.DecipherGCM).setAuthTag(tag);
      }
      expect(Buffer.concat([decipher.update(encrypted), decipher.final()])).toEqual(input);
    },
  );

  it.each(["md5", "sha256"])("%s 摘要与 HMAC 支持分段输入", (algorithm) => {
    for (const hmac of [false, true]) {
      const expected = hmac ? native.createHmac(algorithm, "密钥") : native.createHash(algorithm);
      const actual = hmac ? mobile.createHmac(algorithm, "密钥") : mobile.createHash(algorithm);
      expect(actual.update("歌曲").update(Buffer.from("参数")).digest("hex")).toBe(
        expected.update("歌曲").update(Buffer.from("参数")).digest("hex"),
      );
    }
  });

  it("网易云与酷狗使用的 RSA 无填充输出保持一致", () => {
    const { publicKey } = native.generateKeyPairSync("rsa", { modulusLength: 1024 });
    const key = publicKey.export({ format: "pem", type: "spki" });
    const data = Buffer.alloc(128);
    Buffer.from("0123456789abcdef").copy(data, 112);
    const options = { key, padding: mobile.constants.RSA_NO_PADDING };
    expect(mobile.publicEncrypt(options, data)).toEqual(native.publicEncrypt(options, data));
  });

  it("酷狗设备注册使用的 PKCS1 填充可由原生 RSA 解开", () => {
    const { publicKey, privateKey } = native.generateKeyPairSync("rsa", { modulusLength: 1024 });
    const input = Buffer.from("device-registration");
    const encrypted = mobile.publicEncrypt(
      {
        key: publicKey.export({ format: "pem", type: "spki" }),
        padding: mobile.constants.RSA_PKCS1_PADDING,
      },
      input,
    );
    const block = native.privateDecrypt(
      { key: privateKey, padding: native.constants.RSA_NO_PADDING },
      encrypted,
    );
    expect([...block.subarray(0, 2)]).toEqual([0, 2]);
    const separator = block.indexOf(0, 2);
    expect(separator).toBeGreaterThanOrEqual(10);
    expect(block.subarray(separator + 1)).toEqual(input);
  });

  it("安全随机数与 UUID 在没有原生 randomUUID 的 Siri 环境也可用", () => {
    expect(mobile.randomBytes(32)).toHaveLength(32);
    const ids = Array.from({ length: 20 }, () => mobile.randomUUID());
    for (const id of ids)
      expect(id).toMatch(/^[\da-f]{8}-[\da-f]{4}-4[\da-f]{3}-[89ab][\da-f]{3}-[\da-f]{12}$/);
    expect(new Set(ids).size).toBe(ids.length);
  });
});
