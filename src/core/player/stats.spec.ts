import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { nextTick, reactive } from "vue";
import type { PlayerState, Track } from "@shared/types/player";

const mocks = vi.hoisted(() => ({
  media: null as unknown as { track: Track | null },
  status: null as unknown as { state: PlayerState },
  recordPlay: vi.fn(),
}));

vi.mock("@/stores/media", () => ({ useMediaStore: () => mocks.media }));
vi.mock("@/stores/status", () => ({ useStatusStore: () => mocks.status }));

beforeEach(() => {
  vi.resetModules();
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-09-19T08:00:00Z"));
  mocks.media = reactive({ track: null });
  mocks.status = reactive({ state: "idle" as PlayerState });
  mocks.recordPlay.mockReset();
  Object.defineProperty(window, "api", {
    configurable: true,
    value: { stats: { recordPlay: mocks.recordPlay } },
  });
});

afterEach(() => vi.useRealTimers());

describe("播放统计会话", () => {
  it("同一首歌补全音质后使用最新元数据落库", async () => {
    const stats = await import("./stats");
    stats.installPlayStats();

    mocks.media.track = {
      id: "1",
      source: "netease",
      title: "红豆",
      artists: [{ name: "方大同" }],
      duration: 240000,
    };
    await nextTick();
    mocks.status.state = "playing";
    await nextTick();

    mocks.media.track = {
      ...mocks.media.track,
      quality: { codec: "flac", sampleRate: 44100, channels: 2, bitsPerSample: 16, bitRate: 0 },
    };
    await nextTick();
    vi.advanceTimersByTime(6000);
    stats.onTrackEnded(false);

    expect(mocks.recordPlay).toHaveBeenCalledWith(
      expect.objectContaining({
        listenedMs: 6000,
        track: expect.objectContaining({ quality: expect.objectContaining({ codec: "flac" }) }),
      }),
    );
  });
});
