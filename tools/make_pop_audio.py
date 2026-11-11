#!/usr/bin/env python3
"""Renders Pop-Up Panic's sound effects and music loop into game/sfx/ as 16-bit
mono WAV files. Everything is synthesised here from sine, square and noise, so
the game ships no third-party audio. Run from the repo root."""
import math, random, struct, wave, os

SR = 22050
OUT = os.path.join(os.path.dirname(__file__), "..", "game", "sfx")
os.makedirs(OUT, exist_ok=True)
random.seed(7)
TAU = math.tau


def save(name, buf, gain=0.9):
    peak = max(1e-6, max(abs(x) for x in buf))
    k = gain / peak
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, x * k)) * 32000)) for x in buf))
    print(name, len(buf) / SR, "s")


def env_ad(t, a, d):
    if t < a:
        return t / a
    return math.exp(-(t - a) / d)


def sweep(dur, f0, f1, shape="sine", curve=1.0, vib=0.0, vib_hz=0.0, a=0.005, d=None):
    n = int(dur * SR)
    out = [0.0] * n
    ph = 0.0
    d = d or dur / 3
    for i in range(n):
        t = i / SR
        u = (t / dur) ** curve
        f = f0 + (f1 - f0) * u
        if vib:
            f *= 1.0 + vib * math.sin(TAU * vib_hz * t)
        ph += TAU * f / SR
        s = math.sin(ph)
        if shape == "square":
            s = math.tanh(4 * s)
        elif shape == "tri":
            s = 2 / math.pi * math.asin(math.sin(ph))
        out[i] = s * env_ad(t, a, d)
    return out


def noise(dur, a=0.002, d=0.05, lp=0.5):
    n = int(dur * SR)
    out = [0.0] * n
    y = 0.0
    for i in range(n):
        t = i / SR
        y += lp * (random.uniform(-1, 1) - y)
        out[i] = y * env_ad(t, a, d)
    return out


def mix(*parts):
    n = max(len(p[0]) for p in parts)
    out = [0.0] * n
    for buf, g in parts:
        for i, x in enumerate(buf):
            out[i] += x * g
    return out


# ------------------------------------------------------------------ effects
save("boing.wav", mix((sweep(0.32, 260, 720, curve=0.6, vib=0.06, vib_hz=28, d=0.12), 1.0),
                      (sweep(0.32, 520, 1440, curve=0.6, d=0.08), 0.25)))
save("bonk.wav", mix((sweep(0.28, 420, 110, curve=0.5, d=0.07), 1.0),
                     (noise(0.05, d=0.012, lp=0.8), 0.7),
                     (sweep(0.18, 1600, 900, shape="tri", d=0.03), 0.25)))
save("pop.wav", mix((sweep(0.12, 380, 1500, curve=0.5, d=0.04), 1.0), (noise(0.03, d=0.006, lp=0.9), 0.5)))
save("hop.wav", sweep(0.11, 520, 900, shape="tri", d=0.04), 0.6)
save("pad.wav", sweep(0.6, 150, 320, vib=0.25, vib_hz=16, curve=0.4, d=0.25))
save("ko.wav", mix((sweep(0.95, 1500, 180, curve=0.8, vib=0.03, vib_hz=7, a=0.02, d=0.6), 1.0),
                   (noise(0.9, a=0.3, d=0.3, lp=0.08), 0.5)))
save("whoosh.wav", noise(0.5, a=0.18, d=0.12, lp=0.06))


def tone_seq(notes, step, shape="square", d=0.12, gain=1.0):
    out = []
    for f in notes:
        seg = sweep(step, f, f, shape=shape, d=d) if f else [0.0] * int(step * SR)
        out.extend(x * gain for x in seg)
    return out


save("honk.wav", mix((tone_seq([392, 523], 0.12, "square", 0.09), 1.0), (tone_seq([196, 262], 0.12, "square", 0.09), 0.4)), 0.7)
save("tick.wav", sweep(0.07, 1400, 1400, shape="tri", d=0.02), 0.5)
save("go.wav", mix((tone_seq([523, 659, 784, 1047], 0.09, "square", 0.1), 1.0)), 0.7)
save("fanfare.wav", mix((tone_seq([523, 659, 784, 1047, 0, 784, 1047, 1047, 1047], 0.14, "square", 0.13), 1.0),
                        (tone_seq([262, 330, 392, 523, 0, 392, 523, 523, 523], 0.14, "tri", 0.2), 0.6)), 0.7)

# ------------------------------------------------------------------ music loop
# A bouncy oom-pah tune in C major, 132 BPM, 16 bars: it loops seamlessly.
BPM = 132
BEAT = 60 / BPM
BARS = 16
N = int(round(BARS * 4 * BEAT * SR))
music = [0.0] * N


def add(buf, start, g):
    s = int(start * SR)
    for i, x in enumerate(buf):
        j = (s + i) % N
        music[j] += x * g


def midi(m):
    return 440 * 2 ** ((m - 69) / 12)


prog = [(48, "maj"), (53, "maj"), (55, "maj"), (48, "maj"), (45, "min"), (53, "maj"), (55, "maj"), (48, "maj")]
# melody: (beat offset in a 2-bar phrase, midi, length in beats)
phrase_a = [(0, 72, .5), (.5, 76, .5), (1, 79, .5), (1.5, 76, .5), (2, 77, 1), (3, 74, .5), (3.5, 76, .5),
            (4, 72, .5), (4.5, 72, .5), (5, 79, 1), (6, 77, .5), (6.5, 76, .5), (7, 74, 1)]
phrase_b = [(0, 81, .5), (.5, 79, .5), (1, 77, .5), (1.5, 76, .5), (2, 74, .5), (2.5, 76, .5), (3, 77, 1),
            (4, 79, .75), (4.75, 79, .25), (5, 84, 1), (6, 79, .5), (6.5, 76, .5), (7, 72, 1)]
kick = sweep(0.18, 140, 45, curve=0.4, d=0.06)
hat = noise(0.04, d=0.01, lp=0.95)
clap = noise(0.12, d=0.035, lp=0.7)
for bar in range(BARS):
    root, q = prog[bar % 8]
    t0 = bar * 4 * BEAT
    third = 3 if q == "min" else 4
    for b in range(4):
        tb = t0 + b * BEAT
        add(kick, tb, 0.55 if b % 2 == 0 else 0.35)
        add(hat, tb + BEAT / 2, 0.18)
        if b % 2 == 1:
            add(clap, tb, 0.22)
        # oom-pah: bass on 1 and 3, chord stab on 2 and 4
        if b % 2 == 0:
            bass_note = root - 12 if b == 0 else root - 5
            add(sweep(BEAT * 0.9, midi(bass_note), midi(bass_note), shape="tri", d=0.22), tb, 0.45)
        else:
            for m in (root + 12, root + 12 + third, root + 19):
                add(sweep(BEAT * 0.45, midi(m), midi(m), shape="square", d=0.05), tb, 0.06)
    if bar % 2 == 0:
        ph = phrase_a if (bar // 2) % 2 == 0 else phrase_b
        if bar >= 8:
            ph = [(o, m + (0 if bar < 12 else 0), l) for (o, m, l) in ph]
        for (o, m, l) in ph:
            note = sweep(l * BEAT * 0.95, midi(m), midi(m), shape="tri", vib=0.006, vib_hz=6, d=l * BEAT * 0.5)
            add(note, t0 + o * BEAT, 0.2)
            if bar >= 8:   # second half: a squeaky counter-voice an octave up
                add(sweep(l * BEAT * 0.5, midi(m + 12), midi(m + 12), shape="square", d=0.05), t0 + o * BEAT, 0.035)
save("pop_music.wav", music, 0.75)
print("loop frames", N)
