import { describe, expect, it, vi } from "vitest";
import { xeapi, xeapiDecryptPublicKey } from "../../electron/main/apis/netease/core/crypto";

vi.mock("node:crypto", async (importOriginal) => ({
  ...(await importOriginal<typeof import("node:crypto")>()),
  ...(await import("./shims/crypto")),
}));

describe("移动端匿名会话加密与 Node 服务端互通", () => {
  it("通过浏览器 AES 解密公钥包，不读取 null IV 的 length", async () => {
    const native = await vi.importActual<typeof import("node:crypto")>("node:crypto");
    const key = Buffer.from(
      "ab1d5a430f6bb04a3f01e81ddd72bd916d5ce591248ac128714806d7f8fb1b84",
      "hex",
    );
    const payload = { version: "1", publicKey: "test", sk: "test-key" };
    const cipher = native.createCipheriv("aes-256-ecb", key, null);
    const encrypted = Buffer.concat([cipher.update(JSON.stringify(payload)), cipher.final()]);
    expect(xeapiDecryptPublicKey(encrypted.toString("base64"))).toEqual(payload);
  });

  it("X25519 与 AES-GCM 封装可由 Node 原生密钥解密", async () => {
    const native = await vi.importActual<typeof import("node:crypto")>("node:crypto");
    const server = native.generateKeyPairSync("x25519");
    const peer = server.publicKey.export({ format: "der", type: "spki" }).subarray(-32);
    const encrypted = xeapi(
      "/api/register/anonimous",
      { username: "test" },
      {
        publicKeyState: { version: "1", publicKey: peer.toString("base64"), sk: "server-key" },
        sessionKey: "0123456789abcdef",
        sessionId: "test-session",
      },
    );
    const data = Buffer.from(encrypted.S, "base64");
    const publicKey = native.createPublicKey({
      key: Buffer.concat([Buffer.from("302a300506032b656e032100", "hex"), data.subarray(0, 32)]),
      format: "der",
      type: "spki",
    });
    const secret = native.diffieHellman({ privateKey: server.privateKey, publicKey });
    const prk = native.createHmac("sha256", Buffer.alloc(32)).update(secret).digest();
    const aesKey = native
      .createHmac("sha256", prk)
      .update(Buffer.concat([data.subarray(0, 32), Buffer.from([1])]))
      .digest()
      .subarray(0, 16);
    const decipher = native.createDecipheriv("aes-128-gcm", aesKey, data.subarray(32, 44));
    decipher.setAuthTag(data.subarray(-16));
    const plaintext = Buffer.concat([decipher.update(data.subarray(44, -16)), decipher.final()]);
    expect(plaintext.toString()).toBe(
      `${Buffer.from("0123456789abcdef").toString("base64")}|android|server-key`,
    );
    expect(Buffer.from(encrypted.B, "base64").length).toBeGreaterThan(0);
  });
});
