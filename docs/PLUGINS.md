# Writing OBSpad plugins

OBSpad plugins are small web packages: a manifest, plus JavaScript and HTML that run in a sandbox
inside the app. They work on both Android and iPad, and users install them by pasting a GitHub link or
picking a `.zip`.

Desktop OBS plugins (C/C++ built against libobs, like DistroAV or Move Transition) can't run on tablets.
iPadOS and Google Play don't allow downloaded native code, and this app isn't built on libobs. Features
that need native code, like NDI, ship as **built-in plugins** instead.

## Repos and zips without a manifest

Most "OBS plugins" on GitHub have no `obspad-plugin.json`. OBSpad converts them when they're installed
(from a GitHub link or a `.zip`):

| What's in the package | What OBSpad makes of it |
| --- | --- |
| `.html` pages (overlays, widgets, alerts) | **Overlays**: Add Source › From plugins adds a Browser source showing the page |
| `.html` pages named like `dock`, `panel`, `control`, `remote`, `dashboard` | **Docks**, opened from the Plugins screen |
| `.cube` files (or PNG LUTs in a `lut`/`luts` folder) | **LUTs** in the Apply LUT filter's plugin menu |
| Images and videos, when there are no web pages (overlay and stinger packs) | **Media**: Add Source › From plugins adds an Image or Media source |
| C/C++ code, `.dll`/`.so`/`.dylib`, Lua or Python scripts, shader effects | Not installable: they only run inside OBS Studio on a computer |

If a release's `.zip` asset is a desktop build, OBSpad installs the release's source code instead.
`node_modules`, `.git` and compiled binaries are left out. Add an `obspad-plugin.json` to control names,
sizes and permissions yourself.

## What a plugin can do

- **Sources:** draw on a canvas and show up in scenes like any other source (overlays, alerts, chat,
  timers, scoreboards, tickers).
- **Docks:** full HTML panels the user opens from the Plugins screen (control panels, chat readers,
  macro buttons).
- **Network** (with the `network` permission): use `fetch`, WebSockets and remote images. Without the
  permission, the sandbox blocks all connections.
- **Control** (with the `control` permission): switch scenes, show/hide sources, and start/stop
  streaming and recording.

## Layout

```
my-plugin/
  obspad-plugin.json   # required
  main.js                  # required if the plugin has sources
  dock.html                # optional, one per dock
  assets/...               # anything else (images, fonts)
```

The plugin can be the whole repository, or a folder inside one. Users can link to a folder:
`https://github.com/you/plugins/tree/main/my-plugin`.

## Manifest: `obspad-plugin.json`

```json
{
  "id": "com.example.scoreboard",
  "name": "Scoreboard",
  "version": "1.0.0",
  "description": "Two-team scoreboard overlay",
  "author": "You",
  "homepage": "https://github.com/you/scoreboard",
  "minAppVersion": "1.0.0",
  "main": "main.js",
  "permissions": ["control"],
  "sources": [{
    "type": "scoreboard",
    "name": "Scoreboard",
    "width": 1200, "height": 160, "fps": 5,
    "settings": [
      {"key": "home", "label": "Home team", "type": "text", "default": "HOME"},
      {"key": "homeScore", "label": "Home score", "type": "number", "default": 0, "min": 0, "max": 999},
      {"key": "dark", "label": "Dark style", "type": "bool", "default": true},
      {"key": "accent", "label": "Accent", "type": "color", "default": 4282870743},
      {"key": "size", "label": "Size", "type": "select", "default": "M", "options": ["S", "M", "L"]}
    ]
  }],
  "docks": [{"id": "panel", "name": "Score panel", "page": "dock.html"}]
}
```

| Field | Notes |
| --- | --- |
| `id` | Reverse-DNS style, lowercase, unique. Updates replace the plugin with the same id. |
| `version` | Semantic version. "Check for update" installs a newer version from the latest GitHub release (or default branch). |
| `permissions` | `network` and/or `control`. The user sees these before installing. |
| `sources[].width/height` | Canvas size in pixels (the default size in the scene). |
| `sources[].fps` | Maximum frames per second the plugin can present (1 to 30). Use the lowest that looks right. |
| `settings[].type` | `text`, `number` (`min`/`max`), `bool`, `color` (ARGB integer, e.g. `4294967295` = white), `select` (`options`). The app builds the properties form for you. |

## The `obstablet` API

```js
obstablet.registerSource('scoreboard', {
  create(ctx) {
    // ctx.canvas   HTMLCanvasElement, ctx.width x ctx.height
    // ctx.settings current values of the manifest settings
    const g = ctx.canvas.getContext('2d');
    const draw = () => {
      g.clearRect(0, 0, ctx.width, ctx.height);   // transparent = see-through on stream
      g.fillStyle = '#fff';
      g.font = 'bold 80px sans-serif';
      g.fillText(`${ctx.settings.home} ${ctx.settings.homeScore}`, 40, 110);
      ctx.present();                             // show it (throttled to the source fps)
    };
    draw();
    ctx.onSettings(draw);                         // user changed the properties
  },
  destroy(ctx) { /* stop timers, close sockets */ },
});

obstablet.on('sceneChanged', e => obstablet.log('now on', e.name));
obstablet.on('streamingChanged', e => {});        // {active: bool}
obstablet.on('recordingChanged', e => {});        // {active: bool}

const state = await obstablet.getState();         // {scenes, programScene, streaming, recording}

// Needs the "control" permission:
await obstablet.control.switchScene('Be Right Back');
await obstablet.control.setSourceVisible('Webcam', false /*, 'Scene name' */);
await obstablet.control.startStreaming();       // also stopStreaming, startRecording, stopRecording
```

- One source type can have many instances (one per source the user adds). Keep per-instance state on
  `ctx`.
- Only call `ctx.present()` when something changed; each call converts the canvas to an image.
- Docks get the same `obstablet` object (except `registerSource`).
- `obstablet.log()`, console messages and errors appear under **Plugins → Log**.

## Publishing

1. Push the plugin to a public GitHub repository.
2. Optionally create a release (tag `v1.0.0`). Installs and updates follow the latest release. A `.zip`
   asset on the release is used if present; otherwise the release's source zip.
3. Share the link. Users paste it in **Plugins → Get plugins**. To appear in the built-in catalog, add
   an entry to `plugins/catalog.json` in the OBSpad repository (or host your own catalog: the app's
   catalog URL is configurable).

## Testing in a browser

Plugins are plain web code, so you can develop them in any browser. Paste this stand-in for the app
bridge into the page before loading `lib/plugins/plugin_runtime_js.dart`'s script and your `main.js`:

```js
window.flutter_inappwebview = { callHandler: (name, msg) => console.log(JSON.parse(msg)) };
```

Then call `__obst.create('test', 'scoreboard', {home: 'HOME', homeScore: 3}, 1200, 160, 5)`.

## Examples

See `plugins/` in this repository:
- **clock**: a minimal source.
- **twitch-chat**: network access plus WebSockets.
- **scene-rotator**: a dock using `control`.
