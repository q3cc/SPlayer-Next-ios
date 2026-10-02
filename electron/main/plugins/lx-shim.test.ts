import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { normalizeLxMusicInfo } from "./lx-shim";

describe("normalizeLxMusicInfo", () => {
  it("处理网易云等无 hash 歌曲时，不应设置空串 hash，且 ?? 能正确兜底到 songmid", () => {
    const raw = {
      songmid: "208902",
      name: "红色高跟鞋",
      singer: "蔡健雅",
      albumId: "20744",
      albumName: "若你碰到他",
    };

    const info = normalizeLxMusicInfo(raw, "wy");

    assert.equal(info.songmid, "208902");
    assert.equal(info.id, "208902");
    assert.equal(info.hash, undefined);
    assert.equal("hash" in info, false);
    assert.equal(info.meta.hash, undefined);
    assert.equal("hash" in info.meta, false);

    // 验证第三方插件常见写法：const songId = musicInfo.hash ?? musicInfo.songmid
    const resolvedSongId = info.hash ?? info.songmid;
    assert.equal(resolvedSongId, "208902");
  });

  it("当输入中包含空串 hash 时，应清理掉而不能透传空串", () => {
    const raw = {
      songmid: "208902",
      name: "红色高跟鞋",
      singer: "蔡健雅",
      hash: "",
      meta: {
        songId: "208902",
        albumName: "",
        albumId: "",
        picUrl: null,
        hash: "",
      },
    };

    const info = normalizeLxMusicInfo(raw, "wy");

    assert.equal(info.hash, undefined);
    assert.equal("hash" in info, false);
    assert.equal(info.meta.hash, undefined);
    assert.equal("hash" in info.meta, false);

    const resolvedSongId = info.hash ?? info.songmid;
    assert.equal(resolvedSongId, "208902");
  });

  it("处理酷狗歌曲且有有效 32 位 hash 时，应保留并正确提取 hash", () => {
    const hex32 = "e10adc3949ba59abbe56e057f20f883e";
    const raw = {
      songmid: hex32,
      name: "测试歌曲",
      singer: "测试歌手",
    };

    const info = normalizeLxMusicInfo(raw, "kg");

    assert.equal(info.hash, hex32);
    assert.equal(info.meta.hash, hex32);

    const resolvedSongId = info.hash ?? info.songmid;
    assert.equal(resolvedSongId, hex32);
  });

  it("处理酷狗歌曲显式传入 hash 时，应优先使用显式传入的 hash", () => {
    const customHash = "a1b2c3d4e5f60718293a4b5c6d7e8f90";
    const raw = {
      songmid: "123456",
      name: "测试歌曲",
      singer: "测试歌手",
      hash: customHash,
    };

    const info = normalizeLxMusicInfo(raw, "kg");

    assert.equal(info.hash, customHash);
    assert.equal(info.meta.hash, customHash);
    assert.equal(info.songmid, "123456");
  });

  it("非咪咕源无 copyrightId 时不应挂载空串 copyrightId", () => {
    const raw = {
      songmid: "208902",
      name: "红色高跟鞋",
      copyrightId: "",
    };

    const info = normalizeLxMusicInfo(raw, "wy");
    assert.equal(info.copyrightId, undefined);
    assert.equal("copyrightId" in info, false);
  });
});
