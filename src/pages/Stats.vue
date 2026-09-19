<script setup lang="ts">
defineOptions({ name: "Stats" });

import type {
  DailyPlayStats,
  HourlyPlayStats,
  PlayStatsSummary,
  TopAlbum,
  TopArtist,
  TopTrack,
} from "@shared/types/stats";
import { useFloatingPlayerBar } from "@/composables/useFloatingPlayerBar";

const { isFloatingBar } = useFloatingPlayerBar();

const summary = ref<PlayStatsSummary | null>(null);
const daily = ref<DailyPlayStats[]>([]);
const hourly = ref<HourlyPlayStats[]>([]);
const topSongs = shallowRef<TopTrack[]>([]);
const topAlbums = shallowRef<TopAlbum[]>([]);
const topArtists = shallowRef<TopArtist[]>([]);
const loading = ref(true);

onMounted(async () => {
  try {
    const [overview, history, hourlyHistory, songs, albums, artists] = await Promise.all([
      window.api.stats.getStatsSummary(),
      window.api.stats.getPlayHistoryDaily(90),
      window.api.stats.getPlayHistoryHourly(),
      window.api.stats.getTopTracks(10),
      window.api.stats.getTopAlbums(10),
      window.api.stats.getTopArtists(10),
    ]);
    summary.value = overview;
    daily.value = history;
    hourly.value = hourlyHistory;
    topSongs.value = songs;
    topAlbums.value = albums;
    topArtists.value = artists;
  } finally {
    loading.value = false;
  }
});
</script>

<template>
  <div class="h-full overflow-y-auto [scrollbar-gutter:stable]">
    <div
      class="mx-auto flex max-w-[1400px] flex-col gap-5 px-5 pt-2"
      :class="isFloatingBar ? 'pb-28' : 'pb-10'"
    >
      <!-- 全来源收听概览 -->
      <StatsOverview :stats="summary" />
      <!-- 聆听足迹、播放时段与音质构成 -->
      <StatsHeatmap :daily="daily" :hourly="hourly" :stats="summary" :loading="loading" />
      <!-- 最常听榜单 -->
      <StatsTopList
        :songs="topSongs"
        :albums="topAlbums"
        :artists="topArtists"
        :loading="loading"
      />
    </div>
  </div>
</template>
