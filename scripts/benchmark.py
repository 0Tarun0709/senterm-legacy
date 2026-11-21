#!/usr/bin/env python3
"""Run capped, screen-captured benchmarks in disposable macOS windows."""
import json, os, pathlib, plistlib, shlex, shutil, statistics, subprocess as sp, sys, tempfile, time, uuid

source = pathlib.Path(__file__).resolve().parent / 'bench'
repo = source.parent.parent
if sys.argv[1:] not in ([], ['--split-only']):
    raise SystemExit('usage: python3 scripts/benchmark.py [--split-only]')
split_only = sys.argv[1:] == ['--split-only']
w = pathlib.Path(tempfile.mkdtemp(prefix='senterm-bench.'))
print(f'raw results: {w}', flush=True)
os.chdir(repo)
ghost = pathlib.Path('/Applications/Ghostty.app/Contents')
sen = w / 'SenTermBench.app/Contents/MacOS/SenTerm'
domain = 'local.senterm.benchmark.' + uuid.uuid4().hex

def wait(p, test, seconds=10):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if test(): return
        if p.poll() is not None: raise RuntimeError(f'process exited: {p.returncode}')
        time.sleep(.02)
    raise TimeoutError()

def stats(p):
    cpu, rss = sp.check_output(['ps', '-p', str(p.pid), '-o', 'time=,rss='], text=True).split()
    seconds = 0
    for part in cpu.split(':'):
        seconds = seconds * 60 + float(part)
    return seconds, int(rss)/1024

def stop(p):
    if p and p.poll() is None:
        p.terminate()
        try: p.wait(3)
        except sp.TimeoutExpired: p.kill(); p.wait()

def trial(app,i):
    d = w / f'{app}-{i}'
    d.mkdir(exist_ok=False)
    wrapper = d/'benchmark-shell'
    wrapper.write_text('#!/bin/sh\nexec ' + shlex.join([sys.executable,str(source/'workload.py'),str(d)]) + '\n')
    wrapper.chmod(0o755)
    env = dict(os.environ, SHELL=str(wrapper))
    if app=='sen':
        data = json.dumps({'projects':[{'id':str(uuid.uuid4()),'path':str(d),'terminals':[{'id':str(uuid.uuid4()),'name':'terminal'}]}]}).encode()
        sp.run(['defaults','write',domain,'projects','-data',data.hex()], check=True)
        args = [str(sen), '-fontSize','13','-disableMetal','NO']
    elif app == 'preview':
        args = [str(w/'preview')]
    else:
        env['GHOSTTY_RESOURCES_DIR'] = str(ghost/'Resources/ghostty')
        args = [str(ghost/'MacOS/ghostty'),'--config-default-files=false','--window-save-state=never','--quit-after-last-window-closed=true','--font-size=13','--window-width=113','--window-height=44','-e',str(wrapper)]
    with (d/'app.log').open('w') as log, (d/'capture.log').open('w') as capture:
        t = time.time()
        p = sp.Popen(args, env=env, cwd=d, stdout=log, stderr=log)
        c = None
        try:
            wait(p, (d/'ready').exists)
            ready = round(1000*(float((d/'ready').read_text())-t),1)
            c = sp.Popen([str(w/'capture'),str(p.pid)], stdout=capture,stderr=capture)
            wait(c,lambda:'ready' in (d/'capture.log').read_text())
            time.sleep(.4)
            a,_ = stats(p); time.sleep(2); b,rss = stats(p)
            (d/'start').touch()
            start=time.monotonic()
            wait(p,(d/'done').exists, 15)
            end=time.monotonic(); last,peak = stats(p)
            stop(c)
            (d/'throughput').touch()
            wait(p, lambda: (d/'pty.json').exists() and (d/'pty.json').stat().st_size, 15)
            (d/'exit').touch()
        finally:
            stop(c)
            stop(p)
    frames = [line.split() for line in (d/'capture.log').read_text().splitlines() if len(line.split())==2]
    events = [line.split() for line in (d/'events').read_text().splitlines()]
    grouped = {}
    for j,(ts,phase,id) in enumerate(events):
        if phase not in grouped:
            start_t = float(ts)
            hz = 30 if phase.endswith('30') else 8
            count = sum(line[1] == phase for line in events)
            changes = sum(c != '-1' and start_t <= float(f) < start_t + count / hz for f,c in frames)
            grouped[phase] = [count, changes, []]
        t = float(ts)
        if phase.endswith('8'):
            matching = [1000*(float(f)-t) for f,c in frames if c==id and t <= float(f) < t+.115]
            if matching: grouped[phase][2].append(round(min(matching),2))
    out={'ready_ms':ready,'grid':(d/'grid').read_text(),'idle_cpu':round(100*(b-a)/2,2),'idle_rss_mib':round(rss,1),'load_cpu':round(100*(last-b)/(end-start),1),'post_load_rss_mib':round(peak,1),'tui':grouped}
    out['pty'] = json.loads((d/'pty.json').read_text())
    out['capture_available'] = any(c != '-1' for _, c in frames)
    (d/'result.json').write_text(json.dumps(out,indent=2))
    if not out['capture_available']:
        print(f'{app} {i}: no marker frames captured; screen metrics unavailable', flush=True)
    print(app,i,{**out,'tui':{k:[n,changes,len(vals),round(statistics.median(vals),1) if vals else None] for k,(n,changes,vals) in grouped.items()}},flush=True)
    return out


def summarize(trials):
    result = {}
    for app, rows in trials.items():
        summary = {key: statistics.median(row[key] for row in rows)
                   for key in ('ready_ms', 'idle_rss_mib', 'idle_cpu', 'load_cpu')}
        summary['pty_10000_ms'] = {name: statistics.median(row['pty'][key]['median_ms'] for row in rows)
                                   for name, key in [('colored', '10000'), ('plain', 'plain'), ('unicode', 'unicode'), ('escape', 'escape')]}
        summary['capture_trials'] = sum(row['capture_available'] for row in rows)
        for phase in ('tui8', 'logs+tui8'):
            samples = sorted(t for row in rows for t in row['tui'][phase][2])
            summary[phase] = {'matched': len(samples), 'sent': sum(row['tui'][phase][0] for row in rows),
                              'median_ms': statistics.median(samples) if samples else None,
                              'p95_ms': statistics.quantiles(samples, n=20, method='inclusive')[18] if len(samples) > 1 else None}
        result[app] = summary
    (w/'summary.json').write_text(json.dumps(result, indent=2))

def build():
    if not split_only and not (ghost/'MacOS/ghostty').is_file():
        raise SystemExit('ghostty must be installed in /Applications')
    sp.run(['swiftc', '-O', '-parse-as-library', str(source/'capture.swift'), '-o', str(w/'capture')], check=True, timeout=30)
    sp.run(['swift', 'build', '-c', 'release', '-Xswiftc', '-enable-testing'], check=True, timeout=180)
    bin_dir = pathlib.Path(sp.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], text=True, timeout=30).strip())
    sen.parent.mkdir(parents=True)
    contents = sen.parent.parent
    (contents/'Resources').mkdir()
    shutil.copy2(bin_dir/'SenTerm', sen)
    shutil.copy2(bin_dir/'SwiftTerm_SwiftTerm.bundle/Shaders.metal', contents/'Resources')
    (contents/'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable':'SenTerm', 'CFBundleIdentifier':domain,
        'CFBundleName':'senterm benchmark', 'CFBundlePackageType':'APPL',
    }))
    headers = repo/'.build/artifacts/sen-term/GhosttyVt/ghostty-vt.xcframework/macos-arm64_x86_64/Headers'
    link = ['swiftc', '-O', '-parse-as-library', '-I', str(bin_dir/'Modules'), '-I', str(headers),
            '-L', str(bin_dir), '-lghostty-vt', '-lc++',
            *(bin_dir/'SenTerm.product/Objects.LinkFileList').read_text().splitlines()]
    sp.run(link + [str(source/'preview.swift'), '-o', str(w/'preview')], check=True, timeout=45)
    probe = split_probe_path()
    probe.parent.mkdir(parents=True)
    probe_contents = probe.parent.parent
    shutil.copytree(contents/'Resources', probe_contents/'Resources')
    (probe_contents/'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable':'split', 'CFBundleIdentifier':domain + '.split',
        'CFBundleName':'senterm split benchmark', 'CFBundlePackageType':'APPL',
    }))
    sp.run(link + ['-Onone', str(repo/'tests/senterm-tests/split-window-probe.swift'), '-o', str(probe)],
           check=True, timeout=45)


def split_probe_path():
    return w/'SplitBench.app/Contents/MacOS/split'

build()
awake = sp.Popen(['/usr/bin/caffeinate', '-d', '-w', str(os.getpid())])
try:
    if not split_only:
        apps = ['sen', 'ghost', 'preview']
        trials = {app: [] for app in apps}
        for i in range(3):
            for app in apps[i:] + apps[:i]:
                trials[app].append(trial(app, i))
        summarize(trials)
    env = dict(os.environ, SENTERM_EXTENDED_PROBE='1', SHELL='/bin/zsh')
    for tool in ('tmux', 'vttest'):
        if path := shutil.which(tool):
            env[f'SENTERM_TEST_{tool.upper()}'] = path
    log_path = w/'split.log'
    try:
        with log_path.open('w') as log:
            sp.run([str(split_probe_path())], stdout=log, stderr=log, cwd=w, env=env, timeout=75, check=True)
    finally:
        print(log_path.read_text(), end='')
        if (tmux := env.get('SENTERM_TEST_TMUX')) and (w/'tmux.sock').exists():
            sp.run([tmux, '-S', str(w/'tmux.sock'), 'kill-server'], timeout=5, stderr=sp.DEVNULL)
finally:
    stop(awake)
    for prefs in (domain, domain + '.split'):
        sp.run(['defaults','delete',prefs],stderr=sp.DEVNULL,timeout=5)
