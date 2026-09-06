import { searchSongs } from "@/apis/search";
import { resolveNeteaseUrl } from "@/apis/song/netease";
import * as player from "@/core/player";
import { useMediaStore } from "@/stores/media";
import { useStatusStore } from "@/stores/status";
import { useSettingsStore } from "@/stores/settings";
import { CURRENT_AGREEMENT_VERSION } from "@shared/constants/agreement";
import { mobileLyricPip } from "./lyricPip";
import { useSettingsDialog } from "@/settings/useSettingsDialog";
import type { PlayerStatus } from "@shared/types/player";

const delay = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/** 仅在手动 Actions 的模拟器测试构建启用，不随普通 IPA 暴露测试入口。 */
export const installPlaybackTest = async (): Promise<void> => {
  const settings = useSettingsStore();
  await settings.setSystem("system.diagnosticLogging", true);
  await settings.setSystem("system.onboardingCompleted", true);
  await settings.setSystem("system.agreedAgreementVersion", CURRENT_AGREEMENT_VERSION);
  location.hash = "#/";
  const panel = document.createElement("div");
  panel.style.cssText =
    "position:fixed;left:60px;top:90px;z-index:99999;display:flex;gap:8px;flex-wrap:wrap;max-width:700px;background:#182030;padding:12px;color:white";
  const report = document.createElement("span");
  report.textContent = "Playback test ready";
  report.setAttribute("role", "status");
  panel.append(report);
  const button = (label: string, action: () => Promise<void>): HTMLButtonElement => {
    const element = document.createElement("button");
    element.textContent = label;
    element.style.cssText = "background:white;color:black;padding:12px;border-radius:8px";
    element.onclick = async () => {
      element.disabled = true;
      try {
        await action();
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        console.error("[playback-test] failed", message);
        report.textContent = `Playback test failed: ${message}`;
      } finally {
        element.disabled = false;
      }
    };
    panel.append(element);
    return element;
  };
  button("Open Siri settings test", async () => {
    useSettingsDialog().show("siri");
    panel.style.top = "auto";
    panel.style.bottom = "10px";
  });
  button("Play Senbonzakura test", async () => {
    await settings.setSystem("player.equalizer.bands", [0, 0, 0, 0, 0, 6, 0, 0, 0, 0]);
    await settings.setSystem("player.equalizer.preamp", -6);
    await settings.setSystem("player.equalizer.enabled", true);
    console.info("[playback-test] native-equalizer-enabled", {
      frequency: 1000,
      gain: 6,
      preamp: -6,
    });
    const result = await searchSongs("netease", "千本樱", 0, 10);
    console.info("[playback-test] search-results", result.items.length);
    let selected = false;
    for (const track of result.items.filter((item) => /千本[樱桜櫻]/.test(item.title))) {
      const source = await resolveNeteaseUrl(track, "lq");
      if (!source.available || source.isTrial) {
        console.info(
          "[playback-test] unavailable",
          track.id,
          source.available ? "trial" : source.errorCode,
        );
        continue;
      }
      console.info("[playback-test] selected", {
        id: track.id,
        title: track.title,
        artists: track.artists.map((artist) => artist.name),
      });
      await player.playNow(track);
      selected = true;
      break;
    }
    if (!selected) throw new Error("千本樱搜索结果没有游客可完整播放的版本");
    useStatusStore().isPlayerExpanded = true;
    let firstPosition: number | undefined;
    for (let attempt = 0; attempt < 60; attempt++) {
      await delay(500);
      const result = await window.api.player.getStatus();
      const status = result.data;
      if (!status || status.state !== "playing" || status.position <= 0) continue;
      firstPosition ??= status.position;
      if (status.position - firstPosition < 3000 || !useMediaStore().parsedLyric.length) continue;
      console.info("[playback-test] playback-verified", {
        from: firstPosition,
        to: status.position,
        duration: status.duration,
        lyricLines: useMediaStore().parsedLyric.length,
      });
      report.textContent = "Song playback verified";
      return;
    }
    throw new Error("播放进度未持续前进，或真实歌词未加载");
  });
  button("Open lyric PiP test", async () => {
    await mobileLyricPip.toggle();
    for (let attempt = 0; attempt < 20; attempt++) {
      if (await mobileLyricPip.isOpen()) {
        report.textContent = "Lyric PiP opened";
        console.info("[playback-test] pip-opened");
        return;
      }
      await delay(250);
    }
    throw new Error("系统未确认画中画开启");
  });
  button("Verify pause resume test", async () => {
    await player.pause();
    const before = (await window.api.player.getStatus()).data;
    await delay(1500);
    const paused = (await window.api.player.getStatus()).data;
    if (
      !before ||
      paused?.state !== "paused" ||
      Math.abs(paused.position - before.position) > 250
    ) {
      throw new Error("暂停后进度仍在前进");
    }
    await player.play();
    await delay(2500);
    const resumed = (await window.api.player.getStatus()).data;
    if (resumed?.state !== "playing" || resumed.position <= paused.position + 1000) {
      throw new Error("恢复播放后进度未前进");
    }
    console.info("[playback-test] pause-resume-verified", {
      paused: paused.position,
      resumed: resumed.position,
    });
    report.textContent = "Pause resume verified";
  });
  let backgroundPosition = 0;
  button("Verify equalizer test", async () => {
    const bands = [15, -15, 1, 0, -3, 6, 2, -1, 4, -2];
    await settings.setSystem("player.equalizer.bands", bands);
    await settings.setSystem("player.equalizer.preamp", -6);
    await delay(500);
    type NativeStatus = PlayerStatus & {
      equalizer?: { enabled: boolean; bands: number[]; preamp: number };
    };
    const value = (await window.api.player.getStatus()).data as NativeStatus | undefined;
    if (
      value?.state !== "playing" ||
      !value.equalizer?.enabled ||
      value.equalizer.preamp !== -6 ||
      JSON.stringify(value.equalizer.bands) !== JSON.stringify(bands)
    ) {
      throw new Error("均衡器控件未改变原生音频节点");
    }
    await settings.setSystem("player.equalizer.enabled", false);
    const bypassed = (await window.api.player.getStatus()).data as NativeStatus | undefined;
    if (bypassed?.equalizer?.enabled !== false || bypassed.equalizer.preamp !== 0) {
      throw new Error("关闭均衡器后原生节点未旁路");
    }
    await settings.setSystem("player.equalizer.enabled", true);
    backgroundPosition = (await window.api.player.getStatus()).data?.position ?? 0;
    console.info("[playback-test] equalizer-live-update-verified", value.equalizer);
    report.textContent = "Equalizer playback verified";
  });
  button("Verify background audio test", async () => {
    const value = (await window.api.player.getStatus()).data;
    if (value?.state !== "playing" || value.position < backgroundPosition + 4000) {
      throw new Error("原生均衡器播放在后台停止或进度未前进");
    }
    console.info("[playback-test] equalizer-background-verified", {
      before: backgroundPosition,
      after: value.position,
    });
    report.textContent = "Background audio verified";
  });
  button("Close lyric PiP test", async () => {
    await mobileLyricPip.close();
    await delay(1500);
    if (await mobileLyricPip.isOpen()) throw new Error("关闭画中画失败");
    if ((await window.api.player.getStatus()).data?.state !== "playing")
      throw new Error("关闭小窗停止了音乐");
    report.textContent = "Playback test complete";
    console.info("[playback-test] complete");
  });
  document.body.append(panel);
};
