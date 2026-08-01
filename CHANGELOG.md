# Changelog

All notable changes to this fork of IINA. This fork adds Dolby Vision, immersive
audio, exclusive Core Audio output, DSD/DoP, SACD ISO playback and an audiophile
DSP rack on Apple silicon.

Findings below are marked **verified** when a runnable probe reproduced them, and
**unverified** when the reasoning is sound but the behaviour could not be
observed on this hardware. That distinction is deliberate — it is what the
release is worth trusting on.

---

## Unreleased — Phase 5

- Added selectable r8brain upsampling using Aleksey Vaneev's pinned, MIT-licensed
  r8brain-free-src 7.2 implementation. It runs at mpv's final resampling boundary,
  so audio is never sample-rate converted twice. The app adds 352.8 and 384 kHz
  output choices and pins mpv `328741a92` plus r8brain `8fff6f3db2`.
- Added PCM-to-DSD64 and PCM-to-DSD128 over the existing guarded DoP 1.1 output.
  The converter uses a second-order modulator with 6 dB headroom, exact 176.4 or
  352.8 kHz integer carriers, Core Audio hog mode, and unity hardware volume.
- Fixed DSD64/DSD128/PCM switching latching the DAC's hardware mute. Encoded
  carriers are already stopped before their format is restored, so teardown no
  longer mutes DoP and accidentally teaches the replacement output that mute-on
  was the device's original state. DoP stays enabled and locked in settings
  while PCM-to-DSD is active.
- Merged current upstream `master` into the patched dependency branches:
  mpv `104091ecf` includes mpv-player/mpv `1d1568614`, and libplacebo
  `6e6cb8fe` includes haasn/libplacebo `4d82c689`.

---

## 1.9.1 — Review-driven hardening

An adversarial review of the whole fork, followed by a surgical patch pass.
No new features. Net **−454 lines** in the app repo, plus fixes in all three
pinned dependencies.

### Fixed — memory safety and untrusted input

- **FFmpeg / DST decoder: stale buffer contents leaked to the caller.**
  `ff_get_buffer()` does not zero, and the uncompressed passthrough branch
  jumped past the `memset` the arithmetic path relied on. A short packet
  returned a frame whose tail still held the *previous* frame's samples, since
  the allocation comes from a recycled pool during playback. The `memset` now
  happens once, before both branches. *Verified:* a full frame of `0x22`
  followed by a short frame returned the same buffer pointer with 9309 stale
  bytes; after the fix those bytes read `0x00`.

- **mpv / SACD demuxer: unclamped frame size.** The 64 KB buffer capacity was
  passed to the bridge but the returned size was trusted for both allocation
  and `memcpy`, so an oversized value read past a fixed buffer and copied
  adjacent memory into the packet. This path parses untrusted ISO file data.
  *Verified:* reproduced under AddressSanitizer with a bridge returning 69632
  for a 65536-byte buffer. Whether the shipped bridge can actually return an
  oversized value is **unverified** — the guard does not depend on it.

- **mpv / gpu-next: stack array bounded only by `assert`.** `assert()` compiles
  out under `NDEBUG`, so a release build wrote past a 32-entry frame-mix array
  instead of aborting. Now clamped at runtime. *Verified* with ASan.

### Fixed — audio

- **Realtime-unsafe logging in the Core Audio callback.** `MP_ERR` inside the
  HAL IOProc formats a string and takes the log lock, neither of which is
  permitted on a realtime thread. Removed; the error return was always the
  actual fix.

- **Three-second stall on every exclusive-output teardown.** An unconditional
  `mp_sleep_ns(3s)` ran on quit, track change, device change, and even after the
  device had been unplugged. Removed. The guarded warmup delay is unchanged.

- **SACD demuxer reported allocation failure as success**, which told the demux
  core to call again and turned an out-of-memory condition into a retry loop.

### Fixed — Dolby Vision and colour

- **Two Dolby Vision trim ingestion paths produced different results for the
  same stream.** The libdovi and FFmpeg paths each carried their own copy of the
  append-and-deduplicate logic and had drifted: one round-tripped preset
  brightness through PQ (1000 nits came back as 1000.021) and one did not; one
  deduplicated level 8 blocks and one did not. The picture therefore depended on
  which backend was compiled in. Both now go through a single
  `pl_hdr_metadata_add_trim()`. *Verified* numerically against the real library;
  the differing trim **counts** were shown with transcribed logic in a harness,
  not by driving both live paths.

- **Trims were applied against a target that was not a display.** The trim is
  selected from the tone curve's output peak, but when the curve is not
  compressing — which is what happens whenever the target peak is left to infer
  and a PQ target resolves to 10000 nits — that number is not a display peak.
  The selection returned the trim authored for the brightest target and applied
  it under an identity highlight curve. Trims now require the curve to actually
  be compressing. *Verified* against the library; the on-screen consequence is
  **unverified**.

- **Trim selection extrapolated without limit.** Content carrying only a 100-nit
  (SDR) trim had that look stretched onto a 1000-nit display. Beyond roughly 8×
  a trim is no longer a match, and no trim is the better answer. The threshold
  is named and tunable.

- **Deduplication compared floats with `==`.** A preset stored directly
  (1000.0) and the same physical display arriving PQ-encoded (1000.60651) are
  one target but were both kept. Now compared in log space with a tolerance.

- **`--tone-mapping` did nothing.** The gpu-next backend built its render
  parameters from the library defaults and read back only the target
  primaries/transfer/peak/gamut, so the tone curve was always libplacebo's
  spline no matter what was selected. IINA exposes this as a preference, so the
  UI was reporting a choice that had no effect. The curve, its parameter and the
  inverse flag are now mapped. *Compile- and structure-verified only:*
  confirming the curve changes pixels needs a GPU render.

- **A Dolby Vision enhancement layer that cannot be composed is now reported.**
  libplacebo composes it only when the RPU has NLQ active; otherwise it silently
  renders the base picture, which looks like working Dolby Vision and is not.

- **Enhancement-layer frames could overwrite base-layer colour.** The pairing
  filter treated an unknown timestamp as "same access unit", which is the branch
  that fuses the EL's RPU and colorimetry onto the base frame. **Unverified** —
  no dual-track Dolby Vision sample could be produced.

- **Rotation was lost on the software-decode path.** The frame uploader replaced
  the whole `pl_frame` with a compound literal, clearing the rotation the caller
  had set, so rotated video rendered upright. *Verified* against the real
  struct: rotation went 3 → 0. (Geometry, not colour.)

- **Enhancement-layer teardown could dereference a null mapper** when the base
  layer is software-decoded but the EL is not, or after a failed mapper
  re-creation.

### Fixed — DSP input handling

- **Filtergraph injection through numeric DSP fields.** Every numeric parameter
  is free text that was interpolated straight into an FFmpeg filtergraph. A
  delay value of `0,volume=volume=-20dB` closed `stereotools` and installed a
  working second filter. *Verified:* measured output dropped from −21.1 dB to
  −41.1 dB — the injected filter really ran. `0[a];amovie=filename=…[b];[a][b]amix`
  injected an arbitrary file source. Values are now parsed and the *parsed*
  number re-emitted, which also normalises literals Swift accepts but FFmpeg
  rejects (hex floats). Enumerated fields are checked against the characters
  their options actually use, since a saved filter file can be hand-edited.
  The common case mattered more than the exotic one: typing `1,5` with a comma
  decimal silently killed the entire DSP graph with no error shown.

- **Convolution failed for impulse responses with an unbalanced bracket.** mpv
  finds the end of `lavfi=[…]` by counting brackets and ignores backslash
  escapes, so an IR named `room [A.wav` desynchronised the count and mpv
  rejected the command with no user-visible error. Graphs now use the
  length-quoted `%n%` form. *Verified:* the bracket form returns `rc=-9` and
  installs nothing for those paths where `%n%` returns `rc=0` and plays. The
  double escaping inside the graph is correct for FFmpeg's two parser levels
  and is unchanged.

### Fixed — the release gate itself

The automated checks could report success while the features they cover were
broken. This was the most serious class of finding, because it undermines every
other guarantee.

- **The DSP check passed for filters that could not initialize.** mpv reports
  the `af` property back before libavfilter has built the graph; on failure it
  drops the filter, logs the error and keeps playing — so "set returned 0",
  "property reads back non-empty" and "playback advanced" were all true for a
  filter that never ran. *Verified:* a filter named
  `this_filter_does_not_exist` satisfied every condition the check tested. It
  now watches the log, the technique its sibling check already used.

- **A failed compile ran the previous run's binary.** The runner scripts lacked
  `set -e` and the inline compiles were not error-checked, so a build failure
  left the stale binary in place and the check reported PASS for source that no
  longer compiles. *Verified* by reproduction.

- **The SACD forward-only timeline assertion never ran in CI.** It lived behind
  an `--inspect` flag that nothing automated passed, so the overlapping-timestamp
  bug the file exists to catch was untested. It now runs on the default path.
  The check also refuses to overwrite an existing file, having previously opened
  its argument with `O_TRUNC`.

- **CI compiled a different render configuration than anyone tested.** The mpv
  workflow resolved Vulkan from Homebrew and built `HAVE_VULKAN 1`, while every
  hardware test runs against a `HAVE_VULKAN 0` OpenGL build. Now pinned to match.

- **The published artifact was described as "signed".** It is ad-hoc signed: no
  Team ID, not notarizable, and Gatekeeper rejects it on any machine that
  downloads it. The workflow now says so and ships a `GATEKEEPER.txt` explaining
  what a downloader has to do.

- **Dependency revision bumps did not trigger a rebuild.** libplacebo and
  mpeghdec were guarded on the existence of a `.pc` file rather than the pinned
  revision, so changing `PLACEBO_REV` silently kept testing the old library.

- **The Dolby Vision build features were asserted by nothing.** The feature
  check now covers the `dovi_split` and `dovi_rpu` bitstream filters, libplacebo,
  and the GL backend the shipped app actually renders through.

### Removed

- `other/check_exclusive_format.c`, `other/check_exclusive_volume.swift` and
  `other/check_bit_perfect_output.swift` (639 lines). Nothing referenced, ran or
  compiled them; they provided the appearance of coverage while drifting out of
  sync with the libmpv API. Their subject matter is covered by
  `run_hardware_checks.sh`, which does run.

- The dead `raw_dsd` guard around DSD table initialisation in the DST decoder,
  and the duplicated uncompressed copy loop it forced.

- Three `ponytail:` authoring markers left in libplacebo source.

### Known limitations, unchanged

- **Dolby Vision and HDR10+ have never been tested on real content.** No RPU or
  ST 2094-40 stream could be authored with the available tooling. The transport
  and the maths are verified; that a real disc renders correctly is not.
- **No on-screen pixel has been measured.** The software render API used for
  testing is provably not display-colour-managed, so "correct SDR" means correct
  through decode and colour conversion, not on the panel.
- **Whether macOS applies a second tone-map roll-off is undetermined.** The
  configuration permits it, but it was never observed. Replacing IINA's manual
  EDR handling with `target-colorspace-hint` is deliberately **not** done in this
  release: the default path emits a luminance passthrough, so macOS may already
  be the single correct mapper, and changing it blind could regress a working
  default. It needs a colorimeter.
- **Deferred pending hardware:** removing the DoP marker regeneration (needs the
  DAC), and reworking the screenshot path, which cannot capture
  hardware-decoded frames and omits the Dolby Vision enhancement layer (needs a
  GPU session).

### Dependencies

| Component | Revision |
|---|---|
| FFmpeg | `0e3ed1fcb7` (`iina-dv-atmos`) |
| libplacebo | `c4a5fa01` (`dovi-l2-l8-trims`) |
| mpv | `450ec8523` (`iina-dv-atmos`) |

### Validation

39/39 mpv tests, 11/11 libplacebo tests, the full AutoEQ/DSP unit suite, and the
headless DSP integration suite (8 option-switching cases, 13 DSP modules
including real-file convolution) all pass against the rebuilt stack. The new
injection test was mutation-tested: reverting the validation kills it.

---

## 1.9.0 — Audiophile DSP rack

AutoEQ/REW `ParametricEQ.txt` and `GraphicEQ.txt` import, dynamic EQ, FIR
convolution, headphone crossfeed, 2.1 Linkwitz–Riley bass management, speaker
matrix and time alignment, stereo width/balance/polarity correction, and a
safety limiter, built on IINA's existing ordered audio-filter window.

## 1.8.1 — DSF and DFF Open With support

## 1.8.0 — Hardware-verified DSD over PCM

DoP 1.1 output verified on a Topping D10s, SACD ISO playback with areas,
chapters and seeking, and raw DST-to-DSD decoding.

## 1.7.3 — Audio driver switching and forced rate fixes

## 1.7.2 — Exclusive mode device fix and AVFoundation rate matching

## 1.7.1 — Make the new settings reachable

## 1.7.0 — Configurable resampler and wider format support

## 1.6.0 — Bit-perfect Core Audio output

Exclusive (hog mode) Core Audio output, sample-rate matching, hardware volume
control, and a bit-perfect signal path readout in the Inspector.

## 1.5.0 — Dolby Vision + Atmos

Dolby Vision profiles 5, 7 and 8 with per-frame L1/L2/L8 metadata and FEL
composition; Dolby Atmos and DTS:X object rendering.

## 1.4.9 / 1.4.7 — Dolby previews
