# MonitorControl

A menu bar app for brightness and volume on external monitors, for Apple Silicon Macs.
It works with any DDC/CI monitor, including identical models and daisy-chained
Thunderbolt displays.

- **MonitorControl.app**: menu bar app with per-monitor brightness and volume sliders,
  mute, and a "link monitors" toggle.
- **`monitorctl`**: CLI for the same controls, for scripts and shortcuts.

(Not affiliated with the open-source [MonitorControl](https://github.com/MonitorControl/MonitorControl)
project. This one uses its own bundle ID, `dev.monitorctl.MonitorControl`.)

## How it works

**Brightness** goes to the monitor over DDC/CI, via the private `IOAVServiceWriteI2C`
API (the same one the open-source MonitorControl and m1ddc use). Each Thunderbolt display, daisy-chained
ones included, gets its own `DCPAVServiceProxy`. Monitors are identified by EDID serial,
so two identical models stay distinct.

**Volume** is done in software. Many monitors accept DDC volume writes (VCP `0x62`) but
ignore them, and macOS has no volume control for Thunderbolt/DisplayPort audio. So
MonitorControl uses a CoreAudio process tap (macOS 14.2+) that captures and mutes everything
headed to one monitor's audio device, then plays it back scaled through a private
aggregate device. MonitorControl excludes its own process from the tap so its playback isn't
captured again. At 100% the tap is removed and audio takes the native path. Taps belong
to the process, so if MonitorControl quits or crashes, audio returns to normal.

Identical monitors share an EDID UUID, so their audio devices do too. Each one is paired with its display by
walking the IORegistry: the DCP that owns a display's AV service proxy also owns the
`DCPAVAudioDriver` that publishes its CoreAudio UID.

## Build and install

```sh
make install   # CLI → ~/.local/bin/monitorctl, app → ~/Applications/MonitorControl.app
```

Volume needs the **System Audio Recording** permission, which MonitorControl asks for the first
time it needs it. The app is ad-hoc signed, so macOS may ask again after each rebuild.

## Usage

```sh
monitorctl list                  # monitors, brightness, volume
monitorctl set b 70              # both monitors (default target is "all")
monitorctl set b -10 portrait    # relative change, one monitor
monitorctl set v 40 main         # volume (needs MonitorControl running)
monitorctl mute 2
```

Display selectors: `1`, `2`, `all`, `main`, `portrait`, `landscape`, or an EDID serial.
Set `MONITORCTL_DEBUG=1` with `list` to show display IDs and audio device UIDs.
