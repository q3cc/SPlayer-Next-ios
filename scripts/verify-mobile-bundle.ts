import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const dist = path.resolve("dist-mobile");
const indexPath = path.join(dist, "index.html");
const assetsPath = path.join(dist, "assets");
const tauriConfigPath = path.resolve("src-tauri/tauri.conf.json");
const iosInfoPath = path.resolve("src-tauri/Info.ios.plist");
const isAndroidBuild = process.argv.includes("--android");

const fail = (message: string): never => {
  console.error(`[VerifyMobileBundle] ${message}`);
  process.exit(1);
};

if (!fs.existsSync(indexPath)) fail("dist-mobile/index.html 不存在");

const scripts = fs
  .readdirSync(assetsPath)
  .filter((name) => name.endsWith(".js"))
  .map((name) => path.join(assetsPath, name));

if (scripts.length < 2) fail("移动 bundle 未分包，可能再次阻塞 iPad 主线程");

const html = fs.readFileSync(indexPath, "utf8");
const javascript = scripts.map((file) => fs.readFileSync(file, "utf8")).join("\n");
const styles = fs
  .readdirSync(assetsPath)
  .filter((name) => name.endsWith(".css"))
  .map((name) => fs.readFileSync(path.join(assetsPath, name), "utf8"))
  .join("\n");
const entryName =
  html.match(/<script[^>]+src="\.\/assets\/([^"?]+\.js)"/)?.[1] ?? fail("无法定位移动端入口脚本");
const entryPath = path.join(assetsPath, entryName);
const entry = fs.readFileSync(entryPath, "utf8");
if (/import\(["']\.\/(?:bootstrap|main)-/.test(entry)) {
  fail("移动入口仍动态导入 bootstrap 或 main，可能卡住 iOS WKWebView");
}
if (fs.statSync(entryPath).size > 750_000) {
  fail("移动静态入口超过 750 KB，会拖慢 iPad 首屏启动");
}

if (!html.includes("viewport-fit=cover")) fail("缺少 iOS 全屏 viewport-fit=cover");
if (!html.includes('class="splash-logo"')) fail("缺少内联启动 Logo");
if (!javascript.includes("splayer.mobile.settings")) fail("移动端 window.api 桥接未进入 bundle");
if (!isAndroidBuild && !javascript.includes("iPhone / iPad")) fail("移动播放器实现未进入 bundle");
if (/\.mobile\s*\{[^}]*display\s*:\s*none/.test(styles)) {
  fail("移动样式错误地隐藏了整个 html.mobile 根节点");
}
if (!styles.includes("html.mobile .onboarding-titlebar")) fail("缺少移动端引导页适配样式");
if (!/--s-safe-top\s*:\s*env\(safe-area-inset-top\s*,\s*0px\)/.test(styles)) {
  fail("缺少 iPhone/iPad 动态安全区变量");
}

const tauriConfig = JSON.parse(fs.readFileSync(tauriConfigPath, "utf8")) as {
  app?: { windows?: Array<{ fullscreen?: boolean }> };
};
if (tauriConfig.app?.windows?.[0]?.fullscreen !== false) fail("iPad 窗口仍被强制全屏");
if (isAndroidBuild) {
  const androidConfig = JSON.parse(
    fs.readFileSync(path.resolve("src-tauri/tauri.android.conf.json"), "utf8"),
  ) as { identifier?: string };
  if (androidConfig.identifier !== "top.imsyy.splayernext")
    fail("Android 应用标识与签名包配置不一致");
  const iosCommands = [
    "plugin:ipa-update|",
    "plugin:lyric-pip|",
    "plugin:native-audio|siri",
    "plugin:native-audio|airplay",
  ];
  for (const command of iosCommands) {
    if (javascript.includes(command)) fail(`Android 包含 iOS 命令 ${command}`);
  }
  if (fs.existsSync(path.join(dist, "licenses", "AudioStreaming.txt")))
    fail("Android 包含 iOS 音频库资源");
} else {
  const iosInfo = fs.readFileSync(iosInfoPath, "utf8");
  if (iosInfo.includes("UIRequiresFullScreen")) fail("Info.plist 仍禁止 iPad 动态窗口调度");
}

console.log(
  `[VerifyMobileBundle] 通过：${scripts.length} 个 JS 分包，静态入口 ${Math.ceil(fs.statSync(entryPath).size / 1024)} KB`,
);
