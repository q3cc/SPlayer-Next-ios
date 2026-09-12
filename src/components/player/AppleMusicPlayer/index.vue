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
import { getQualityLabel, isLosslessQuality } from "@/utils/quality";
import { isIOS } from "@/utils/config";
import * as player from "@/core/player";
import AMLLLyrics from "../Lyrics/AMLLLyrics.vue";
import PlayerBackground from "../FullPlayer/PlayerBackground.vue";
import PlayerCover from "../FullPlayer/PlayerCover.vue";
import AirPlayControl from "../AirPlayControl.vue";
import VolumeControl from "../VolumeControl.vue";
import PlayingNext from "./PlayingNext.vue";
import PlaylistPickerDialog from "@/components/modals/PlaylistPickerDialog.vue";
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
const controlsVisible = ref(false);
const immersive = computed(() => !wide.value && panel.value === "lyrics" && !controlsVisible.value);
const lyrics = ref<InstanceType<typeof AMLLLyrics>>();
const root = ref<HTMLElement>();
const track = computed(() => media.track ?? status.currentTrack);
const sourceLabel = computed(() =>
  track.value?.cloud ? "CLOUD" : (track.value?.source ?? "local").toUpperCase(),
);
const artist = computed(
  () => track.value?.artists?.map((value) => value.name).join(" / ") || t("playlist.unknownArtist"),
);
const visible = computed(() => status.isPlayerExpanded && visibility.value === "visible");
const showLyrics = computed(
  () => visible.value && panel.value === "lyrics" && media.parsedLyric.length > 0,
);
const initialTime = ref(getCurrentTime() + status.lyricOffsetMs);
const favorite = useFavorite();
const quality = computed(() => media.detail?.quality ?? track.value?.quality);
const { snapToNearestLyric } = useProgressLyric();
const {
  open: pickerOpen,
  tracks: pickerTracks,
  mode: pickerMode,
  openPicker,
} = usePlaylistPicker();
const { enqueue } = useDownload();
const equalizerOpen = ref(false);
const speedOpen = ref(false);
const abLoopOpen = ref(false);
const autoCloseOpen = ref(false);
const fmModeOpen = ref(false);
const copyLyricsOpen = ref(false);
const { items: trackMenuItems, handleSelect } = useTrackMenu(track, {
  hidePlayActions: true,
  canRemove: false,
  onAddToPlaylist: (value) => openPicker([value]),
  onDownload: (value, quality) => {
    void enqueue(value, quality ? { quality } : {});
  },
});
const menuItems = computed(() => [
  {
    key: "am-favorite",
    label: t(
      favorite.isLiked(track.value) ? "player.appleMusic.unfavorite" : "player.appleMusic.favorite",
    ),
    disabled: !track.value || !favorite.isSupported(track.value),
  },
  ...unref(trackMenuItems),
  { key: "am-desktop-lyric", label: t("settings.section.desktopLyric"), separator: true },
  {
    key: "am-copy-lyrics",
    label: t("player.copyLyric.title"),
    disabled: !media.parsedLyric.length,
  },
  { key: "am-equalizer", label: t("equalizer.title") },
  { key: "am-speed", label: t("speed.title") },
  { key: "am-ab-loop", label: t("abLoop.title") },
  { key: "am-auto-close", label: t("autoClose.title") },
  { key: "am-fm", label: t("player.fm.modeTooltip"), show: status.fmMode },
]);
const selectMenu = (key: string): void => {
  if (key === "am-favorite") favorite.toggle(track.value);
  else if (key === "am-desktop-lyric") void window.api.window.toggleDesktopLyric().catch(() => {});
  else if (key === "am-copy-lyrics") copyLyricsOpen.value = true;
  else if (key === "am-equalizer") equalizerOpen.value = true;
  else if (key === "am-speed") speedOpen.value = true;
  else if (key === "am-ab-loop") abLoopOpen.value = true;
  else if (key === "am-auto-close") autoCloseOpen.value = true;
  else if (key === "am-fm") fmModeOpen.value = true;
  else void handleSelect(key);
};

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
const dragOffset = ref(0);
const dragging = ref(false);
let dismissGesture: { id: number; x: number; y: number; time: number } | undefined;
let suppressHandleClick = false;

/** 手势仅从顶部栏开始，方向锁定后才接管指针。 */
const startDismiss = (event: PointerEvent): void => {
  if (!event.isPrimary || event.button !== 0) return;
  dismissGesture = {
    id: event.pointerId,
    x: event.clientX,
    y: event.clientY,
    time: event.timeStamp,
  };
  suppressHandleClick = false;
};
const moveDismiss = (event: PointerEvent): void => {
  const gesture = dismissGesture;
  if (!gesture || gesture.id !== event.pointerId) return;
  const dx = event.clientX - gesture.x;
  const dy = event.clientY - gesture.y;
  if (!dragging.value) {
    if (Math.max(Math.abs(dx), Math.abs(dy)) < 8) return;
    suppressHandleClick = true;
    if (dy <= 0 || Math.abs(dx) > dy) {
      dismissGesture = undefined;
      return;
    }
    dragging.value = true;
    (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
  }
  dragOffset.value = Math.max(0, dy);
};
const endDismiss = (event: PointerEvent): void => {
  const gesture = dismissGesture;
  if (!gesture || gesture.id !== event.pointerId) return;
  const distance = Math.max(0, event.clientY - gesture.y);
  const velocity = distance / Math.max(1, event.timeStamp - gesture.time);
  const shouldClose = dragging.value && (distance >= 80 || (distance >= 24 && velocity >= 0.6));
  dismissGesture = undefined;
  dragging.value = false;
  if (shouldClose) close();
  else dragOffset.value = 0;
};
const cancelDismiss = (): void => {
  dismissGesture = undefined;
  dragging.value = false;
  dragOffset.value = 0;
};
const guardHandleClick = (event: MouseEvent): void => {
  if (suppressHandleClick && event.detail !== 0) {
    event.preventDefault();
    event.stopPropagation();
  }
  suppressHandleClick = false;
};
const togglePanel = (value: "lyrics" | "queue"): void => {
  panel.value = panel.value === value ? "cover" : value;
};
</script>

<template>
  <Teleport to="body">
    <Transition name="am-player" @after-leave="cancelDismiss">
      <section
        v-if="status.isPlayerExpanded"
        ref="root"
        class="apple-music-player"
        :class="{
          'am-wide': wide,
          'am-details': panel !== 'cover',
          'am-immersive': immersive,
          'am-dragging': dragging,
        }"
        :style="{ '--am-drag-offset': `${dragOffset}px` }"
        role="dialog"
        data-fullscreen
        aria-modal="true"
        :aria-label="t('player.appleMusic.nowPlaying')"
        tabindex="-1"
        @keydown.esc.stop="close"
      >
        <PlayerBackground :active="visible" :reduced-motion="reducedMotion" />
        <div class="am-shade" aria-hidden="true" />
        <header
          class="am-header"
          @pointerdown="startDismiss"
          @pointermove="moveDismiss"
          @pointerup="endDismiss"
          @pointercancel="cancelDismiss"
          @lostpointercapture="dismissGesture && cancelDismiss()"
          @click.capture="guardHandleClick"
        >
          <button
            type="button"
            class="am-handle"
            :aria-label="t('player.appleMusic.close')"
            @click="close"
          >
            <span aria-hidden="true" />
          </button>
        </header>
        <div class="am-body">
          <div class="am-record">
            <div class="am-artwork"><PlayerCover /></div>
            <div class="am-song">
              <div class="am-song-text">
                <h1 :title="track?.title">
                  <span class="am-title">{{ track?.title || t("player.appleMusic.noTrack") }}</span>
                  <span v-if="track" class="am-source">{{ sourceLabel }}</span>
                </h1>
                <p :title="artist">{{ track ? artist : t("player.appleMusic.nowPlaying") }}</p>
              </div>
              <SDropdownMenu :items="menuItems" align="end" @select="selectMenu">
                <template #trigger>
                  <button
                    class="am-icon am-more"
                    :disabled="!track"
                    :aria-label="t('player.appleMusic.more')"
                  >
                    <IconLucideEllipsis />
                  </button>
                </template>
              </SDropdownMenu>
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
          <div v-show="!immersive" class="am-controls">
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
                <span v-if="quality" class="am-quality">
                  <IconSpLossless v-if="isLosslessQuality(quality)" />
                  {{ getQualityLabel(quality) }}
                </span>
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
                <IconMaterialSymbolsFastRewindRounded />
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
                <IconMaterialSymbolsFastForwardRounded />
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
          </div>
        </div>
        <footer v-show="!immersive" class="am-footer">
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
        <button
          v-if="!wide && panel === 'lyrics'"
          class="am-icon am-reveal"
          :aria-label="
            t(immersive ? 'player.appleMusic.showControls' : 'player.appleMusic.hideControls')
          "
          @click="controlsVisible = !controlsVisible"
        >
          <IconLucideChevronUp v-if="immersive" />
          <IconLucideChevronDown v-else />
        </button>
      </section>
    </Transition>
    <PlaylistPickerDialog v-model:open="pickerOpen" :mode="pickerMode" :tracks="pickerTracks" />
    <EqualizerDialog v-if="equalizerOpen" v-model:open="equalizerOpen" />
    <SpeedDialog v-if="speedOpen" v-model:open="speedOpen" />
    <AbLoopDialog v-if="abLoopOpen" v-model:open="abLoopOpen" />
    <AutoCloseDialog v-if="autoCloseOpen" v-model:open="autoCloseOpen" />
    <FmModeDialog v-if="fmModeOpen" v-model:open="fmModeOpen" />
    <CopyLyricsDialog v-if="copyLyricsOpen" v-model:open="copyLyricsOpen" />
  </Teleport>
</template>
