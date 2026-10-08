#!/usr/bin/env python3
"""Procedural audio generator for Level 1 (abandoned industrial building).

Every sound is synthesised from scratch (no samples): filtered noise, damped
modal resonator banks, pitch-dropping thumps, stick-slip friction excitation,
saturation, and convolution with synthetic room impulse responses.

Run from the repo root:

    python3 dev/asset_gen/audio.py              # everything + QA report
    python3 dev/asset_gen/audio.py weapons ui   # only some families (+ QA)

Output: 16-bit PCM 44.1 kHz WAVs under assets/audio/. Positional sounds are
mono; ambience beds and UI are stereo. Loops are built to be exactly periodic
and carry a RIFF `smpl` chunk (forward loop, start=0, end=last sample) so
Godot's "Detect from WAV" loop import picks them up.

QA output (report + spectrogram/loop-seam PNGs) goes to dev/asset_gen/previews/.
All randomness is seeded from the output name, so runs are deterministic.
"""

from __future__ import annotations

import math
import os
import struct
import sys
import zlib

import numpy as np
from scipy import signal

SR = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, "assets", "audio")
PREV = os.path.join(HERE, "previews")
LN1000 = 6.907755  # ln(1000): exp(-LN1000 * t / t60) reaches -60 dB at t60

WRITTEN: list[str] = []


# =============================================================================
# Basic helpers
# =============================================================================

def rng_for(name: str) -> np.random.Generator:
    """Deterministic RNG seeded from a name."""
    return np.random.default_rng(zlib.crc32(name.encode("utf-8")))


def ns(sec: float) -> int:
    return int(round(sec * SR))


def tvec(n: int) -> np.ndarray:
    return np.arange(n) / SR


def db(x: float) -> float:
    return 20.0 * math.log10(max(x, 1e-12))


def undb(d: float) -> float:
    return 10.0 ** (d / 20.0)


def peak(x: np.ndarray) -> float:
    return float(np.max(np.abs(x))) if x.size else 0.0


def unit(x: np.ndarray) -> np.ndarray:
    p = peak(x)
    return x / p if p > 0 else x


def place(buf: np.ndarray, src: np.ndarray, t: float, gain: float = 1.0) -> None:
    """Add src into buf (last axis) at time t seconds, clipped to buf length."""
    i = ns(t)
    n = buf.shape[-1]
    if i >= n or i + src.shape[-1] <= 0:
        return
    s0 = max(0, -i)
    e = min(n, i + src.shape[-1])
    buf[..., max(i, 0):e] += gain * src[..., s0:s0 + e - max(i, 0)]


def place_circ(buf: np.ndarray, src: np.ndarray, t: float, gain: float = 1.0) -> None:
    """Add src into a periodic buffer, wrapping around its end."""
    n = buf.shape[-1]
    idx = (ns(t) + np.arange(src.shape[-1])) % n
    if buf.ndim == 1:
        np.add.at(buf, idx, gain * src)
    else:
        for c in range(buf.shape[0]):
            s = src[c] if src.ndim == 2 else src
            np.add.at(buf[c], idx, gain * s)


def pan(x: np.ndarray, p: float) -> np.ndarray:
    """Equal-power pan, p in [-1, 1] -> (2, n)."""
    a = (p + 1.0) * math.pi / 4.0
    return np.stack([x * math.cos(a), x * math.sin(a)])


def pf(f: float, period: float) -> float:
    """Round frequency so it completes an integer number of cycles per period."""
    return max(1, round(f * period)) / period


# =============================================================================
# Noise
# =============================================================================

def white(r: np.random.Generator, n: int) -> np.ndarray:
    return r.standard_normal(n)


def colored(r: np.random.Generator, n: int, exponent: float) -> np.ndarray:
    """1/f^exponent power-spectrum noise (1=pink, 2=brown). Periodic in n."""
    X = np.fft.rfft(r.standard_normal(n))
    f = np.fft.rfftfreq(n, 1.0 / SR)
    f[0] = f[1]
    X *= f ** (-exponent / 2.0)
    X[0] = 0
    y = np.fft.irfft(X, n)
    return y / (np.std(y) + 1e-12)


def smooth_curve(r: np.random.Generator, n: int, cutoff_hz: float) -> np.ndarray:
    """Smooth random curve in [0, 1] (band-limited, periodic in n)."""
    X = np.fft.rfft(r.standard_normal(n))
    k = max(2, int(cutoff_hz * n / SR))
    X[k:] = 0
    X[0] = 0
    y = np.fft.irfft(X, n)
    y -= y.min()
    return y / (y.max() + 1e-12)


# =============================================================================
# Filters (scipy.signal butterworth / biquads)
# =============================================================================

def _wn(f: float) -> float:
    return min(max(f, 5.0), SR * 0.49) / (SR / 2)


def lp(x, fc, order=2):
    return signal.sosfilt(signal.butter(order, _wn(fc), "low", output="sos"), x, axis=-1)


def hp(x, fc, order=2):
    return signal.sosfilt(signal.butter(order, _wn(fc), "high", output="sos"), x, axis=-1)


def bp(x, lo, hi, order=2):
    return signal.sosfilt(signal.butter(order, [_wn(lo), _wn(hi)], "band", output="sos"), x, axis=-1)


def reson(x, f0, q):
    """Resonant band-pass (biquad peak)."""
    b, a = signal.iirpeak(min(f0, SR * 0.45), q, fs=SR)
    return signal.lfilter(b, a, x, axis=-1)


def circ(fn, x):
    """Apply time-invariant processing to a periodic signal: run it over three
    copies and keep the middle one, so the result is exactly periodic."""
    n = x.shape[-1]
    y = fn(np.concatenate([x, x, x], axis=-1))
    return y[..., n:2 * n]


def morph_noise(noise, center, lo=120.0, hi=4000.0, bands=12, width_oct=0.55, filt=None):
    """Time-varying band-pass noise: crossfade a static filterbank by the
    distance of each band to the moving centre frequency `center` (array)."""
    filt = filt or (lambda s, a, b: bp(s, a, b, 2))
    cs = np.geomspace(lo, hi, bands)
    out = np.zeros_like(noise)
    lc = np.log2(np.maximum(center, 20.0))
    norm = np.zeros_like(noise)
    for fc in cs:
        band = filt(noise, fc / 2 ** 0.35, fc * 2 ** 0.35)
        band /= np.std(band) + 1e-12
        w = np.exp(-0.5 * ((math.log2(fc) - lc) / width_oct) ** 2)
        out += w * band
        norm += w * w
    return out / np.sqrt(norm + 1e-9)


# =============================================================================
# Envelopes and generators
# =============================================================================

def env_ad(n: int, attack: float, t60: float) -> np.ndarray:
    """Linear attack then exponential decay reaching -60 dB at t60 after the peak."""
    t = tvec(n)
    e = np.exp(-LN1000 * np.maximum(t - attack, 0.0) / max(t60, 1e-4))
    if attack > 0:
        e *= np.clip(t / attack, 0.0, 1.0)
    return e


def env_hann(n: int) -> np.ndarray:
    return np.hanning(n) if n > 2 else np.ones(n)


def thump(n, f0, f1, tau, t60, attack=0.0008, r=None):
    """Pitch-dropping sine (f0 -> f1 with time constant tau) under an AD envelope."""
    t = tvec(n)
    f = f1 + (f0 - f1) * np.exp(-t / tau)
    ph = 2 * np.pi * np.cumsum(f) / SR + (r.uniform(0, 2 * np.pi) if r is not None else 0.0)
    return np.sin(ph) * env_ad(n, attack, t60)


def modal_ir(freqs, t60s, amps, dur, r=None):
    """Bank of exponentially decaying sinusoids (impulse response of a modal resonator bank)."""
    n = ns(dur)
    t = tvec(n)
    y = np.zeros(n)
    for f, T, a in zip(freqs, t60s, amps):
        if f <= 20 or f >= SR * 0.45:
            continue
        ph = r.uniform(0, 2 * np.pi) if r is not None else 0.0
        y += a * np.exp(-LN1000 * t / T) * np.sin(2 * np.pi * f * t + ph)
    return y


def strike(r, freqs, t60s, amps, dur, hard=8000.0, exc_ms=0.3):
    """Excite a modal bank with a short noise burst (contact). `hard` = brightness."""
    L = max(4, ns(exc_ms / 1000.0))
    exc = r.standard_normal(L) * np.hanning(L)
    exc = lp(np.concatenate([exc, np.zeros(64)]), hard, 2)
    y = signal.fftconvolve(exc, modal_ir(freqs, t60s, amps, dur, r))[:ns(dur)]
    return unit(y)


def mclick(r, f, t60, nmodes=7, spread=(1.25, 5.5), hard=9000.0, tick=0.45, dur=None):
    """Short metallic click: inharmonic modal ring plus a broadband contact tick."""
    ratios = np.sort(np.concatenate([[1.0], r.uniform(spread[0], spread[1], nmodes - 1)]))
    freqs = f * ratios * r.uniform(0.98, 1.02, nmodes)
    t60s = t60 * ratios ** -0.45 * r.uniform(0.7, 1.3, nmodes)
    amps = r.uniform(0.4, 1.0, nmodes) / ratios ** 0.3
    dur = dur or min(t60 * 2.2 + 0.02, 3.0)
    ring = strike(r, freqs, t60s, amps, dur, hard=hard)
    n = ring.size
    tk = np.zeros(n)
    L = ns(0.003)
    tk[:L] = hp(r.standard_normal(L), 1800) * np.exp(-tvec(L) / 0.0004)
    return unit(ring + tick * unit(tk))


def thud(r, f, t60, noise_lp=None, dur=None):
    """Dull low impact: pitch-dropping sine + low-passed noise burst."""
    dur = dur or t60 * 1.5 + 0.02
    n = ns(dur)
    s = thump(n, f * 1.7, f, 0.008, t60, r=r)
    nz = lp(white(r, n), noise_lp or f * 5, 2)
    nz = unit(nz) * env_ad(n, 0.0008, t60 * 0.6)
    return unit(s + 0.7 * nz)


def scrape(r, dur, lo, hi, rough=0.6, attack=0.3, release=0.4, grit=0.0):
    """Friction slide: band-passed noise with grainy amplitude roughness."""
    n = ns(dur)
    nz = bp(white(r, n), lo, hi, 2)
    am = np.abs(lp(white(r, n), 90, 2))
    am = (1 - rough) + rough * unit(am)
    t = np.linspace(0, 1, n)
    shape = np.clip(t / max(attack, 1e-3), 0, 1) * np.clip((1 - t) / max(release, 1e-3), 0, 1)
    y = unit(nz) * am * shape
    if grit > 0:
        y += grit * grains(r, n, 0, dur, int(dur * 120), lo * 1.5, min(hi * 1.5, 16000))
    return unit(y)


def grains(r, n, t0, t1, count, lo, hi, gdur=(0.0004, 0.004), decay=None, amp=(0.15, 1.0)):
    """Scatter of tiny noise grains (grit, debris, crackle), band-passed."""
    out = np.zeros(n)
    if decay is None:
        times = r.uniform(t0, t1, count)
    else:
        times = t0 + r.exponential(decay, count)
        times = times[times < t1]
    for tt in times:
        L = max(3, ns(r.uniform(*gdur)))
        g = r.standard_normal(L) * np.hanning(L)
        a = r.uniform(*amp)
        if decay is not None:
            a *= math.exp(-(tt - t0) / (decay * 1.5))
        place(out, g, tt, a)
    return bp(out, lo, hi, 2)


def spring(r, f, t60, dur=None):
    """Coil spring twang: clusters of close, slightly detuned modes."""
    base = np.array([1.0, 1.012, 1.98, 2.03, 3.05, 4.2])
    freqs = f * base * r.uniform(0.99, 1.01, base.size)
    t60s = t60 * np.array([1, 0.9, 0.6, 0.6, 0.4, 0.3])
    amps = np.array([1, 0.8, 0.5, 0.4, 0.25, 0.15])
    return strike(r, freqs, t60s, amps, dur or t60 * 1.3, hard=6000)


def friction_pulses(r, n, rate, amp, jitter=0.12):
    """Stick-slip excitation: impulse train whose instantaneous rate (Hz) varies.
    Driving a resonator bank with it gives creaks (slow) and groans (fast)."""
    ph = np.cumsum(rate) / SR + r.uniform()
    idx = np.nonzero(np.diff(np.floor(ph)))[0] + 1
    if idx.size == 0:
        return np.zeros(n)
    per = SR / np.maximum(rate[idx], 1.0)
    idx = np.clip((idx + r.normal(0, jitter, idx.size) * per).astype(int), 0, n - 1)
    exc = np.zeros(n)
    np.add.at(exc, idx, amp[idx] * r.uniform(0.3, 1.0, idx.size))
    return exc


# =============================================================================
# Dynamics
# =============================================================================

def sat(x, drive):
    """tanh saturation, output peak-normalised."""
    return np.tanh(drive * unit(x)) / math.tanh(drive)


def soft_limit(x, knee=0.7):
    """Soft knee limiter for a peak-normalised signal (keeps |y| < 1)."""
    x = unit(x)
    a = np.abs(x)
    over = a > knee
    y = a.copy()
    y[over] = knee + (1 - knee) * np.tanh((a[over] - knee) / (1 - knee))
    return np.sign(x) * y


def normalize(x, peak_db):
    return unit(x) * undb(peak_db)


def normalize_rms(x, rms_db, peak_max_db=-1.0):
    rms = math.sqrt(float(np.mean(x ** 2))) + 1e-12
    y = x * undb(rms_db) / rms
    p = peak(y)
    if p > undb(peak_max_db):
        y *= undb(peak_max_db) / p
    return y


# =============================================================================
# Synthetic room impulse responses and convolution
# =============================================================================

def room_ir(r, rt60, predelay=0.005, er_span=0.07, er_count=14, er_gain=0.6,
            damping=0.6, er_lp=7000.0, stereo=False, dur=None, build=None, low_rt=0.8):
    """Synthetic room IR: sparse early reflections (low-passed by wall absorption)
    plus a diffuse noise tail whose decay rate varies smoothly with frequency
    (shaped per STFT bin): RT60 is `rt60` around 150-500 Hz, shorter above
    (highs die faster -> the tail gets darker with time) and `low_rt` x rt60
    in the sub range so the tail does not turn into mud.
    Energy-normalised (sum of squares = 1 per channel)."""
    dur = dur or rt60 * 1.15 + predelay
    n = ns(dur)
    t = tvec(n)
    nper = 512
    chans = []
    for _ in range(2 if stereo else 1):
        f, tt, Z = signal.stft(r.standard_normal(n + nper), SR, nperseg=nper)
        fr = np.maximum(f, 20.0)
        rt = rt60 * np.minimum(1.0, (500.0 / fr) ** damping)
        lowf = np.clip((fr - 40.0) / 110.0, 0.0, 1.0)          # 40 Hz -> low_rt, 150 Hz -> 1
        rt = np.maximum(rt * (low_rt + (1 - low_rt) * lowf), 0.05)
        Z *= np.exp(-LN1000 * tt[None, :] / rt[:, None])
        _, tail = signal.istft(Z, SR, nperseg=nper)
        tail = tail[:n]
        b = build or er_span
        ramp = np.clip((t - predelay) / b, 0, 1) ** 1.5
        tail *= ramp
        tail /= math.sqrt(np.sum(tail ** 2)) + 1e-12
        er = np.zeros(n)
        times = np.sort(predelay + r.uniform(0, er_span, er_count))
        for tt_ in times:
            a = er_gain * r.uniform(0.4, 1.0) * (1.0 - 0.6 * (tt_ - predelay) / er_span)
            i = ns(tt_)
            if i < n:
                er[i] += a * r.choice([-1.0, 1.0])
        er = lp(er, er_lp, 2)
        ir = tail + er
        ir /= math.sqrt(np.sum(ir ** 2)) + 1e-12
        chans.append(ir)
    return np.stack(chans) if stereo else chans[0]


def reverb(x, ir, wet, dry=1.0):
    """Linear convolution reverb; output is extended by the IR length."""
    y = signal.fftconvolve(x if ir.ndim == 1 else x[None, :], ir, axes=-1)
    out = wet * y
    out[..., :x.shape[-1]] += dry * x
    return out


def circ_conv(x, ir):
    """Circular convolution (for loops): the reverb tail wraps to the start."""
    n = x.shape[-1]
    L = ir.shape[-1]
    m = int(math.ceil(L / n)) * n
    irp = np.zeros(ir.shape[:-1] + (m,))
    irp[..., :L] = ir
    irf = irp.reshape(ir.shape[:-1] + (m // n, n)).sum(axis=-2)
    return np.fft.irfft(np.fft.rfft(x, axis=-1) * np.fft.rfft(irf, axis=-1), n, axis=-1)


def loop_crossfade(x, n, xf):
    """Crossfade-to-start: x has n + xf samples; its tail (which continues
    naturally from sample n-1) is equal-power faded into the first xf samples."""
    w = np.linspace(0, 1, xf)
    fin = np.sin(w * np.pi / 2)
    fout = np.cos(w * np.pi / 2)
    out = x[..., :n].copy()
    out[..., :xf] = x[..., :xf] * fin + x[..., n:n + xf] * fout
    return out


# =============================================================================
# Finishing and WAV I/O
# =============================================================================

def finish(x, peak_db=-1.0, trim_db=-66.0, fade=0.03, max_len=None, limit=None, lead=0):
    """One-shot finishing: DC removal, trim silent tail, fade out, (limit), normalise."""
    x = hp(x, 18, 2)
    if lead:
        x = np.concatenate([np.zeros(x.shape[:-1] + (lead,)), x], axis=-1)
    mono = np.max(np.abs(x), axis=0) if x.ndim == 2 else np.abs(x)
    thr = mono.max() * undb(trim_db)
    last = int(np.nonzero(mono > thr)[0][-1]) + 1
    last = min(x.shape[-1], last + ns(0.01))
    if max_len:
        last = min(last, ns(max_len))
    x = x[..., :last].copy()
    f = min(ns(fade), last // 3)
    x[..., last - f:] *= np.cos(np.linspace(0, np.pi / 2, f)) ** 2
    if limit is not None:
        x = soft_limit(x, limit)
    return normalize(x, peak_db)


def finish_loop(x, peak_db=None, rms_db=None, peak_max_db=-1.0):
    """Loop finishing: periodic DC removal, normalise. No fades."""
    x = circ(lambda s: hp(s, 18, 2), x)
    x = x - np.mean(x, axis=-1, keepdims=True)
    if rms_db is not None:
        return normalize_rms(x, rms_db, peak_max_db)
    return normalize(x, peak_db if peak_db is not None else -1.0)


def write_wav(rel: str, x: np.ndarray, loop: bool = False) -> str:
    """16-bit PCM WAV. x: (n,) mono or (2, n) stereo, float in [-1, 1].
    loop=True appends a RIFF `smpl` chunk with one forward loop 0..n-1."""
    path = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    x = np.asarray(x, dtype=np.float64)
    ch = 1 if x.ndim == 1 else x.shape[0]
    frames = x if x.ndim == 1 else x.T
    pcm = np.clip(np.round(frames * 32767.0), -32768, 32767).astype("<i2")
    n = x.shape[-1]
    data = pcm.tobytes()
    fmt = struct.pack("<HHIIHH", 1, ch, SR, SR * ch * 2, ch * 2, 16)
    chunks = [(b"fmt ", fmt), (b"data", data)]
    if loop:
        smpl = struct.pack("<9I", 0, 0, int(round(1e9 / SR)), 60, 0, 0, 0, 1, 0)
        smpl += struct.pack("<6I", 0, 0, 0, n - 1, 0, 0)  # id, forward, start, end, fraction, count(0=inf)
        chunks.append((b"smpl", smpl))
    body = b"WAVE"
    for cid, cdata in chunks:
        body += cid + struct.pack("<I", len(cdata)) + cdata
        if len(cdata) % 2:
            body += b"\x00"
    with open(path, "wb") as fh:
        fh.write(b"RIFF" + struct.pack("<I", len(body)) + body)
    WRITTEN.append(path)
    return path


def read_wav(path: str):
    """Parse our WAVs back: returns (float data (ch, n), sample rate, loop tuple or None)."""
    with open(path, "rb") as fh:
        raw = fh.read()
    assert raw[:4] == b"RIFF" and raw[8:12] == b"WAVE", path
    pos = 12
    ch = sr = bits = None
    data = None
    loop = None
    while pos + 8 <= len(raw):
        cid = raw[pos:pos + 4]
        size = struct.unpack("<I", raw[pos + 4:pos + 8])[0]
        body = raw[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            _, ch, sr, _, _, bits = struct.unpack("<HHIIHH", body[:16])
        elif cid == b"data":
            data = np.frombuffer(body, dtype="<i2").astype(np.float64) / 32768.0
        elif cid == b"smpl":
            nloops = struct.unpack("<I", body[28:32])[0]
            if nloops:
                _, ltype, start, end, _, _ = struct.unpack("<6I", body[36:60])
                loop = (ltype, start, end)
        pos += 8 + size + (size % 2)
    assert bits == 16
    data = data.reshape(-1, ch).T
    return data, sr, loop


# =============================================================================
# Shared rooms
# =============================================================================

def hall_ir(name, rt60, **kw):
    """Big concrete/steel hall."""
    kw.setdefault("predelay", 0.006)
    kw.setdefault("er_span", 0.09)
    kw.setdefault("er_count", 18)
    kw.setdefault("er_gain", 0.7)
    kw.setdefault("damping", 0.65)
    return room_ir(rng_for("ir_" + name), rt60, **kw)


def small_ir(name, rt60=0.6, **kw):
    """Small concrete room / close foley space."""
    kw.setdefault("predelay", 0.002)
    kw.setdefault("er_span", 0.025)
    kw.setdefault("er_count", 10)
    kw.setdefault("er_gain", 0.5)
    kw.setdefault("damping", 0.7)
    return room_ir(rng_for("ir_" + name), rt60, **kw)


# =============================================================================
# Weapons
# =============================================================================

GUNS = {
    # crack: supersonic N-wave + bright tick; blast: (band, bright t60, body t60, dark lp)
    # boom: (f0, f1, tau, t60, gain); mech: [(time, freq, t60, gain)]
    "ak47": dict(crack=0.75, blast=1.0, nwave_ms=0.32, crack_hp=1800,
                 band=(110, 5200), bright_t60=0.10, body_t60=0.20, dark_lp=1150, dark_gain=1.3,
                 boom=(155, 52, 0.012, 0.16, 0.42), mech=[(0.003, 2300, 0.06, 0.10),
                                                        (0.050, 1200, 0.11, 0.17),
                                                        (0.056, 700, 0.12, 0.12)],
                 drive=2.6, rt60=1.45, wet=0.30),
    "m16": dict(crack=1.0, blast=1.0, nwave_ms=0.22, crack_hp=3000,
                band=(320, 9000), bright_t60=0.075, body_t60=0.13, dark_lp=1900, dark_gain=0.8,
                boom=(210, 80, 0.008, 0.09, 0.18), mech=[(0.003, 3100, 0.05, 0.08),
                                                        (0.038, 2000, 0.07, 0.10),
                                                        (0.041, 1850, 0.32, 0.035)],  # buffer spring
                drive=2.2, rt60=1.3, wet=0.27),
    "mp5": dict(crack=0.3, blast=0.9, nwave_ms=0.18, crack_hp=2600,
                band=(250, 3600), bright_t60=0.045, body_t60=0.08, dark_lp=1500, dark_gain=0.9,
                boom=(240, 100, 0.006, 0.07, 0.16), mech=[(0.004, 2600, 0.05, 0.20),
                                                        (0.024, 1700, 0.07, 0.30),
                                                        (0.029, 3400, 0.04, 0.18)],
                drive=1.8, rt60=1.1, wet=0.24),
    "m40": dict(crack=1.0, blast=1.1, nwave_ms=0.38, crack_hp=1600,
                band=(80, 6000), bright_t60=0.13, body_t60=0.30, dark_lp=900, dark_gain=1.6,
                boom=(130, 42, 0.016, 0.26, 0.62), mech=[(0.002, 3300, 0.04, 0.05)],
                drive=3.0, rt60=1.8, wet=0.36),
    # .45 ACP is subsonic: no crack, a deep rounded blast and a slide clack.
    "m1911": dict(crack=0.0, blast=0.85, nwave_ms=0.1, crack_hp=2000,
                  band=(150, 4200), bright_t60=0.05, body_t60=0.11, dark_lp=1300, dark_gain=1.25,
                  boom=(185, 62, 0.008, 0.11, 0.36), mech=[(0.003, 2400, 0.04, 0.12),
                                                          (0.030, 1500, 0.08, 0.26),
                                                          (0.034, 2900, 0.04, 0.12)],
                  drive=2.2, rt60=1.25, wet=0.28),
    # 12 gauge buckshot: a huge rounded boom, barely a crack.
    "remington870": dict(crack=0.3, blast=1.2, nwave_ms=0.2, crack_hp=1500,
                         band=(90, 4500), bright_t60=0.12, body_t60=0.28, dark_lp=900, dark_gain=1.7,
                         boom=(120, 40, 0.016, 0.24, 0.7), mech=[(0.003, 2000, 0.05, 0.08)],
                         drive=3.2, rt60=1.7, wet=0.34),
    # Open bolt: the bolt slamming forward is half the sound.
    "uzi": dict(crack=0.35, blast=1.0, nwave_ms=0.18, crack_hp=2400,
                band=(220, 4200), bright_t60=0.05, body_t60=0.10, dark_lp=1400, dark_gain=1.0,
                boom=(220, 90, 0.007, 0.08, 0.2), mech=[(0.004, 2200, 0.06, 0.25), (0.022, 1300, 0.09, 0.35)],
                drive=2.0, rt60=1.15, wet=0.25),
    "fal": dict(crack=1.0, blast=1.1, nwave_ms=0.36, crack_hp=1700,
                band=(90, 6000), bright_t60=0.12, body_t60=0.26, dark_lp=1000, dark_gain=1.5,
                boom=(140, 46, 0.014, 0.22, 0.55), mech=[(0.003, 2600, 0.05, 0.10), (0.045, 1400, 0.10, 0.16)],
                drive=2.9, rt60=1.7, wet=0.34),
    # Roller-delayed: a hard metallic slap after the blast.
    "g3": dict(crack=1.0, blast=1.1, nwave_ms=0.35, crack_hp=1800,
               band=(100, 6500), bright_t60=0.11, body_t60=0.24, dark_lp=1050, dark_gain=1.45,
               boom=(145, 48, 0.013, 0.2, 0.5), mech=[(0.003, 2900, 0.05, 0.12), (0.030, 1800, 0.12, 0.22)],
               drive=2.8, rt60=1.65, wet=0.33),
    # Short barrel: a vicious, bright blast.
    "aks74u": dict(crack=0.8, blast=1.2, nwave_ms=0.24, crack_hp=2600,
                   band=(200, 8000), bright_t60=0.09, body_t60=0.15, dark_lp=1500, dark_gain=1.0,
                   boom=(190, 70, 0.009, 0.12, 0.3), mech=[(0.003, 2600, 0.05, 0.10), (0.045, 1300, 0.10, 0.15)],
                   drive=2.6, rt60=1.4, wet=0.30),
    "svd": dict(crack=1.0, blast=1.1, nwave_ms=0.4, crack_hp=1500,
                band=(80, 6000), bright_t60=0.13, body_t60=0.30, dark_lp=900, dark_gain=1.6,
                boom=(130, 42, 0.016, 0.26, 0.6), mech=[(0.003, 2400, 0.05, 0.08), (0.050, 1200, 0.10, 0.14)],
                drive=3.0, rt60=1.8, wet=0.36),
    "beretta92": dict(crack=0.2, blast=0.8, nwave_ms=0.12, crack_hp=2400,
                      band=(220, 5000), bright_t60=0.045, body_t60=0.09, dark_lp=1500, dark_gain=1.0,
                      boom=(220, 85, 0.007, 0.09, 0.25), mech=[(0.003, 2600, 0.04, 0.12), (0.028, 1700, 0.07, 0.24)],
                      drive=2.0, rt60=1.2, wet=0.27),
    # .357 Magnum out of a revolver: loud, with the cylinder gap's spit.
    "python": dict(crack=0.6, blast=1.15, nwave_ms=0.2, crack_hp=2200,
                   band=(130, 5500), bright_t60=0.08, body_t60=0.16, dark_lp=1200, dark_gain=1.4,
                   boom=(170, 55, 0.01, 0.16, 0.5), mech=[(0.003, 3300, 0.03, 0.05)],
                   drive=2.6, rt60=1.4, wet=0.30),
}


def gun_dry(gid: str, r: np.random.Generator, var: float = 1.0, with_crack=True):
    """Dry gunshot source (crack + muzzle blast + low boom + action)."""
    g = GUNS[gid]
    n = ns(0.9)
    out = np.zeros(n)
    t0 = 0.0005
    # 1. supersonic crack: N-wave + very short highpassed noise tick
    if with_crack:
        L = max(4, ns(g["nwave_ms"] / 1000.0 * r.uniform(0.9, 1.1)))
        nw = np.linspace(1.0, -1.0, L)
        tk = hp(white(r, ns(0.003)), g["crack_hp"], 2) * np.exp(-tvec(ns(0.003)) / 0.00035)
        crack = np.zeros(ns(0.004))
        crack[:L] += nw
        crack[:tk.size] += 0.6 * unit(tk)
        place(out, crack, t0, g["crack"])
    # 2. muzzle blast: bright fast-decaying noise + darker slower body
    m = n
    lo, hi = g["band"]
    def std1(z):
        return z / (np.std(z) + 1e-12)
    bright = std1(bp(white(r, m), lo * var, hi * var, 2)) * env_ad(m, 0.0003, g["bright_t60"] * r.uniform(0.9, 1.1))
    dark = std1(lp(white(r, m), g["dark_lp"] * var, 2)) * env_ad(m, 0.0012, g["body_t60"] * r.uniform(0.9, 1.1))
    blast = g["blast"] * (0.45 * bright + g["dark_gain"] * 0.22 * dark)
    place(out, blast, t0 + 0.0002)
    # 3. low boom: pitch-dropping thump + sub noise
    f0, f1, tau, t60, gain = g["boom"]
    bm = thump(m, f0 * var, f1 * var, tau, t60, attack=0.0012, r=r)
    sub = unit(lp(white(r, m), f0 * 1.5, 2)) * env_ad(m, 0.002, t60 * 0.7)
    place(out, gain * (bm + 0.35 * sub), t0 + 0.0004, 0.8)
    # 4. mechanical action
    for (tt, f, t60m, gm) in g["mech"]:
        c = mclick(r, f * var * r.uniform(0.96, 1.04), t60m)
        place(out, c, t0 + tt + r.uniform(-0.0015, 0.0015), gm * r.uniform(0.85, 1.15))
    return out


def gunshot(gid, variant):
    g = GUNS[gid]
    r = rng_for(f"shot_{gid}_{variant}")
    var = r.uniform(0.97, 1.03)
    dry = gun_dry(gid, r, var)
    dry = sat(dry, g["drive"])
    ir = hall_ir(f"gunhall_{gid}", g["rt60"], er_gain=0.85)
    y = reverb(dry, ir, g["wet"] * r.uniform(0.92, 1.08))
    y = hp(y, 45, 2)
    return finish(y, -1.0, trim_db=-62, max_len=g["rt60"] + 0.35, limit=0.6, lead=8)


def gunshot_distant(gid):
    g = GUNS[gid]
    r = rng_for(f"shot_distant_{gid}")
    dry = gun_dry(gid, r, 1.0, with_crack=False)
    dry = lp(dry, 700 if gid != "mp5" else 900, 4)
    ir = hall_ir("distant_hall", g["rt60"] * 1.4, predelay=0.03, er_span=0.18, er_count=30,
                 er_gain=0.5, damping=0.9, er_lp=2500, low_rt=1.0)
    y = reverb(dry, ir, 1.0, dry=0.2)
    y = lp(y, 2200, 2)
    return finish(y, -6.0, trim_db=-58, max_len=g["rt60"] * 1.4 + 0.6, lead=8)


def seq(events, dur):
    """Mix a list of (time, signal, gain) into a buffer of dur seconds."""
    buf = np.zeros(ns(dur))
    for tt, s, gain in events:
        place(buf, s, tt, gain)
    return buf


FOLEY_TILT = {"ak47": 0.85, "m16": 1.15, "mp5": 1.0, "m40": 0.95, "m1911": 1.05, "remington870": 0.9, "uzi": 0.95,
              "fal": 0.9, "g3": 1.05, "aks74u": 0.95, "svd": 0.88, "beretta92": 1.1, "python": 1.0}
## Which handling sounds a gun shares (new guns borrow the nearest action).
FOLEY_STYLE = {"remington870": "pump", "uzi": "mp5", "fal": "ak47", "g3": "mp5", "aks74u": "ak47", "svd": "ak47",
               "beretta92": "m1911", "python": "revolver"}


def foley_finish(name, x, wet=0.10, peak_db=-3.0):
    ir = small_ir("foley", 0.55)
    return finish(reverb(x, ir, wet), peak_db, trim_db=-60, lead=8)


def gen_weapon_foley(gid):
    k = FOLEY_TILT[gid]
    base = f"weapons/{gid}/"
    style = FOLEY_STYLE.get(gid, gid)

    def R(name):
        return rng_for(f"{gid}_{name}")

    # dry fire -----------------------------------------------------------------
    r = R("dry")
    if style == "ak47":
        ev = [(0.0, mclick(r, 3000 * k, 0.02), 0.18), (0.06, mclick(r, 1700 * k, 0.07), 1.0),
              (0.061, thud(r, 260, 0.04), 0.45)]
    elif style == "m16":
        ev = [(0.0, mclick(r, 3400 * k, 0.02), 0.2), (0.05, mclick(r, 2500 * k, 0.05), 1.0),
              (0.051, thud(r, 320, 0.03), 0.25)]
    elif style == "mp5":
        ev = [(0.0, mclick(r, 2800, 0.015), 0.25), (0.045, mclick(r, 2100, 0.04, hard=6000), 1.0),
              (0.046, thud(r, 420, 0.03, noise_lp=2500), 0.5)]
    elif style == "m1911":  # hammer falling on an empty chamber
        ev = [(0.0, mclick(r, 3100, 0.015), 0.2), (0.03, mclick(r, 2200, 0.05), 1.0),
              (0.031, thud(r, 380, 0.025), 0.35)]
    elif style == "revolver":  # double-action pull, hammer on a spent case
        ev = [(0.0, scrape(r, 0.1, 1500, 5000, grit=0.1), 0.25), (0.12, mclick(r, 2600, 0.04), 1.0),
              (0.121, thud(r, 420, 0.02), 0.3)]
    elif style == "pump":  # hammer drop on an empty chamber
        ev = [(0.0, mclick(r, 2800, 0.02), 0.25), (0.04, mclick(r, 1900, 0.06), 1.0), (0.041, thud(r, 300, 0.03), 0.4)]
    else:
        ev = [(0.0, mclick(r, 3500, 0.015), 0.2), (0.05, mclick(r, 3200, 0.04), 1.0),
              (0.051, spring(r, 2600, 0.09), 0.12)]
    write_wav(base + "dry_fire.wav", foley_finish("dry", seq(ev, 0.4)))

    # mag out ------------------------------------------------------------------
    r = R("magout")
    if style == "ak47":
        ev = [(0.0, mclick(r, 1600 * k, 0.05), 0.7),
              (0.05, scrape(r, 0.2, 600, 4000, grit=0.3), 0.35),
              (0.26, mclick(r, 900, 0.13), 0.75),
              (0.27, grains(r, ns(0.2), 0, 0.15, 14, 1500, 7000, decay=0.05), 0.5),
              (0.27, spring(r, 1400, 0.15), 0.08)]
    elif style == "m16":
        ev = [(0.0, mclick(r, 2900, 0.03), 0.7),
              (0.035, scrape(r, 0.12, 1500, 7000, grit=0.2), 0.3),
              (0.16, mclick(r, 1750, 0.16, hard=11000), 0.55),
              (0.165, grains(r, ns(0.15), 0, 0.1, 10, 2000, 9000, decay=0.03), 0.35)]
    elif style == "mp5":
        ev = [(0.0, mclick(r, 2400, 0.03), 0.75),
              (0.04, scrape(r, 0.16, 900, 5000, grit=0.25), 0.33),
              (0.2, mclick(r, 1300, 0.10), 0.65),
              (0.205, grains(r, ns(0.15), 0, 0.1, 10, 1500, 8000, decay=0.03), 0.35)]
    elif style == "m1911":  # mag catch button, magazine slides out of the grip
        ev = [(0.0, mclick(r, 3300, 0.025), 0.75),
              (0.02, scrape(r, 0.09, 1600, 7000, grit=0.15), 0.3),
              (0.12, mclick(r, 1900, 0.06), 0.4)]
    elif style == "revolver":  # cylinder latch, cylinder swings out, empties tinkle out
        ev = [(0.0, mclick(r, 3000, 0.03), 0.7), (0.05, scrape(r, 0.08, 1200, 5000), 0.3),
              (0.13, mclick(r, 1700, 0.07), 0.8),
              (0.3, grains(r, ns(0.25), 0, 0.2, 18, 3000, 9000, decay=0.06), 0.5)]
    elif style == "pump":  # nothing comes out: the tube is loaded from below
        ev = [(0.0, mclick(r, 2400, 0.03), 0.4)]
    else:  # hinged floorplate release (internal magazine)
        ev = [(0.0, mclick(r, 3000, 0.03), 0.7), (0.03, scrape(r, 0.06, 1500, 6000), 0.2),
              (0.09, mclick(r, 1500, 0.08), 0.6), (0.09, spring(r, 1900, 0.18), 0.1)]
    write_wav(base + "mag_out.wav", foley_finish("magout", seq(ev, 0.7)))

    # mag in -------------------------------------------------------------------
    r = R("magin")
    if style == "ak47":
        ev = [(0.0, scrape(r, 0.12, 700, 4500, grit=0.3), 0.35),
              (0.12, mclick(r, 1400, 0.05), 0.5),
              (0.24, mclick(r, 950, 0.11), 1.0), (0.241, thud(r, 210, 0.05), 0.55),
              (0.245, grains(r, ns(0.12), 0, 0.08, 10, 1500, 7000, decay=0.03), 0.3)]
    elif style == "m16":
        ev = [(0.0, scrape(r, 0.10, 1500, 7500, grit=0.2), 0.3),
              (0.11, mclick(r, 2600, 0.06, hard=11000), 1.0), (0.112, thud(r, 180, 0.05), 0.5),
              (0.115, grains(r, ns(0.1), 0, 0.06, 8, 2500, 9000, decay=0.02), 0.25)]
    elif style == "mp5":
        ev = [(0.0, scrape(r, 0.12, 900, 5500, grit=0.25), 0.3),
              (0.13, mclick(r, 2000, 0.07), 1.0), (0.132, thud(r, 200, 0.05), 0.5),
              (0.14, mclick(r, 3300, 0.03), 0.3)]
    elif style == "m1911":  # magazine slapped home
        ev = [(0.0, scrape(r, 0.07, 1500, 7000, grit=0.15), 0.3),
              (0.08, thud(r, 170, 0.05, noise_lp=1200), 0.7),
              (0.081, mclick(r, 2700, 0.05, hard=10000), 1.0)]
    elif style == "revolver":  # one round into a chamber
        ev = [(0.0, scrape(r, 0.05, 2500, 9000, rough=0.7), 0.25),
              (0.055, mclick(r, 4200, 0.04, hard=12000), 0.9), (0.056, thud(r, 600, 0.015), 0.2)]
    elif style == "pump":  # a shell thumbed into the tube against the spring
        ev = [(0.0, scrape(r, 0.07, 900, 4000, rough=0.7), 0.35),
              (0.075, mclick(r, 1500, 0.05), 0.8), (0.076, thud(r, 240, 0.04, noise_lp=1500), 0.6),
              (0.08, spring(r, 1100, 0.12), 0.12)]
    else:  # single .308 round pushed into the internal magazine
        ev = [(0.0, scrape(r, 0.09, 2000, 8000, rough=0.8), 0.3),
              (0.095, mclick(r, 3900, 0.05, hard=12000), 0.9),
              (0.097, spring(r, 2300, 0.12), 0.12), (0.096, thud(r, 400, 0.02), 0.25)]
    write_wav(base + "mag_in.wav", foley_finish("magin", seq(ev, 0.7)))

    # charge -------------------------------------------------------------------
    r = R("charge")
    if style == "ak47":
        ev = [(0.0, mclick(r, 1500, 0.04), 0.5),
              (0.02, scrape(r, 0.15, 700, 5000, rough=0.8, grit=0.4), 0.45),
              (0.17, mclick(r, 1100, 0.07), 0.6),
              (0.33, mclick(r, 780, 0.15), 1.0), (0.331, mclick(r, 2100, 0.08), 0.6),
              (0.332, thud(r, 190, 0.06), 0.55),
              (0.34, grains(r, ns(0.2), 0, 0.14, 22, 1200, 7000, decay=0.04), 0.45),
              (0.335, spring(r, 1250, 0.2), 0.08)]
        dur = 0.9
    elif style == "m16":
        ev = [(0.0, mclick(r, 2900, 0.03), 0.5),
              (0.02, scrape(r, 0.12, 1500, 7000, grit=0.2), 0.35),
              (0.15, mclick(r, 2000, 0.05), 0.5),
              (0.30, mclick(r, 1500, 0.10), 1.0), (0.301, thud(r, 240, 0.04), 0.35),
              (0.302, spring(r, 1900, 0.3), 0.1),
              (0.37, mclick(r, 3200, 0.03), 0.55)]
        dur = 0.8
    elif style == "mp5":
        ev = [(0.0, mclick(r, 1800, 0.04), 0.5),
              (0.02, scrape(r, 0.09, 900, 5000, grit=0.2), 0.35),
              (0.11, mclick(r, 2600, 0.04), 0.7),
              (0.36, thud(r, 150, 0.06, noise_lp=1100), 0.9),   # palm slap
              (0.362, mclick(r, 1300, 0.10), 1.0),
              (0.365, grains(r, ns(0.12), 0, 0.08, 12, 1500, 7000, decay=0.025), 0.35)]
        dur = 0.8
    elif style == "m1911":  # slide racked back and released
        ev = [(0.0, mclick(r, 2300, 0.03), 0.5),
              (0.01, scrape(r, 0.1, 1300, 7000, grit=0.2), 0.45),
              (0.11, mclick(r, 3000, 0.04), 0.6),
              (0.22, mclick(r, 1800, 0.08), 1.0), (0.221, thud(r, 260, 0.04), 0.5),
              (0.222, spring(r, 2100, 0.15), 0.1)]
        dur = 0.6
    elif style == "revolver":  # cylinder snapped shut
        ev = [(0.0, scrape(r, 0.05, 1500, 6000), 0.2), (0.06, mclick(r, 1900, 0.06), 1.0),
              (0.061, thud(r, 320, 0.03), 0.45), (0.065, mclick(r, 3600, 0.03), 0.4)]
        dur = 0.4
    elif style == "pump":  # shuck-shuck: back (wood on steel, the action bars) and forward
        ev = [(0.0, mclick(r, 1500, 0.04), 0.6),
              (0.01, scrape(r, 0.12, 400, 3500, rough=0.9, grit=0.4), 0.55),
              (0.13, mclick(r, 900, 0.10), 1.0), (0.131, thud(r, 180, 0.06, noise_lp=1200), 0.7),
              (0.2, scrape(r, 0.1, 500, 3800, rough=0.9, grit=0.3), 0.45),
              (0.31, mclick(r, 1150, 0.09), 1.0), (0.311, thud(r, 210, 0.05, noise_lp=1300), 0.6)]
        dur = 0.6
    else:  # bolt up, back, forward, down
        ev = [(0.0, mclick(r, 2400, 0.04), 0.6), (0.0, scrape(r, 0.07, 1500, 6000), 0.2),
              (0.13, scrape(r, 0.2, 1200, 6000, attack=0.6, release=0.1, grit=0.15), 0.4),
              (0.33, mclick(r, 3500, 0.03), 0.6), (0.335, mclick(r, 5200, 0.12, hard=14000), 0.15),
              (0.46, scrape(r, 0.16, 1000, 5000, attack=0.2, release=0.3, grit=0.1), 0.35),
              (0.62, mclick(r, 1600, 0.06), 0.7),
              (0.71, mclick(r, 2000, 0.06), 1.0), (0.712, thud(r, 260, 0.04), 0.5)]
        dur = 1.1
    write_wav(base + "charge.wav", foley_finish("charge", seq(ev, dur)))

    # fire select / safety -----------------------------------------------------
    r = R("select")
    if style == "ak47":
        ev = [(0.0, mclick(r, 1300, 0.08), 1.0), (0.018, mclick(r, 2300, 0.03), 0.4),
              (0.001, thud(r, 300, 0.03), 0.3)]
    elif style == "m16":
        ev = [(0.0, mclick(r, 3000, 0.035, hard=11000), 1.0), (0.001, thud(r, 380, 0.02), 0.2)]
    elif style == "mp5":
        ev = [(0.0, mclick(r, 2600, 0.04, hard=7000), 1.0), (0.001, thud(r, 450, 0.02, noise_lp=2500), 0.3)]
    elif style == "m1911":  # thumb safety
        ev = [(0.0, mclick(r, 3800, 0.02), 0.9), (0.001, thud(r, 500, 0.015), 0.15)]
    elif style in ("revolver", "pump"):  # crossbolt safety / thumbing the hammer
        ev = [(0.0, mclick(r, 3200, 0.03), 0.9), (0.001, thud(r, 450, 0.02), 0.2)]
    else:
        ev = [(0.0, mclick(r, 3600, 0.025), 0.8), (0.01, mclick(r, 4400, 0.015), 0.25)]
    write_wav(base + "fire_select.wav", foley_finish("select", seq(ev, 0.3), peak_db=-4.0))


def gen_weapons():
    for gid in GUNS:
        for v in (1, 2, 3):
            write_wav(f"weapons/{gid}/shot_{v}.wav", gunshot(gid, v))
        write_wav(f"weapons/{gid}/shot_distant.wav", gunshot_distant(gid))
        gen_weapon_foley(gid)


# =============================================================================
# Impacts
# =============================================================================

METAL_RATIOS = np.array([1.0, 1.47, 2.09, 2.56, 2.91, 3.62, 4.47, 5.13, 6.31, 7.82, 9.4])


def metal_ring(r, f0, t60, dur):
    ratios = METAL_RATIOS * r.uniform(0.97, 1.03, METAL_RATIOS.size)
    t60s = np.clip(t60 * ratios ** -0.55 * r.uniform(0.7, 1.3, ratios.size), 0.04, 2.0)
    amps = r.uniform(0.3, 1.0, ratios.size) / ratios ** 0.4
    return strike(r, f0 * ratios, t60s, amps, dur, hard=14000, exc_ms=0.12)


def whine(r, dur, f_start, f_end, tumble=(50, 130)):
    """Ricochet whine: tumbling fragment, Doppler-falling narrowband tone."""
    n = ns(dur)
    t = tvec(n)
    f = f_end + (f_start - f_end) * np.exp(-t / (dur * 0.45))
    ph = 2 * np.pi * np.cumsum(f) / SR
    nb = unit(lp(white(r, n), 260, 2))          # narrowband noise via ring modulation
    tone = np.sin(ph) * (0.6 + 0.4 * nb) + 0.25 * np.sin(2 * ph + 1.0) + 0.35 * nb * np.sin(ph * 1.5)
    tb = r.uniform(*tumble)
    am = 0.65 + 0.35 * np.sin(2 * np.pi * np.cumsum(tb * (1 - 0.3 * t / dur)) / SR)
    env = np.clip(t / 0.03, 0, 1) * np.exp(-LN1000 * t / (dur * 1.1))
    return unit(tone * am * env)


def gen_impacts():
    base = "impacts/"
    ir = small_ir("impact_room", 0.9, er_gain=0.6)
    # metal ---------------------------------------------------------------------
    for i in (1, 2, 3):
        r = rng_for(f"impact_metal_{i}")
        n = ns(1.2)
        f0 = r.uniform(750, 1500)
        ring = metal_ring(r, f0, r.uniform(0.35, 0.8), 1.2)
        crack = np.zeros(n)
        L = ns(0.004)
        crack[:L] = unit(hp(white(r, L), 2500)) * np.exp(-tvec(L) / 0.0006)
        x = crack + 0.75 * ring
        x += 0.35 * unit(bp(white(r, n), 400, 3000)) * env_ad(n, 0.0005, 0.06)
        if i == 2:
            place(x, whine(r, 0.55, 4200, 1700), 0.02, 0.35)
        y = reverb(x, ir, 0.18)
        write_wav(f"{base}metal_{i}.wav", finish(y, -2.0, trim_db=-60))
    for i in (1, 2):
        r = rng_for(f"ricochet_{i}")
        dur = r.uniform(0.6, 0.85)
        n = ns(dur + 0.1)
        x = np.zeros(n)
        L = ns(0.004)
        place(x, unit(hp(white(r, L), 2500)) * np.exp(-tvec(L) / 0.0006), 0.0, 0.8)
        place(x, metal_ring(r, r.uniform(1400, 2200), 0.25, 0.4), 0.0, 0.45)
        place(x, whine(r, dur, r.uniform(3800, 5200), r.uniform(1100, 1700)), 0.012, 1.0)
        y = reverb(x, ir, 0.22)
        write_wav(f"{base}ricochet_{i}.wav", finish(y, -3.0, trim_db=-60))
    # concrete ------------------------------------------------------------------
    for i in (1, 2, 3):
        r = rng_for(f"impact_concrete_{i}")
        n = ns(0.8)
        x = np.zeros(n)
        L = ns(0.006)
        x[:L] += unit(hp(white(r, L), 1500)) * np.exp(-tvec(L) / 0.0009)
        x += 0.6 * unit(bp(white(r, n), 250, 1800)) * env_ad(n, 0.0005, 0.07)
        x += 0.35 * thud(r, r.uniform(110, 150), 0.06, dur=0.8)[:n]
        x += 0.55 * unit(grains(r, n, 0.004, 0.5, 70, 2200, 11000, decay=0.08, gdur=(0.0003, 0.002)))
        chunks = grains(r, n, 0.02, 0.45, 9, 700, 3000, decay=0.12, gdur=(0.002, 0.008))
        x += 0.3 * unit(chunks)
        y = reverb(x, ir, 0.16)
        write_wav(f"{base}concrete_{i}.wav", finish(y, -2.0, trim_db=-60))
    # wood ----------------------------------------------------------------------
    for i in (1, 2, 3):
        r = rng_for(f"impact_wood_{i}")
        n = ns(0.6)
        f0 = r.uniform(170, 300)
        ratios = np.array([1.0, 2.31, 3.9, 5.2, 6.8, 9.1])
        knock = strike(r, f0 * ratios, np.array([0.16, 0.1, 0.07, 0.05, 0.04, 0.03]) * r.uniform(0.8, 1.2),
                       np.array([1, 0.7, 0.5, 0.35, 0.25, 0.15]), 0.6, hard=5000, exc_ms=0.6)
        x = np.zeros(n)
        L = ns(0.004)
        x[:L] += unit(hp(white(r, L), 1500)) * np.exp(-tvec(L) / 0.0007)
        x += 0.9 * knock
        x += 0.35 * unit(bp(white(r, n), 700, 1800)) * env_ad(n, 0.0005, 0.04)
        x += 0.4 * unit(grains(r, n, 0.003, 0.2, 45, 1500, 6500, decay=0.04, gdur=(0.0002, 0.0012)))
        y = reverb(x, ir, 0.14)
        write_wav(f"{base}wood_{i}.wav", finish(y, -2.0, trim_db=-60))
    # flesh (non-gory: dull body thump + soft slap) -----------------------------
    for i in (1, 2, 3):
        r = rng_for(f"impact_flesh_{i}")
        n = ns(0.35)
        x = thump(n, r.uniform(140, 170), r.uniform(50, 65), 0.012, 0.14, attack=0.002, r=r)
        x += 0.6 * unit(lp(white(r, n), 450, 2)) * env_ad(n, 0.0015, 0.08)
        x += 0.3 * unit(bp(white(r, n), 500, 2200, 2)) * env_ad(n, 0.001, 0.025)
        x = lp(x, 3000, 2)
        y = reverb(x, ir, 0.06)
        write_wav(f"{base}flesh_{i}.wav", finish(y, -3.0, trim_db=-60))


# =============================================================================
# Footsteps and landings
# =============================================================================

def wood_creak(r, dur, f_center):
    """Floorboard creak: slow stick-slip pulses driving a few wood modes."""
    n = ns(dur)
    t = tvec(n)
    rate = r.uniform(60, 110) * (1 + 0.5 * smooth_curve(r, n, 6))
    amp = np.sin(np.pi * np.clip(t / dur, 0, 1)) ** 1.5
    exc = friction_pulses(r, n, rate, amp, jitter=0.08)
    ratios = np.array([1.0, 1.6, 2.4, 3.3])
    ir = modal_ir(f_center * ratios, np.array([0.05, 0.04, 0.03, 0.02]), np.array([1, 0.6, 0.4, 0.2]), 0.12, r)
    return unit(signal.fftconvolve(exc, ir)[:n])


def footstep(surface, i, heavy=False):
    r = rng_for(f"step_{surface}_{i}_{heavy}")
    n = ns(1.0)
    x = np.zeros(n)
    g = 1.6 if heavy else 1.0
    heel = 0.0
    sole = r.uniform(0.018, 0.035)
    if surface == "concrete":
        place(x, thud(r, r.uniform(80, 100) * (0.85 if heavy else 1), 0.07 * g, noise_lp=350), heel, 0.8 * g)
        sl = unit(bp(white(r, ns(0.08)), 700, 5000)) * env_ad(ns(0.08), 0.0015, 0.045)
        place(x, sl, sole, 0.55)
        place(x, grains(r, ns(0.25), 0, 0.2, 30 if not heavy else 55, 2500, 11000,
                        decay=0.05, gdur=(0.0002, 0.0012)), 0.002, 1.6)
        if i in (2, 4) or heavy:
            place(x, scrape(r, 0.07, 1500, 9000, rough=0.7), sole + 0.01, 0.12)
        ir = small_ir("steps_concrete", 0.9)
        wet = 0.12
    elif surface == "metal":
        f0 = r.uniform(210, 290)
        clank = metal_ring(r, f0, 0.35 * g, 0.9)
        hi = mclick(r, r.uniform(1300, 1900), 0.12)
        place(x, thud(r, 110, 0.06, noise_lp=500), heel, 0.6 * g)
        place(x, clank, heel + 0.001, 0.55 * g)
        place(x, hi, sole, 0.3)
        for k in range(r.integers(3, 6) + (3 if heavy else 0)):   # grating rattle
            place(x, mclick(r, r.uniform(1800, 3200), 0.03), sole + 0.012 + k * r.uniform(0.012, 0.022),
                  0.22 * math.exp(-k * 0.45) * g)
        ir = small_ir("steps_metal", 1.2, er_gain=0.6)
        wet = 0.16
    else:  # wood
        f0 = r.uniform(110, 170)
        ratios = np.array([1.0, 2.2, 3.4, 4.9])
        board = strike(r, f0 * ratios, np.array([0.12, 0.08, 0.05, 0.04]) * g,
                       np.array([1, 0.6, 0.35, 0.2]), 0.5, hard=3500, exc_ms=1.5)
        place(x, thud(r, 90, 0.06 * g, noise_lp=400), heel, 0.7 * g)
        place(x, board, heel + 0.001, 0.6 * g)
        place(x, unit(bp(white(r, ns(0.05)), 600, 3500)) * env_ad(ns(0.05), 0.002, 0.035), sole, 0.4)
        place(x, grains(r, ns(0.15), 0, 0.12, 12, 2000, 8000, decay=0.03), 0.003, 0.8)
        if i in (2, 4):
            place(x, wood_creak(r, r.uniform(0.18, 0.3), r.uniform(550, 900)), sole + 0.04, 0.22)
        ir = small_ir("steps_wood", 0.8)
        wet = 0.11
    if heavy:  # second foot + gear rustle
        y2 = x.copy()
        x = x + 0.6 * np.concatenate([np.zeros(ns(0.035)), y2[:-ns(0.035)]])
        rust = unit(bp(white(r, n), 900, 5000)) * env_ad(n, 0.01, 0.25) * 0.08
        x += rust
    return finish(reverb(x, ir, wet), -4.0 if not heavy else -2.0, trim_db=-58)


def gen_footsteps():
    for surface in ("concrete", "metal", "wood"):
        for i in (1, 2, 3, 4):
            write_wav(f"footsteps/{surface}_{i}.wav", footstep(surface, i))
    write_wav("footsteps/land_concrete.wav", footstep("concrete", 9, heavy=True))
    write_wav("footsteps/land_metal.wav", footstep("metal", 9, heavy=True))


# =============================================================================
# Shell casings
# =============================================================================

def casing(name, floor):
    r = rng_for(name)
    dur = 1.0
    n = ns(dur)
    f0 = r.uniform(4300, 6200)
    ratios = np.array([1.0, 1.006, 2.32, 2.36, 3.71, 4.9, 6.2])
    t60s = np.array([0.35, 0.33, 0.2, 0.19, 0.12, 0.08, 0.06]) * r.uniform(0.8, 1.2)
    amps = np.array([1.0, 0.8, 0.6, 0.5, 0.35, 0.2, 0.12])
    exc = np.zeros(n)
    tt = 0.0
    dt = r.uniform(0.13, 0.2)
    a = 1.0
    times = []
    for _ in range(r.integers(3, 5)):
        times.append((tt, a))
        tt += dt
        dt *= r.uniform(0.5, 0.65)
        a *= r.uniform(0.45, 0.65)
    for _ in range(r.integers(5, 10)):  # short roll / chatter
        tt += r.uniform(0.008, 0.02)
        a *= 0.8
        times.append((tt, a * 0.6))
    for tt_, a_ in times:
        place(exc, np.array([1.0, -0.6]) * r.choice([-1, 1]), tt_, a_)
    ring = signal.fftconvolve(exc, modal_ir(f0 * ratios * r.uniform(0.99, 1.01, 7), t60s, amps, 0.6, r))[:n]
    x = unit(ring)
    contact = np.zeros(n)
    for tt_, a_ in times:
        place(contact, hp(white(r, ns(0.002)), 3000) * np.exp(-tvec(ns(0.002)) / 0.0003), tt_, a_)
    x += 0.4 * unit(contact)
    if floor == "metal":
        fl = signal.fftconvolve(exc, modal_ir(r.uniform(900, 1300) * METAL_RATIOS[:7],
                                              np.full(7, 0.25) * METAL_RATIOS[:7] ** -0.5,
                                              np.ones(7) / METAL_RATIOS[:7], 0.5, r))[:n]
        x += 0.45 * unit(fl)
        ir, wet = small_ir("casing_metal", 1.0), 0.12
    else:
        x += 0.15 * unit(grains(r, n, 0, tt, 25, 4000, 12000))
        ir, wet = small_ir("casing_concrete", 0.9), 0.10
    return finish(reverb(x, ir, wet), -6.0, trim_db=-58)


def gen_casings():
    for i in (1, 2, 3):
        write_wav(f"casings/brass_concrete_{i}.wav", casing(f"casing_c_{i}", "concrete"))
    for i in (1, 2):
        write_wav(f"casings/brass_metal_{i}.wav", casing(f"casing_m_{i}", "metal"))


# =============================================================================
# Ambience
# =============================================================================

def metal_groan(r, dur):
    """Structural steel groan/creak: stick-slip friction pulses whose rate glides
    through the low pitch range (tonal groan) and drops into separate ticks at
    the ends (creak), driving a dense bank of steel-beam modes."""
    n = ns(dur)
    t = tvec(n)
    u = t / dur
    lo, hi = r.uniform(28, 45), r.uniform(70, 130)
    glide = smooth_curve(r, n, 0.8)
    rate = lo + (hi - lo) * glide
    edge = np.clip(np.minimum(u, 1 - u) / 0.18, 0, 1)         # ticks at start/end
    rate = 7 + (rate - 7) * edge ** 0.7
    amp = np.sin(np.pi * u) ** 0.7 * (0.55 + 0.45 * smooth_curve(r, n, 2.5))
    exc = friction_pulses(r, n, rate, amp, jitter=0.04)
    k = 40
    freqs = np.sort(np.geomspace(90, 1800, k) * r.uniform(0.9, 1.1, k))
    t60s = np.clip(0.9 * (freqs / 200) ** -0.5 * r.uniform(0.6, 1.4, k), 0.12, 1.6)
    amps = r.uniform(0.2, 1.0, k) * (freqs / 300) ** -0.3
    body = signal.fftconvolve(exc, modal_ir(freqs, t60s, amps, 1.6, r))
    creak_modes = np.sort(r.uniform(900, 2600, 8))
    creak = signal.fftconvolve(exc, modal_ir(creak_modes, np.full(8, 0.06), np.ones(8), 0.15, r))
    m = max(body.size, creak.size)
    y = np.zeros(m)
    y[:body.size] += unit(body)
    y[:creak.size] += 0.2 * unit(creak)
    return lp(y, 2800, 2)


def drip_dry(r):
    """Water drop: tiny impact click + rising-pitch bubble resonance."""
    n = ns(0.12)
    t = tvec(n)
    f0 = r.uniform(900, 1500)
    f = f0 * np.exp(t * r.uniform(25, 45)).clip(1, 3.2)
    ph = 2 * np.pi * np.cumsum(f) / SR
    bub = np.sin(ph) * env_ad(n, 0.0008, r.uniform(0.04, 0.07))
    x = 0.9 * bub
    L = ns(0.0015)
    x[:L] += 0.4 * unit(hp(white(r, L), 3000)) * np.hanning(L)
    return x


def gen_ambience():
    base = "ambience/"
    # one-shot drips and groans ------------------------------------------------
    hall = hall_ir("amb_hall", 2.6, er_span=0.12, er_gain=0.5, damping=0.8)
    for i in (1, 2, 3):
        r = rng_for(f"drip_{i}")
        x = drip_dry(r)
        y = reverb(x, hall, 0.55, dry=0.8)
        write_wav(f"{base}drip_{i}.wav", finish(y, -6.0, trim_db=-55))
    for i in (1, 2, 3):
        r = rng_for(f"groan_{i}")
        x = metal_groan(r, r.uniform(2.2, 3.8))
        y = reverb(x, hall, 0.8, dry=0.6)
        y = lp(y, 3500, 2)
        write_wav(f"{base}metal_groan_{i}.wav", finish(y, -3.0, trim_db=-55))

    # industrial interior loop (40 s, stereo) ---------------------------------
    T = 40.0
    N = ns(T)
    XF = ns(4.0)
    PRE = ns(1.0)
    M = N + XF + PRE
    bed = []
    for c in range(2):
        r = rng_for(f"amb_bed_{c}")
        room = 0.55 * unit(lp(colored(r, M, 2.0), 220, 2)) + 0.12 * unit(lp(colored(r, M, 1.0), 1400, 2))
        gust = smooth_curve(rng_for("amb_gust"), M, 0.12) ** 1.6  # shared -> correlated gusts L/R
        gust = 0.15 + 0.85 * (0.7 * gust + 0.3 * smooth_curve(r, M, 0.4))
        center = 300 + 650 * smooth_curve(r, M, 0.15)
        wind = unit(morph_noise(white(r, M), center, 150, 2500, 10)) * gust
        whistle_f = 760 + 120 * smooth_curve(r, M, 0.08)
        whistle = unit(morph_noise(white(r, M), whistle_f, 600, 1000, 8, width_oct=0.08)) * gust ** 2.5
        layer = room + 0.35 * wind + 0.06 * whistle
        layer = layer[PRE:]
        bed.append(loop_crossfade(layer, N, XF))
    bed = np.stack(bed)
    t = tvec(N)
    drone = np.zeros((2, N))
    for c in range(2):
        ph0 = rng_for(f"drone_{c}").uniform(0, 6.28, 6)
        for k, (f, a) in enumerate([(41.0, 0.5), (41.6, 0.4), (61.5, 0.15), (82.1, 0.18), (123.2, 0.06)]):
            lfo = 0.6 + 0.4 * np.sin(2 * np.pi * (k % 3 + 1) * t / T + ph0[k])
            drone[c] += a * lfo * np.sin(2 * np.pi * pf(f + 0.1 * c, T) * t + ph0[k])
    drone = 0.25 * drone
    # discrete events, added circularly (their reverb tails wrap around)
    ev_dry = np.zeros((2, N))
    ev_src = np.zeros(N)
    for k, (tt, p, gain) in enumerate([(5.5, -0.6, 0.25), (19.0, 0.5, 0.17), (31.5, -0.2, 0.21)]):
        g = metal_groan(rng_for(f"amb_groan_{k}"), 2.5 + k * 0.5)
        place_circ(ev_dry, pan(g, p), tt, gain * 0.15)
        place_circ(ev_src, g, tt, gain)
    for k, (tt, p) in enumerate([(12.3, 0.7), (12.9, 0.7), (26.4, -0.5), (37.2, 0.2)]):
        d = drip_dry(rng_for(f"amb_drip_{k}"))
        place_circ(ev_dry, pan(d, p), tt, 0.12)
        place_circ(ev_src, d, tt, 0.3)
    amb_ir = hall_ir("amb_loop_hall", 3.0, er_span=0.15, er_gain=0.4, damping=0.85, stereo=True)
    ev = ev_dry + circ_conv(ev_src, amb_ir) * 0.5
    mix = 1.0 * bed + drone + 1.0 * ev
    write_wav(f"{base}industrial_interior_loop.wav", finish_loop(mix, rms_db=-24.0, peak_max_db=-3.0), loop=True)

    # fluorescent buzz (4 s, mono) --------------------------------------------
    T = 4.0
    N = ns(T)
    t = tvec(N)
    r = rng_for("fluoro")
    hum = (np.sin(2 * np.pi * 100 * t) + 0.35 * np.sin(2 * np.pi * 200 * t + 0.4)
           + 0.12 * np.sin(2 * np.pi * 50 * t) + 0.2 * np.sin(2 * np.pi * 300 * t + 1.1))
    buzz_raw = np.tanh(5.0 * np.sin(2 * np.pi * 100 * t + 0.3 * np.sin(2 * np.pi * 200 * t)))
    buzz = circ(lambda s: bp(s, 900, 5000, 2), buzz_raw)
    flick = smooth_curve(r, N, 3.0)
    flick = np.clip(1.0 - 1.4 * np.maximum(flick - 0.55, 0), 0.15, 1)  # occasional dips
    sputter = np.zeros(N)
    for _ in range(14):
        tt = r.uniform(0, T)
        L = ns(r.uniform(0.01, 0.08))
        burst = r.standard_normal(L) * np.hanning(L) * (r.random(L) < 0.08)
        place_circ(sputter, burst, tt, r.uniform(0.3, 1.0))
    sputter = circ(lambda s: bp(s, 1800, 9000, 2), sputter)
    hiss = circ(lambda s: bp(s, 3000, 12000, 2), white(r, N))
    x = 0.55 * hum * (0.8 + 0.2 * flick) + 0.22 * unit(buzz) * flick + 0.25 * unit(sputter) + 0.015 * unit(hiss)
    write_wav(f"{base}fluorescent_buzz_loop.wav", finish_loop(x, rms_db=-20.0, peak_max_db=-2.0), loop=True)

    # wind gust loop (20 s, stereo) --------------------------------------------
    T = 20.0
    N = ns(T)
    out = []
    shared = smooth_curve(rng_for("wind_shared"), N, 0.25)
    for c in range(2):
        r = rng_for(f"wind_{c}")
        filt = lambda s, a, b: circ(lambda z: bp(z, a, b, 2), s)
        gust = 0.1 + 0.9 * (0.75 * shared + 0.25 * smooth_curve(r, N, 0.6)) ** 1.8
        center = 220 + 900 * (0.6 * shared + 0.4 * smooth_curve(r, N, 0.3))
        w = unit(morph_noise(white(r, N), center, 120, 3000, 12, filt=filt)) * gust
        whist_f = 650 + 350 * shared + 60 * smooth_curve(r, N, 0.5)
        wh = unit(morph_noise(white(r, N), whist_f, 500, 1300, 10, width_oct=0.06, filt=filt)) * gust ** 3
        rumble = unit(circ(lambda z: lp(z, 140, 2), colored(r, N, 2.0))) * (0.3 + 0.7 * gust)
        out.append(w + 0.12 * wh + 0.35 * rumble)
    write_wav(f"{base}wind_gust_loop.wav", finish_loop(np.stack(out), rms_db=-20.0, peak_max_db=-2.0), loop=True)


# =============================================================================
# Player
# =============================================================================

def gen_player():
    base = "player/"
    # hurt impact ----------------------------------------------------------------
    for i in (1, 2):
        r = rng_for(f"hurt_{i}")
        n = ns(1.7)
        t = tvec(n)
        body = thump(n, r.uniform(110, 140), r.uniform(38, 48), 0.02, 0.3, attack=0.002, r=r)
        body += 0.6 * unit(lp(white(r, n), 300, 2)) * env_ad(n, 0.002, 0.18)
        body += 0.25 * unit(bp(white(r, n), 400, 1500)) * env_ad(n, 0.001, 0.04)
        body = lp(sat(body, 2.0), 900, 2)
        fr = r.uniform(3600, 4300)
        ring_env = np.clip(t / 0.08, 0, 1) ** 2 * np.exp(-LN1000 * t / 1.5)
        ring = (np.sin(2 * np.pi * fr * t) + 0.8 * np.sin(2 * np.pi * (fr + 3.5) * t)
                + 0.1 * np.sin(2 * np.pi * fr * 1.997 * t)) * ring_env
        x = unit(body) + 0.07 * unit(ring)
        write_wav(f"{base}hurt_impact_{i}.wav", finish(x, -2.0, trim_db=-50))

    # flashlight switch: a stiff plastic slide-click, on and off ---------------
    for i, name in enumerate(("flashlight_on", "flashlight_off")):
        r = rng_for(name)
        n = ns(0.18)
        x = np.zeros(n)
        place(x, mclick(r, 2600 + 500 * i, 0.03, tick=0.8, dur=0.06), 0.0, 1.0)
        place(x, mclick(r, 3400 - 400 * i, 0.02, tick=0.6, dur=0.05), 0.012 + 0.006 * i, 0.55)
        x += 0.2 * unit(bp(white(r, n), 900, 3000)) * env_ad(n, 0.0005, 0.02)
        write_wav(f"{base}{name}.wav", finish(x, -6.0, trim_db=-50))

    # heartbeat loop: 4 beats at ~58 bpm --------------------------------------
    beat = 60.0 / 58.0
    T = 4 * beat
    N = ns(T)
    x = np.zeros(N)
    r = rng_for("heart")
    for k in range(4):
        tt = k * beat + r.uniform(-0.01, 0.01)
        m = ns(0.35)
        lub = thump(m, 75, 42, 0.03, 0.2, attack=0.006, r=r) + 0.4 * unit(lp(white(r, m), 120)) * env_ad(m, 0.004, 0.12)
        dub = thump(m, 95, 55, 0.02, 0.14, attack=0.004, r=r) + 0.3 * unit(lp(white(r, m), 160)) * env_ad(m, 0.003, 0.08)
        place_circ(x, unit(lub), tt, 1.0 * r.uniform(0.92, 1.0))
        place_circ(x, unit(dub), tt + 0.29, 0.62 * r.uniform(0.9, 1.0))
    x = np.tanh(2.2 * x)                                   # adds audible upper harmonics
    x = circ(lambda s: lp(s, 260, 2), x)
    write_wav(f"{base}heartbeat_loop.wav", finish_loop(x, peak_db=-3.0), loop=True)

    # heavy breathing loop -------------------------------------------------------
    cycles = [(0.95, 0.12, 1.25, 0.38), (1.05, 0.1, 1.35, 0.3)]  # inhale, hold, exhale, rest
    T = sum(sum(c) for c in cycles)
    N = ns(T)
    r = rng_for("breath")
    nz = white(r, N)

    def formants(s, fs, q):
        return sum(circ(lambda z, f=f: reson(z, f, q), s) * a for f, a in fs)

    inhale_src = formants(nz, [(650, 1.0), (1250, 0.7), (2700, 0.5), (4200, 0.35)], 3.5)
    inhale_src += 0.6 * unit(circ(lambda z: hp(z, 3500, 2), nz))
    exhale_src = formants(white(r, N), [(480, 1.0), (1050, 0.8), (2400, 0.4)], 3.0)
    exhale_src += 0.5 * unit(circ(lambda z: lp(z, 400, 2), white(r, N)))
    ein = np.zeros(N)
    eex = np.zeros(N)
    pos = 0.0
    for (a, h, e, rest) in cycles:
        ni = ns(a)
        ne = ns(e)
        shp_i = np.sin(np.pi * np.linspace(0, 1, ni)) ** 1.5
        tt = np.linspace(0, 1, ne)
        shp_e = (np.clip(tt / 0.15, 0, 1) ** 1.2) * (1 - tt) ** 1.4
        place_circ(ein, shp_i, pos, 0.75)
        place_circ(eex, unit(shp_e), pos + a + h, 1.0)
        pos += a + h + e + rest
    x = unit(inhale_src) * ein + unit(exhale_src) * eex
    x = circ(lambda s: lp(s, 6000, 2), x)
    write_wav(f"{base}breath_heavy_loop.wav", finish_loop(x, peak_db=-6.0), loop=True)

    # bullet flyby --------------------------------------------------------------
    ir = small_ir("flyby_room", 1.0, er_gain=0.5)
    for i in (1, 2, 3):
        r = rng_for(f"flyby_{i}")
        dur = 0.45
        n = ns(dur)
        t = tvec(n)
        tc = r.uniform(0.07, 0.11)       # moment of closest pass
        x = np.zeros(n)
        L = ns(0.00035 * r.uniform(0.8, 1.2))
        nw = np.linspace(1, -1, max(L, 6))
        place(x, nw, tc, 1.0)
        place(x, hp(white(r, ns(0.002)), 4000) * np.exp(-tvec(ns(0.002)) / 0.0002), tc, 0.5)
        center = 1300 + 3800 / (1 + np.exp((t - tc) / 0.02))   # Doppler: high approaching, low leaving
        wz = unit(morph_noise(white(r, n), center, 600, 7000, 10, width_oct=0.25))
        env = np.exp(-np.abs(t - tc) / np.where(t < tc, 0.018, 0.06))
        x += 0.6 * wz * env
        y = reverb(x, ir, 0.2)
        write_wav(f"{base}bullet_flyby_{i}.wav", finish(y, -2.0, trim_db=-55))


# =============================================================================
# UI
# =============================================================================

def stereoize(x, delay_ms=0.25, r_gain=0.96):
    d = ns(delay_ms / 1000.0)
    rch = np.concatenate([np.zeros(d), x])[:x.size] * r_gain
    return np.stack([x, rch])


def gen_ui():
    base = "ui/"
    room = small_ir("ui_room", 0.4, stereo=True, er_gain=0.3)
    # hover: subtle soft tick
    r = rng_for("ui_hover")
    x = strike(r, np.array([2300, 3550, 5200]), np.array([0.025, 0.018, 0.012]), np.array([1, 0.5, 0.25]),
               0.08, hard=4500, exc_ms=0.6)
    y = reverb(x, room, 0.08)
    write_wav(f"{base}hover.wav", finish(y, -14.0, trim_db=-50, fade=0.01))
    # click: muted mechanical click (press + release)
    r = rng_for("ui_click")
    x = seq([(0.0, mclick(r, 1500, 0.03, hard=4000, tick=0.2), 1.0), (0.0005, thud(r, 190, 0.035), 0.5),
             (0.045, mclick(r, 2300, 0.02, hard=4000, tick=0.15), 0.35)], 0.2)
    x = lp(x, 6000, 2)
    write_wav(f"{base}click.wav", finish(reverb(x, room, 0.08), -6.0, trim_db=-50, fade=0.01))
    # back: lower, descending pair
    r = rng_for("ui_back")
    n = ns(0.2)
    x = seq([(0.0, mclick(r, 2000, 0.025, hard=4000, tick=0.15), 0.5),
             (0.04, mclick(r, 1100, 0.04, hard=3500, tick=0.2), 1.0),
             (0.04, thump(n, 220, 110, 0.03, 0.08, r=r), 0.45)], 0.25)
    x = lp(x, 5000, 2)
    write_wav(f"{base}back.wav", finish(reverb(x, room, 0.08), -6.0, trim_db=-50, fade=0.01))
    # open: low ominous swell ~1 s
    r = rng_for("ui_open")
    dur = 1.25
    n = ns(dur)
    t = tvec(n)
    sw = np.clip(t / 0.75, 0, 1) ** 2.2 * np.clip((dur - t) / 0.5, 0, 1) ** 1.5
    tones = np.zeros(n)
    for f, a in [(55.0, 1.0), (58.27, 0.55), (82.4, 0.5), (110.0, 0.25), (116.5, 0.15)]:
        tones += a * np.sin(2 * np.pi * f * t + r.uniform(0, 6.28))
    tones = np.tanh(1.6 * tones)
    noise = morph_noise(white(r, n), 200 + 1100 * np.clip(t / 0.8, 0, 1) ** 2, 150, 2500, 8)
    shimmer = modal_ir(np.array([1870, 2433, 3121, 4410]), np.full(4, 3.0), np.full(4, 0.25), dur, r)
    shimmer *= np.clip((t - 0.4) / 0.4, 0, 1) * sw
    x = unit(tones) * sw + 0.25 * unit(noise) * sw + 0.06 * unit(shimmer)
    hall = hall_ir("ui_open_hall", 2.2, stereo=True, er_gain=0.3)
    write_wav(f"{base}open.wav", finish(reverb(x, hall, 0.35), -3.0, trim_db=-50, fade=0.2))

    # menu drone loop (30 s, stereo) -----------------------------------------
    T = 30.0
    N = ns(T)
    t = tvec(N)
    voices = [(36.71, 1.0, 1), (55.0, 0.7, 2), (73.42, 0.45, 3), (77.78, 0.16, 1),   # D, A, D, Eb (b2)
              (103.83, 0.12, 2), (110.0, 0.22, 1), (146.83, 0.1, 3)]               # G# (tritone), A, D
    chans = []
    for c in range(2):
        r = rng_for(f"menu_{c}")
        y = np.zeros(N)
        fc = 160 + 520 * (0.5 - 0.5 * np.cos(2 * np.pi * t / T + c * 0.6)) ** 1.5
        for vi, (f, a, m) in enumerate(voices):
            f = pf(f + (0.0667 if c else -0.0667) * (vi % 2 * 2 - 1), T)
            amp_lfo = 0.55 + 0.45 * np.sin(2 * np.pi * m * t / T + r.uniform(0, 6.28))
            if vi in (3, 4):  # dissonant voices drift in and out
                amp_lfo = (0.5 - 0.5 * np.cos(2 * np.pi * m * t / T + r.uniform(0, 6.28))) ** 2
            kmax = int(min(1600, SR * 0.4) // f)
            for kk in range(1, kmax + 1):
                hk = (1.0 / kk) / np.sqrt(1 + (kk * f / fc) ** 4)
                y += a * amp_lfo * hk * np.sin(2 * np.pi * kk * f * t + r.uniform(0, 6.28))
        nz = white(r, N)
        breath = unit(circ(lambda s: bp(s, 250, 900, 2), nz))
        breath *= 0.3 + 0.7 * (0.5 - 0.5 * np.cos(2 * np.pi * 3 * t / T + c)) ** 2
        shimmer = np.zeros(N)
        for j, f in enumerate([1874.0, 2441.0, 3127.0, 3988.0, 5213.0]):
            bump = (0.5 - 0.5 * np.cos(2 * np.pi * (j % 3 + 1) * t / T + r.uniform(0, 6.28))) ** 6
            shimmer += bump * np.sin(2 * np.pi * pf(f, T) * t + r.uniform(0, 6.28)) / (1 + j * 0.3)
        chans.append(unit(y) + 0.10 * breath + 0.035 * unit(shimmer))
    x = np.stack(chans)
    hall = hall_ir("menu_hall", 4.0, stereo=True, er_gain=0.2, damping=0.7)
    x = x + 0.6 * circ_conv(x.mean(axis=0), hall)
    write_wav(f"{base}menu_drone_loop.wav", finish_loop(x, rms_db=-20.0, peak_max_db=-2.0), loop=True)


# =============================================================================
# QA: report, metrics, spectrograms, loop seams
# =============================================================================

_CMAP = np.array([[0, 0, 0], [30, 10, 70], [110, 25, 110], [200, 60, 70], [245, 140, 30], [255, 230, 120],
                  [255, 255, 240]], dtype=float)


def colormap(v):
    v = np.clip(v, 0, 1) * (len(_CMAP) - 1)
    i = np.minimum(v.astype(int), len(_CMAP) - 2)
    f = (v - i)[..., None]
    return (_CMAP[i] * (1 - f) + _CMAP[i + 1] * f).astype(np.uint8)


def spectrogram_png(path, x, title, width=1000, height=320, wave_h=110, fmin=20.0):
    from PIL import Image, ImageDraw
    x = x if x.ndim == 1 else x[0]
    nper = 2048 if x.size > SR * 5 else 1024
    f, _, Z = signal.stft(x, SR, nperseg=nper, noverlap=nper * 3 // 4, boundary=None)
    P = np.abs(Z) ** 2
    cols = P.shape[1]
    edges = np.linspace(0, cols, min(width, cols) + 1).astype(int)
    edges = np.unique(edges)
    P = np.add.reduceat(P, edges[:-1], axis=1) / np.diff(edges)[None, :]
    rows = np.geomspace(fmin, SR / 2, height)[::-1]
    fi = np.interp(rows, f, np.arange(f.size))
    lo = np.floor(fi).astype(int)
    hi = np.minimum(lo + 1, f.size - 1)
    w = (fi - lo)[:, None]
    S = P[lo] * (1 - w) + P[hi] * w
    S = 10 * np.log10(S + 1e-20)
    S = (S - (S.max() - 100)) / 100
    img = Image.fromarray(colormap(S)).resize((width, height), Image.NEAREST)
    canvas = Image.new("RGB", (width + 60, height + wave_h + 50), (16, 16, 20))
    canvas.paste(img, (50, 30))
    d = ImageDraw.Draw(canvas)
    d.text((50, 8), f"{title}   ({x.size / SR:.2f} s, log-freq 20 Hz-22 kHz, 100 dB range)", fill=(230, 230, 230))
    for fr in (50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000):
        y = 30 + int(np.interp(math.log(fr), np.log(rows[::-1]), np.arange(height)[::-1]))
        d.line([(44, y), (50, y)], fill=(200, 200, 200))
        d.text((2, y - 6), f"{fr // 1000}k" if fr >= 1000 else str(fr), fill=(200, 200, 200))
    # waveform
    wy0 = height + 40
    mid = wy0 + wave_h // 2
    ed = np.linspace(0, x.size, width + 1).astype(int)
    d.line([(50, mid), (50 + width, mid)], fill=(60, 60, 70))
    for i in range(width):
        seg = x[ed[i]:max(ed[i + 1], ed[i] + 1)]
        if seg.size:
            d.line([(50 + i, mid - int(seg.max() * wave_h / 2)), (50 + i, mid - int(seg.min() * wave_h / 2))],
                   fill=(120, 200, 255))
    for sec in np.arange(0, x.size / SR, 0.5 if x.size < SR * 5 else 5.0):
        px = 50 + int(sec * SR / x.size * width)
        d.text((px, wy0 + wave_h - 2), f"{sec:g}s", fill=(160, 160, 160))
    canvas.save(path)


def loop_seam_png(path, x, title, span_ms=15.0):
    """Waveform across the loop boundary: last span_ms + first span_ms."""
    from PIL import Image, ImageDraw
    x = x if x.ndim == 2 else x[None, :]
    k = ns(span_ms / 1000)
    W, H = 900, 150 * x.shape[0] + 30
    im = Image.new("RGB", (W, H), (16, 16, 20))
    d = ImageDraw.Draw(im)
    d.text((5, 5), f"{title}: end|start seam ({span_ms:g} ms each side)", fill=(230, 230, 230))
    for c in range(x.shape[0]):
        seg = np.concatenate([x[c, -k:], x[c, :k]])
        s = seg / (np.max(np.abs(seg)) + 1e-9)
        y0 = 30 + c * 150 + 75
        pts = [(int(i * (W - 1) / (seg.size - 1)), int(y0 - s[i] * 65)) for i in range(seg.size)]
        d.line(pts, fill=(120, 200, 255))
        d.line([(W // 2, y0 - 70), (W // 2, y0 + 70)], fill=(255, 80, 80))
    im.save(path)


def seam_metric(x):
    """Jump across the loop seam relative to typical sample-to-sample steps."""
    x = x if x.ndim == 2 else x[None, :]
    res = []
    for c in range(x.shape[0]):
        jump = abs(x[c, 0] - x[c, -1])
        steps = np.abs(np.diff(x[c]))
        res.append((jump, float(np.percentile(steps, 99)), float(steps.max())))
    return res


def env_db(x, hop=0.002, win=0.005):
    x = x if x.ndim == 1 else x.mean(axis=0)
    h = ns(hop)
    w = ns(win)
    k = np.ones(w) / w
    e = np.sqrt(np.convolve(x ** 2, k, mode="same"))[::h]
    return 20 * np.log10(e + 1e-9), hop


def decay_time(x, drop_db):
    e, hop = env_db(x)
    i0 = int(np.argmax(e))
    below = np.nonzero(e[i0:] < e[i0] - drop_db)[0]
    return (below[0] * hop) if below.size else float("nan")


def spectral_stats(x, t0=0.0, t1=None):
    x = x if x.ndim == 1 else x.mean(axis=0)
    seg = x[ns(t0):(ns(t1) if t1 else None)]
    X = np.abs(np.fft.rfft(seg * np.hanning(seg.size))) ** 2
    f = np.fft.rfftfreq(seg.size, 1 / SR)
    cen = float(np.sum(f * X) / np.sum(X))
    low = float(np.sum(X[f < 200]) / np.sum(X))
    return cen, low


def qa():
    os.makedirs(PREV, exist_ok=True)
    gd = os.path.join(PREV, ".gdignore")
    if not os.path.exists(gd):
        open(gd, "w").close()
    files = []
    for dp, _, fns in os.walk(OUT):
        for fn in fns:
            if fn.endswith(".wav"):
                files.append(os.path.join(dp, fn))
    files.sort()
    lines = ["Procedural audio report (generated by dev/asset_gen/audio.py)", "",
             f"{'file':58s} {'dur s':>7s} {'ch':>3s} {'peak dBFS':>10s} {'RMS dBFS':>9s} {'DC':>9s}  loop"]
    total = 0
    problems = []
    loops = {}
    for p in files:
        x, sr, loop = read_wav(p)
        total += os.path.getsize(p)
        rel = os.path.relpath(p, OUT)
        pk = db(peak(x))
        rms = db(math.sqrt(float(np.mean(x ** 2))))
        dc = float(np.max(np.abs(np.mean(x, axis=1))))
        lp_s = f"smpl fwd {loop[1]}..{loop[2]}" if loop else "-"
        lines.append(f"{rel:58s} {x.shape[1] / sr:7.2f} {x.shape[0]:3d} {pk:10.2f} {rms:9.2f} {dc:9.1e}  {lp_s}")
        if sr != SR:
            problems.append(f"{rel}: sample rate {sr}")
        if pk > -0.5:
            problems.append(f"{rel}: peak {pk:.2f} dBFS")
        if np.sum(np.abs(x) >= 32767 / 32768) > 0:
            problems.append(f"{rel}: hard-clipped samples")
        if dc > 2e-3:
            problems.append(f"{rel}: DC offset {dc:.1e}")
        if "loop" in os.path.basename(p):
            if not loop or loop[0] != 0 or loop[1] != 0 or loop[2] != x.shape[1] - 1:
                problems.append(f"{rel}: bad/missing smpl loop {loop}")
            loops[rel] = x
    lines += ["", f"Total size: {total / 1e6:.2f} MB in {len(files)} files", ""]

    lines.append("Loop seam check (|x[0]-x[-1]| vs 99th percentile / max of sample-to-sample steps):")
    for rel, x in loops.items():
        for c, (jump, p99, mx) in enumerate(seam_metric(x)):
            ok = "OK" if jump <= p99 else "CHECK"
            lines.append(f"  {rel} ch{c}: jump {jump:.5f}  p99 step {p99:.5f}  max step {mx:.5f}  {ok}")
            if jump > p99:
                problems.append(f"{rel} ch{c}: seam jump {jump:.5f} > p99 {p99:.5f}")
        base = os.path.splitext(os.path.basename(rel))[0]
        loop_seam_png(os.path.join(PREV, f"seam_{base}.png"), x, rel)
    lines.append("")

    lines.append("Gunshot metrics (shot_1..3 averaged; centroid = power-weighted spectral centroid):")
    lines.append(f"  {'weapon':6s} {'centroid all':>13s} {'centroid 0-50ms':>16s} {'<200Hz frac':>12s} "
                 f"{'T-20dB':>8s} {'T-40dB':>8s} {'length':>7s}")
    for gid in GUNS:
        ms = []
        for v in (1, 2, 3):
            x, _, _ = read_wav(os.path.join(OUT, "weapons", gid, f"shot_{v}.wav"))
            c_all, low = spectral_stats(x)
            c_early, _ = spectral_stats(x, 0, 0.05)
            ms.append((c_all, c_early, low, decay_time(x, 20), decay_time(x, 40), x.shape[1] / SR))
        m = np.mean(np.array(ms), axis=0)
        lines.append(f"  {gid:6s} {m[0]:11.0f}Hz {m[1]:14.0f}Hz {m[2]:12.3f} {m[3] * 1000:6.0f}ms "
                     f"{m[4] * 1000:6.0f}ms {m[5]:6.2f}s")
        xd, _, _ = read_wav(os.path.join(OUT, "weapons", gid, "shot_distant.wav"))
        cd, ld = spectral_stats(xd)
        lines.append(f"  {'':6s} distant: centroid {cd:.0f} Hz, <200Hz frac {ld:.3f}, T-20dB "
                     f"{decay_time(xd, 20) * 1000:.0f} ms")
    lines.append("")
    lines.append("Problems: " + ("none" if not problems else ""))
    lines += ["  " + p for p in problems]
    with open(os.path.join(PREV, "audio_report.txt"), "w") as fh:
        fh.write("\n".join(lines) + "\n")

    specs = ["weapons/ak47/shot_1.wav", "weapons/m16/shot_1.wav", "weapons/mp5/shot_1.wav",
             "weapons/m40/shot_1.wav", "weapons/m40/shot_distant.wav", "weapons/ak47/charge.wav",
             "impacts/metal_1.wav", "impacts/ricochet_1.wav", "impacts/concrete_1.wav",
             "footsteps/metal_1.wav", "casings/brass_concrete_1.wav", "player/bullet_flyby_1.wav",
             "ambience/industrial_interior_loop.wav", "ambience/metal_groan_1.wav",
             "ambience/fluorescent_buzz_loop.wav", "ui/menu_drone_loop.wav", "ui/open.wav"]
    for rel in specs:
        p = os.path.join(OUT, rel)
        if os.path.exists(p):
            x, _, _ = read_wav(p)
            name = rel.replace("/", "_").replace(".wav", "")
            spectrogram_png(os.path.join(PREV, f"spec_{name}.png"), x, rel)
    print("\n".join(lines))


# =============================================================================

# =============================================================================
# World interaction (exits, breakers)
# =============================================================================

def gen_world():
    ir = small_ir("world_room", 0.9)
    # Heavy breaker lever: spring tension, a big clunk, relay chatter, a hum swelling up
    r = rng_for("breaker")
    hum_n = ns(1.6)
    t = tvec(hum_n)
    hum = (np.sin(2 * np.pi * 50 * t) + 0.5 * np.sin(2 * np.pi * 100 * t) + 0.25 * np.sin(2 * np.pi * 150 * t))
    hum *= np.clip((t - 0.35) / 0.6, 0, 1) * np.exp(-np.clip(t - 1.0, 0, None) * 3.0)
    ev = [(0.0, scrape(r, 0.12, 400, 3000, grit=0.3), 0.35), (0.0, spring(r, 900, 0.2), 0.12),
          (0.14, thud(r, 120, 0.12, noise_lp=900), 1.0), (0.141, mclick(r, 850, 0.25), 0.9),
          (0.18, grains(r, ns(0.4), 0, 0.3, 18, 1500, 7000, decay=0.08), 0.35),
          (0.32, mclick(r, 2400, 0.04), 0.4), (0.36, mclick(r, 2600, 0.04), 0.35), (0.41, mclick(r, 2200, 0.05), 0.3),
          (0.0, 0.12 * hum, 1.0)]
    write_wav("world/breaker.wav", finish(reverb(seq(ev, 1.8), ir, 0.25), -2.0, trim_db=-60, lead=8))
    # Door unlocking: solenoid snap and latch
    r = rng_for("unlock")
    ev = [(0.0, mclick(r, 1800, 0.08), 0.8), (0.0, thud(r, 200, 0.05), 0.5),
          (0.25, mclick(r, 1200, 0.12), 1.0), (0.26, spring(r, 1500, 0.15), 0.1)]
    write_wav("world/door_unlock.wav", finish(reverb(seq(ev, 0.9), ir, 0.2), -3.0, trim_db=-60, lead=8))
    # Locked door: handle rattles against the latch
    r = rng_for("locked")
    ev = []
    for i in range(4):
        ev.append((i * 0.07, mclick(r, 1500 + 200 * i, 0.06), 0.8 - 0.12 * i))
        ev.append((i * 0.07 + 0.01, thud(r, 260, 0.04), 0.4))
    write_wav("world/door_locked.wav", finish(reverb(seq(ev, 0.8), ir, 0.2), -4.0, trim_db=-60, lead=8))


# =============================================================================
# People: radio chatter (callouts) and gear rattle (running)
# =============================================================================

def radio_chatter(r, dur):
    """A burst of radio traffic: squelch on, a voice too garbled to follow
    (speech-band noise through two wandering formants, chopped into
    syllables, clipped by a cheap set), squelch tail."""
    n = ns(dur)
    # Syllables: 4-7 per second, uneven, with short gaps.
    env = np.zeros(n)
    t = 0.05
    while t < dur - 0.12:
        L = r.uniform(0.07, 0.2)
        s0, s1 = ns(t), min(n, ns(t + L))
        seg = s1 - s0
        if seg > 8:
            env[s0:s1] = np.sin(np.linspace(0, np.pi, seg)) ** 0.6 * r.uniform(0.5, 1.0)
        t += L + r.uniform(0.02, 0.09)
    src = white(r, n)
    f1 = 450 + 350 * smooth_curve(r, n, 6.0)
    f2 = 1300 + 700 * smooth_curve(r, n, 5.0)
    voice = np.zeros(n)
    hop = ns(0.02)
    for i in range(0, n, hop):
        a, b = i, min(n, i + hop)
        seg = src[a:b]
        voice[a:b] = reson(seg, float(f1[a]), 6.0) + 0.7 * reson(seg, float(f2[a]), 8.0)
    voice = unit(lp(voice, 3000, 2)) * env
    voice = sat(voice * 2.5, 3.0)
    hiss = bp(white(r, n), 400, 3200, 2) * 0.08
    on = hp(white(r, ns(0.03)), 1500, 2) * env_ad(ns(0.03), 0.001, 0.02)
    off = bp(white(r, ns(0.12)), 600, 4000, 2) * env_ad(ns(0.12), 0.002, 0.09)
    y = np.zeros(n + ns(0.15))
    place(y, mclick(r, 2400, 0.01), 0.0, 0.4)
    place(y, on, 0.0, 0.5)
    place(y, voice + hiss, 0.03, 0.8)
    place(y, off, dur, 0.45)
    y = bp(y, 300, 3400, 2)
    return finish(y, -4.0, trim_db=-60, lead=4)


def gear_rattle(r):
    """Kit on a running body: buckles and magazines knocking, webbing rustling."""
    n = ns(0.35)
    y = np.zeros(n)
    for i in range(r.integers(3, 7)):
        place(y, mclick(r, r.uniform(1800, 4200), r.uniform(0.02, 0.06)), r.uniform(0.0, 0.2), r.uniform(0.2, 0.6))
    rustle = scrape(r, 0.25, 600, 3500, rough=0.9, grit=0.2)
    place(y, rustle, 0.0, 0.25)
    place(y, thud(r, r.uniform(180, 260), 0.04), r.uniform(0.0, 0.05), 0.25)
    return finish(reverb(y, small_ir("foley", 0.4), 0.06), -8.0, trim_db=-60, lead=4)


def gen_people():
    for i in range(1, 7):
        r = rng_for(f"radio_{i}")
        write_wav(f"people/radio_{i}.wav", radio_chatter(r, r.uniform(0.6, 1.5)))
    for i in range(1, 5):
        write_wav(f"people/gear_rattle_{i}.wav", gear_rattle(rng_for(f"gear_{i}")))


# =============================================================================
# Doors: opening (latch, hinge squeal), closing (swing, slam, latch)
# =============================================================================

def hinge_squeal(r, dur, f_center):
    """A dry hinge: stick-slip pulses gliding in rate, ringing a few steel modes."""
    n = ns(dur)
    t = tvec(n)
    rate = r.uniform(180, 320) * (1 + 0.6 * smooth_curve(r, n, 3) + 0.3 * t / dur)
    amp = np.sin(np.pi * np.clip(t / dur, 0, 1)) ** 0.8
    exc = friction_pulses(r, n, rate, amp, jitter=0.05)
    ratios = np.array([1.0, 1.47, 2.09, 2.8, 3.9])
    ir = modal_ir(f_center * ratios, np.array([0.06, 0.05, 0.04, 0.03, 0.02]), np.array([1, 0.7, 0.5, 0.3, 0.15]), 0.15, r)
    return unit(signal.fftconvolve(exc, ir)[:n])


def gen_doors():
    ir = small_ir("door_room", 0.8)
    for i in range(1, 4):
        r = rng_for(f"door_open_{i}")
        dur = r.uniform(0.7, 1.2)
        ev = [(0.0, mclick(r, r.uniform(1300, 1900), 0.07), 0.7),     # handle and latch
              (0.02, thud(r, r.uniform(180, 260), 0.04), 0.35),
              (0.12, hinge_squeal(r, dur, r.uniform(700, 1100)), 0.5),
              (0.12, wood_creak(r, dur * 0.8, r.uniform(240, 340)), 0.25),
              (0.1, scrape(r, dur, 200, 1500, rough=0.4, grit=0.1), 0.12)]
        write_wav(f"doors/open_{i}.wav", finish(reverb(seq(ev, dur + 0.4), ir, 0.22), -4.0, trim_db=-60, lead=4))
    for i in range(1, 3):
        r = rng_for(f"door_close_{i}")
        ev = [(0.0, bp(white(r, ns(0.25)), 150, 900, 2) * env_hann(ns(0.25)), 0.12),   # the swing
              (0.22, thud(r, r.uniform(90, 130), 0.18, noise_lp=700), 1.0),           # slam
              (0.221, mclick(r, r.uniform(700, 1000), 0.2), 0.6),
              (0.24, mclick(r, r.uniform(1600, 2200), 0.06), 0.5)]                   # latch
        write_wav(f"doors/close_{i}.wav", finish(reverb(seq(ev, 1.0), ir, 0.3), -2.0, trim_db=-60, lead=4))


FAMILIES = {
    "world": gen_world,
    "weapons": gen_weapons,
    "impacts": gen_impacts,
    "footsteps": gen_footsteps,
    "casings": gen_casings,
    "ambience": gen_ambience,
    "player": gen_player,
    "ui": gen_ui,
    "people": gen_people,
    "doors": gen_doors,
}


def main(argv):
    names = [a for a in argv if not a.startswith("-")] or list(FAMILIES)
    for name in names:
        print(f"[audio] {name} ...", flush=True)
        FAMILIES[name]()
    if "--no-qa" not in argv:
        qa()


if __name__ == "__main__":
    main(sys.argv[1:])
