<script setup lang="ts">
import type { DropdownMenuItem } from "@/components/ui/SDropdownMenu.vue";
import { useStatusStore } from "@/stores/status";
import { useSettingsStore } from "@/stores/settings";
import * as player from "@/core/player";
import { isIOS } from "@/utils/config";
import IconLucideSliders from "~icons/lucide/sliders-horizontal";
import IconLucideGauge from "~icons/lucide/gauge";
import IconLucideMoreVertical from "~icons/lucide/more-vertical";
import IconLucideClock from "~icons/lucide/clock";
import IconLucideRepeat2 from "~icons/lucide/repeat-2";
import IconLucideRadio from "~icons/lucide/radio";

const props = withDefaults(
  defineProps<{
    /** 是否使用封面主题 */
    cover?: boolean;
  }>(),
  { cover: false },
);

const { t } = useI18n();
const status = useStatusStore();
const settings = useSettingsStore();
const { isDesktopLyricOpen } = storeToRefs(settings);

const buttonType = computed<"default" | "cover">(() => (props.cover ? "cover" : "default"));
const mutedClass = computed(() => (props.cover ? "text-cover/50" : "text-on-surface-variant"));

const lyricButtonType = computed(() =>
  isDesktopLyricOpen.value ? (props.cover ? "cover" : "primary") : buttonType.value,
);

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

const toggleDesktopLyric = (): void => {
  window.api.window.toggleDesktopLyric().catch(() => {});
};

const equalizerOpen = ref(false);
const speedOpen = ref(false);
const autoCloseOpen = ref(false);
const abLoopOpen = ref(false);
const fmModeOpen = ref(false);

const moreMenuItems = computed<DropdownMenuItem[]>(() => [
  { key: "equalizer", label: t("equalizer.title"), icon: IconLucideSliders },
  { key: "speed", label: t("speed.title"), icon: IconLucideGauge },
  { key: "abLoop", label: t("abLoop.title"), icon: IconLucideRepeat2 },
  { key: "autoClose", label: t("autoClose.title"), icon: IconLucideClock },
]);

const onMoreMenuSelect = (key: string): void => {
  if (key === "equalizer") equalizerOpen.value = true;
  else if (key === "speed") speedOpen.value = true;
  else if (key === "abLoop") abLoopOpen.value = true;
  else if (key === "autoClose") autoCloseOpen.value = true;
};
</script>

<template>
  <div class="flex items-center gap-1">
    <!-- 在线音质 -->
    <QualityControl v-if="settings.appearance.showQualitySwitch" :cover="cover" />
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
    <SButton
      :type="lyricButtonType"
      :variant="isDesktopLyricOpen ? 'tertiary' : 'ghost'"
      circle
      size="large"
      :class="isDesktopLyricOpen ? undefined : mutedClass"
      @click="toggleDesktopLyric"
    >
      <template #icon><IconLucideCaptions /></template>
    </SButton>
    <!-- 私人 FM 模式调整 -->
    <SButton
      v-if="status.fmMode"
      :type="buttonType"
      :variant="fmModeOpen ? 'tertiary' : 'ghost'"
      circle
      size="large"
      :class="fmModeOpen ? undefined : mutedClass"
      :title="t('player.fm.modeTooltip')"
      @click="fmModeOpen = true"
    >
      <template #icon><IconLucideRadio /></template>
    </SButton>
    <!-- 全屏播放器内播放列表 -->
    <SButton
      v-else-if="cover"
      :type="buttonType"
      :variant="status.fullQueueOpen ? 'tertiary' : 'ghost'"
      circle
      size="large"
      :class="status.fullQueueOpen ? undefined : mutedClass"
      @click="status.fullQueueOpen = !status.fullQueueOpen"
    >
      <template #icon><IconLucideListMusic /></template>
    </SButton>
    <!-- 常规播放列表气泡 -->
    <SPopover
      v-else
      v-model:open="status.outerQueueOpen"
      trigger="click"
      side="top"
      :side-offset="12"
      content-class="!p-0 w-72 h-[min(60vh,520px)] overflow-hidden"
    >
      <template #trigger>
        <SButton
          :type="status.outerQueueOpen ? 'primary' : buttonType"
          :variant="status.outerQueueOpen ? 'tertiary' : 'ghost'"
          circle
          size="large"
          :class="status.outerQueueOpen ? undefined : mutedClass"
        >
          <template #icon><IconLucideListMusic /></template>
        </SButton>
      </template>
      <QueuePopover @close="status.outerQueueOpen = false" />
    </SPopover>
    <SDropdownMenu
      :items="moreMenuItems"
      side="top"
      align="end"
      :cover="cover"
      @select="onMoreMenuSelect"
    >
      <template #trigger>
        <SButton :type="buttonType" variant="ghost" circle size="large" :class="mutedClass">
          <template #icon><IconLucideMoreVertical /></template>
        </SButton>
      </template>
    </SDropdownMenu>
    <EqualizerDialog v-model:open="equalizerOpen" />
    <SpeedDialog v-model:open="speedOpen" />
    <AbLoopDialog v-model:open="abLoopOpen" />
    <AutoCloseDialog v-model:open="autoCloseOpen" />
    <FmModeDialog v-model:open="fmModeOpen" />
  </div>
</template>
