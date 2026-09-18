import { readFileSync } from "node:fs";
import { expect, it } from "vitest";

const native = readFileSync("src-tauri/plugins/native-audio/ios/Sources/CloudUpload.swift", "utf8");
const permissions = readFileSync("src-tauri/plugins/native-audio/permissions/default.toml", "utf8");
const build = readFileSync("src-tauri/plugins/native-audio/build.rs", "utf8");

it("云盘桥接命令和权限配套注册", () => {
  for (const [command, method] of [
    ["prepare_cloud_upload", "prepareCloudUpload"],
    ["upload_cloud_file", "uploadCloudFile"],
  ]) {
    expect(build).toContain('"' + command + '"');
    expect(permissions).toContain('"allow-' + command.replaceAll("_", "-") + '"');
    expect(native).toContain("@objc func " + method);
  }
});

it("哈希逐块读取、系统从磁盘上传并释放会话，不整首缓存音频", () => {
  expect(native).toContain("read(upToCount: 64 * 1024)");
  expect(native).toContain("autoreleasepool");
  expect(native).toContain("uploadTask(with: request, fromFile: file)");
  expect(native).toContain("finishTasksAndInvalidate()");
  expect(native).not.toContain("Data(contentsOf:");
  expect(native).not.toContain("httpBody =");
});

it("原生上传限制文件和目标地址，拒绝转发凭证的重定向", () => {
  expect(native).toContain('url.path.hasPrefix(root + "/")');
  expect(native).toContain('url.scheme == "https"');
  expect(native).toContain('host.hasSuffix(".127.net")');
  expect(native).toContain("completionHandler(nil)");
  expect(native).toContain("size == Int(args.size)");
});

it("上传进度节流且后台不推送高频事件", () => {
  expect(native).toContain("now - lastProgress >= 0.2");
  expect(native).toContain("UIApplication.shared.applicationState == .active");
  expect(native).toContain("progress = nil");
});
