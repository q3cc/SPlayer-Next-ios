import { readFileSync } from "node:fs";
import { expect, it } from "vitest";

it("原生音频命令匹配 Tauri 转换后的 Swift 方法名", () => {
  const root = `${process.cwd()}/src-tauri/plugins/native-audio`;
  const commands = readFileSync(`${root}/build.rs`, "utf8")
    .split("Builder::new(&[")[1]
    .split("])")[0]
    .matchAll(/"([a-z_]+)"/g);
  const swift = readFileSync(`${root}/ios/Sources/NativeAudioPlugin.swift`, "utf8");
  const permissions = readFileSync(`${root}/permissions/default.toml`, "utf8");
  // 监听方法由 Tauri.Plugin 基类提供。
  const inherited = new Set(["register_listener", "remove_listener"]);
  const androidOnly = new Set(["keep_awake"]);
  for (const [, command] of commands) {
    if (inherited.has(command) || androidOnly.has(command)) continue;
    expect(permissions, command).toContain(`"allow-${command.replaceAll("_", "-")}"`);
    const selector = command.replace(/_([a-z])/g, (_, char: string) => char.toUpperCase());
    expect(swift, command).toMatch(new RegExp(`@objc func ${selector}\\(_ invoke: Invoke\\)`));
  }
});

it("安卓常亮命令只授权安卓实现", () => {
  const root = `${process.cwd()}/src-tauri`;
  const android = readFileSync(
    `${root}/plugins/native-audio/android/src/main/java/NativeAudioPlugin.kt`,
    "utf8",
  );
  const ios = readFileSync(`${root}/plugins/native-audio/permissions/default.toml`, "utf8");
  const permissions = readFileSync(`${root}/capabilities/android.json`, "utf8");
  expect(android).toContain("@Command fun keepAwake(invoke: Invoke)");
  expect(permissions).toContain('"native-audio:allow-keep-awake"');
  expect(ios).not.toContain('"allow-keep-awake"');
});
