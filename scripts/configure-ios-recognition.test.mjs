import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { addRecognitionTarget } from "./configure-ios-recognition.mjs";

test("广播扩展嵌入应用并共享 App Group，重复配置不增加依赖", () => {
  const app = {
    type: "application",
    platform: "iOS",
    deploymentTarget: "26.2",
    dependencies: [{ sdk: "WebKit.framework" }],
    entitlements: {
      path: "app/app.entitlements",
      properties: { "com.apple.developer.siri": true },
    },
    settings: { base: { CURRENT_PROJECT_VERSION: "42", IPHONEOS_DEPLOYMENT_TARGET: "26.2" } },
  };
  const project = { targets: { app_iOS: app } };
  addRecognitionTarget(project);
  addRecognitionTarget(project);
  assert.equal(app.dependencies.length, 2);
  assert.equal(app.dependencies[1].embed, true);
  assert.equal(app.entitlements.properties["com.apple.developer.siri"], true);
  const extension = project.targets.RecognitionBroadcast;
  const config = JSON.parse(readFileSync("src-tauri/tauri.conf.json", "utf8"));
  assert.equal(app.deploymentTarget, config.bundle.iOS.minimumSystemVersion);
  assert.equal(
    app.settings.base.IPHONEOS_DEPLOYMENT_TARGET,
    config.bundle.iOS.minimumSystemVersion,
  );
  assert.equal(extension.deploymentTarget, config.bundle.iOS.minimumSystemVersion);
  assert.equal(extension.settings.base.MARKETING_VERSION, config.version);
  assert.equal(extension.info.properties.CFBundleShortVersionString, config.version);
  assert.deepEqual(
    extension.entitlements.properties["com.apple.security.application-groups"],
    app.entitlements.properties["com.apple.security.application-groups"],
  );
  assert.equal(extension.settings.base.CURRENT_PROJECT_VERSION, "42");
  assert.equal(
    extension.info.properties.NSExtension.NSExtensionPointIdentifier,
    "com.apple.broadcast-services-upload",
  );
  assert.equal(extension.type, "app-extension");
  assert.equal(
    extension.info.properties.NSExtension.RPBroadcastProcessMode,
    "RPBroadcastProcessModeSampleBuffer",
  );
});

test("没有 iOS 应用时拒绝生成孤立扩展", () => {
  assert.throws(() => addRecognitionTarget({ targets: {} }), /未找到 iOS/);
});
