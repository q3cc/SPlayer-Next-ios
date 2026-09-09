<script setup lang="ts">
import { useStatusStore } from "@/stores/status";
import * as player from "@/core/player";
import { isIOS } from "@/utils/config";
const props = withDefaults(defineProps<{ cover?: boolean }>(), { cover: false });
const status = useStatusStore();
const buttonType = computed(() => (props.cover ? "cover" : "default"));
const mutedClass = computed(() => (props.cover ? "text-cover/50" : "text-on-surface-variant"));
const volumePercent = computed(() => Math.round(status.volume * 100));

const volumeAnchor = ref<HTMLElement | null>(null);
const showSystemVolume = async (): Promise<void> => {
  if (!isIOS || document.hidden) return;
  const rect = volumeAnchor.value?.getBoundingClientRect();
  if (!rect?.width || !rect.height) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("plugin:native-audio|system_volume", {
    show: true,
    x: rect.x + rect.width / 2,
    y: rect.y,
    viewportWidth: innerWidth,
    viewportHeight: innerHeight,
  });
};
const systemVolumeChanged = (event: Event): void => {
  const volume = (event as CustomEvent<number>).detail;
  if (!Number.isFinite(volume)) return;
  status.volume = volume;
  // 全屏和底部工具栏可能同时挂载，只让当前可见播放器展开原生滑条。
  if (props.cover === status.isPlayerExpanded) void showSystemVolume().catch(console.warn);
};
const hideSystemVolume = (): void => {
  if (isIOS)
    void import("@tauri-apps/api/core")
      .then(({ invoke }) => invoke("plugin:native-audio|system_volume", { show: false }))
      .catch(console.warn);
};
onMounted(() => {
  if (isIOS) {
    window.addEventListener("splayer:system-volume", systemVolumeChanged);
    window.addEventListener("resize", hideSystemVolume);
  }
});
onUnmounted(() => {
  window.removeEventListener("splayer:system-volume", systemVolumeChanged);
  window.removeEventListener("resize", hideSystemVolume);
  hideSystemVolume();
});

const onVolumeWheel = (e: WheelEvent): void => {
  const delta = e.deltaY < 0 ? 0.05 : -0.05;
  const next = Math.max(0, Math.min(1, status.volume + delta));
  player.setVolume(next);
};
</script>
<template>
  <SPopover
    :trigger="isIOS ? 'manual' : 'click'"
    side="top"
    :cover="cover"
    content-class="px-3 pb-2 pt-3"
  >
    <template #trigger>
      <span ref="volumeAnchor">
        <SButton
          :type="buttonType"
          variant="ghost"
          circle
          size="large"
          :class="mutedClass"
          :aria-label="cover ? '播放器音量' : '音量'"
          data-player-volume
          @click="isIOS && showSystemVolume().catch(console.warn)"
          @wheel.prevent="onVolumeWheel"
        >
          <template #icon>
            <IconLucideVolumeX v-if="volumePercent === 0" />
            <IconLucideVolume1 v-else-if="volumePercent < 50" />
            <IconLucideVolume2 v-else />
          </template>
        </SButton>
      </span>
    </template>
    <div class="flex flex-col items-center w-7" @wheel.prevent="onVolumeWheel">
      <div class="h-30">
        <SSlider
          :model-value="status.volume"
          :min="0"
          :max="1"
          :step="0.01"
          :thumb-size="15"
          :track-height="5"
          :cover="cover"
          vertical
          @change="player.setVolume($event)"
        />
      </div>
      <span class="text-xs tabular-nums mt-2">{{ volumePercent }}%</span>
    </div>
  </SPopover>
</template>
