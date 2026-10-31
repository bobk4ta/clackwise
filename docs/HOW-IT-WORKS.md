# How Clackwise works

Clackwise is a menu bar app that plays a keyboard sound for every key you press, in any app. Two
things set it apart: the sound starts as early as the system allows, and (on MacBooks that have the
sensor) it reacts, subtly, to how hard you hit the key. This page explains both, what was measured,
and what is still uncertain. Numbers come from one MacBook Air (M4) on macOS 27; other Macs may differ.

## Pipeline

```
key event ──► listen-only event tap ──► detector (sensor ring) ──► mapper ──► mixer ──► speakers
 (Input Monitoring)                      reads samples that already    loudness    16 voices,
                                         arrived, adds ~0 ms           + timbre    64-frame buffer
```

- **Event tap.** A listen-only `CGEventTap` sees key down, key up and modifier changes. It needs the
  Input Monitoring permission and nothing else; it never modifies or blocks keys.
- **Sensor.** The motion sensor needs no permission at all (see below).
- **Sound.** Packs are decoded once to PCM. A small mixer inside one `AVAudioSourceNode` plays up to
  16 voices with gain, pitch and a layer crossfade. A press queues its sound under an unfair lock the
  render thread only try-locks, so the event thread never waits on audio.

## The sensor

Apple Silicon MacBooks with the sensor processing unit (SPU) carry a Bosch IMU. macOS does not
document it; Clackwise uses the interface that others have reverse engineered:

1. **Wake it.** Setting `SensorPropertyReportingState = 1`, `SensorPropertyPowerState = 1` and
   `ReportInterval = 1000` (µs) on the `AppleSPUHIDDriver` service for vendor page `0xFF00`, usage 3.
   The properties act as commands; they never show up afterwards. Setting them on the HID device is
   ignored. The wake survives the process exiting, but Clackwise does not rely on that: it wakes the
   sensor on every launch and after every system wake, which costs nothing because it needs no privileges.
2. **Open it.** `IOHIDDeviceCreate` + `IOHIDDeviceOpen` on the `AppleSPUHIDDevice` service with the same
   page and usage, with a callback that receives the report timestamp.
3. **Read it.** Reports are 22 bytes, little-endian: a 16-bit sequence counter, then X, Y, Z as signed
   Q16 fixed point (g = raw / 65536). Rate is about **803 Hz** (1.245 ms apart, jitter below 0.01 ms),
   delivered to the callback in about 0.2 ms.

Nothing here needs root or any privacy permission on the machine it was tested on. The interface is
private: a macOS update can change or lock it, and Clackwise would then fall back to playing every key
at the normal level.

**Clocks.** The HID timestamp is in `mach_absolute_time` ticks, `CGEvent` timestamps on the tested macOS are
nanoseconds of the same clock, and one tick is 41.67 ns on M4 (timebase 125/3), not 1 ns. Mixing them
puts events off by a factor of 24, so Clackwise detects the event clock from the first key event and
always converts through the timebase.

**Macs without the sensor** (M1 MacBook Air, 13" M1 MacBook Pro, Intel Macs, desktop Macs) have no
accelerometer entry on the SPU. Clackwise checks for it at launch; if it is missing, every key plays at the
normal level, Dynamics is off, and Settings says so in one line.

## Reading how hard a key was hit

A keystroke makes the chassis ring at about 100 Hz, almost entirely on the vertical axis (X and Y stay
under 3 mg). The method:

- **Gravity** = per-axis median of the samples 300 to 80 ms before the key event. This follows the Mac's
  tilt and ignores earlier keystrokes.
- **Impact** = the largest |a − gravity| from 40 ms before the event up to the moment the event arrives.

The shock starts 7 to 10 ms *before* the key event's timestamp (the keyboard reports after debounce and
scan), so the samples that matter are already in the buffer when the event arrives. Using only those
costs **no added latency**, and in the lab data it separated hard from soft strikes better than waiting
for the full peak (P(hard > soft) 1.00 vs 0.95). With fast typing, the window starts 25 ms after the
previous key, but never later than 12 ms before this one.

Separation is real but limited: hard vs soft is clean, normal vs soft overlaps. Key position matters
too (the sensor is not under the middle of the keyboard), so Clackwise applies a per-key correction learned
from typing statistics. Clackwise therefore treats force as a continuous value and maps it gently, never into
discrete tiers.

## Dynamics

Dynamics maps impact (on a log scale) to **timbre first, loudness second**:

- Each clip is pre-rendered into three zero-phase layers: *soft* (transient softened, highs reduced),
  the *recording*, and *hard* (sharper transient, more highs and body). Layers are matched in loudness,
  so velocity changes how the key sounds more than how loud it is.
- The mixer crossfades the two neighbouring layers. The 10th percentile of typing force maps to the soft
  layer, the median to the recording, the 90th to the hard layer.
- Loudness moves only about **±2 dB** at the default 100 % (±3 dB at 150 %); the slider scales the whole
  effect, 0 = every key alike.
- **Adaptation:** a decaying histogram of your impacts (memory about 2000 keys) shifts the anchors so
  your median stays at the recording, and rescales the spread within a narrow range. It is never fitted
  to stretch normal typing across the full range.

Be realistic about the effect: in the author's own listening test, the timbre mapping and the older
loudness-only mapping were not clearly distinguishable, so the default is deliberately subtle.

## Latency

Estimated from the audio system's reported latencies at a 64-frame buffer and 48 kHz (not measured
acoustically with a microphone):

| stage | MacBook Air speakers | wired headphones |
|---|---|---|
| key event → event tap callback | 0.7 ms | 0.7 ms |
| callback → sound queued (detect + map) | 0.05 ms | 0.05 ms |
| queued → picked up by a render cycle | 0.7 ms | 0.7 ms |
| render → output time (buffer + safety offset) | 2.3 ms | 2.3 ms |
| device + stream latency reported by CoreAudio | 12.8 ms | 1.7 ms |
| **key event → sound out** | **about 16.5 ms** | **about 5.5 ms** |

Most of the speaker figure is the built-in speakers' own processing, which software can't reduce.
The keyboard itself adds roughly 7 to 10 ms before the event, so the *physical* press comes earlier
than the key event. Bluetooth and AirPlay outputs add 100 ms or more (a Bluetooth headset reported
about 160 ms); Clackwise **mutes** them by default and says why. HDMI/DisplayPort audio was not tested.

### Trim: the clack lands with your finger

Many recordings carry quiet pre-travel or tactile-bump noise before the click. In one pack the click came
about 24 ms after the start of the clip. With the "wait for the full peak" alternative at 20 ms, that is
a clear delay. Clackwise starts every clip 2 ms before its main transient (with a 0.5 ms fade-in) when
the clack begins more than 3 ms after the first sound. The cut part is mostly inaudible behind the click
(median −22.8 dB below the clip's peak), but in about 10 % of slices a faint bump tick is gone. In the
author's listening test, trimming sounded clearly better than not trimming.

### An early trigger was measured and rejected

Because the shock begins before the key event, starting the sound from the shock itself could win a few
milliseconds. Over one hour of typing (1773 key-downs), the best detector threshold saw an onset in time for
only 52 % of key-downs, with 7.5 ms median lead, so the average gain was about 4 ms. It also produced about
one false onset per real one (key-ups, trackpad clicks, palm contact), each an audible phantom click,
and the key is unknown at onset time, so a quarter of the detected keys (Space, Delete, Return have their
own recordings) would start with the wrong key's attack. Not worth it, so it was not built.

## Sound packs

Packs use the Mechvibes format (v1 sprite sheets and v2 multi-file). The kbsim packs carry real press
and release recordings; a kbsim `GENERIC_R0…R4` sample belongs to a keyboard *row*, not to a random
variant. Packs without release recordings get a synthesized key-up (from 1 ms before the main transient,
high-passed at 400 Hz, a decay of 10 ms, about 8 dB below the press).

- **Loudness matching.** BS.1770 K-weighting on the loudest 50 ms of each press clip; a per-pack gain brings
  the median press to a common level, and individual clips that would clip are scaled down. Across the
  five Mechvibes packs that took an 18 dB spread down to 1.6 LU (checked independently with ffmpeg's
  `ebur128`).
- **Less repetition.** Keys never repeat the same recording twice in a row; one-recording keys alternate
  between their own and their neighbours' samples; every key has a fixed voicing (±30 cents, ±0.7 dB), and
  every press adds a small triangular jitter (±0.6 dB, ±20 cents).
- **More packs.** Drop Mechvibes folders into `~/Library/Application Support/Clackwise/SoundPacks/`
  (read at launch).

## Output, sleep, power

- The engine follows the default output device, rebuilds at its sample rate, and requests a 64-frame
  buffer (clamped to what the device allows).
- After sleep, display wake or a fast user switch, Clackwise wakes the sensor again, re-creates the event tap
  if macOS left it disabled, and restarts the engine if needed.
- The sensor stream (800 Hz of HID callbacks) is paused after 30 s without a key; the next key plays
  immediately at the normal level, and the stream is back, at full rate, within about half a second.
  Measured CPU: about 0.7 to 0.9 % idle, about 2 to 3 % while typing or while the stream runs (the stream
  is about 1.6 %, the audio engine about 0.8 %: a 64-frame buffer means roughly 750 wakeups per second,
  which is the price of that latency).
- Presses are not played while another app is recording from a microphone (default on; Clackwise reads only
  whether a process is capturing, never audio).

## Privacy

- **No network.** There is no networking code, no analytics and no update check; the app opens no
  sockets. The Settings window's GitHub link opens your browser.
- **Nothing typed is stored or sent.** Key events produce a sound and update aggregate counters. Typed text, key
  order and per-keystroke times are never stored or logged.
- **What is stored**, in `~/Library/Application Support/Clackwise/` (mode 0600): `stats.json` has
  histograms of impact, played gain and latency, plus per-key press counts and impact medians (keys by
  position name, such as "A" or "LeftShift"); `adaptation.json` has the two decaying histograms. Delete the
  folder to reset. Right after a reset, a handful of counts can reveal which letters were typed (not their
  order); they mean nothing once they reach the thousands.
- **In memory only:** the last velocity per key (for its key-up sound), the previous key's time (to
  place the detection window), and the last 512 latency measurements.
- **Secure input** (password fields): macOS stops delivering key events to every app. Clackwise shows "Paused"
  and plays nothing. An app that leaves "secure keyboard entry" on silences Clackwise until it is turned off.

## Known limits

- The sensor interface is undocumented and macOS may change it; only one Mac model has been tested.
- Dynamics was calibrated from a short lab session and one person's typing; adaptation corrects part of it.
- Fast typing: the previous key's 60 ms ring can raise the next key's reading; the window clamp only helps
  partly.
- Latency is computed from CoreAudio's reported figures, not measured with a microphone.
- The app is signed with a self-signed identity and not notarized, so macOS asks you to approve the first
  launch (see the README).
