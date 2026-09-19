<script setup lang="ts">
import IconFolder from "~icons/lucide/folder";
import IconChevronLeft from "~icons/lucide/chevron-left";
import { useLibraryStore } from "@/stores/library";

const { t } = useI18n();
const libraryStore = useLibraryStore();
defineEmits<{ (e: "next"): void; (e: "back"): void }>();

/** 目录导入完成后立即扫描，避免引导页只保存目录而不更新曲库。 */
const handleFolderAdded = (): void => {
  void libraryStore.startScan(false);
};
</script>

<template>
  <div class="flex flex-col max-w-2xl w-full mx-auto">
    <div class="flex items-center gap-3 mb-2">
      <IconFolder class="size-6 text-primary" />
      <h2 class="text-2xl font-bold">{{ t("onboarding.library.title") }}</h2>
    </div>
    <p class="text-on-surface-variant/70 mb-6 leading-relaxed">
      {{ t("onboarding.library.subtitle") }}
    </p>

    <div class="bg-on-surface/4 border border-solid border-primary/10 rounded-xl p-4 mb-6">
      <FolderManager @added="handleFolderAdded" />
    </div>

    <div class="flex items-center gap-3">
      <SButton variant="ghost" round @click="$emit('back')">
        <template #icon><IconChevronLeft /></template>
        {{ t("onboarding.back") }}
      </SButton>
      <div class="flex-1" />
      <SButton type="primary" round @click="$emit('next')">
        {{ t("onboarding.next") }}
      </SButton>
    </div>
  </div>
</template>
