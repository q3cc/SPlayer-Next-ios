<script setup lang="ts">
import { useSettingsStore } from "@/stores/settings";
import { useStatusStore } from "@/stores/status";
import { useMediaStore } from "@/stores/media";
import { usePlaybackTime } from "@/composables/usePlaybackTime";
import { useProgressLyric } from "@/composables/useProgressLyric";
import { useFavorite } from "@/composables/useFavorite";
import { usePlaylistPicker } from "@/composables/usePlaylistPicker";
import { useDownload } from "@/composables/useDownload";
import { useTrackMenu } from "@/composables/useTrackMenu";
import { getCurrentTime } from "@/services/playback";
import { formatTime } from "@/utils/time";
import { isIOS } from "@/utils/config";
import * as player from "@/core/player";
import AMLLLyrics from "../Lyrics/AMLLLyrics.vue";
import BackgroundRender from "../FullPlayer/BackgroundRender.vue";
import PlayerCover from "../FullPlayer/PlayerCover.vue";
import AirPlayControl from "../AirPlayControl.vue";
import VolumeControl from "../VolumeControl.vue";
import PlayingNext from "./PlayingNext.vue";
import PlaylistPickerDialog from "@/components/modals/PlaylistPickerDialog.vue";
import DEFAULT_COVER from "@/assets/images/song.jpg";
import "./style.css";

const emit = defineEmits<{ lyricsVisible: [visible: boolean] }>();
const { t } = useI18n();
const settings = useSettingsStore();
const status = useStatusStore();
const media = useMediaStore();
const wide = useMediaQuery("(min-width: 900px)");
const reducedMotion = useMediaQuery("(prefers-reduced-motion: reduce)");
const visibility = useDocumentVisibility();
const panel = ref<"cover" | "lyrics" | "queue">(wide.value ? "lyrics" : "cover");
const lyrics = ref<InstanceType<typeof AMLLLyrics>>();
const root = ref<HTMLElement>();
const track = computed(() => media.track ?? status.currentTrack);
const artist = computed(
  () => track.value?.artists?.map((value) => value.name).join(" / ") || t("playlist.unknownArtist"),
);
const visible = computed(() => status.isPlayerExpanded && visibility.value === "visible");
const showLyrics = computed(
  () => visible.value && panel.value === "lyrics" && media.parsedLyric.length > 0,
);
const initialTime = ref(getCurrentTime() + status.lyricOffsetMs);
const favorite = useFavorite();
const { snapToNearestLyric } = useProgressLyric();
const {
  open: pickerOpen,
  tracks: pickerTracks,
  mode: pickerMode,
  openPicker,
} = usePlaylistPicker();
const { enqueue } = useDownload();
const { items: menuItems, handleSelect } = useTrackMenu(track, {
  hidePlayActions: true,
  canRemove: false,
  onAddToPlaylist: (value) => openPicker([value]),
  onDownload: (value, quality) => {
    void enqueue(value, quality ? { quality } : {});
  },
});

const { start, stop } = usePlaybackTime((time) => {
  if (!status.trackLoading && !media.lyricLoading)
    lyrics.value?.setCurrentTime(time + status.lyricOffsetMs, player.isSeeking());
});
watch(
  [showLyrics, lyrics],
  ([shown]) => {
    stop();
    if (shown) {
      initialTime.value = getCurrentTime() + status.lyricOffsetMs;
      lyrics.value?.setCurrentTime(initialTime.value, true);
      lyrics.value?.resume();
      start();
    } else lyrics.value?.freeze();
    emit("lyricsVisible", shown);
  },
  { immediate: true, flush: "post" },
);

let previousFocus: HTMLElement | null = null;
watch(
  () => status.isPlayerExpanded,
  async (expanded) => {
    if (expanded) {
      previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
      await nextTick();
      root.value?.focus({ preventScroll: true });
    } else {
      stop();
      previousFocus?.focus({ preventScroll: true });
    }
  },
  { immediate: true },
);
onBeforeUnmount(() => {
  stop();
  emit("lyricsVisible", false);
});

const seek = async (time: number): Promise<void> => {
  await player.seek(snapToNearestLyric(time));
};
const seekLyric = async (time: number): Promise<void> => {
  await player.seek(time);
  if (!status.isPlaying) await player.play();
};
const close = (): void => {
  status.isPlayerExpanded = false;
};
const togglePanel = (value: "lyrics" | "queue"): void => {
  panel.value = panel.value === value ? "cover" : value;
};
</script>

<template>
  <Teleport to="body">
    <Transition name="am-player">
      <section
        v-if="status.isPlayerExpanded"
        ref="root"
        class="apple-music-player"
        :class="{ 'am-wide': wide, 'am-details': panel !== 'cover' }"
        role="dialog"
        data-fullscreen
        aria-modal="true"
        :aria-label="t('player.appleMusic.nowPlaying')"
        tabindex="-1"
        @keydown.esc.stop="close"
      >
        <BackgroundRender
          :album="track?.cover || DEFAULT_COVER"
          :active="visible"
          :playing="status.isPlaying && !reducedMotion"
          :fps="settings.player.playerBgFps"
          :render-scale="settings.player.playerBgRenderScale"
          :flow-speed="settings.player.playerBgFlowSpeed"
          :has-lyric="media.parsedLyric.length > 0"
        />
        <div class="am-shade" aria-hidden="true" />
        <header class="am-header">
          <button class="am-icon" :aria-label="t('player.appleMusic.close')" @click="close">
            <IconLucideChevronDown />
          </button>
          <span class="am-handle" aria-hidden="true" />
          <span class="am-context">{{ t("player.appleMusic.nowPlaying") }}</span>
          <SDropdownMenu :items="menuItems" align="end" @select="handleSelect">
            <template #trigger>
              <button class="am-icon" :disabled="!track" :aria-label="t('player.appleMusic.more')">
                <IconLucideEllipsis />
              </button>
            </template>
          </SDropdownMenu>
        </header>
        <div class="am-body">
          <div class="am-record">
            <div class="am-artwork"><PlayerCover /></div>
            <div class="am-song">
              <div class="am-song-text">
                <h1 :title="track?.title">{{ track?.title || t("player.appleMusic.noTrack") }}</h1>
                <p :title="artist">{{ track ? artist : t("player.appleMusic.nowPlaying") }}</p>
              </div>
              <button
                class="am-icon am-favorite"
                :disabled="!track || !favorite.isSupported(track)"
                :aria-pressed="favorite.isLiked(track)"
                :aria-label="
                  t(
                    favorite.isLiked(track)
                      ? 'player.appleMusic.unfavorite'
                      : 'player.appleMusic.favorite',
                  )
                "
                @click="favorite.toggle(track)"
              >
                <IconLucideStar :class="{ 'am-filled': favorite.isLiked(track) }" />
              </button>
            </div>
          </div>
          <div v-if="panel !== 'cover'" class="am-detail-panel">
            <PlayingNext v-if="panel === 'queue'" />
            <AMLLLyrics
              v-else-if="showLyrics"
              ref="lyrics"
              :lyric-lines="media.parsedLyric"
              :initial-time="initialTime"
              :playing="status.isPlaying"
              :align-position="0.35"
              enable-blur
              :show-translation="settings.lyric.showTranslation"
              :show-line-romanization="settings.lyric.amllShowLineRomanization"
              :show-word-romanization="settings.lyric.amllShowWordRomanization"
              @seek="seekLyric"
            />
            <div v-else class="am-empty">
              <IconLucideMusic2 />
              <p>
                {{
                  t(
                    media.lyricLoading
                      ? "player.appleMusic.loadingLyrics"
                      : "player.appleMusic.noLyrics",
                  )
                }}
              </p>
            </div>
          </div>
          <div class="am-controls">
            <div class="am-progress">
              <SSlider
                :model-value="status.position"
                :max="status.duration || 1"
                :step="100"
                :disabled="!track || !status.duration"
                :always-show-thumb="false"
                :show-popover="false"
                :track-height="5"
                cover
                :aria-label="t('player.appleMusic.progress')"
                @drag-end="seek"
              />
              <div class="am-times">
                <span>{{ formatTime(status.position) }}</span>
                <span>−{{ formatTime(Math.max(0, status.duration - status.position)) }}</span>
              </div>
            </div>
            <div class="am-transport">
              <button
                class="am-icon am-mode"
                :disabled="status.fmMode"
                :aria-pressed="status.shuffleMode === 'on'"
                :aria-label="t(`player.shuffleMode.${status.shuffleMode}`)"
                @click="player.toggleShuffleMode()"
              >
                <IconLucideShuffle />
              </button>
              <button
                class="am-icon am-skip"
                :disabled="!track || status.fmMode"
                :aria-label="t('player.prev')"
                @click="player.prevTrack()"
              >
                <IconMaterialSymbolsSkipPreviousRounded />
              </button>
              <button
                class="am-icon am-play"
                :disabled="!track"
                :aria-busy="status.isLoading"
                :aria-label="
                  t(status.isPlaying ? 'player.appleMusic.pause' : 'player.appleMusic.play')
                "
                @click="player.togglePlay()"
              >
                <IconLucideLoaderCircle v-if="status.isLoading" class="am-loading" />
                <IconMaterialSymbolsPauseRounded v-else-if="status.isPlaying" />
                <IconMaterialSymbolsPlayArrowRounded v-else />
              </button>
              <button
                class="am-icon am-skip"
                :disabled="!track"
                :aria-label="t('player.next')"
                @click="player.nextTrack()"
              >
                <IconMaterialSymbolsSkipNextRounded />
              </button>
              <button
                class="am-icon am-mode"
                :disabled="status.fmMode"
                :aria-pressed="status.repeatMode === 'one'"
                :aria-label="t(`player.repeatMode.${status.repeatMode}`)"
                @click="player.cycleRepeatMode()"
              >
                <IconLucideRepeat1 v-if="status.repeatMode === 'one'" />
                <IconLucideRepeat2 v-else />
              </button>
            </div>
            <div class="am-volume">
              <VolumeControl cover />
              <SSlider
                :model-value="status.volume"
                :max="1"
                :step="0.01"
                :always-show-thumb="false"
                :show-popover="false"
                cover
                :aria-label="t('player.appleMusic.volume')"
                @change="player.setVolume($event)"
              />
              <IconLucideVolume2 aria-hidden="true" />
            </div>
            <footer class="am-footer">
              <button
                class="am-icon"
                :aria-pressed="panel === 'lyrics'"
                :aria-label="t('player.appleMusic.lyrics')"
                @click="togglePanel('lyrics')"
              >
                <IconLucideMessageSquareQuote />
              </button>
              <AirPlayControl v-if="isIOS" cover class="am-airplay" />
              <button
                v-else
                class="am-icon"
                :aria-pressed="panel === 'cover'"
                :aria-label="t('player.appleMusic.cover')"
                @click="panel = 'cover'"
              >
                <IconLucideDisc3 />
              </button>
              <button
                class="am-icon"
                :aria-pressed="panel === 'queue'"
                :aria-label="t('player.appleMusic.queue')"
                @click="togglePanel('queue')"
              >
                <IconLucideListMusic />
              </button>
            </footer>
          </div>
        </div>
      </section>
    </Transition>
    <PlaylistPickerDialog v-model:open="pickerOpen" :mode="pickerMode" :tracks="pickerTracks" />
  </Teleport>
</template>
