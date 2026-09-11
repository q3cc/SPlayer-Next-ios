<script setup lang="ts">
import type { Track } from "@shared/types/player";
import type { SVirtualListExposed } from "@/components/ui/SVirtualList.vue";
import { useQueuePanel } from "@/composables/useQueuePanel";

const { t } = useI18n();
const listRef = shallowRef<SVirtualListExposed | null>(null);
const { statusStore, queue, queueLength, formatArtists, playAt, removeAt, scrollToCurrent } =
  useQueuePanel({ listRef });
</script>

<template>
  <section class="am-next" :aria-label="t('player.appleMusic.queue')">
    <header>
      <div>
        <h2>{{ t("player.appleMusic.queue") }}</h2>
        <p>{{ t("common.totalSongs", { count: queueLength }) }}</p>
      </div>
      <button
        class="am-icon"
        :disabled="!queueLength"
        :aria-label="t('player.appleMusic.locate')"
        @click="scrollToCurrent"
      >
        <IconLucideListMusic />
      </button>
    </header>
    <SVirtualList
      v-if="queueLength"
      ref="listRef"
      class="am-next-list"
      :items="queue"
      :item-height="80"
      item-fixed
      cover
      height="100%"
      :default-scroll-index="Math.max(0, statusStore.playIndex)"
      :get-item-key="(item: Track, index: number) => `${item.source}:${item.id}:${index}`"
    >
      <template #default="{ item, index }: { item: Track; index: number }">
        <div class="am-next-row" :class="{ current: index === statusStore.playIndex }">
          <button
            class="am-next-song"
            :aria-current="index === statusStore.playIndex ? 'true' : undefined"
            @click="playAt(index)"
          >
            <SImg :src="item.cover" class="am-next-art" />
            <span>
              <strong>{{ item.title }}</strong>
              <small>{{ formatArtists(item.artists) }}</small>
            </span>
          </button>
          <button
            class="am-icon"
            :aria-label="`${t('player.appleMusic.remove')}：${item.title}`"
            @click="removeAt(index)"
          >
            <IconLucideX />
          </button>
        </div>
      </template>
    </SVirtualList>
    <p v-else class="am-empty">{{ t("playlist.empty") }}</p>
  </section>
</template>

<style scoped>
.am-next {
  height: 100%;
  display: flex;
  flex-direction: column;
  min-height: 0;
}
header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 16px;
  padding: 16px 8px 24px;
}
h2 {
  margin: 0;
  font-size: 28px;
  font-weight: 700;
  letter-spacing: -0.6px;
}
header p {
  margin: 8px 0 0;
  color: #ffffffb8;
  font-size: 14px;
}
.am-next-list {
  flex: 1;
  min-height: 0;
}
.am-next-row {
  display: flex;
  align-items: center;
  border-radius: 12px;
  padding: 8px;
  gap: 4px;
}
.am-next-row.current {
  background: #ffffff20;
}
.am-next-song {
  display: flex;
  align-items: center;
  gap: 16px;
  flex: 1;
  min-width: 0;
  text-align: left;
  border: 0;
  color: inherit;
  background: none;
  cursor: pointer;
  padding: 0;
}
.am-next-art {
  width: 56px;
  height: 56px;
  border-radius: 8px;
  flex-shrink: 0;
}
.am-next-song span {
  min-width: 0;
}
strong,
small {
  display: block;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
strong {
  font-size: 17px;
  font-weight: 600;
}
small {
  margin-top: 5px;
  font-size: 14px;
  color: #ffffffb8;
}
.am-empty {
  margin: auto;
  color: #ffffffb8;
}
</style>
