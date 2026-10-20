import { describe, expect, it } from "vitest";
import { neteaseCdnUrl } from "@shared/utils/neteaseCdnUrl";

describe("neteaseCdnUrl", () => {
  it("将网易云音频与封面 CDN 的 HTTP 地址升级为 HTTPS，并保留签名", () => {
    expect(neteaseCdnUrl("http://m10.music.126.net/song.mp3?token=abc%2Fdef")).toBe(
      "https://m10.music.126.net/song.mp3?token=abc%2Fdef",
    );
    expect(neteaseCdnUrl("http://p4.music.126.net/cover.jpg?param=300y300")).toBe(
      "https://p4.music.126.net/cover.jpg?param=300y300",
    );
  });

  it("不改动其他来源或伪装成网易云域名的地址", () => {
    expect(neteaseCdnUrl("http://music.126.net.example.com/song.mp3")).toBe(
      "http://music.126.net.example.com/song.mp3",
    );
    expect(neteaseCdnUrl("http://example.com/song.mp3")).toBe("http://example.com/song.mp3");
    expect(neteaseCdnUrl("https://m10.music.126.net/song.mp3")).toBe(
      "https://m10.music.126.net/song.mp3",
    );
  });
});
