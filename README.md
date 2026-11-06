# mic-helper

A small helper that watches your microphone level and tells you when you've
**gone quiet**, so you can speak up before people have to ask.

It learns your normal speaking level, then warns you when you're still talking
but your level has dropped well below that normal. It also warns when the mic
stops picking up anything at all. Audio is never recorded or sent anywhere.
Only the level is measured.

There are two versions:

| | `mac/`: native menu bar app | `web/`: no-install browser version |
|---|---|---|
| Install | Build once (needs Xcode command line tools) | Nothing. Open a web page |
| Lives in | Menu bar icon with live level bar | Small always-on-top mini window (Chrome/Edge) |
| Alert | Icon turns orange + "Speak up", click-through pill under the menu bar (works over full-screen Zoom/Teams) | Mini window turns orange, tab title + favicon change, optional notification/beep |
| Sees macOS input volume changes | ✅ alerts when an app lowers it, can lock it | ❌ (you still see the resulting level drop) |
| Detects mic switching (e.g. AirPods take over) | ✅ | ✅ (when using "System default") |

## Why you might suddenly sound quiet

- **Auto-gain in Zoom / Teams / Meet** lowers your macOS input volume. The Mac
  app spots this, and *Lock input volume* puts it back automatically.
- **The mic switched**: Bluetooth headphones connected and became the input,
  or a USB headset was unplugged and the laptop mic took over.
- **Position**: turning away from a laptop mic or a boom mic that has drifted.
- **Muted / dead mic**: hardware mute switch, bad cable, or macOS input mute.

---

## Mac app (`mac/`)

### Build and install

```bash
xcode-select --install        # once, if you don't have the command line tools
cd mac
./build.sh --install          # builds, copies to /Applications, launches
```

`./build.sh` on its own just builds `mac/build/Mic Helper.app`.

On first launch macOS asks for microphone access. Allow it. A mic icon with
a small level bar appears in the menu bar.

### Using it

- **Normal**: plain mic icon; the bar moves as you talk.
- **Calibrating**: for the first ~8 seconds of talking it learns your normal level.
- **Gone quiet**: the icon turns orange with **"Speak up"** and an orange pill
  appears at the top of the screen. It goes away as soon as you're back to normal.
- **Silent / muted**: the icon turns red and a red pill says the mic is picking up nothing.

Click the icon for:

- a 60-second graph of your level, your speaking level, your normal level and the alert line
  (click it, or press ⌘H, to open the **history window**)
- **Open data folder (CSV)**
- the current mic and a **macOS input volume slider**
- **Lock input volume**: if any app changes it, it's put straight back
- **Re-learn my normal level** (use after changing mic or seating position)
- sensitivity (6 / 8 / 10 / 12 dB drop), on-screen alert, silent alert, sound, open at login

### History window

A resizable window with a time range picker (**1m · 5m · 15m · 1h · 4h · 24h**) and a
**Keep on top** option, so you can leave it in a corner during a call. It shows:

- grey: mic level (light = loudest moment, darker = average)
- blue: your speaking level · dashed: your normal level · dotted orange: the alert line
- orange / red bands: times you were quiet / the mic was silent
- gaps: the app wasn't running

Hover to read exact values at any moment. The footer summarises the visible range:
number of quiet alerts, time spent quiet or silent, time talking and average speaking level.
The last 24 hours are reloaded when the app starts.

### Stored data (for your own analysis)

Everything is saved locally in `~/Library/Application Support/MicHelper/`:

- `history/YYYY-MM-DD.csv` has one row per second:
  `timestamp, epoch, level_db, peak_db, speech_db, normal_db, alert_line_db, state, input_volume, device`.
  `speech_db` is empty when you weren't talking. `state` is `calibrating`, `ok`, `quiet` or `silent`.
- `events.csv` holds the moments that matter: `state_quiet` (with how big the drop was),
  `state_ok`, `state_silent`, `mic_switched`, `input_volume_lowered`, `input_volume_restored`,
  `relearn_normal_level`, `app_started` and `app_quit`.

Only levels are stored, never audio. Daily files older than 90 days are deleted automatically.
A full day of continuous use is roughly 8 MB.

Quick look in a terminal: `grep ',quiet,' ~/Library/Application\ Support/MicHelper/history/$(date +%F).csv | wc -l`
gives the seconds you spent quiet today. Or open the CSVs in Numbers or Excel.

Notes:

- Requires macOS 13 or later.
- If you use AirPods for music only, note that any app reading the default mic
  (including this one) makes macOS use the AirPods mic, which switches them to
  lower-quality call audio. Pick a different input in Sound settings if that bothers you.
- The app is ad-hoc signed. If you rebuild it, macOS may ask for mic permission again.

---

## No-install version (`web/`)

A single HTML file. Nothing to install, so it works on a locked-down work laptop
(Mac or Windows).

**Option A: hosted (recommended).** Open
**https://twcollins.github.io/mic-helper/web/** in Chrome or Edge. The browser
remembers the mic permission.

**Option B: local file.** Download [`web/index.html`](web/index.html) and open it
in Chrome or Edge.

Then:

1. Click **Start listening** and allow the microphone.
2. Click **Pop out mini window**. A small always-on-top window shows your
   level and turns orange when you go quiet. Put it in a corner near your camera.
3. Keep the original tab open. It can be in the background.

It measures the raw mic signal with the browser's echo cancellation, noise
suppression and auto-gain turned off, and it shares the mic happily with
Zoom/Teams/Meet. Optional extras: desktop notification and a soft beep (use the
beep only with headphones).

The always-on-top mini window uses Document Picture-in-Picture (Chrome/Edge 116+).
Other browsers get a normal small pop-up window instead.

---

## How detection works

Both versions use the same algorithm (`mac/Sources/Detector.swift`, and the
`Detector` class in `web/index.html`):

1. Measure RMS level (dBFS) roughly every 0.1 s.
2. Track the background **noise floor** (falls fast, rises slowly).
3. Treat frames clearly above the noise floor as **speech**.
4. Keep a short average of your speech (~1.5 s) and a long **baseline** (~45 s
   of speech). The first ~8 s of speech sets the initial baseline.
5. If the short average stays more than *N* dB (default 8) below the baseline for
   2 seconds **while you're talking**, alert. The alert clears with 2 dB of
   hysteresis, or after 6 s of not talking.
6. Near-zero signal (below −100 dBFS) for 3 s means the mic is silent or muted.

The baseline adapts slowly so it follows gradual changes, and adapts far more
slowly while you're quiet so it doesn't simply follow you down.
