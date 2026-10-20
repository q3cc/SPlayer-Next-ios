import type { NowPlayingSnapshot } from "@shared/types/nowPlaying";
import type { PlayerStatus } from "@shared/types/player";

/** Android uses its media notification for playback controls. */
export const mobileLyricPip = {
  configure(_snapshot: () => Promise<NowPlayingSnapshot>, _onPlayback: (playing: boolean) => void) {
    return;
  },
  preview: async (): Promise<string> => "",
  releasePreview: async (): Promise<void> => {},
  isOpen: async (): Promise<boolean> => false,
  onVisibility:
    (_callback: (open: boolean) => void): (() => void) =>
    () => {},
  sync: (_status: PlayerStatus, _force = false): void => {},
  update: async (): Promise<void> => {},
  close: async (): Promise<void> => {},
  toggle: async (): Promise<void> => {},
};
