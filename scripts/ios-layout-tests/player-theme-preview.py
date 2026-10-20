"""在独立浏览器上下文中验证播放器主题；先启动 Vite mobile，再用 Python Playwright 运行。"""
import json
from pathlib import Path
from playwright.sync_api import sync_playwright

output = Path("dist-mobile/theme-evidence")
output.mkdir(parents=True, exist_ok=True)

with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True)
    context = browser.new_context(viewport={"width": 390, "height": 844}, locale="zh-CN")
    page = context.new_page()
    page.add_init_script("""(() => {
      let next = 0;
      window.__TAURI_INTERNALS__ = {
        transformCallback: () => ++next,
        unregisterCallback: () => {},
        invoke: async (command) => {
          if (command.startsWith('plugin:http|')) throw new Error('Offline preview');
          if (command === 'plugin:deep-link|get_current') return [];
          return command.endsWith('|airplay') ? {visible:false} : {};
        },
        convertFileSrc: value => value,
      };
    })()""")
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.route("**/*", lambda route: route.continue_() if route.request.url.startswith(("http://127.0.0.1:5173", "data:", "blob:")) else route.abort())
    page.goto("http://127.0.0.1:5173", wait_until="domcontentloaded")
    page.wait_for_function("document.querySelector('#app')?.__vue_app__?.config.globalProperties.$pinia", timeout=60000)
    page.evaluate("""async () => {
      const pinia = document.querySelector('#app').__vue_app__.config.globalProperties.$pinia;
      const { useSettingsStore } = await import('/src/stores/settings.ts');
      const { useStatusStore } = await import('/src/stores/status.ts');
      const { useMediaStore } = await import('/src/stores/media.ts');
      const { CURRENT_AGREEMENT_VERSION } = await import('/shared/constants/agreement.ts');
      const { setQueue } = await import('/src/stores/queue.ts');
      const clock = await import('/src/services/playback.ts');
      const settings = useSettingsStore(pinia), status = useStatusStore(pinia), media = useMediaStore(pinia);
      await settings.setSystem('onboardingCompleted', true);
      await settings.setSystem('agreedAgreementVersion', CURRENT_AGREEMENT_VERSION);
      await document.querySelector('#app').__vue_app__.config.globalProperties.$router.push('/');
      const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="600"><defs><radialGradient id="a"><stop stop-color="#ffbe87"/><stop offset="1" stop-color="#883769"/></radialGradient></defs><rect width="600" height="600" fill="#342657"/><circle cx="370" cy="230" r="300" fill="url(#a)"/><circle cx="160" cy="480" r="210" fill="#285b71"/><text x="40" y="90" fill="white" font-family="sans-serif" font-size="44">AFTER HOURS</text></svg>';
      const cover = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
      const track = { id: 'theme-preview', source: 'local', title: '晚风里的旋律', artists: [{id:'artist', name:'SPlayer Sessions'}], album: {id:'album', name:'After Hours'}, duration: 240000, cover, coverOriginal: cover };
      setQueue([track, {...track, id:'next-1', title:'城市入眠之后'}, {...track, id:'next-2', title:'留一点温柔给明天'}]);
      media.track = track;
      media.parsedLyric = ['让晚风轻轻经过', '把今天的心事慢慢说', '沿着灯火闪烁的街头', '还有一首歌 陪着我'].map((text, index) => ({
        startTime: index * 10000, endTime: (index + 1) * 10000, isBG:false, isDuet:false,
        translatedLyric:'', romanLyric:'', words: [...text].map((word,j)=>({word, startTime: index*10000+j*500, endTime:index*10000+(j+1)*500}))
      }));
      media.lyricLoading = false;
      status.playIndex = 0; status.state = 'paused'; status.position = 12000; status.duration = 240000;
      clock.setCurrentTime(12000);
      settings.player.theme = 'apple-music'; settings.player.playerBgType = 'animation'; status.isPlayerExpanded = true;
      window.themePreview = {settings, status, media, lines: media.parsedLyric};
    }""")
    page.wait_for_timeout(3000)
    page.screenshot(path=str(output / "boot.png"))
    page.locator(".apple-music-player h1").wait_for(timeout=10000)
    page.wait_for_timeout(2000)
    page.evaluate("window.themePreview.media.parsedLyric = window.themePreview.lines; window.themePreview.media.lyricLoading = false")
    page.get_by_role("button", name="更多歌曲操作", exact=True).click()
    page.get_by_role("menu").wait_for(state="visible")
    page.keyboard.press("Escape")
    for name, width, height, panel in [
        ("ipad-user-ratio", 1180, 820, "歌词"),
        ("ipad-landscape-lyrics", 1280, 800, "歌词"),
        ("ipad-short-lyrics", 1024, 600, None),
        ("ipad-portrait-cover", 820, 1180, "歌词"),
        ("phone-cover", 390, 844, None),
        ("phone-lyrics", 390, 844, "歌词"),
        ("phone-queue", 390, 844, "待播列表"),
        ("phone-small-queue", 320, 568, None),
    ]:
        page.set_viewport_size({"width": width, "height": height})
        page.wait_for_timeout(100)
        if panel and page.get_by_role("button", name="显示播放控制", exact=True).count():
            page.get_by_role("button", name="显示播放控制", exact=True).click()
        if panel:
            button = page.get_by_role("button", name=panel, exact=True)
            if name not in ("ipad-landscape-lyrics", "ipad-user-ratio") or button.get_attribute("aria-pressed") != "true":
                button.click()
        page.wait_for_timeout(700)
        if name == "phone-lyrics":
            page.get_by_role("button", name="隐藏播放控制", exact=True).click()
        page.screenshot(path=str(output / f"{name}.png"))
        if page.get_by_role("button", name="显示播放控制", exact=True).count():
            page.get_by_role("button", name="显示播放控制", exact=True).click()
        bounds = page.locator(".apple-music-player").bounding_box()
        assert bounds and round(bounds["width"]) == width and round(bounds["height"]) == height, page.locator('.apple-music-player').evaluate("e => ({rect:e.getBoundingClientRect().toJSON(), styles: Object.fromEntries(['width','max-width','transform','zoom','left','right','margin'].map(k=>[k,getComputedStyle(e).getPropertyValue(k)]))})")
        assert page.get_by_role("button", name="播放", exact=True).is_visible()
        assert page.get_by_role("button", name="待播列表", exact=True).bounding_box()["y"] < height - 40
        for state in ("playing", "paused"):
            page.evaluate("state => window.themePreview.status.state = state", state)
            page.wait_for_timeout(600)
            artwork = page.locator(".am-artwork > div").bounding_box()
            song = page.locator(".am-song").bounding_box()
            if width >= 900 or "cover" in name:
                assert artwork["y"] + artwork["height"] <= song["y"] - 12, (name, state, artwork, song)
            if width >= 900 or "cover" not in name:
                assert abs(artwork["width"] - artwork["height"]) < 2, (name, artwork)
            page.screenshot(path=str(output / f"{name}-{state}.png"))
    canvas_counts = []
    for _ in range(4):
        page.evaluate("window.themePreview.status.isPlayerExpanded = false")
        page.wait_for_timeout(500)
        assert page.locator(".apple-music-player canvas").count() == 0
        page.evaluate("window.themePreview.status.isPlayerExpanded = true")
        page.wait_for_timeout(1100)
        canvas_counts.append(page.locator(".apple-music-player canvas").count())
        assert canvas_counts[-1] == 1, canvas_counts
        page.evaluate("window.themePreview.settings.player.theme = 'original'")
        page.locator(".full-player").wait_for(state="visible")
        assert page.locator(".apple-music-player").count() == 0
        page.evaluate("window.themePreview.settings.player.theme = 'apple-music'")
        page.locator(".apple-music-player").wait_for(state="visible")
    page.evaluate("window.themePreview.settings.player.theme = 'original'")
    page.locator(".full-player").wait_for(state="visible")
    assert page.locator(".apple-music-player").count() == 0
    assert page.evaluate("window.themePreview.status.position") == 12000
    page.screenshot(path=str(output / "original-restored.png"))
    print(json.dumps({"screenshots": str(output), "pageErrors": errors, "canvasCountsAfterReopen": canvas_counts}))
    context.close()
    browser.close()
    assert not errors, errors
