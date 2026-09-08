import { beforeEach, describe, expect, it, vi } from "vitest";
import type { LyricLine } from "@shared/types/lyrics";
import type { Track } from "@shared/types/player";
import { mobileMediaSession } from "./mediaSession";

const config = vi.hoisted(() => ({ enabled: true, dynamic: true, native: false }));
const nativeInvoke = vi.hoisted(() => vi.fn().mockResolvedValue(undefined));
vi.mock("@tauri-apps/api/core", () => ({
  invoke: nativeInvoke,
  isTauri: () => config.native,
}));
vi.mock("./shims/store", () => ({
  store: {
    get: (key: string) => (key === "media.dynamicLyrics" ? config.dynamic : config.enabled),
  },
}));

const track: Track = {
  id: "one",
  source: "netease",
  title: "歌曲标题",
  artists: [{ name: "歌手" }],
  album: { name: "专辑" },
  duration: 5000,
  cover: "https://example.com/cover.jpg",
};
const line: LyricLine = {
  startTime: 1000,
  endTime: 2000,
  words: [{ word: "当前歌词", startTime: 1000, endTime: 2000 }],
  translatedLyric: "",
  romanLyric: "",
  isBG: false,
  isDuet: false,
};

class ArtworkImage {
  static instances: ArtworkImage[] = [];
  src = "";
  decoding = "";
  naturalWidth = 600;
  naturalHeight = 600;
  onload: (() => void) | null = null;
  onerror: (() => void) | null = null;
  constructor() {
    ArtworkImage.instances.push(this);
  }
}

beforeEach(() => {
  config.enabled = true;
  config.native = false;
  config.dynamic = true;
  ArtworkImage.instances = [];
  vi.stubGlobal("Image", ArtworkImage);
  Object.defineProperty(navigator, "mediaSession", {
    configurable: true,
    value: { metadata: null },
  });
  vi.stubGlobal(
    "MediaMetadata",
    class {
      constructor(data: MediaMetadataInit) {
        Object.assign(this, data);
      }
    },
  );
  mobileMediaSession.setTrack(null);
  mobileMediaSession.setTrack(track);
  mobileMediaSession.setLyrics({ track, lyric: [line], source: null }, 0);
});

describe("iOS 原生控制中心", () => {
  beforeEach(() => {
    config.native = true;
    mobileMediaSession.setTrack(null);
    nativeInvoke.mockClear();
  });

  it("普通播放直接提交歌名、歌手和封面，不依赖浏览器卡片", () => {
    mobileMediaSession.setTrack(track);
    expect(nativeInvoke).toHaveBeenLastCalledWith(
      "plugin:native-audio|metadata",
      expect.objectContaining({
        enabled: true,
        title: track.title,
        artist: "歌手",
        cover: track.cover,
      }),
    );
  });

  it("Siri 接管后歌词同步保留当前歌曲，不清空原生卡片", () => {
    mobileMediaSession.setTrack(track);
    mobileMediaSession.setLyrics({ track, lyric: [line], source: null }, 0);
    expect(nativeInvoke).toHaveBeenLastCalledWith(
      "plugin:native-audio|metadata",
      expect.objectContaining({
        enabled: true,
        title: track.title,
        lines: [{ start: 1000, end: 2000, text: "当前歌词" }],
      }),
    );
    const next = { ...track, id: "next", title: "Siri 下一首" };
    mobileMediaSession.setTrack(next);
    mobileMediaSession.setLyrics({ track, lyric: [line], source: null }, 0);
    expect(nativeInvoke).toHaveBeenLastCalledWith(
      "plugin:native-audio|metadata",
      expect.objectContaining({
        enabled: true,
        title: next.title,
        lines: [],
      }),
    );
  });

  it("关闭系统控制仅清除原生卡片，不向 WebKit 写入空媒体信息", () => {
    const setter = vi.fn();
    Object.defineProperty(navigator.mediaSession, "metadata", { configurable: true, set: setter });
    mobileMediaSession.setTrack(track);
    config.enabled = false;
    mobileMediaSession.refresh();
    expect(nativeInvoke).toHaveBeenLastCalledWith(
      "plugin:native-audio|metadata",
      expect.objectContaining({ enabled: false }),
    );
    expect(setter).not.toHaveBeenCalled();
  });
});

describe("系统高清封面", () => {
  const song = {
    ...track,
    cover: "https://p1.music.126.net/album.jpg?param=300y300",
    coverOriginal: "https://p1.music.126.net/album.jpg?param=1024y1024",
  };

  it("先显示缩略图，原图加载成功后更新系统封面，不修改曲目", () => {
    mobileMediaSession.setTrack(song);
    expect(navigator.mediaSession.metadata?.artwork).toEqual([{ src: song.cover }]);
    const image = ArtworkImage.instances[0];
    expect(image.src).toBe("https://p1.music.126.net/album.jpg");
    image.onload?.();
    expect(navigator.mediaSession.metadata?.artwork).toEqual([
      { src: image.src, sizes: "600x600" },
    ]);
    expect(song.cover).toContain("300y300");
    mobileMediaSession.setPosition(1500);
    mobileMediaSession.setPosition(1600);
    expect(ArtworkImage.instances).toHaveLength(1);
  });

  it("加载失败保留缩略图，不随每次歌词更新重复请求", () => {
    mobileMediaSession.setTrack(song);
    ArtworkImage.instances[0].onerror?.();
    mobileMediaSession.setPosition(1500);
    expect(navigator.mediaSession.metadata?.artwork).toEqual([{ src: song.cover }]);
    expect(ArtworkImage.instances).toHaveLength(1);
  });

  it("切歌取消旧图片，迟到的加载结果不能覆盖新歌", () => {
    mobileMediaSession.setTrack(song);
    const image = ArtworkImage.instances[0];
    const lateLoad = image.onload;
    mobileMediaSession.setTrack({ ...track, id: "next" });
    expect(image.src).toBe("");
    lateLoad?.();
    expect(navigator.mediaSession.metadata?.artwork).toEqual([{ src: track.cover }]);
  });

  it("关闭系统媒体控制不加载高清封面，重新开启才加载", () => {
    config.enabled = false;
    mobileMediaSession.setTrack(song);
    expect(ArtworkImage.instances).toHaveLength(0);
    config.enabled = true;
    mobileMediaSession.refresh();
    expect(ArtworkImage.instances).toHaveLength(1);
    config.enabled = false;
    mobileMediaSession.refresh();
    expect(ArtworkImage.instances[0].src).toBe("");
  });

  it("其他来源复用原图地址，不添加网易云尺寸参数", () => {
    const original = "https://example.com/original.jpg?signature=test";
    mobileMediaSession.setTrack({ ...track, coverOriginal: original });
    expect(ArtworkImage.instances[0].src).toBe(original);
  });

  it("没有单独原图地址时移除网易云缩放参数，保留其他查询参数", () => {
    mobileMediaSession.setTrack({
      ...song,
      coverOriginal: undefined,
      cover: "https://p1.music.126.net/a.jpg?param=300y300&v=2",
    });
    expect(ArtworkImage.instances[0].src).toBe("https://p1.music.126.net/a.jpg?v=2");
  });

  it("不改写伪装为网易云的第三方地址", () => {
    const original = "https://music.126.net.example.com/a.jpg?param=300y300&signature=test";
    mobileMediaSession.setTrack({ ...song, coverOriginal: original });
    expect(ArtworkImage.instances[0].src).toBe(original);
  });
});

describe("系统正在播放动态歌词", () => {
  it("有歌词时以歌词为标题，歌曲名与歌手为副标题，保留封面", () => {
    mobileMediaSession.setPosition(1500);
    expect(navigator.mediaSession.metadata).toMatchObject({
      title: "当前歌词",
      artist: "歌曲标题 - 歌手",
      album: "",
      artwork: [{ src: track.cover }],
    });
  });

  it("同一行内不重复创建媒体信息", () => {
    mobileMediaSession.setPosition(1200);
    const metadata = navigator.mediaSession.metadata;
    mobileMediaSession.setPosition(1500);
    expect(navigator.mediaSession.metadata).toBe(metadata);
  });

  it.each([0, 999, 5000, 6000])("前奏或歌词结束满三秒的 %i ms 恢复歌曲信息", (position) => {
    mobileMediaSession.setPosition(1500);
    mobileMediaSession.setPosition(position);
    expect(navigator.mediaSession.metadata).toMatchObject({
      title: "歌曲标题",
      artist: "歌手",
      album: "专辑",
    });
  });

  it.each([2000, 4000, 4999])("歌词结束后三秒内的 %i ms 保留歌词", (position) => {
    mobileMediaSession.setPosition(1500);
    const metadata = navigator.mediaSession.metadata;
    mobileMediaSession.setPosition(position);
    expect(navigator.mediaSession.metadata).toBe(metadata);
    expect(navigator.mediaSession.metadata?.title).toBe("当前歌词");
  });

  it("保留期间新歌词立即替换，长句播放中不恢复歌名", () => {
    mobileMediaSession.setLyrics(
      {
        track,
        lyric: [
          line,
          {
            ...line,
            startTime: 3000,
            endTime: 10000,
            words: [{ word: "下一句歌词", startTime: 3000, endTime: 10000 }],
          },
        ],
        source: null,
      },
      0,
    );
    mobileMediaSession.setPosition(2999);
    expect(navigator.mediaSession.metadata?.title).toBe("当前歌词");
    mobileMediaSession.setPosition(3000);
    expect(navigator.mediaSession.metadata?.title).toBe("下一句歌词");
    mobileMediaSession.setPosition(9000);
    expect(navigator.mediaSession.metadata?.title).toBe("下一句歌词");
    mobileMediaSession.setPosition(13000);
    expect(navigator.mediaSession.metadata?.title).toBe("歌曲标题");
  });

  it("间奏空白行不提前清除歌词，也不延长保留时间", () => {
    mobileMediaSession.setLyrics(
      {
        track,
        lyric: [
          line,
          {
            ...line,
            startTime: 2000,
            endTime: 10000,
            words: [{ word: " ", startTime: 2000, endTime: 10000 }],
          },
        ],
        source: null,
      },
      0,
    );
    mobileMediaSession.setPosition(4000);
    expect(navigator.mediaSession.metadata?.title).toBe("当前歌词");
    mobileMediaSession.setPosition(5000);
    expect(navigator.mediaSession.metadata?.title).toBe("歌曲标题");
  });

  it("开关即时生效，不必重新播放", () => {
    config.dynamic = false;
    mobileMediaSession.setPosition(1500);
    expect(navigator.mediaSession.metadata?.title).toBe("歌曲标题");
    config.dynamic = true;
    mobileMediaSession.refresh();
    expect(navigator.mediaSession.metadata?.title).toBe("当前歌词");
    config.dynamic = false;
    mobileMediaSession.refresh();
    expect(navigator.mediaSession.metadata?.title).toBe("歌曲标题");
  });

  it("使用公共歌词偏移并支持回拖", () => {
    mobileMediaSession.setPosition(500);
    mobileMediaSession.setOffset(track.id, 1000);
    expect(navigator.mediaSession.metadata?.title).toBe("当前歌词");
    mobileMediaSession.setPosition(0);
    mobileMediaSession.setOffset(track.id, 0);
    expect(navigator.mediaSession.metadata?.title).toBe("歌曲标题");
  });

  it("切歌或晚到的上一首歌词不能污染新标题", () => {
    mobileMediaSession.setTrack({ ...track, id: "two", title: "下一首" });
    mobileMediaSession.setLyrics({ track, lyric: [line], source: null }, 0);
    mobileMediaSession.setPosition(1500);
    expect(navigator.mediaSession.metadata?.title).toBe("下一首");
  });

  it("关闭媒体控件或清空播放信息时移除系统元数据", () => {
    config.enabled = false;
    mobileMediaSession.refresh();
    expect(navigator.mediaSession.metadata).toBeNull();
    config.enabled = true;
    mobileMediaSession.refresh();
    mobileMediaSession.setLyrics({ track: null, lyric: [], source: null }, 0);
    expect(navigator.mediaSession.metadata).toBeNull();
  });
});
