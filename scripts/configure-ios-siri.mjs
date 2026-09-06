import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { resolve, join } from "node:path";
import { execFileSync } from "node:child_process";

const apple = resolve("src-tauri/gen/apple");
if (existsSync(join(apple, "project.yml"))) {
  const assets = join(apple, "assets/siri");
  mkdirSync(assets, { recursive: true });
  mkdirSync(join(apple, "Sources"), { recursive: true });
  for (const name of ["siri-bootstrap.js", "siri-background.js"]) {
    copyFileSync(
      resolve("src-tauri/plugins/native-audio/ios/Sources/Resources", name),
      join(assets, name),
    );
  }
  copyFileSync(
    resolve("src-tauri/ios-siri/SPlayerIntents.swift"),
    join(apple, "Sources/SPlayerIntents.swift"),
  );
  if (process.platform === "darwin") {
    const targets = readdirSync(apple, { withFileTypes: true }).filter(
      (entry) => entry.isDirectory() && entry.name.endsWith("_iOS"),
    );
    // Tauri 已合并权限、后台音频和窗口配置；XcodeGen 会用模板重写这些 plist。
    const preserved = targets.flatMap((entry) =>
      ["Info.plist", `${entry.name}.entitlements`]
        .map((name) => join(apple, entry.name, name))
        .filter(existsSync)
        .map((file) => ({ file, data: readFileSync(file) })),
    );
    execFileSync("xcodegen", ["generate", "--spec", join(apple, "project.yml")], {
      stdio: "inherit",
    });
    for (const { file, data } of preserved) writeFileSync(file, data);
    for (const entry of targets) {
      const file = join(apple, entry.name, `${entry.name}.entitlements`);
      if (!existsSync(file)) execFileSync("plutil", ["-create", "xml1", file]);
      const key = "com\\.apple\\.developer\\.siri";
      try {
        execFileSync("plutil", ["-insert", key, "-bool", "YES", file], { stdio: "pipe" });
      } catch {
        execFileSync("plutil", ["-replace", key, "-bool", "YES", file]);
      }
    }
  }
}
