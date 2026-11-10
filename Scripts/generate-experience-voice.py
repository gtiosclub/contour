#!/usr/bin/env python3
"""Regenerate the prototype's bundled English recordings using macOS speech.

Run on a Mac with the manifest's voice installed. No network service or secret
is used. The app only plays the resulting WAVs; it never runs this script.
"""
import array
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import wave


def main():
    root = Path(__file__).resolve().parents[1]
    output = root / 'Packages/ContourFeedback/Sources/ContourFeedback/Resources/VoicePrompts'
    manifest = json.loads((output / 'manifest.json').read_text())
    with tempfile.TemporaryDirectory(prefix='contour-voice-') as scratch:
        for clip in manifest['clips']:
            raw = Path(scratch) / (clip['id'] + '.aiff')
            pcm = raw.with_suffix('.wav')
            subprocess.run(['say', '-v', manifest['voice'], '-r', str(clip['wordsPerMinute']),
                            '-o', str(raw), clip['text']], check=True)
            subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16', str(raw), str(pcm)], check=True)
            with wave.open(str(pcm), 'rb') as source:
                assert source.getnchannels() == 1 and source.getsampwidth() == 2
                rate = source.getframerate()
                samples = array.array('h', source.readframes(source.getnframes()))
            if sys.byteorder != 'little':
                samples.byteswap()
            audible = [i for i, value in enumerate(samples) if abs(value) >= 60]
            if not audible:
                raise RuntimeError('System speech produced empty/silent audio: ' + clip['id'])
            # Remove synthesis padding, retain consonant tails, and fade only the
            # outer 5 ms. Full phrases preserve the voice's natural intonation.
            samples = samples[max(0, audible[0] - int(rate * .02)):
                              min(len(samples), audible[-1] + int(rate * .08) + 1)]
            gain = min(2.0, 23000 / max(abs(value) for value in samples))
            fade = max(1, int(rate * .005))
            for i in range(len(samples)):
                envelope = min(1, i / fade, (len(samples) - 1 - i) / fade)
                samples[i] = round(samples[i] * gain * envelope)
            destination = output / (clip['id'] + '.wav')
            if sys.byteorder != 'little':
                samples.byteswap()
            with wave.open(str(destination), 'wb') as result:
                result.setnchannels(1)
                result.setsampwidth(2)
                result.setframerate(rate)
                result.writeframes(samples.tobytes())
            print(f"{destination.name}: {len(samples) / rate:.2f}s", flush=True)


if __name__ == '__main__':
    main()
