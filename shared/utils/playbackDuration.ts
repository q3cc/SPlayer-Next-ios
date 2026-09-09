/** 优先实际音源时长，曲库整首时长仅在引擎尚未读出时兜底。单位：毫秒。 */
export const playbackDuration = (audio: number | undefined, catalog = 0): number =>
  typeof audio === "number" && Number.isFinite(audio) && audio > 0 ? audio : catalog;
