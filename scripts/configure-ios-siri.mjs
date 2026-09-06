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
    if (process.env.SPLAYER_SIRI_SIMULATOR_ENTITLEMENTS === "1") {
      // Tauri 不透传外部 xcconfig；测试权限直接交给 XcodeGen，且仅影响模拟器。
      const project = join(apple, "project.yml");
      const source = readFileSync(project, "utf8");
      const marker = "# SPlayer Siri simulator smoke settings";
      if (!source.includes(marker)) {
        if (/^settings:/m.test(source)) throw new Error("模拟器测试不能覆盖已有项目级设置");
        writeFileSync(
          project,
          `${source}\n${marker}\nsettings:\n  base:\n    ENABLE_DEBUG_DYLIB: NO\n    OTHER_LDFLAGS[sdk=iphonesimulator*]: $(inherited) -Wl,-sectcreate,__TEXT,__entitlements,$(SRCROOT)/../../../scripts/ios-siri-tests/simulator.entitlements\n`,
        );
      }
    }
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
