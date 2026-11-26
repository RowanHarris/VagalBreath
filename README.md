# VagalBreath (Garmin Venu 3 Connect IQ App)

A standalone, scientifically backed vagal-tone & stress-reduction breathwork Watch App for the **Garmin Venu 3** (`venu3`, 454×454 AMOLED), featuring **Lab Mode** (`2m Pre-Baseline → Active Breathing → 5m Post-Recovery`), **Andrew Huberman's Cyclic Sighing (Physiological Sigh)** alongside 4 additional peer-reviewed breathing protocols, customizable per-stage timings, eyes-closed haptic cues, live **RMSSD HRV** vagal biofeedback, and a Mac USB `.FIT` pull & analysis suite.

## Included Protocols (Peer-Reviewed)

1. **Cyclic Sigh (`3 + 1 - 7 s`)** — *Balban, Huberman, Spiegel et al. (Cell Reports Medicine, 2023)*
   - 3s deep nasal inhale + 1s sharp nasal top-off sip (distinct sharp double-tap haptic) → 7s slow relaxed mouth exhale. Ranked #1 in the Stanford Medicine RCT for acute stress relief, mood lift, and resting respiration drop. Every stage is customizable directly on the watch (e.g., `3 + 2 - 8 s`).
2. **Resonance 0.1Hz (`5.5 - 5.5 s`)** — *Laborde et al. (2022, 223-study meta-analysis); Lehrer & Gevirtz*
   - Synchronizes breathing with the baroreflex loop (~5.5 breaths/min) to maximize vagal HRV (`RMSSD`).
3. **Vagal 4-6 (`4 - 6 s`)** — *Van Diest et al. (2014); Magnon et al. (Scientific Reports, 2021)*
   - Combines 0.1 Hz cadence (6 breaths/min) with an extended exhale for strong parasympathetic cardiac deceleration — ideal for post-work downshifting.
4. **4-7-8 Relax (`4 - 7 - 8 s`)** — *Vierra et al. (Physiological Reports, 2022)*
   - Deep wind-down & pre-sleep protocol shown to elevate HF-HRV and acutely lower heart rate and systolic BP.
5. **Box 4-4-4-4 (`4 - 4 - 4 - 4 s`)** — *Balban et al. (Cell Reports Medicine, 2023, #2)*
   - Balanced calm-focus cadence without drowsiness.

## Features
- **Psychophysiology Lab Mode (Default ON):** Automatically structures each trial into:
  1. **2-min Pre-Baseline** — sit quietly, breathe normally (captures true pre-session resting HR & RMSSD).
  2. **Active Breathing** — guided pacing with full-bezel-to-core breathing circle and eyes-closed haptics.
  3. **5-min Post-Recovery** — stop pacing and breathe normally while the watch measures carried-over parasympathetic rebound (`Recovery − Baseline`).
  - Toggle ON/OFF anytime in **Breath Setup → Lab Mode**.
- **Eyes-Closed Haptic Guidance:** Distinct tactile vibration signatures for `Inhale`, `Top-Off`, `Hold`, `Exhale`, and stage transitions (`Baseline → Breathing → Recovery → Complete`).
- **Full-Screen Bioluminescent Breathing Ring:** 10 Hz cosine-eased circular pacer expanding from a compact empty core (`26 px`) to the full bezel ring (`cx - 8`), plus per-stage duration customization persisted in `Application.Storage`.
- **Live Biofeedback & 4 Post-Session Review Pages:** Swipeable **Overview** (with `BASE → REC` Lab deltas), **Heart Rate Graph**, **0–100 Autonomic Stress Graph**, and **Vagal RMSSD HRV Graph** with vertical dashed stage-boundary dividers.
- **High-Resolution `.FIT` Research Logging:** Saves natively as `Activity.SPORT_TRAINING` / `Activity.SUB_SPORT_BREATHING` with `session.addLap()` markers at every stage boundary, 1 Hz developer fields (`stage_code`, `live_rmssd`, `live_stress`, lossless beat-to-beat `rr1_ms` & `rr2_ms`), and session summary fields (`breath_protocol`, `hr_drop_bpm`, `vagal_rmssd`, `breath_cycles`, `base_rmssd`, `rec_rmssd`, `base_hr`, `rec_hr`).

## USB `.FIT` Pull & Protocol Comparison Analysis (macOS)

1. **Build the fast uncached USB MTP puller** (requires `brew install libmtp`):
   ```bash
   clang -O2 -Wall -Wextra -I/opt/homebrew/include -L/opt/homebrew/lib \
         -Wl,-rpath,/opt/homebrew/lib -lmtp tools/garmin_pull_fit.c -o tools/garmin_pull_fit
   ```
2. **Plug in your Garmin Venu 3 via USB and pull new `.fit` logs** into `sessions/`:
   ```bash
   ./tools/garmin_pull_fit --out sessions
   ```
   *(Tip: pass `--recent 20` to only inspect the 20 newest activities, or `--list` to preview.)*
3. **Run the zero-dependency Python protocol comparison analyzer:**
   ```bash
   python3 tools/analyze_sessions.py sessions --out analysis_out
   ```
   This prints a per-session table + **Lab Mode Protocol Leaderboard** (`ΔHR`, `ΔRMSSD`, `ΔStress`, `pNN50`, and minute-by-minute 5m recovery curves), exports `analysis_out/sessions_summary.csv`, and generates `analysis_out/protocol_comparison.png` plus individual per-session timeline plots.

## Build & Test (Connect IQ SDK 9.3.0)
```bash
monkeyc -d venu3 -f monkey.jungle -o bin/VagalBreath.prg -y ../GarminSwim/developer_key.der -l 3 -O 2 -w
monkeyc -t -d venu3 -f monkey.jungle -o bin/VagalBreath-test.prg -y ../GarminSwim/developer_key.der -l 3 -w
python3 tools/analyze_sessions.py --self-test
```
