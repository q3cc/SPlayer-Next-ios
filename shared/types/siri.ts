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
}

export interface SiriStatus {
  authorization: "notDetermined" | "restricted" | "denied" | "authorized" | "missingEntitlement";
  enabled: boolean;
  lastResult: string;
}
