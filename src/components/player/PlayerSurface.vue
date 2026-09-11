<script setup lang="ts">
import FullPlayer from "./FullPlayer/index.vue";
import { useSettingsStore } from "@/stores/settings";
import { useStatusStore } from "@/stores/status";
import { useMediaStore } from "@/stores/media";
import { isIOS } from "@/utils/config";
import { invoke } from "@tauri-apps/api/core";

const AppleMusicPlayer = defineAsyncComponent(() => import("./AppleMusicPlayer/index.vue"));
const settings = useSettingsStore();
const status = useStatusStore();
const media = useMediaStore();
const appleTheme = computed(() => settings.player.theme === "apple-music");
const appleLyricsVisible = ref(false);
const visibility = useDocumentVisibility();

// 两套界面共用一个常亮开关，避免主题卸载与挂载的异步请求相互覆盖。
if (isIOS) {
  let updating = Promise.resolve();
  watch(
    () =>
      status.isPlayerExpanded &&
      visibility.value === "visible" &&
      (appleTheme.value
        ? appleLyricsVisible.value
        : status.showLyric &&
          !status.fullQueueOpen &&
          settings.player.coverLayout !== "fullscreen" &&
          (media.parsedLyric.length > 0 || media.lyricLoading)),
    (enabled) => {
      updating = updating
        .catch(() => {})
        .then(() => invoke<void>("plugin:lyric-pip|keepawake", { enabled }));
      void updating.catch((error) => console.warn("[lyrics] 常亮状态更新失败", error));
    },
    { immediate: true },
  );
  onBeforeUnmount(() => {
    void updating
      .catch(() => {})
      .then(() => invoke("plugin:lyric-pip|keepawake", { enabled: false }))
      .catch((error) => console.warn("[lyrics] 恢复自动熄屏失败", error));
  });
}
</script>

<template>
  <AppleMusicPlayer v-if="appleTheme" @lyrics-visible="appleLyricsVisible = $event" />
  <FullPlayer v-else />
</template>
