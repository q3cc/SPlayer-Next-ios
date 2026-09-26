const fs = require("node:fs");

module.exports = async ({ github, context }) => {
  const { owner, repo } = context.repo;
  const commit = context.sha;
  const branch = await github.rest.repos.getBranch({ owner, repo, branch: "main" });
  if (branch.data.commit.sha !== commit) {
    console.log("跳过旧提交，等待 main 的最新安卓构建。");
    return;
  }

  const tag = "android-action-latest";
  let release;
  try {
    release = (await github.rest.repos.getReleaseByTag({ owner, repo, tag })).data;
  } catch (error) {
    if (error.status !== 404) throw error;
    release = (
      await github.rest.repos.createRelease({
        owner,
        repo,
        tag_name: tag,
        target_commitish: commit,
        name: "Android Action 构建版",
        prerelease: true,
        make_latest: "false",
        body: "安卓构建正在上传。",
      })
    ).data;
  }

  const uploadedNames = new Set();
  for (const arch of ["arm64", "arm32", "x64"]) {
    const source = `SPlayer-Next-Android-${arch}.apk`;
    const name = `SPlayer-Next-Android-${arch}-${commit.slice(0, 7)}.apk`;
    uploadedNames.add(name);
    const existing = release.assets.find((asset) => asset.name === name);
    const size = fs.statSync(source).size;
    if (size <= 0) throw new Error(`更新包为空：${source}`);
    if (!existing || existing.state !== "uploaded" || existing.size !== size) {
      if (existing) {
        await github.rest.repos.deleteReleaseAsset({ owner, repo, asset_id: existing.id });
      }
      await github.rest.repos.uploadReleaseAsset({
        owner,
        repo,
        release_id: release.id,
        name,
        data: fs.readFileSync(source),
        headers: { "content-type": "application/vnd.android.package-archive" },
      });
    }
  }

  const details = await github.rest.repos.getCommit({ owner, repo, ref: commit });
  const metadata = {
    commit,
    version: JSON.parse(fs.readFileSync("package.json", "utf8")).version,
    date: details.data.commit.committer.date,
  };
  await github.rest.repos.updateRelease({
    owner,
    repo,
    release_id: release.id,
    prerelease: true,
    make_latest: "false",
    name: `Android Action 构建版 · ${commit.slice(0, 7)}`,
    body: `<!-- splayer-android-action:${JSON.stringify(metadata)} -->\nmain 分支的安卓开发构建。请选择与设备架构对应的 APK。\n\n提交：${commit}\n${details.data.commit.message.split("\n")[0]}`,
  });
  await github.rest.git.updateRef({ owner, repo, ref: `tags/${tag}`, sha: commit, force: true });
  for (const asset of release.assets) {
    if (
      !uploadedNames.has(asset.name) &&
      /^SPlayer-Next-Android-(?:arm64|arm32|x64)-[a-f0-9]{7}\.apk$/.test(asset.name)
    ) {
      await github.rest.repos.deleteReleaseAsset({ owner, repo, asset_id: asset.id });
    }
  }
};
