import os, pathlib, random, re, sys, time, tty, select, termios
from shutil import get_terminal_size
d = pathlib.Path(sys.argv[1])
sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from importlib import import_module
throughput = import_module('benchmark-output')
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
def emit(data):
    view = memoryview(data)
    while view:
        view = view[os.write(1, view):]
def wait(name):
    until = time.monotonic() + 45
    while not (d / name).exists():
        if time.monotonic() > until:
            raise TimeoutError(name)
        time.sleep(.01)
try:
    emit(b'\x1b[6n')
    response = b''
    until = time.monotonic() + 4
    while time.monotonic() < until and not re.search(rb'\x1b\[\d+;\d+R', response):
        if select.select([fd], [], [], .1)[0]:
            response += os.read(fd, 64)
    assert re.search(rb'\x1b\[\d+;\d+R', response), response
    (d / 'ready').write_text(str(time.time()))
    emit(b'\x1b[?25l\x1b[2J')
    wait('start')
    cols, rows = get_terminal_size()
    assert (cols, rows) == (113, 44), (cols, rows)
    (d / 'grid').write_text(f'{cols}x{rows}')
    rng = random.Random(97)
    colors = ['230;40;40','40;230;40','40;40;230','230;40;230']
    previous = -1
    with (d / 'events').open('w', buffering=1) as f:
        for phase, hz in [('tui8', 8), ('tui30', 30), ('logs+tui8', 8), ('logs+tui30', 30)]:
            emit(b'\x1b[0m\x1b[2J')
            time.sleep(.35)
            target = time.monotonic()
            for _ in range(hz * 2):
                id = rng.choice([i for i in range(4) if i != previous])
                previous = id
                patch = (f'\x1b[48;2;{colors[id]}m' + ''.join(f'\x1b[{line};2H' + ' ' * 60 for line in range(2,18)) + '\x1b[0m').encode()
                log = (b'\x1b[999;1H' + b'\r\n\x1b[33mcompile worker: status=ok duration=40ms\x1b[0m test message' * 200) if phase.startswith('logs') else b''
                time.sleep(max(0,target-time.monotonic()))
                f.write(f'{time.time()} {phase} {id}\n')
                emit(log + patch)
                target += 1 / hz
    time.sleep(.3)
    (d / 'done').touch()
    wait('throughput')
    throughput.run(d / 'pty.tmp', [10_000], mixed=True)
    (d / 'pty.tmp').rename(d / 'pty.json')
    wait('exit')
finally:
    emit(b'\x1b[0m\x1b[?25h')
    termios.tcsetattr(fd,termios.TCSANOW,old)
