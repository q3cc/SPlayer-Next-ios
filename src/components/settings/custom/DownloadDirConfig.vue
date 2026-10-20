<script setup lang="ts">
import IconLucideFolderOpen from "~icons/lucide/folder-open";
import IconLucideRotateCcw from "~icons/lucide/rotate-ccw";

import { isAndroid, isIOS, isMobile } from "@/utils/config";

defineOptions({ inheritAttrs: false });

const { t } = useI18n();

const dir = ref("");

const load = async (): Promise<void> => {
  dir.value = await window.api.download.getDir();
};

const change = async (): Promise<void> => {
  const result = await window.api.download.pickDir();
  if (result.ok) dir.value = result.dir;
};

const reset = async (): Promise<void> => {
  dir.value = await window.api.download.resetDir();
};

const openDir = (): void => {
  if (dir.value) void window.api.system.showInExplorer(dir.value);
};

onMounted(load);
</script>

<template>
  <div
    class="flex items-center justify-between gap-4 rounded-xl border border-solid border-outline-variant/15 bg-surface-panel px-4 py-3.5"
  >
    <div class="min-w-0 flex-1">
      <div class="text-base">{{ t("settings.downloadDir.label") }}</div>
      <div class="mt-0.5 truncate font-mono text-sm text-on-surface-variant/70" :title="dir">
        {{
          isIOS
            ? t("settings.downloadDir.mobile")
            : isAndroid
              ? t("settings.downloadDir.android")
              : dir || "—"
        }}
      </div>
    </div>
    <div v-if="!isMobile" class="shrink-0 flex items-center gap-2">
      <SButton variant="ghost" circle :title="t('settings.cacheDir.open')" @click="openDir">
        <template #icon><IconLucideFolderOpen /></template>
      </SButton>
      <SButton variant="ghost" circle :title="t('common.reset')" @click="reset">
        <template #icon><IconLucideRotateCcw /></template>
      </SButton>
      <SButton variant="secondary" @click="change">{{ t("settings.downloadDir.change") }}</SButton>
    </div>
  </div>
</template>
