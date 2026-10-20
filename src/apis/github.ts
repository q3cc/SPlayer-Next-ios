/**
 * GitHub 仓库相关接口
 */

/** 贡献者信息 */
export interface Contributor {
  /** 用户名 */
  login: string;
  /** 主页地址 */
  htmlUrl: string;
  /** 头像地址 */
  avatar: string;
}

/** iOS 版本仓库 */
export const IOS_REPO_SLUG = "q3cc/SPlayer-Next-ios";
/** 原版仓库 */
export const ORIGINAL_REPO_SLUG = "SPlayer-Dev/SPlayer-Next";

/**
 * 获取仓库贡献者列表
 * @returns 贡献者数组
 */
export const getContributors = async (
  repoSlug = IOS_REPO_SLUG,
  options?: { compareBase: string },
): Promise<Contributor[]> => {
  const contributors = new Map<string, Contributor>();
  let page = 1;
  let totalCommits = 0;
  for (;;) {
    const endpoint = options
      ? `https://api.github.com/repos/${repoSlug}/compare/${options.compareBase}...main?per_page=100&page=${page}`
      : `https://api.github.com/repos/${repoSlug}/contributors?per_page=100&anon=true&page=${page}`;
    const res = await fetch(endpoint);
    if (!res.ok) throw new Error(`GitHub API ${res.status}`);
    const data = await res.json();
    const items = options ? data.commits : data;
    if (!Array.isArray(items)) throw new Error("Invalid GitHub contributors response");
    for (const item of items) {
      const author = options ? item.author : item;
      if (!author || author.type === "Bot" || author.login === "type-bot") continue;
      if (options && !author.login) continue;
      const login = author.login ?? author.name ?? "anonymous";
      contributors.set(login.toLowerCase(), {
        login,
        htmlUrl: author.html_url ?? (author.login ? `https://github.com/${author.login}` : ""),
        avatar: author.avatar_url ?? "",
      });
    }
    totalCommits += items.length;
    if (!items.length || (options ? totalCommits >= data.total_commits : items.length < 100)) break;
    page++;
  }
  return [...contributors.values()];
};
