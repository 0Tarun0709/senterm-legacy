#!/usr/bin/env python3
"""Run inside a disposable terminal pane."""
import argparse
import json
import os
import re
import select
import statistics
import termios
import time
import tty


def run(output, counts, *, mixed=False):
    with open('/dev/tty', 'r+b', buffering=0) as terminal:
        fd = terminal.fileno()
        prior = termios.tcgetattr(fd)
        tty.setraw(fd)
        try:
            colored = b'\x1b[32mINFO\x1b[0m senterm benchmark: request completed in 12ms\r\n'
            workloads = [(count, colored, count, 8) for count in counts]
            if mixed:
                workloads.extend((name, line, 10_000, 4) for name, line in {
                    'plain': b'senterm benchmark: request completed in 12ms\r\n',
                    'unicode': 'senterm: café 日本語 🔧 e\u0301\r\n'.encode(),
                    'escape': b'\x1b[1;2H\x1b[1;4;38;2;230;80;40mstatus\x1b[0m\x1b[K\x1b[2;8Hready\x1b[K',
                }.items())
            samples = {}
            for name, line, count, repeats in workloads:
                payload = line * count + b'\x1b[6n'
                timings = []
                for _ in range(repeats):
                    time.sleep(0.2)
                    start = time.monotonic()
                    view = memoryview(payload)
                    while view:
                        view = view[os.write(fd, view):]
                    response = bytearray()
                    deadline = time.monotonic() + 5
                    while not re.search(rb'\x1b\[\d+;\d+R', response):
                        if not select.select([fd], [], [], max(0, deadline - time.monotonic()))[0]:
                            raise TimeoutError('terminal did not answer cursor position query')
                        chunk = os.read(fd, 128)
                        if not chunk or time.monotonic() >= deadline:
                            raise TimeoutError('terminal did not answer cursor position query')
                        response.extend(chunk)
                    timings.append(round((time.monotonic() - start) * 1_000, 3))
                samples[name] = {'median_ms': statistics.median(timings[1:]), 'samples_ms': timings[1:]}
        finally:
            termios.tcsetattr(fd, termios.TCSANOW, prior)
    with open(output, 'w', encoding='utf-8') as result:
        json.dump(samples, result, indent=2)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output')
    parser.add_argument('lines', nargs='*', type=int, default=[0, 10_000])
    args = parser.parse_args()
    if any(count < 0 for count in args.lines):
        parser.error('line counts must be nonnegative')
    run(args.output, args.lines)
