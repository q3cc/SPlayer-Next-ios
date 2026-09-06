import { readFileSync } from "node:fs";
import vm from "node:vm";
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomBytes, createCipheriv, createHmac, generateKeyPairSync } from "node:crypto";
import { gzipSync } from "node:zlib";

const resources = "src-tauri/plugins/native-audio/ios/Sources/Resources/";
const scripts = ["siri-bootstrap.js", "siri-background.js"].map((name) =>
  readFileSync(resources + name, "utf8"),
);
const local = {
  source: "local",
  id: "one",
  title: "晴天",
  artists: [{ name: "周杰伦" }],
  path: "/Documents/test.mp3",
  duration: 120000,
};
const options = {
  source: "netease",
  scope: "localFirst",
  library: [local],
  quality: "hq",
  allowTrial: false,
};

async function run(
  request,
  response = () => {
    throw new Error("不应发起网络请求");
  },
) {
  const timers = new Set();
  const context = vm.createContext({
    __siriStorage: {
      "splayer.mobile.session.netease": JSON.stringify({ MUSIC_U: "test-only-session" }),
    },
    __siriRandom: (count) => [...randomBytes(count)],
    __siriBytes: (base64) => [...Buffer.from(base64, "base64")],
    __siriUTF8: (base64) => Buffer.from(base64, "base64").toString(),
    __siriURL: (text, base) => {
      const url = new URL(text, base || undefined);
      return JSON.stringify({
        href: url.href,
        pathname: url.pathname,
        search: url.search,
        hostname: url.hostname,
        origin: url.origin,
      });
    },
    __siriTimer: (callback, ms) => {
      const timer = setTimeout(callback, ms);
      timers.add(timer);
      return timer;
    },
    __siriClearTimer: (timer) => {
      clearTimeout(timer);
      timers.delete(timer);
    },
    __siriHttp: (url, method, headers, body, timeout, success, failure) => {
      try {
        const data = response({ url, method, headers: JSON.parse(headers), body, timeout });
        success(
          200,
          "{}",
          (Buffer.isBuffer(data) ? data : Buffer.from(JSON.stringify(data))).toString("base64"),
        );
      } catch (error) {
        failure(error.message);
      }
    },
  });
  try {
    for (const script of scripts) vm.runInContext(script, context, { timeout: 10000 });
    const result = await vm.runInContext(
      `SPlayerSiri.run(${JSON.stringify({ ...options, ...request })})`,
      context,
      { timeout: 10000 },
    );
    return JSON.parse(JSON.stringify(result));
  } finally {
    for (const timer of timers) clearTimeout(timer);
  }
}

test("无网页环境可以按歌名和歌手搜索本地标签", async () => {
  assert.deepEqual(await run({ action: "search", query: "晴天", artist: "周杰伦" }), {
    tracks: [local],
  });
  assert.deepEqual(await run({ action: "search", query: "", artist: "周杰伦" }), {
    tracks: [local],
  });
  assert.deepEqual(
    await run({ action: "search", query: "晴天", artist: "另一位", scope: "local" }),
    { tracks: [] },
  );
});
test("本地解析不请求网络，空白搜索明确失败", async () => {
  assert.deepEqual(await run({ action: "resolve", track: local }), {
    url: local.path,
    isTrial: false,
  });
  await assert.rejects(run({ action: "search", query: "", artist: "" }), /歌名或歌手/);
});

const encrypt = (key, value) => {
  const cipher = createCipheriv(`aes-${key.length * 8}-ecb`, key, null);
  return Buffer.concat([cipher.update(value), cipher.final()]);
};
const publicKey = generateKeyPairSync("x25519")
  .publicKey.export({ format: "der", type: "spki" })
  .subarray(-32)
  .toString("base64");
const fixture =
  (item, compressed) =>
  ({ url, body, headers }) => {
    if (url.endsWith("/security/key/get")) {
      const nonce = new URLSearchParams(body).get("nonce");
      const timestamp = "1700000000000";
      const signature = createHmac(
        "sha256",
        "mUHCwVNWJbunMqAHf5MImuirT6plvs6VSFW62MGHstFQxhBGdEoIhLItH3djc4+FB/OKty3+lL2rGeoFBpVe5g==",
      )
        .update(timestamp + nonce)
        .digest("base64");
      const key = Buffer.from(
        "ab1d5a430f6bb04a3f01e81ddd72bd916d5ce591248ac128714806d7f8fb1b84",
        "hex",
      );
      return {
        code: 200,
        data: {
          signature,
          timestamp,
          encryptedData: encrypt(
            key,
            Buffer.from(JSON.stringify({ version: "test", publicKey, sk: "test-only" })),
          ).toString("base64"),
        },
      };
    }
    assert.match(url, /song\/enhance\/player\/url\/v1$/);
    assert.match(headers.Cookie ?? headers.cookie, /MUSIC_U=test-only-session/);
    const payload = Buffer.from(JSON.stringify({ code: 200, data: [item] }));
    return encrypt(Buffer.from("e82ckenh8dichen8"), compressed ? gzipSync(payload) : payload);
  };
for (const compressed of [false, true]) {
  test(`复用网易云完整加密链路并解密${compressed ? " gzip" : "普通"}响应`, async () => {
    const track = { ...local, source: "netease", id: "123" };
    const item = { url: "https://example.com/full.mp3", freeTrialInfo: null };
    assert.deepEqual(await run({ action: "resolve", track }, fixture(item, compressed)), {
      url: item.url,
      isTrial: false,
    });
  });
}
test("试听权限明确控制，不能把试听当完整歌曲", async () => {
  const track = { ...local, source: "netease", id: "123" };
  const item = { url: "https://example.com/trial.mp3", freeTrialInfo: { start: 0, end: 30 } };
  await assert.rejects(run({ action: "resolve", track }, fixture(item, true)), /试听/);
  assert.equal(
    (await run({ action: "resolve", track, allowTrial: true }, fixture(item, true))).isTrial,
    true,
  );
});
