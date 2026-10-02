# Using Plugins

Plugins can extend **music sources** (resolve playable track URLs) and **control** (react to playback and control the player). This page is for plugin users. Authors should start with [Plugin Development](/en/plugins/).

## Opening plugin management

Open **Settings → Plugin Management**. Each installed plugin card shows its name, version, author, runtime state, and supported sources.

## Installing a plugin

- **Local import:** Select a `.js` file.
- **Import from URL:** Paste an `http(s)` URL to a `.js` file, such as a GitHub or Gitee raw URL.

Scripts distributed with a `gz_` prefix are detected and decompressed automatically.

## Enable, disable, and uninstall

- Newly installed plugins are enabled automatically.
- Multiple plugins may be enabled at once. If several support the same source, SPlayer-Next selects one by priority.
- A control plugin can expose settings from its plugin card.
- **Uninstalling deletes the script and its local data and cannot be undone.**

States are **Imported**, **Loading**, **Available**, **Failed to load** (with a reason), and **Disabled**. Importing saves the script; a script that initializes over the network remains loading until initialization completes.

## LX plugin compatibility

SPlayer-Next supports [lx-music-desktop](https://github.com/lyswhut/lx-music-desktop) `user_api` scripts. Most public LX scripts can be imported directly, though scripts using uncommon or newer LX APIs may fail to load.

### Custom sources on iOS / Android

Use **Settings → Plugin Management** to import a local script or an HTTPS script URL, not a GitHub repository or preview page. Local development URLs may use HTTP.

[pdone/lx-music-source](https://github.com/pdone/lx-music-source) lists several independent scripts and their direct URLs. They are not bundled or automatically installed. Check their provenance and usage requirements before importing.

- Playback integration covers NetEase, QQ Music, and Kugou tracks. Additional platforms declared by a script do not add search providers.
- Multiple sources remain supported: official full tracks first, enabled plugins in the configured order next, and permitted previews last.
- **Available** means initialization completed, not that every remote service, track, or quality works.
- LX update alerts never replace code automatically. Open the update page and import the new script manually. Reimporting the same identity preserves its enabled state and settings.
- Mobile scripts receive `lx.env = "mobile"`; the protocol version stays `2.0.0`. Running custom sources inside Siri's background runtime is not included.

Initialization timeouts can indicate an unreachable script service. Invalid keys, rate limits, and unavailable services must be resolved with the source author; reimporting cannot repair those services.

## Troubleshooting

**Why does the plugin show Failed to load?**

Read the error shown on its card. Common causes are syntax/runtime errors or an API level newer than the installed app supports.

**Can a plugin crash the app?**  
Plugins run in an isolated host process. Failures are contained and the host is restarted automatically.

**Why are plugin requests slow?**  
Plugin network requests follow the system proxy. Performance depends on the destination and network conditions.
