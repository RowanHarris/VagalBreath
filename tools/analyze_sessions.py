#!/usr/bin/env python3
"""
VagalBreath Lab Mode Analyzer (Zero-Dependency Pure-Python FIT Decoder + Matplotlib Plots)

Parses Garmin .FIT files pulled over USB MTP from GARMIN/Activity/, identifies VagalBreath
sessions (Lab Mode & standard), independently recomputes gold-standard RMSSD, SDNN, pNN50,
and Autonomic Stress from lossless beat-to-beat R-R intervals (rr1_ms, rr2_ms) per stage
(Pre-Baseline -> Active Breathing -> Post-Recovery, plus minute-by-minute recovery slope),
prints a protocol comparison leaderboard, exports CSV, and saves comparison charts.

Usage:
    python3 tools/analyze_sessions.py [sessions_dir_or_fit_files ...] [--out analysis_out]
    python3 tools/analyze_sessions.py --self-test
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import math
import os
import statistics
import struct
import sys
import tempfile
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# Ensure matplotlib has a writable config/cache directory even in restricted shells
os.environ.setdefault("MPLCONFIGDIR", os.path.join(tempfile.gettempdir(), "vagalbreath_mpl"))

FIT_EPOCH_UNIX = 631065600  # 1989-12-31T00:00:00Z

PROTOCOL_NAMES = {
    1: "Cyclic Sigh",
    2: "Resonance 0.1Hz",
    3: "Vagal 4-6",
    4: "4-7-8 Relax",
    5: "Box 4-4-4-4",
}

PROTOCOL_COLORS = {
    1: "#00D4C8",  # Cyan
    2: "#4DE8B0",  # Mint
    3: "#60A5FA",  # Sky blue
    4: "#A78BFA",  # Lavender
    5: "#FBBF24",  # Amber
}

STAGE_NAMES = {
    1: "Pre-Baseline",
    2: "Breathing",
    3: "Post-Recovery",
}

# FIT base type table: base_type_num -> (struct_code, byte_size, invalid_sentinel)
FIT_BASE_TYPES: Dict[int, Tuple[Optional[str], int, Optional[int]]] = {
    0x00: ("B", 1, 0xFF),                 # enum
    0x01: ("b", 1, 0x7F),                 # sint8
    0x02: ("B", 1, 0xFF),                 # uint8
    0x03: ("h", 2, 0x7FFF),               # sint16
    0x04: ("H", 2, 0xFFFF),               # uint16
    0x05: ("i", 4, 0x7FFFFFFF),           # sint32
    0x06: ("I", 4, 0xFFFFFFFF),           # uint32
    0x07: (None, 1, None),                # string
    0x08: ("f", 4, None),                 # float32 (raw 0xFFFFFFFF = invalid)
    0x09: ("d", 8, None),                 # float64 (raw 0xFFFFFFFFFFFFFFFF = invalid)
    0x0A: ("B", 1, 0x00),                 # uint8z
    0x0B: ("H", 2, 0x0000),               # uint16z
    0x0C: ("I", 4, 0x00000000),           # uint32z
    0x0D: (None, 1, None),                # byte array
    0x0E: ("q", 8, 0x7FFFFFFFFFFFFFFF),   # sint64
    0x0F: ("Q", 8, 0xFFFFFFFFFFFFFFFF),   # uint64
    0x10: ("Q", 8, 0x0000000000000000),   # uint64z
}


# ---------------------------------------------------------------------------
# Pure-Python FIT Binary Decoder (supports FIT 1.0/2.0 + Developer Data Fields)
# ---------------------------------------------------------------------------

def _decode_fit_value(raw: bytes, base_type: int, endian: str) -> Any:
    bt_num = base_type & 0x1F
    info = FIT_BASE_TYPES.get(bt_num)
    if info is None:
        return None
    fmt_char, elem_size, invalid = info

    if bt_num == 0x07:  # string
        return raw.split(b"\x00", 1)[0].decode("utf-8", errors="replace")
    if bt_num == 0x0D:  # byte array
        return None if all(b == 0xFF for b in raw) else raw

    if fmt_char is None or elem_size == 0 or len(raw) < elem_size:
        return None

    count = len(raw) // elem_size
    if count <= 0:
        return None

    def _decode_one(chunk: bytes) -> Any:
        if bt_num == 0x08:  # float32
            if struct.unpack(endian + "I", chunk)[0] == 0xFFFFFFFF:
                return None
            val = struct.unpack(endian + "f", chunk)[0]
            return None if (math.isnan(val) or math.isinf(val)) else val
        if bt_num == 0x09:  # float64
            if struct.unpack(endian + "Q", chunk)[0] == 0xFFFFFFFFFFFFFFFF:
                return None
            val = struct.unpack(endian + "d", chunk)[0]
            return None if (math.isnan(val) or math.isinf(val)) else val
        val = struct.unpack(endian + fmt_char, chunk)[0]
        if invalid is not None and val == invalid:
            return None
        return val

    if count == 1:
        return _decode_one(raw[:elem_size])

    items = []
    for i in range(count):
        v = _decode_one(raw[i * elem_size:(i + 1) * elem_size])
        if v is not None:
            items.append(v)
    return items if items else None


def parse_fit_file(path: Path) -> Dict[str, Any]:
    """Decode relevant messages (file_id, session, lap, record, hrv) + developer fields."""
    data = path.read_bytes()
    if len(data) < 14:
        raise ValueError(f"{path.name}: file too small ({len(data)} bytes)")

    header_size = data[0]
    if header_size not in (12, 14) or data[8:12] != b".FIT":
        raise ValueError(f"{path.name}: not a valid FIT file")

    data_size = struct.unpack_from("<I", data, 4)[0]
    offset = header_size
    end_offset = min(len(data), header_size + data_size)

    local_defs: Dict[int, Dict[str, Any]] = {}
    dev_field_defs: Dict[Tuple[int, int], Dict[str, Any]] = {}

    file_id: Dict[int, Any] = {}
    sessions: List[Dict[str, Any]] = []
    laps: List[Dict[str, Any]] = []
    records: List[Dict[str, Any]] = []
    native_hrv_ms: List[int] = []

    last_timestamp = 0

    while offset < end_offset:
        hdr = data[offset]
        offset += 1

        if hdr & 0x80:
            # Compressed timestamp header
            is_def = False
            local_num = (hdr >> 5) & 0x03
            time_off = hdr & 0x1F
            if time_off >= (last_timestamp & 0x1F):
                comp_ts = (last_timestamp & ~0x1F) + time_off
            else:
                comp_ts = (last_timestamp & ~0x1F) + 0x20 + time_off
            last_timestamp = comp_ts
        else:
            is_def = bool(hdr & 0x40)
            has_dev = bool(hdr & 0x20)
            local_num = hdr & 0x0F
            comp_ts = None

        if is_def:
            if offset + 5 > end_offset:
                break
            _reserved = data[offset]
            arch = data[offset + 1]
            endian = ">" if arch == 1 else "<"
            global_num = struct.unpack_from(endian + "H", data, offset + 2)[0]
            num_fields = data[offset + 4]
            offset += 5

            fields: List[Tuple[int, int, int]] = []
            for _ in range(num_fields):
                if offset + 3 > end_offset:
                    break
                f_num, f_size, f_type = data[offset], data[offset + 1], data[offset + 2]
                fields.append((f_num, f_size, f_type))
                offset += 3

            dev_fields: List[Tuple[int, int, int]] = []
            if has_dev and offset < end_offset:
                num_dev = data[offset]
                offset += 1
                for _ in range(num_dev):
                    if offset + 3 > end_offset:
                        break
                    df_num, df_size, df_idx = data[offset], data[offset + 1], data[offset + 2]
                    dev_fields.append((df_num, df_size, df_idx))
                    offset += 3

            local_defs[local_num] = {
                "endian": endian,
                "global_num": global_num,
                "fields": fields,
                "dev_fields": dev_fields,
            }
            continue

        # Data message
        defn = local_defs.get(local_num)
        if defn is None:
            break

        endian = defn["endian"]
        global_num = defn["global_num"]
        std_vals: Dict[int, Any] = {}
        dev_vals: Dict[str, Any] = {}

        if comp_ts is not None:
            std_vals[253] = comp_ts

        for f_num, f_size, f_type in defn["fields"]:
            if offset + f_size > end_offset:
                offset = end_offset
                break
            raw = data[offset:offset + f_size]
            offset += f_size
            val = _decode_fit_value(raw, f_type, endian)
            if val is not None:
                std_vals[f_num] = val

        for df_num, df_size, df_idx in defn["dev_fields"]:
            if offset + df_size > end_offset:
                offset = end_offset
                break
            raw = data[offset:offset + df_size]
            offset += df_size
            meta = dev_field_defs.get((df_idx, df_num))
            if meta is not None:
                val = _decode_fit_value(raw, meta["base_type"], endian)
                if val is not None:
                    scale = meta.get("scale")
                    off = meta.get("offset")
                    if isinstance(val, (int, float)):
                        if scale and scale != 1:
                            val = val / float(scale)
                        if off:
                            val = val - float(off)
                    dev_vals[meta["name"]] = val
                    dev_vals[f"_id_{df_num}"] = val

        if 253 in std_vals and isinstance(std_vals[253], int):
            last_timestamp = std_vals[253]

        if global_num == 206:  # field_description
            d_idx = std_vals.get(0, 0)
            d_num = std_vals.get(1)
            d_bt = std_vals.get(2, 0x02)
            d_name = std_vals.get(3, f"dev_{d_idx}_{d_num}")
            if d_num is not None:
                dev_field_defs[(d_idx, d_num)] = {
                    "name": str(d_name),
                    "base_type": int(d_bt),
                    "scale": std_vals.get(6),
                    "offset": std_vals.get(7),
                    "units": std_vals.get(8, ""),
                }
        elif global_num == 0:  # file_id
            file_id = std_vals
        elif global_num == 18:  # session
            sessions.append({"std": std_vals, "dev": dev_vals})
        elif global_num == 19:  # lap
            laps.append({"std": std_vals, "dev": dev_vals})
        elif global_num == 20:  # record
            records.append({"std": std_vals, "dev": dev_vals})
        elif global_num == 78:  # native hrv
            t_vals = std_vals.get(0)
            if isinstance(t_vals, list):
                native_hrv_ms.extend(int(v) for v in t_vals if 300 <= v <= 2000)
            elif isinstance(t_vals, int) and 300 <= t_vals <= 2000:
                native_hrv_ms.append(t_vals)

    return {
        "file_id": file_id,
        "sessions": sessions,
        "laps": laps,
        "records": records,
        "native_hrv_ms": native_hrv_ms,
        "dev_field_defs": dev_field_defs,
    }


# ---------------------------------------------------------------------------
# Psychophysiology Metrics (Matches Watch Formula + Gold-Standard R-R Recompute)
# ---------------------------------------------------------------------------

def compute_stress_from_rmssd(rmssd_ms: float) -> float:
    clamped = max(5.0, float(rmssd_ms))
    ln_val = math.log(clamped)
    raw = 100.0 - ((ln_val - 2.08) * (95.0 / 2.86))
    return max(1.0, min(100.0, raw))


def compute_hrv_from_rr(rr_list: List[int]) -> Dict[str, Optional[float]]:
    """Apply Malik physiological + jump filter and compute RMSSD, SDNN, pNN50, valid pairs."""
    clean_rr: List[int] = []
    sq_diffs: List[float] = []
    nn50 = 0
    prev: Optional[int] = None

    for rr in rr_list:
        if rr < 300 or rr > 2000:
            prev = None
            continue
        if prev is None:
            prev = rr
            clean_rr.append(rr)
            continue
        diff = rr - prev
        abs_diff = abs(diff)
        if abs_diff > 250 or (abs_diff / float(prev)) > 0.25:
            prev = rr
            continue
        sq_diffs.append(float(diff * diff))
        if abs_diff > 50:
            nn50 += 1
        clean_rr.append(rr)
        prev = rr

    rmssd = math.sqrt(sum(sq_diffs) / len(sq_diffs)) if len(sq_diffs) >= 5 else None
    sdnn = statistics.stdev(clean_rr) if len(clean_rr) >= 5 else None
    pnn50 = (100.0 * nn50 / len(sq_diffs)) if len(sq_diffs) >= 5 else None
    mean_hr_rr = (60000.0 / statistics.mean(clean_rr)) if clean_rr else None
    return {
        "rmssd": rmssd,
        "sdnn": sdnn,
        "pnn50": pnn50,
        "mean_hr_rr": mean_hr_rr,
        "valid_pairs": float(len(sq_diffs)),
        "clean_beats": float(len(clean_rr)),
    }


@dataclass
class StageStats:
    stage_code: int
    duration_s: float = 0.0
    mean_hr: Optional[float] = None
    min_hr: Optional[float] = None
    rmssd_rr: Optional[float] = None
    rmssd_live_mean: Optional[float] = None
    sdnn: Optional[float] = None
    pnn50: Optional[float] = None
    stress: Optional[float] = None
    valid_rr_pairs: int = 0

    @property
    def best_rmssd(self) -> Optional[float]:
        return self.rmssd_rr if self.rmssd_rr is not None else self.rmssd_live_mean


@dataclass
class SessionAnalysis:
    filename: str
    start_dt: dt.datetime
    protocol_id: int
    protocol_name: str
    is_lab_mode: bool
    duration_s: float
    breath_cycles: Optional[int]
    stages: Dict[int, StageStats] = field(default_factory=dict)
    recovery_minutes: List[Dict[str, Optional[float]]] = field(default_factory=list)
    # Time-series arrays for plotting
    t_sec: List[float] = field(default_factory=list)
    hr_series: List[Optional[float]] = field(default_factory=list)
    rmssd_series: List[Optional[float]] = field(default_factory=list)
    stress_series: List[Optional[float]] = field(default_factory=list)
    stage_series: List[int] = field(default_factory=list)
    # FIT session summary fallbacks
    fit_base_hr: Optional[float] = None
    fit_rec_hr: Optional[float] = None
    fit_base_rmssd: Optional[float] = None
    fit_rec_rmssd: Optional[float] = None

    @property
    def base_hr(self) -> Optional[float]:
        s = self.stages.get(1)
        if s and s.mean_hr is not None:
            return s.mean_hr
        return self.fit_base_hr

    @property
    def rec_hr(self) -> Optional[float]:
        s = self.stages.get(3)
        if s and s.mean_hr is not None:
            return s.mean_hr
        return self.fit_rec_hr

    @property
    def base_rmssd(self) -> Optional[float]:
        s = self.stages.get(1)
        if s and s.best_rmssd is not None:
            return s.best_rmssd
        return self.fit_base_rmssd

    @property
    def rec_rmssd(self) -> Optional[float]:
        s = self.stages.get(3)
        if s and s.best_rmssd is not None:
            return s.best_rmssd
        return self.fit_rec_rmssd

    @property
    def base_stress(self) -> Optional[float]:
        r = self.base_rmssd
        return compute_stress_from_rmssd(r) if r is not None else None

    @property
    def rec_stress(self) -> Optional[float]:
        r = self.rec_rmssd
        return compute_stress_from_rmssd(r) if r is not None else None

    @property
    def delta_hr(self) -> Optional[float]:
        if self.base_hr is not None and self.rec_hr is not None:
            return self.rec_hr - self.base_hr
        return None

    @property
    def delta_rmssd(self) -> Optional[float]:
        if self.base_rmssd is not None and self.rec_rmssd is not None:
            return self.rec_rmssd - self.base_rmssd
        return None

    @property
    def delta_stress(self) -> Optional[float]:
        if self.base_stress is not None and self.rec_stress is not None:
            return self.rec_stress - self.base_stress
        return None


def analyze_fit_session(path: Path, include_native: bool = False) -> Optional[SessionAnalysis]:
    parsed = parse_fit_file(path)
    sessions = parsed["sessions"]
    records = parsed["records"]
    laps = parsed["laps"]

    if not sessions and not records:
        return None

    sess_std = sessions[0]["std"] if sessions else {}
    sess_dev = sessions[0]["dev"] if sessions else {}

    proto_id = sess_dev.get("breath_protocol")
    has_vb_record_fields = any(
        ("stage_code" in r["dev"] or "live_rmssd" in r["dev"] or "rr1_ms" in r["dev"])
        for r in records[:30]
    )
    sub_sport = sess_std.get(6)

    if proto_id is None and not has_vb_record_fields:
        if include_native and sub_sport == 62:
            proto_id = 0
        else:
            return None

    proto_int = int(proto_id) if proto_id is not None else 0
    proto_name = PROTOCOL_NAMES.get(proto_int, "Garmin Breathwork" if proto_int == 0 else f"Protocol #{proto_int}")

    # Determine start timestamp
    start_ts = sess_std.get(2) or parsed["file_id"].get(4)
    if start_ts is None and records:
        start_ts = records[0]["std"].get(253)
    if start_ts is not None:
        start_dt = dt.datetime.fromtimestamp(FIT_EPOCH_UNIX + int(start_ts))
    else:
        start_dt = dt.datetime.fromtimestamp(path.stat().st_mtime)

    # Lap boundary fallback if stage_code wasn't logged in older builds
    lap_ends: List[int] = []
    for lp in laps:
        ts = lp["std"].get(253)
        if isinstance(ts, int):
            lap_ends.append(ts)

    t0: Optional[int] = None
    t_sec: List[float] = []
    hr_series: List[Optional[float]] = []
    rmssd_series: List[Optional[float]] = []
    stress_series: List[Optional[float]] = []
    stage_series: List[int] = []

    stage_hrs: Dict[int, List[float]] = defaultdict(list)
    stage_live_rmssd: Dict[int, List[float]] = defaultdict(list)
    stage_rr: Dict[int, List[int]] = defaultdict(list)
    stage_times: Dict[int, List[float]] = defaultdict(list)
    rec_minute_hrs: Dict[int, List[float]] = defaultdict(list)
    rec_minute_rr: Dict[int, List[int]] = defaultdict(list)
    rec_minute_live_rmssd: Dict[int, List[float]] = defaultdict(list)

    rec_start_t: Optional[float] = None

    for idx, rec in enumerate(records):
        std = rec["std"]
        dev = rec["dev"]
        ts = std.get(253)
        if ts is not None:
            if t0 is None:
                t0 = int(ts)
            rel_t = float(int(ts) - t0)
        else:
            rel_t = float(idx)

        hr = std.get(3)
        hr_f = float(hr) if isinstance(hr, (int, float)) and 30 <= hr <= 220 else None

        live_rmssd = dev.get("live_rmssd")
        rmssd_f = float(live_rmssd) if isinstance(live_rmssd, (int, float)) and live_rmssd > 0 else None

        live_stress = dev.get("live_stress")
        stress_f = float(live_stress) if isinstance(live_stress, (int, float)) and 1 <= live_stress <= 100 else (
            compute_stress_from_rmssd(rmssd_f) if rmssd_f is not None else None
        )

        sc = dev.get("stage_code")
        if isinstance(sc, (int, float)) and int(sc) in (1, 2, 3):
            stage = int(sc)
        elif len(lap_ends) >= 3 and ts is not None:
            if ts <= lap_ends[0]:
                stage = 1
            elif ts <= lap_ends[1]:
                stage = 2
            else:
                stage = 3
        else:
            stage = 2

        t_sec.append(rel_t)
        hr_series.append(hr_f)
        rmssd_series.append(rmssd_f)
        stress_series.append(stress_f)
        stage_series.append(stage)

        stage_times[stage].append(rel_t)
        if hr_f is not None:
            stage_hrs[stage].append(hr_f)
        if rmssd_f is not None:
            stage_live_rmssd[stage].append(rmssd_f)

        rr1 = dev.get("rr1_ms")
        rr2 = dev.get("rr2_ms")
        batch_rr: List[int] = []
        if isinstance(rr1, (int, float)) and 300 <= int(rr1) <= 2000:
            batch_rr.append(int(rr1))
        if isinstance(rr2, (int, float)) and 300 <= int(rr2) <= 2000:
            batch_rr.append(int(rr2))
        if batch_rr:
            stage_rr[stage].extend(batch_rr)

        if stage == 3:
            if rec_start_t is None:
                rec_start_t = rel_t
            rec_min = int((rel_t - rec_start_t) // 60.0) + 1
            if 1 <= rec_min <= 10:
                if hr_f is not None:
                    rec_minute_hrs[rec_min].append(hr_f)
                if rmssd_f is not None:
                    rec_minute_live_rmssd[rec_min].append(rmssd_f)
                if batch_rr:
                    rec_minute_rr[rec_min].extend(batch_rr)

    stages_out: Dict[int, StageStats] = {}
    for st_code in (1, 2, 3):
        times = stage_times.get(st_code, [])
        if not times:
            continue
        dur = max(0.0, times[-1] - times[0]) if len(times) > 1 else float(len(times))
        hrs = stage_hrs.get(st_code, [])
        live_rs = stage_live_rmssd.get(st_code, [])
        hrv_res = compute_hrv_from_rr(stage_rr.get(st_code, []))
        rmssd_rr = hrv_res["rmssd"]
        rmssd_live = statistics.mean(live_rs) if live_rs else None
        best_r = rmssd_rr if rmssd_rr is not None else rmssd_live

        stages_out[st_code] = StageStats(
            stage_code=st_code,
            duration_s=dur,
            mean_hr=statistics.mean(hrs) if hrs else hrv_res["mean_hr_rr"],
            min_hr=min(hrs) if hrs else None,
            rmssd_rr=rmssd_rr,
            rmssd_live_mean=rmssd_live,
            sdnn=hrv_res["sdnn"],
            pnn50=hrv_res["pnn50"],
            stress=compute_stress_from_rmssd(best_r) if best_r is not None else None,
            valid_rr_pairs=int(hrv_res["valid_pairs"] or 0),
        )

    rec_minutes: List[Dict[str, Optional[float]]] = []
    for m in range(1, 6):
        if m not in rec_minute_hrs and m not in rec_minute_rr:
            continue
        m_hrv = compute_hrv_from_rr(rec_minute_rr.get(m, []))
        m_live = rec_minute_live_rmssd.get(m, [])
        best_r = m_hrv["rmssd"] if m_hrv["rmssd"] is not None else (statistics.mean(m_live) if m_live else None)
        rec_minutes.append({
            "minute": float(m),
            "hr": statistics.mean(rec_minute_hrs[m]) if rec_minute_hrs.get(m) else m_hrv["mean_hr_rr"],
            "rmssd": best_r,
            "stress": compute_stress_from_rmssd(best_r) if best_r is not None else None,
        })

    dur_s = float(sess_std.get(7, 0)) / 1000.0 if sess_std.get(7) else (t_sec[-1] if t_sec else 0.0)
    is_lab = (1 in stages_out and 3 in stages_out) or (
        sess_dev.get("base_hr", 0) > 0 and sess_dev.get("rec_hr", 0) > 0
    )

    def _opt_pos(val: Any) -> Optional[float]:
        if isinstance(val, (int, float)) and val > 0:
            return float(val)
        return None

    return SessionAnalysis(
        filename=path.name,
        start_dt=start_dt,
        protocol_id=proto_int,
        protocol_name=proto_name,
        is_lab_mode=is_lab,
        duration_s=dur_s,
        breath_cycles=int(sess_dev["breath_cycles"]) if isinstance(sess_dev.get("breath_cycles"), (int, float)) else None,
        stages=stages_out,
        recovery_minutes=rec_minutes,
        t_sec=t_sec,
        hr_series=hr_series,
        rmssd_series=rmssd_series,
        stress_series=stress_series,
        stage_series=stage_series,
        fit_base_hr=_opt_pos(sess_dev.get("base_hr")),
        fit_rec_hr=_opt_pos(sess_dev.get("rec_hr")),
        fit_base_rmssd=_opt_pos(sess_dev.get("base_rmssd")),
        fit_rec_rmssd=_opt_pos(sess_dev.get("rec_rmssd")),
    )


# ---------------------------------------------------------------------------
# CLI Reporting, CSV Export, and Matplotlib Plots
# ---------------------------------------------------------------------------

def _fmt(val: Optional[float], spec: str = ".1f", signed: bool = False, suffix: str = "") -> str:
    if val is None:
        return "--"
    sign = "+" if (signed and val > 0) else ""
    return f"{sign}{val:{spec}}{suffix}"


def print_summary_tables(results: List[SessionAnalysis]) -> None:
    print("\n" + "=" * 112)
    print("VAGALBREATH SESSION LOGS (Pre-Baseline -> Active Breathing -> Post-Recovery)")
    print("=" * 112)
    header = (
        f"{'Date':<16} {'Protocol':<16} {'Mode':<5} {'Dur':>5}  "
        f"{'HR (Base->Br->Rec)':<21} {'dHR':>6}  "
        f"{'RMSSD ms (B->Br->R)':<21} {'dHRV':>7}  {'dStress':>7} {'RR':>4}"
    )
    print(header)
    print("-" * 112)

    for s in sorted(results, key=lambda x: x.start_dt):
        b = s.stages.get(1)
        br = s.stages.get(2)
        r = s.stages.get(3)

        hr_trip = f"{_fmt(s.base_hr, '.0f')}->{_fmt(br.mean_hr if br else None, '.0f')}->{_fmt(s.rec_hr, '.0f')}"
        rm_trip = f"{_fmt(s.base_rmssd, '.0f')}->{_fmt(br.best_rmssd if br else None, '.0f')}->{_fmt(s.rec_rmssd, '.0f')}"
        rr_pairs = sum(st.valid_rr_pairs for st in s.stages.values())
        dur_m = f"{s.duration_s / 60.0:.1f}m"

        print(
            f"{s.start_dt.strftime('%Y-%m-%d %H:%M'):<16} "
            f"{s.protocol_name:<16} "
            f"{'LAB' if s.is_lab_mode else 'STD':<5} "
            f"{dur_m:>5}  "
            f"{hr_trip:<21} {_fmt(s.delta_hr, '.1f', True):>6}  "
            f"{rm_trip:<21} {_fmt(s.delta_rmssd, '.1f', True):>7}  "
            f"{_fmt(s.delta_stress, '.1f', True):>7} {rr_pairs:>4d}"
        )

        if s.recovery_minutes:
            traj = "  ".join(
                f"M{int(m['minute'] or 0)}:HR={_fmt(m['hr'], '.0f')}/HRV={_fmt(m['rmssd'], '.0f')}"
                for m in s.recovery_minutes
            )
            print(f"    Recovery curve (5m): {traj}")

    # Protocol Comparison Leaderboard (Lab Mode sessions only)
    lab_sessions = [s for s in results if s.is_lab_mode]
    if not lab_sessions:
        print("\nNo complete Lab Mode sessions (2m Base + 5m Rec) found yet.")
        return

    grouped: Dict[int, List[SessionAnalysis]] = defaultdict(list)
    for s in lab_sessions:
        grouped[s.protocol_id].append(s)

    print("\n" + "=" * 112)
    print("LAB MODE PROTOCOL LEADERBOARD (Apples-to-Apples Carry-Over: 5m Post-Recovery vs. 2m Pre-Baseline)")
    print("=" * 112)
    print(
        f"{'Protocol':<18} {'Trials':>6}  {'Mean dHR (bpm)':>15}  {'Mean dRMSSD (ms)':>17}  "
        f"{'Mean dStress':>13}  {'Rec pNN50':>10}"
    )
    print("-" * 112)

    ranked_rows = []
    for pid, items in grouped.items():
        d_hrs = [x.delta_hr for x in items if x.delta_hr is not None]
        d_rms = [x.delta_rmssd for x in items if x.delta_rmssd is not None]
        d_str = [x.delta_stress for x in items if x.delta_stress is not None]
        pnn50s = [x.stages[3].pnn50 for x in items if 3 in x.stages and x.stages[3].pnn50 is not None]

        m_dhr = statistics.mean(d_hrs) if d_hrs else None
        m_drm = statistics.mean(d_rms) if d_rms else None
        m_dst = statistics.mean(d_str) if d_str else None
        m_pnn = statistics.mean(pnn50s) if pnn50s else None
        ranked_rows.append((pid, PROTOCOL_NAMES.get(pid, f"#{pid}"), len(items), m_dhr, m_drm, m_dst, m_pnn))

    # Rank by highest vagal RMSSD carry-over lift (tie-break by largest HR drop)
    ranked_rows.sort(
        key=lambda r: (r[4] if r[4] is not None else -999.0, -(r[3] if r[3] is not None else 999.0)),
        reverse=True,
    )
    for _, pname, n, m_dhr, m_drm, m_dst, m_pnn in ranked_rows:
        print(
            f"{pname:<18} {n:>6d}  "
            f"{_fmt(m_dhr, '.1f', True):>15}  "
            f"{_fmt(m_drm, '.1f', True):>17}  "
            f"{_fmt(m_dst, '.1f', True):>13}  "
            f"{_fmt(m_pnn, '.1f', False, '%'):>10}"
        )

    best = ranked_rows[0]
    print("-" * 112)
    print(
        f"Top downshift protocol so far: {best[1]} "
        f"(dHR {_fmt(best[3], '.1f', True, ' bpm')}, "
        f"dRMSSD {_fmt(best[4], '.1f', True, ' ms')}, "
        f"dStress {_fmt(best[5], '.1f', True)} across n={best[2]} trial(s))"
    )


def export_csv(results: List[SessionAnalysis], out_dir: Path) -> Path:
    csv_path = out_dir / "sessions_summary.csv"
    fieldnames = [
        "filename", "timestamp", "protocol_id", "protocol_name", "lab_mode",
        "duration_s", "breath_cycles",
        "base_hr", "breath_hr", "rec_hr", "delta_hr",
        "base_rmssd_ms", "breath_rmssd_ms", "rec_rmssd_ms", "delta_rmssd_ms",
        "base_stress", "breath_stress", "rec_stress", "delta_stress",
        "base_sdnn_ms", "rec_sdnn_ms", "base_pnn50_pct", "rec_pnn50_pct",
    ]
    with csv_path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for s in sorted(results, key=lambda x: x.start_dt):
            b = s.stages.get(1)
            br = s.stages.get(2)
            r = s.stages.get(3)
            w.writerow({
                "filename": s.filename,
                "timestamp": s.start_dt.isoformat(timespec="seconds"),
                "protocol_id": s.protocol_id,
                "protocol_name": s.protocol_name,
                "lab_mode": int(s.is_lab_mode),
                "duration_s": round(s.duration_s, 1),
                "breath_cycles": s.breath_cycles if s.breath_cycles is not None else "",
                "base_hr": round(s.base_hr, 2) if s.base_hr is not None else "",
                "breath_hr": round(br.mean_hr, 2) if (br and br.mean_hr is not None) else "",
                "rec_hr": round(s.rec_hr, 2) if s.rec_hr is not None else "",
                "delta_hr": round(s.delta_hr, 2) if s.delta_hr is not None else "",
                "base_rmssd_ms": round(s.base_rmssd, 2) if s.base_rmssd is not None else "",
                "breath_rmssd_ms": round(br.best_rmssd, 2) if (br and br.best_rmssd is not None) else "",
                "rec_rmssd_ms": round(s.rec_rmssd, 2) if s.rec_rmssd is not None else "",
                "delta_rmssd_ms": round(s.delta_rmssd, 2) if s.delta_rmssd is not None else "",
                "base_stress": round(s.base_stress, 1) if s.base_stress is not None else "",
                "breath_stress": round(br.stress, 1) if (br and br.stress is not None) else "",
                "rec_stress": round(s.rec_stress, 1) if s.rec_stress is not None else "",
                "delta_stress": round(s.delta_stress, 1) if s.delta_stress is not None else "",
                "base_sdnn_ms": round(b.sdnn, 2) if (b and b.sdnn is not None) else "",
                "rec_sdnn_ms": round(r.sdnn, 2) if (r and r.sdnn is not None) else "",
                "base_pnn50_pct": round(b.pnn50, 2) if (b and b.pnn50 is not None) else "",
                "rec_pnn50_pct": round(r.pnn50, 2) if (r and r.pnn50 is not None) else "",
            })
    return csv_path


def generate_plots(results: List[SessionAnalysis], out_dir: Path) -> List[Path]:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    plt.rcParams.update({
        "figure.facecolor": "#0B101B",
        "axes.facecolor": "#121A2B",
        "axes.edgecolor": "#2A3852",
        "axes.labelcolor": "#E2E8F0",
        "xtick.color": "#94A3B8",
        "ytick.color": "#94A3B8",
        "text.color": "#F8FAFC",
        "grid.color": "#1E293B",
        "grid.linestyle": "--",
        "grid.alpha": 0.65,
    })

    saved: List[Path] = []

    # 1. Protocol Comparison Dashboard (Lab Mode trials)
    lab = [s for s in results if s.is_lab_mode]
    if lab:
        grouped: Dict[int, List[SessionAnalysis]] = defaultdict(list)
        for s in lab:
            grouped[s.protocol_id].append(s)

        pids = sorted(grouped.keys())
        labels = [f"{PROTOCOL_NAMES.get(p, str(p))}\n(n={len(grouped[p])})" for p in pids]
        colors = [PROTOCOL_COLORS.get(p, "#00D4C8") for p in pids]

        fig, axes = plt.subplots(2, 2, figsize=(13, 8.5), dpi=150)
        fig.suptitle("VagalBreath Lab Mode — Protocol Comparison (5m Post-Recovery vs. 2m Pre-Baseline)",
                     fontsize=14, fontweight="bold", y=0.98)

        # Panel A: Delta RMSSD (higher = better vagal carry-over)
        ax = axes[0, 0]
        vals = [statistics.mean([x.delta_rmssd for x in grouped[p] if x.delta_rmssd is not None] or [0.0]) for p in pids]
        bars = ax.bar(labels, vals, color=colors, width=0.55, alpha=0.9)
        ax.axhline(0, color="#64748B", linewidth=1)
        ax.set_title("Vagal Carry-Over: ΔRMSSD (ms, higher = calmer)")
        ax.set_ylabel("Rec RMSSD − Base RMSSD (ms)")
        ax.grid(axis="y")
        for b, v in zip(bars, vals):
            ax.text(b.get_x() + b.get_width() / 2, v, f"{v:+.1f}", ha="center",
                    va="bottom" if v >= 0 else "top", fontsize=9, fontweight="bold")

        # Panel B: Delta HR (more negative = stronger calm downshift)
        ax = axes[0, 1]
        vals_hr = [statistics.mean([x.delta_hr for x in grouped[p] if x.delta_hr is not None] or [0.0]) for p in pids]
        bars = ax.bar(labels, vals_hr, color=colors, width=0.55, alpha=0.9)
        ax.axhline(0, color="#64748B", linewidth=1)
        ax.set_title("Heart Rate Downshift: ΔHR (bpm, lower = calmer)")
        ax.set_ylabel("Rec HR − Base HR (bpm)")
        ax.grid(axis="y")
        for b, v in zip(bars, vals_hr):
            ax.text(b.get_x() + b.get_width() / 2, v, f"{v:+.1f}", ha="center",
                    va="bottom" if v >= 0 else "top", fontsize=9, fontweight="bold")

        # Panel C: Minute-by-minute Recovery RMSSD trajectory (Baseline -> M1..M5)
        ax = axes[1, 0]
        x_pts = ["Base", "Breath", "Rec M1", "Rec M2", "Rec M3", "Rec M4", "Rec M5"]
        for p in pids:
            ys = []
            b_vals = [x.base_rmssd for x in grouped[p] if x.base_rmssd is not None]
            br_vals = [x.stages[2].best_rmssd for x in grouped[p] if 2 in x.stages and x.stages[2].best_rmssd is not None]
            ys.append(statistics.mean(b_vals) if b_vals else math.nan)
            ys.append(statistics.mean(br_vals) if br_vals else math.nan)
            for m in range(1, 6):
                mv = [
                    rm["rmssd"]
                    for x in grouped[p]
                    for rm in x.recovery_minutes
                    if int(rm["minute"] or 0) == m and rm["rmssd"] is not None
                ]
                ys.append(statistics.mean(mv) if mv else math.nan)
            ax.plot(x_pts, ys, marker="o", linewidth=2.2, label=PROTOCOL_NAMES.get(p, str(p)),
                    color=PROTOCOL_COLORS.get(p, "#00D4C8"))
        ax.set_title("Vagal RMSSD Trajectory: Baseline → Breathing → 5m Recovery")
        ax.set_ylabel("RMSSD (ms)")
        ax.grid(True)
        ax.legend(framealpha=0.35, fontsize=8.5)

        # Panel D: Minute-by-minute Recovery HR trajectory
        ax = axes[1, 1]
        for p in pids:
            ys = []
            b_vals = [x.base_hr for x in grouped[p] if x.base_hr is not None]
            br_vals = [x.stages[2].mean_hr for x in grouped[p] if 2 in x.stages and x.stages[2].mean_hr is not None]
            ys.append(statistics.mean(b_vals) if b_vals else math.nan)
            ys.append(statistics.mean(br_vals) if br_vals else math.nan)
            for m in range(1, 6):
                mv = [
                    rm["hr"]
                    for x in grouped[p]
                    for rm in x.recovery_minutes
                    if int(rm["minute"] or 0) == m and rm["hr"] is not None
                ]
                ys.append(statistics.mean(mv) if mv else math.nan)
            ax.plot(x_pts, ys, marker="o", linewidth=2.2, label=PROTOCOL_NAMES.get(p, str(p)),
                    color=PROTOCOL_COLORS.get(p, "#00D4C8"))
        ax.set_title("Heart Rate Trajectory: Baseline → Breathing → 5m Recovery")
        ax.set_ylabel("Heart Rate (bpm)")
        ax.grid(True)
        ax.legend(framealpha=0.35, fontsize=8.5)

        fig.tight_layout(rect=[0, 0, 1, 0.95])
        comp_path = out_dir / "protocol_comparison.png"
        fig.savefig(comp_path)
        plt.close(fig)
        saved.append(comp_path)

    # 2. Per-Session Detailed Timeline Plots (most recent 12 sessions)
    for s in sorted(results, key=lambda x: x.start_dt)[-12:]:
        if len(s.t_sec) < 5:
            continue
        t_min = [t / 60.0 for t in s.t_sec]
        fig, axes = plt.subplots(3, 1, figsize=(11, 7.5), dpi=140, sharex=True)
        title = (
            f"{s.protocol_name} ({s.start_dt.strftime('%Y-%m-%d %H:%M')})  |  "
            f"ΔHR {_fmt(s.delta_hr, '.1f', True, ' bpm')}  •  "
            f"ΔRMSSD {_fmt(s.delta_rmssd, '.1f', True, ' ms')}  •  "
            f"ΔStress {_fmt(s.delta_stress, '.1f', True)}"
        )
        fig.suptitle(title, fontsize=11.5, fontweight="bold", y=0.98)

        # Shade stage regions
        stage_spans: List[Tuple[int, float, float]] = []
        if s.stage_series:
            cur_st = s.stage_series[0]
            start_m = t_min[0]
            for i in range(1, len(s.stage_series)):
                if s.stage_series[i] != cur_st:
                    stage_spans.append((cur_st, start_m, t_min[i]))
                    cur_st = s.stage_series[i]
                    start_m = t_min[i]
            stage_spans.append((cur_st, start_m, t_min[-1]))

        shade_colors = {1: "#334155", 2: "#0E7490", 3: "#065F46"}

        def _apply_shades(axis: Any, add_labels: bool = False) -> None:
            for st_c, x0, x1 in stage_spans:
                axis.axvspan(x0, x1, color=shade_colors.get(st_c, "#1E293B"), alpha=0.22)
                if add_labels and (x1 - x0) > 0.4:
                    axis.text((x0 + x1) / 2.0, 0.96, STAGE_NAMES.get(st_c, ""),
                              transform=axis.get_xaxis_transform(), ha="center", va="top",
                              fontsize=8.5, color="#CBD5E1", fontweight="bold")

        # HR
        ax = axes[0]
        _apply_shades(ax, add_labels=True)
        xs = [t for t, v in zip(t_min, s.hr_series) if v is not None]
        ys = [v for v in s.hr_series if v is not None]
        if xs:
            ax.plot(xs, ys, color="#FB7185", linewidth=1.8)
        ax.set_ylabel("HR (bpm)")
        ax.grid(True)

        # Vagal RMSSD
        ax = axes[1]
        _apply_shades(ax)
        xs = [t for t, v in zip(t_min, s.rmssd_series) if v is not None]
        ys = [v for v in s.rmssd_series if v is not None]
        if xs:
            ax.plot(xs, ys, color="#00D4C8", linewidth=1.8)
            ax.fill_between(xs, 0, ys, color="#00D4C8", alpha=0.14)
        ax.set_ylabel("RMSSD (ms)")
        ax.grid(True)

        # Autonomic Stress 0-100
        ax = axes[2]
        _apply_shades(ax)
        ax.axhline(25, color="#34D399", linestyle=":", linewidth=1.0, alpha=0.8)
        ax.axhline(50, color="#FBBF24", linestyle=":", linewidth=1.0, alpha=0.8)
        ax.axhline(75, color="#F87171", linestyle=":", linewidth=1.0, alpha=0.8)
        xs = [t for t, v in zip(t_min, s.stress_series) if v is not None]
        ys = [v for v in s.stress_series if v is not None]
        if xs:
            ax.plot(xs, ys, color="#FBBF24", linewidth=1.8)
        ax.set_ylim(0, 100)
        ax.set_ylabel("Stress (0-100)")
        ax.set_xlabel("Elapsed Time (minutes)")
        ax.grid(True)

        fig.tight_layout(rect=[0, 0, 1, 0.95])
        slug = s.protocol_name.lower().replace(" ", "_").replace(".", "")
        p_out = out_dir / f"session_{s.start_dt.strftime('%Y%m%d_%H%M')}_{slug}.png"
        fig.savefig(p_out)
        plt.close(fig)
        saved.append(p_out)

    return saved


# ---------------------------------------------------------------------------
# Built-In Synthetic Binary FIT Self-Test (Verifies Decoder + Math + Charts)
# ---------------------------------------------------------------------------

def _write_synthetic_vagalbreath_fit(
    out_path: Path,
    proto_id: int,
    start_unix: int,
    base_hr: int,
    breath_hr: int,
    rec_hr: int,
    base_jitter: int,
    breath_jitter: int,
    rec_jitter: int,
) -> None:
    """Emit a spec-compliant FIT 2.0 binary file matching VagalBreath's exact field definitions."""
    body = bytearray()

    def _def_mesg(local_num: int, global_num: int, fields: List[Tuple[int, int, int]],
                  dev_fields: Optional[List[Tuple[int, int, int]]] = None) -> None:
        hdr = 0x40 | (0x20 if dev_fields else 0x00) | (local_num & 0x0F)
        body.append(hdr)
        body.append(0)  # reserved
        body.append(0)  # little-endian
        body.extend(struct.pack("<HB", global_num, len(fields)))
        for f_num, f_sz, f_bt in fields:
            body.extend(struct.pack("<BBB", f_num, f_sz, f_bt))
        if dev_fields:
            body.append(len(dev_fields))
            for df_num, df_sz, df_idx in dev_fields:
                body.extend(struct.pack("<BBB", df_num, df_sz, df_idx))

    # Local 0: field_description (global 206)
    _def_mesg(0, 206, [
        (0, 1, 0x02),   # developer_data_index
        (1, 1, 0x02),   # field_definition_number
        (2, 1, 0x02),   # fit_base_type_id
        (3, 16, 0x07),  # field_name (16-byte string)
    ])

    def _emit_dev_desc(f_id: int, base_type: int, name: str) -> None:
        body.append(0x00)  # data for local 0
        raw_name = name.encode("utf-8")[:15].ljust(16, b"\x00")
        body.extend(struct.pack("<BBB", 0, f_id, base_type) + raw_name)

    _emit_dev_desc(0, 0x02, "breath_protocol")
    _emit_dev_desc(1, 0x03, "hr_drop_bpm")
    _emit_dev_desc(2, 0x08, "vagal_rmssd")
    _emit_dev_desc(3, 0x04, "breath_cycles")
    _emit_dev_desc(4, 0x08, "live_rmssd")
    _emit_dev_desc(5, 0x02, "live_stress")
    _emit_dev_desc(6, 0x02, "stage_code")
    _emit_dev_desc(7, 0x04, "rr1_ms")
    _emit_dev_desc(8, 0x04, "rr2_ms")
    _emit_dev_desc(9, 0x08, "base_rmssd")
    _emit_dev_desc(10, 0x08, "rec_rmssd")
    _emit_dev_desc(11, 0x02, "base_hr")
    _emit_dev_desc(12, 0x02, "rec_hr")

    # Local 1: record (global 20) with 5 developer fields
    _def_mesg(
        1, 20,
        [(253, 4, 0x06), (3, 1, 0x02)],
        [(4, 4, 0), (5, 1, 0), (6, 1, 0), (7, 2, 0), (8, 2, 0)],
    )

    fit_t0 = start_unix - FIT_EPOCH_UNIX
    # Simulate 120s Baseline + 300s Breathing + 300s Recovery (720 records)
    stages_cfg = [
        (1, 120, base_hr, base_jitter),
        (2, 300, breath_hr, breath_jitter),
        (3, 300, rec_hr, rec_jitter),
    ]
    t_off = 0
    for st_code, dur_s, hr_val, jitter in stages_cfg:
        mean_rr = int(round(60000.0 / hr_val))
        rmssd_est = float(jitter)
        stress_est = int(round(compute_stress_from_rmssd(rmssd_est)))
        for sec in range(dur_s):
            sign = 1 if (sec % 2 == 0) else -1
            rr1 = mean_rr + (sign * jitter // 2)
            rr2 = 0
            body.append(0x01)  # data for local 1
            body.extend(struct.pack(
                "<IBfBBHH",
                fit_t0 + t_off,
                hr_val,
                rmssd_est,
                stress_est,
                st_code,
                rr1,
                rr2,
            ))
            t_off += 1

    # Local 2: session (global 18) with 8 developer fields
    _def_mesg(
        2, 18,
        [(253, 4, 0x06), (2, 4, 0x06), (5, 1, 0x00), (6, 1, 0x00), (7, 4, 0x06)],
        [(0, 1, 0), (1, 2, 0), (2, 4, 0), (3, 2, 0), (9, 4, 0), (10, 4, 0), (11, 1, 0), (12, 1, 0)],
    )
    body.append(0x02)
    body.extend(struct.pack(
        "<IIBBIBhfHffBB",
        fit_t0 + t_off,
        fit_t0,
        10,   # SPORT_TRAINING
        62,   # SUB_SPORT_BREATHING
        t_off * 1000,
        proto_id,
        rec_hr - base_hr,
        float(rec_jitter),
        30,
        float(base_jitter),
        float(rec_jitter),
        base_hr,
        rec_hr,
    ))

    header = struct.pack("<BBHI4sH", 14, 0x20, 2100, len(body), b".FIT", 0)
    footer_crc = struct.pack("<H", 0)
    out_path.write_bytes(header + bytes(body) + footer_crc)


def run_self_test() -> int:
    with tempfile.TemporaryDirectory(prefix="vagalbreath_selftest_") as td:
        td_path = Path(td)
        f1 = td_path / "2026-11-26-17-30-00.fit"
        f2 = td_path / "2026-11-27-17-30-00.fit"

        now_unix = int(dt.datetime(2026, 11, 26, 17, 30, 0).timestamp())
        # Vagal 4-6: strong vagal carry-over (+24 ms RMSSD, -6 bpm HR)
        _write_synthetic_vagalbreath_fit(f1, 3, now_unix, 72, 68, 66, 26, 62, 50)
        # Cyclic Sigh: moderate carry-over (+12 ms RMSSD, -4 bpm HR)
        _write_synthetic_vagalbreath_fit(f2, 1, now_unix + 86400, 72, 71, 68, 26, 48, 38)

        res1 = analyze_fit_session(f1)
        res2 = analyze_fit_session(f2)
        assert res1 is not None and res2 is not None, "Failed to decode synthetic FIT sessions"
        assert res1.protocol_name == "Vagal 4-6", f"Unexpected protocol: {res1.protocol_name}"
        assert res2.protocol_name == "Cyclic Sigh", f"Unexpected protocol: {res2.protocol_name}"
        assert res1.is_lab_mode and res2.is_lab_mode, "Lab Mode not detected"
        assert res1.delta_hr is not None and abs(res1.delta_hr - (-6.0)) < 0.2
        assert res1.delta_rmssd is not None and abs(res1.delta_rmssd - 24.0) < 0.5
        assert res2.delta_rmssd is not None and abs(res2.delta_rmssd - 12.0) < 0.5

        out_dir = td_path / "out"
        out_dir.mkdir()
        print_summary_tables([res1, res2])
        csv_p = export_csv([res1, res2], out_dir)
        plots = generate_plots([res1, res2], out_dir)
        assert csv_p.exists() and csv_p.stat().st_size > 100
        assert len(plots) == 3 and all(p.exists() and p.stat().st_size > 5000 for p in plots)
        print(f"\nSELF-TEST PASSED: decoded 2 synthetic FIT files, exported CSV + {len(plots)} PNG charts.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze VagalBreath Garmin .FIT sessions.")
    parser.add_argument(
        "inputs",
        nargs="*",
        default=["sessions"],
        help="Directory containing .fit files or individual .fit paths (default: sessions)",
    )
    parser.add_argument("--out", default="analysis_out", help="Output directory for CSV and plots")
    parser.add_argument("--include-native", action="store_true", help="Also include native Garmin Breathwork files")
    parser.add_argument("--no-plots", action="store_true", help="Skip generating PNG plots")
    parser.add_argument("--self-test", action="store_true", help="Run built-in binary FIT decoder self-test")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()

    fit_paths: List[Path] = []
    for raw in args.inputs:
        p = Path(raw)
        if p.is_dir():
            fit_paths.extend(sorted(p.glob("*.fit")) + sorted(p.glob("*.FIT")))
        elif p.is_file():
            fit_paths.append(p)

    # Deduplicate while preserving order
    seen = set()
    unique_paths: List[Path] = []
    for p in fit_paths:
        rp = p.resolve()
        if rp not in seen:
            seen.add(rp)
            unique_paths.append(p)

    if not unique_paths:
        print(f"No .fit files found in {args.inputs}. Pull sessions first with ./tools/garmin_pull_fit")
        return 1

    results: List[SessionAnalysis] = []
    for p in unique_paths:
        try:
            res = analyze_fit_session(p, include_native=args.include_native)
            if res is not None:
                results.append(res)
        except Exception as exc:
            print(f"Skipping {p.name}: {exc}", file=sys.stderr)

    if not results:
        print(f"Scanned {len(unique_paths)} .fit file(s), but found no VagalBreath sessions.")
        return 0

    print_summary_tables(results)

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    csv_path = export_csv(results, out_dir)
    print(f"\nExported CSV summary -> {csv_path}")

    if not args.no_plots:
        plots = generate_plots(results, out_dir)
        print(f"Generated {len(plots)} chart(s) in {out_dir}/:")
        for pl in plots:
            print(f"  - {pl}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
