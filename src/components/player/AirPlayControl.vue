<script setup lang="ts">
import { isIOS } from "@/utils/config";

withDefaults(defineProps<{ cover?: boolean }>(), { cover: false });
const { t } = useI18n();
const anchor = ref<HTMLElement | null>(null);
const busy = ref(false);
const error = ref("");
const openAirPlay = async (): Promise<void> => {
  if (busy.value || document.hidden) return;
  const rect = anchor.value?.getBoundingClientRect();
  if (!rect?.width || !rect.height) return;
  busy.value = true;
  error.value = "";
  try {
    const { invoke } = await import("@tauri-apps/api/core");
    await invoke("plugin:native-audio|airplay", {
      x: rect.x + rect.width / 2,
      y: rect.y + rect.height / 2,
      viewportWidth: innerWidth,
      viewportHeight: innerHeight,
    });
  } catch (cause) {
    console.warn("[airplay]", cause);
    error.value = t("player.airPlayError");
  } finally {
    busy.value = false;
  }
};
</script>

<template>
  <span v-if="isIOS" ref="anchor" class="relative inline-flex">
    <SButton
      :type="cover ? 'cover' : 'default'"
      variant="ghost"
      circle
      size="large"
      :class="cover ? 'text-cover/50' : 'text-on-surface-variant'"
      :aria-label="t('player.airPlay')"
      :title="t('player.airPlay')"
      :disabled="busy"
      @click="openAirPlay"
    >
      <template #icon><IconLucideAirplay /></template>
    </SButton>
    <span
      v-if="error"
      role="alert"
      class="absolute bottom-full right-0 w-48 rounded bg-surface p-2 text-xs text-on-surface"
    >
      {{ error }}
    </span>
  </span>
</template>
