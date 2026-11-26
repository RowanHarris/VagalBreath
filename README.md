# VagalBreath (Garmin Venu 3 Connect IQ App)

A standalone, scientifically backed vagal-tone & stress-reduction breathwork Watch App for the **Garmin Venu 3** (`venu3`, 454×454 AMOLED), featuring **Andrew Huberman's Cyclic Sighing (Physiological Sigh)** alongside 4 additional peer-reviewed breathing protocols, distinct eyes-closed haptic cues, and live **RMSSD HRV** vagal biofeedback.

## Included Protocols (Peer-Reviewed)

1. **Cyclic Sigh (`3 + 1 - 7 s`)** — *Balban, Huberman, Spiegel et al. (Cell Reports Medicine, 2023)*
   - 3s deep nasal inhale + 1s sharp nasal top-off sip (with a distinct sharp double-tap haptic cue) → 7s slow relaxed mouth exhale. Ranked #1 in the Stanford Medicine RCT for acute stress relief, mood lift, and resting respiration drop. Every stage is customizable directly on the watch (e.g., `3 + 2 - 8 s`).
2. **Resonance 0.1Hz (`5.5 - 5.5 s`)** — *Laborde et al. (2022, 223-study meta-analysis); Lehrer & Gevirtz*
   - Synchronizes breathing with the baroreflex loop (~5.5 breaths/min) to maximize vagal HRV (`RMSSD`).
3. **Vagal 4-6 (`4 - 6 s`)** — *Van Diest et al. (2014); Magnon et al. (Scientific Reports, 2021)*
   - Combines 0.1 Hz cadence (6 breaths/min) with an extended exhale for strong parasympathetic cardiac deceleration.
4. **4-7-8 Relax (`4 - 7 - 8 s`)** — *Vierra et al. (Physiological Reports, 2022)*
   - Deep wind-down & pre-sleep protocol shown to elevate HF-HRV and acutely lower heart rate and systolic BP.
5. **Box 4-4-4-4 (`4 - 4 - 4 - 4 s`)** — *Balban et al. (Cell Reports Medicine, 2023, #2)*
   - Balanced calm-focus cadence without drowsiness.

## Features
- **Eyes-Closed Haptic Guidance:** Distinct tactile vibration signatures for `Inhale` (ascending pulse), `Top-Off` (crisp sharp double-tap), `Hold` (soft micro-tick), and `Exhale` (gentle descending wave).
- **Smooth Bioluminescent Breathing Ring:** 10 Hz cosine-eased circular pacer (showing the 2-stage 78% → 100% surge during Cyclic Sigh's top-off inhale) + outer bezel session progress arc.
- **Live Vagal Biofeedback & Post-Session Graphs:** Live **Heart Rate**, **HR Drop (`-6 bpm`)**, and real artifact-filtered **RMSSD HRV (`ms`)** computed directly from Venu 3's beat-to-beat R-R intervals (`SensorData.heartBeatIntervals`), plus 4 swipeable post-session pages (**Overview Summary**, **Heart Rate Graph**, **0–100 Autonomic Stress Zone Graph**, and **Vagal RMSSD HRV Graph**).
- **Native Garmin Breathwork Recording:** Saves as `Activity.SPORT_TRAINING` / `Activity.SUB_SPORT_BREATHING` with custom FIT session fields (`breath_protocol`, `hr_drop_bpm`, `vagal_rmssd`, `breath_cycles`), continuous chart fields (`live_rmssd`, `live_stress`), and a secondary *"Are you sure?"* Discard check.

## Build & Test
```bash
monkeyc -d venu3 -f monkey.jungle -o bin/VagalBreath.prg -y ../GarminSwim/developer_key.der -l 3 -O 2 -w
monkeyc -t -d venu3 -f monkey.jungle -o bin/VagalBreath-test.prg -y ../GarminSwim/developer_key.der -l 3 -w
```
