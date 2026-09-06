import { copyFileSync, existsSync, mkdirSync, readdirSync } from "node:fs";
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
    for (const entry of readdirSync(apple, { withFileTypes: true })) {
      if (!entry.isDirectory() || !entry.name.endsWith("_iOS")) continue;
      const file = join(apple, entry.name, `${entry.name}.entitlements`);
      if (!existsSync(file)) execFileSync("plutil", ["-create", "xml1", file]);
      const key = "com\\.apple\\.developer\\.siri";
      try {
        execFileSync("plutil", ["-insert", key, "-bool", "YES", file], { stdio: "pipe" });
      } catch {
        execFileSync("plutil", ["-replace", key, "-bool", "YES", file]);
      }
    }
    execFileSync("xcodegen", ["generate", "--spec", join(apple, "project.yml")], {
      stdio: "inherit",
    });
  }
}
