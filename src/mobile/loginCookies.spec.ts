import { describe, expect, it, vi } from "vitest";
import { createRequest } from "../../electron/main/apis/netease/core/request";
import loginQrCheck from "../../electron/main/apis/netease/modules/login_qr_check";

const { fetchMock } = vi.hoisted(() => ({ fetchMock: vi.fn() }));
vi.mock("@main/utils/proxy", () => ({ fetchWithProxy: fetchMock }));
vi.mock("@main/utils/logger", () => ({ neteaseLog: { warn: vi.fn() } }));

describe("WebKit 扫码授权 Cookie", () => {
  it.each([undefined, () => []])("保留合并响应头中的登录凭据和 CSRF", async (getSetCookie) => {
    const raw = [
      "NMTID=browser; Expires=Wed, 09 Jun 2027 10:18:14 GMT; Path=/",
      "MUSIC_U=authorized-test-token; HttpOnly; Path=/",
      "__csrf=test-csrf; Path=/",
    ].join(", ");
    const response = new Response(JSON.stringify({ code: 803 }));
    Object.defineProperty(response, "headers", {
      value: { get: (name: string) => (name === "set-cookie" ? raw : null), getSetCookie },
    });
    fetchMock.mockResolvedValueOnce(response);
    const result = await loginQrCheck({ key: "test-key", cookie: {} }, createRequest);
    expect(result.body.code).toBe(803);
    expect(result.cookie).toContain("MUSIC_U=authorized-test-token");
    expect(result.cookie).toContain("__csrf=test-csrf");
    expect(result.cookie).toContain("NMTID=browser");
  });
});
