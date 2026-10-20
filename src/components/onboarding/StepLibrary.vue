<script setup lang="ts">
import IconMusic2 from "~icons/lucide/music-2";
import IconFolder from "~icons/lucide/folder";
import IconChevronLeft from "~icons/lucide/chevron-left";
import { useLibraryStore } from "@/stores/library";
import { toast } from "@/composables/useToast";

const { t } = useI18n();
const libraryStore = useLibraryStore();
const mobile = typeof window !== "undefined" && Boolean(window.api.library.addTracksFromFiles);
const addingSongs = ref(false);
defineEmits<{ (e: "next"): void; (e: "back"): void }>();

/** 目录导入完成后立即扫描，避免引导页只保存目录而不更新曲库。 */
const handleFolderAdded = (): void => {
  void libraryStore.startScan(false);
};

const handleSongsAdded = async (): Promise<void> => {
  if (addingSongs.value) return;
  const addTracks = window.api.library.addTracksFromFiles;
  if (!addTracks) return;
  addingSongs.value = true;
  try {
    const result = await addTracks();
    if (result.success) {
      await libraryStore.load();
      if (result.data) toast.success(t("onboarding.library.songsAdded", { count: result.data }));
    } else if (result.error && result.error !== "canceled") {
      toast.error(result.error);
    }
  } catch (error) {
    toast.error(error instanceof Error ? error.message : String(error));
  } finally {
    addingSongs.value = false;
  }
};
</script>

<template>
  <div class="flex flex-col max-w-2xl w-full mx-auto">
    <div class="flex items-center gap-3 mb-2">
      <IconFolder class="size-6 text-primary" />
      <h2 class="text-2xl font-bold">{{ t("onboarding.library.title") }}</h2>
    </div>
    <p class="text-on-surface-variant/70 mb-6 leading-relaxed">
      {{ t(mobile ? "onboarding.library.mobileSubtitle" : "onboarding.library.subtitle") }}
    </p>

    <div class="bg-on-surface/4 border border-solid border-primary/10 rounded-xl p-4 mb-6">
      <SButton
        v-if="mobile"
        variant="secondary"
        block
        :loading="addingSongs"
        @click="handleSongsAdded"
      >
        <template #icon><IconMusic2 /></template>
        {{ t("onboarding.library.addSongs") }}
      </SButton>
      <FolderManager v-else @added="handleFolderAdded" />
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
