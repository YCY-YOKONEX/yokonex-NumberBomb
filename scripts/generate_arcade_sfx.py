"""Generate the three short PCM effects used by Android's arcade feedback."""

import math
import random
import struct
import wave
from pathlib import Path


SAMPLE_RATE = 44100
OUTPUT = Path(__file__).resolve().parents[1] / "android/app/src/main/res/raw"


def save(name, duration, sound):
    samples = [sound(index / SAMPLE_RATE) for index in range(round(duration * SAMPLE_RATE))]
    peak = max(abs(value) for value in samples)
    scale = 0.82 / peak
    pcm = b"".join(struct.pack("<h", int(value * scale * 32767)) for value in samples)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUTPUT / f"arcade_{name}.wav"), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(pcm)


def warning(t):
    # 两个快速上扬的电子脉冲，避免倒计时连续发声遮住玩家提示。
    for start, pitch in ((0.0, 700), (0.085, 850)):
        local = t - start
        if 0 <= local < 0.065:
            envelope = min(1.0, local / 0.006) * (1 - local / 0.065) ** 1.5
            phase = 2 * math.pi * (pitch * local + 1800 * local * local)
            return envelope * (math.sin(phase) + 0.22 * math.sin(2 * phase))
    return 0.0


randomizer = random.Random(42)


def miss(t):
    phase = 2 * math.pi * (380 * t - 500 * t * t)
    body = (math.sin(phase) + 0.3 * math.sin(3 * phase)) * math.exp(-9 * t)
    crack = randomizer.uniform(-1, 1) * math.exp(-45 * t)
    return 0.8 * body + 0.22 * crack


def explosion(t):
    phase = 2 * math.pi * (125 * t - 60 * t * t)
    bass = math.sin(phase) * math.exp(-4.2 * t)
    crack = randomizer.uniform(-1, 1) * math.exp(-13 * t)
    spark = math.sin(2 * math.pi * (1200 * t - 700 * t * t)) * math.exp(-18 * t)
    return 0.65 * bass + 0.5 * crack + 0.16 * spark


if __name__ == "__main__":
    save("warning", 0.17, warning)
    save("miss", 0.27, miss)
    save("explosion", 0.68, explosion)
