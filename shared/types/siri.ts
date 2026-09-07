import type { Track } from "./player";
import type { Platform } from "./platform";

export interface SiriSettings {
  enabled: boolean;
  source: "current" | Platform;
  searchScope: "online" | "local" | "localFirst";
  askBeforePlaying: boolean;
}

export interface SiriSnapshot {
  revision: number;
  queue: Track[];
  currentId: string | null;
  position: number;
  playing: boolean;
  pending?: boolean;
  repeatMode?: "list" | "one" | null;
  shuffleMode?: "on" | "off" | null;
}

export interface SiriStatus {
  authorization: "notDetermined" | "restricted" | "denied" | "authorized" | "missingEntitlement";
  enabled: boolean;
  lastResult: string;
}

/** Siri 内部候选，同曲的多平台音源不写入公共 Track。 */
export interface SiriSongGroup {
  key: string;
  tracks: Track[];
}

export interface SiriArtistCursor {
  source: Platform;
  artistId?: string;
  offset: number;
  done: boolean;
  lastPage?: string;
}

export interface SiriArtistCollection {
  artist: string;
  cursors: SiriArtistCursor[];
  seen: string[];
}

export interface SiriSearchResult {
  tracks: Track[];
  groups: SiriSongGroup[];
  needsConfirmation: boolean;
  collection?: SiriArtistCollection;
  pageFailed?: boolean;
}
