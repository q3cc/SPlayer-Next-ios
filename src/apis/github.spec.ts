import { afterEach, expect, it, vi } from "vitest";
import { getContributors, IOS_REPO_SLUG } from "./github";

const author = (login: string, type = "User") => ({
  login,
  type,
  html_url: `https://github.com/${login}`,
  avatar_url: `https://github.com/${login}.png`,
});
const response = (data: unknown) => new Response(JSON.stringify(data));

afterEach(() => vi.unstubAllGlobals());

it("iOS 贡献只读取与原版不同的提交，翻页后去重并排除机器人及未关联账号", async () => {
  const fetch = vi
    .fn()
    .mockResolvedValueOnce(
      response({
        total_commits: 103,
        commits: Array.from({ length: 100 }, () => ({ author: author("q3cc") })),
      }),
    )
    .mockResolvedValueOnce(
      response({
        total_commits: 103,
        commits: [
          { author: author("ios-contributor") },
          { author: author("automation", "Bot") },
          { author: null },
        ],
      }),
    );
  vi.stubGlobal("fetch", fetch);
  const contributors = await getContributors(IOS_REPO_SLUG, { compareBase: "SPlayer-Dev:main" });
  expect(contributors.map((item) => item.login)).toEqual(["q3cc", "ios-contributor"]);
  expect(fetch.mock.calls.map(([url]) => url)).toEqual([
    "https://api.github.com/repos/q3cc/SPlayer-Next-ios/compare/SPlayer-Dev:main...main?per_page=100&page=1",
    "https://api.github.com/repos/q3cc/SPlayer-Next-ios/compare/SPlayer-Dev:main...main?per_page=100&page=2",
  ]);
});

it("原版贡献者仍由原版仓库读取，并保留完整分页结果", async () => {
  const fetch = vi
    .fn()
    .mockResolvedValueOnce(response(Array.from({ length: 100 }, (_, i) => author(`user-${i}`))))
    .mockResolvedValueOnce(response([author("imsyy")]));
  vi.stubGlobal("fetch", fetch);
  const contributors = await getContributors("SPlayer-Dev/SPlayer-Next");
  expect(contributors).toHaveLength(101);
  expect(contributors.at(-1)?.login).toBe("imsyy");
  expect(fetch).toHaveBeenLastCalledWith(
    "https://api.github.com/repos/SPlayer-Dev/SPlayer-Next/contributors?per_page=100&anon=true&page=2",
  );
});

it("对比接口失败时不回退到含原版继承历史的贡献者列表", async () => {
  const fetch = vi.fn().mockResolvedValue(new Response(null, { status: 403 }));
  vi.stubGlobal("fetch", fetch);
  await expect(getContributors(IOS_REPO_SLUG, { compareBase: "SPlayer-Dev:main" })).rejects.toThrow(
    "GitHub API 403",
  );
  expect(fetch).toHaveBeenCalledOnce();
});
