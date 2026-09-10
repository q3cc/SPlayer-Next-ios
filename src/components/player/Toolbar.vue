<script setup lang="ts">
import type { DropdownMenuItem } from "@/components/ui/SDropdownMenu.vue";
import AirPlayControl from "./AirPlayControl.vue";
import { useStatusStore } from "@/stores/status";
import { useSettingsStore } from "@/stores/settings";
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
    <VolumeControl :cover="cover" />
    <AirPlayControl :cover="cover" />
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
