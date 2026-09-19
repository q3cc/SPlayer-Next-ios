<script setup lang="ts">
import type { Component } from "vue";
import type { PlayStatsSummary } from "@shared/types/stats";
import IconLucideMusic from "~icons/lucide/music";
import IconLucideDisc3 from "~icons/lucide/disc-3";
import IconLucideUser from "~icons/lucide/user";
import IconLucideClock from "~icons/lucide/clock";
import IconLucideListRestart from "~icons/lucide/list-restart";

const props = defineProps<{
  /** 全来源收听统计概览 */
  stats: PlayStatsSummary | null;
}>();

const { t } = useI18n();

/** 概览卡片 */
interface OverviewCard {
  key: string;
  icon: Component;
  /** 主数字 */
  value: string;
  /** 主数字单位（h / m / GB） */
  unit?: string;
  /** 第二段数字 */
  value2?: string;
  /** 第二段数字单位 */
  unit2?: string;
}

/**
 * 总时长拆分为小时和分钟
 * @param ms - 总时长（毫秒）
 * @returns 小时与分钟
 */
const formatDurationParts = (ms: number): { hours: number; minutes: number } => {
  const totalMin = Math.floor(ms / 60000);
  return { hours: Math.floor(totalMin / 60), minutes: totalMin % 60 };
};

/** 顶部概览卡片 */
const overviewCards = computed<OverviewCard[]>(() => {
  const stats = props.stats;
  const duration = stats ? formatDurationParts(stats.totalListenedMs) : null;
  return [
    {
      key: "listenedSongs",
      icon: IconLucideMusic,
      value: stats ? String(stats.uniqueTrackCount) : "--",
    },
    {
      key: "listenedAlbums",
      icon: IconLucideDisc3,
      value: stats ? String(stats.uniqueAlbumCount) : "--",
    },
    {
      key: "listenedArtists",
      icon: IconLucideUser,
      value: stats ? String(stats.uniqueArtistCount) : "--",
    },
    duration
      ? {
          key: "totalListened",
          icon: IconLucideClock,
          value: String(duration.hours),
          unit: "h",
          value2: String(duration.minutes),
          unit2: "m",
        }
      : { key: "totalListened", icon: IconLucideClock, value: "--" },
    {
      key: "playCount",
      icon: IconLucideListRestart,
      value: stats ? String(stats.totalPlayCount) : "--",
    },
  ];
});
</script>

<template>
  <div class="grid grid-cols-2 gap-5 md:grid-cols-3 lg:grid-cols-5">
    <SCard
      v-for="card in overviewCards"
      :key="card.key"
      radius="xl"
      class="relative overflow-hidden"
    >
      <!-- 衬底图标 -->
      <component
        :is="card.icon"
        class="pointer-events-none absolute -right-2 -bottom-3 size-18 -rotate-14 text-primary/20"
      />
      <div class="relative flex h-full flex-col justify-between">
        <div class="flex items-baseline gap-0.5">
          <span class="text-3xl font-bold leading-none text-on-surface tabular-nums">
            {{ card.value }}
          </span>
          <span v-if="card.unit" class="text-sm font-medium text-on-surface-variant/70">
            {{ card.unit }}
          </span>
          <template v-if="card.value2 !== undefined">
            <span class="text-3xl font-bold leading-none text-on-surface tabular-nums">
              {{ card.value2 }}
            </span>
            <span v-if="card.unit2" class="text-sm font-medium text-on-surface-variant/70">
              {{ card.unit2 }}
            </span>
          </template>
        </div>
        <div class="truncate text-xs mt-1 text-on-surface-variant/50">
          {{ t(`stats.${card.key}`) }}
        </div>
      </div>
    </SCard>
  </div>
</template>
