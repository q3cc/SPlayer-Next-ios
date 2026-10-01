import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync, copyFileSync } from "node:fs";
import { join, resolve } from "node:path";

export function addRecognitionTarget(project) {
  const entry = Object.entries(project.targets).find(
    ([, target]) => target.type === "application" && target.platform === "iOS",
  );
  if (!entry) throw new Error("未找到 iOS 应用目标");
  const [name, app] = entry;
  const bundle = "top.imsyy.splayer-next.ios";
  const group = `group.${bundle}.recognition`;
  app.dependencies ??= [];
  if (!app.dependencies.some((dep) => dep.target === "RecognitionBroadcast")) {
    app.dependencies.push({ target: "RecognitionBroadcast", embed: true });
  }
  app.entitlements ??= { path: `${name}/${name}.entitlements` };
  app.entitlements.properties ??= {};
  app.entitlements.properties["com.apple.security.application-groups"] = [group];
  project.targets.RecognitionBroadcast = {
    type: "app-extension",
    platform: "iOS",
    deploymentTarget: "16.0",
    sources: ["RecognitionBroadcast"],
    settings: {
      base: {
        PRODUCT_BUNDLE_IDENTIFIER: `${bundle}.RecognitionBroadcast`,
        SWIFT_VERSION: "5.0",
        TARGETED_DEVICE_FAMILY: "1,2",
        SKIP_INSTALL: "YES",
        APPLICATION_EXTENSION_API_ONLY: "YES",
        MARKETING_VERSION: JSON.parse(readFileSync(resolve("src-tauri/tauri.conf.json"), "utf8"))
          .version,
        CURRENT_PROJECT_VERSION: app.settings?.base?.CURRENT_PROJECT_VERSION ?? "1",
      },
    },
    info: {
      path: "RecognitionBroadcast/Info.plist",
      properties: {
        CFBundleDisplayName: "SPlayer 听歌识曲",
        NSExtension: {
          NSExtensionPointIdentifier: "com.apple.broadcast-services-upload",
          NSExtensionPrincipalClass: "$(PRODUCT_MODULE_NAME).SampleHandler",
          NSExtensionAttributes: { RPBroadcastProcessMode: "RPBroadcastProcessModeSampleBuffer" },
        },
      },
    },
    entitlements: {
      path: "RecognitionBroadcast/RecognitionBroadcast.entitlements",
      properties: {
        "com.apple.security.application-groups": [group],
      },
    },
  };
  return { name, group };
}

export function configureRecognition(apple) {
  const file = join(apple, "project.yml");
  // macOS 自带 Ruby YAML；JSON 也是合法的 XcodeGen YAML，避免手工插入缩进。
  const project = JSON.parse(
    execFileSync(
      "ruby",
      ["-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))", file],
      { encoding: "utf8" },
    ),
  );
  const result = addRecognitionTarget(project);
  if (process.env.SPLAYER_SIRI_SIMULATOR_ENTITLEMENTS === "1") {
    // 仅修改主应用的模拟器设置，不把应用权限链接进广播扩展。
    const app = project.targets[result.name];
    app.settings ??= {};
    app.settings.base ??= {};
    app.settings.base.ENABLE_DEBUG_DYLIB = "NO";
    app.settings.base["OTHER_LDFLAGS[sdk=iphonesimulator*]"] =
      "$(inherited) -Wl,-sectcreate,__TEXT,__entitlements,$(SRCROOT)/../../../scripts/ios-siri-tests/simulator.entitlements";
  }
  const sources = join(apple, "RecognitionBroadcast");
  mkdirSync(sources, { recursive: true });
  copyFileSync(
    resolve("src-tauri/ios-recognition/SampleHandler.swift"),
    join(sources, "SampleHandler.swift"),
  );
  writeFileSync(file, JSON.stringify(project, null, 2));
  return result;
}
