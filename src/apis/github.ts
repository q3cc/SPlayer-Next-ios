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
export const getContributors = async (repoSlug = IOS_REPO_SLUG): Promise<Contributor[]> => {
  const res = await fetch(
    `https://api.github.com/repos/${repoSlug}/contributors?per_page=100&anon=true`,
  );
  if (!res.ok) throw new Error(`GitHub API ${res.status}`);
  const data = await res.json();
  if (!Array.isArray(data)) return [];
  return data
    .filter((item) => item.type !== "Bot" && item.login !== "type-bot")
    .map((item) => ({
      login: item.login ?? item.name ?? "anonymous",
      htmlUrl: item.html_url ?? "",
      avatar: item.avatar_url ?? "",
    }));
};
