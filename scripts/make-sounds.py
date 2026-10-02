"""Synthesizes the start/stop chimes into Resources/*.wav (stdlib only).
A rising two-note bell for start, the same notes falling for stop: short, soft attack, no system-alert likeness."""
import math, struct, wave, pathlib

RATE = 44100

def bell(freq, start, length, amp):
    """Sine with a little 2nd/3rd harmonic, 4 ms attack, exponential decay."""
    out = {}
    for i in range(int(length * RATE)):
        t = i / RATE
        env = min(1.0, t / 0.004) * math.exp(-t / 0.11)
        s = (math.sin(2 * math.pi * freq * t) + 0.22 * math.sin(4 * math.pi * freq * t)
             + 0.06 * math.sin(6 * math.pi * freq * t))
        out[int(start * RATE) + i] = amp * env * s
    return out

def write(name, notes):
    buf = {}
    for n in notes:
        for k, v in bell(*n).items():
            buf[k] = buf.get(k, 0.0) + v
    n = max(buf) + 1
    frames = [buf.get(i, 0.0) for i in range(n)]
    # tiny room: two soft echoes so it doesn't sound dry
    for delay, gain in ((0.045, 0.18), (0.09, 0.08)):
        d = int(delay * RATE)
        frames += [0.0] * d
        frames = [frames[i] + (gain * frames[i - d] if i >= d else 0.0) for i in range(len(frames))]
    peak = max(abs(x) for x in frames)
    path = pathlib.Path(__file__).resolve().parent.parent / "Resources" / name
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(x / peak * 0.5 * 32767)) for x in frames))
    print(f"wrote {path} ({len(frames) / RATE:.2f}s)")

E6, B6 = 1318.5, 1975.5
write("start.wav", [(E6, 0.0, 0.32, 1.0), (B6, 0.075, 0.38, 0.9)])
write("stop.wav", [(B6, 0.0, 0.32, 0.9), (E6, 0.075, 0.38, 1.0)])
