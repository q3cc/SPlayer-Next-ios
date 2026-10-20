import "virtual:uno.css";
import "@/styles/global.css";

import piniaPersistedstate from "pinia-plugin-persistedstate";
import App from "./App.vue";
import router from "./router";
import i18n from "./i18n";

import { useThemeStore } from "./stores/theme";
import { useSettingsStore } from "./stores/settings";
import { useHotkeyStore } from "./stores/hotkey";
import { initPlayer, playFiles, restoreLastTrack } from "./core/player";
import { handleOrpheus } from "./services/orpheus";
import { installHotkeyManager } from "./core/hotkey/manager";
import { vRipple } from "./directives/ripple";
import { reportBootStage } from "./boot";
import { isIOS } from "./utils/config";

reportBootStage("vue-setup-start");
const pinia = createPinia();
pinia.use(piniaPersistedstate);

const app = createApp(App);
app.directive("ripple", vRipple);
app.use(pinia);
app.use(router);
app.use(i18n);

// 初始化主题
useThemeStore().init();

// 同步语言设置
watch(
  () => useSettingsStore().locale,
  (v) => {
    i18n.global.locale.value = v;
    window.api.system.setLocale(v);
  },
  { immediate: true },
);

/**
 * 启动播放服务并分发冷启动任务
 */
const bootstrapPlayback = async (): Promise<void> => {
  const siriPlaying =
    isIOS && import.meta.env.VITE_MOBILE_TARGET !== "android"
      ? await import("./mobile/siri")
          .then(({ mobileSiri }) => mobileSiri.initialize())
          .catch((error) => {
            console.warn("[siri] 初始化失败", error);
            return false;
          })
      : false;

  const pendingAudioFiles = await window.api.system.consumePendingAudioFiles();
  const pendingOrpheusUrl = await window.api.system.consumePendingProtocolUrl();

  if (pendingAudioFiles && pendingAudioFiles.length > 0) {
    await playFiles(pendingAudioFiles);
  } else if (pendingOrpheusUrl) {
    await handleOrpheus(pendingOrpheusUrl);
  } else if (!siriPlaying) {
    await restoreLastTrack();
  }
};

/** 挂载首屏后初始化原生播放器，交由启动层释放交互 */
export const mountApplication = async (): Promise<void> => {
  reportBootStage("router-ready-start");
  await router.isReady();
  reportBootStage("router-ready");
  app.mount("#app");
  reportBootStage("vue-mounted");
  await nextTick();
  await initPlayer();
};

/** 启动层退出后分发 Siri、文件或恢复播放，并安装快捷键 */
export const startApplication = (): void => {
  void bootstrapPlayback()
    .then(async () => {
      if (import.meta.env.VITE_MOBILE_PLAYBACK_TEST === "1") {
        const { installPlaybackTest } = await import("./mobile/playbackTest");
        await installPlaybackTest();
      }
    })
    .catch(console.error);
  if (import.meta.env.VITE_MOBILE_SMOKE === "1") {
    void import("./mobile/smoke").then(({ runMobileSmokeTest }) => runMobileSmokeTest());
  }
  // 初始化快捷键
  useHotkeyStore()
    .init()
    .then(installHotkeyManager)
    .catch((err) => console.error("[hotkey] init failed", err));
};
