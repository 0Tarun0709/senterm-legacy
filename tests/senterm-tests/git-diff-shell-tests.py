import os
import pathlib
import re
import subprocess
import tempfile

integration = pathlib.Path(__file__).resolve().parents[2] / 'scripts/shell-integration.zsh'
with tempfile.TemporaryDirectory() as work:
    repo = pathlib.Path(work, 'repo')
    nested = repo / 'nested'
    nested.mkdir(parents=True)
    env = dict(os.environ, HOME=work, TERM='xterm-256color', TERM_PROGRAM='senterm',
               SENTERM_DIFF_TOKEN='test-token', INTEGRATION=str(integration), GIT_PAGER='/bin/cat')

    def git(*args):
        subprocess.run(['/usr/bin/git', '-c', 'user.name=test', '-c', 'user.email=test@example.invalid',
                        '-c', 'commit.gpgsign=false', *args], cwd=repo, env=env, check=True)

    git('init', '-q')
    file = repo / 'file'
    file.write_text('before\n')
    git('add', 'file')
    git('commit', '-qm', 'initial')
    file.write_text('staged\n')
    git('add', 'file')
    file.write_text('after\n')

    def shell(command, directory=nested):
        return subprocess.check_output(['/usr/bin/script', '-q', '/dev/null', '/bin/zsh', '-fic',
                                        'source "$INTEGRATION"; ' + command], cwd=directory, env=env, timeout=10)

    marker = b'\x1b]7503;test-token;'
    assert marker + b'unstaged\x07' in shell('git diff')
    for flag in ('--cached', '--staged'):
        assert marker + b'staged\x07' in shell('git diff ' + flag)
    for args in ('git diff | /bin/cat', 'git diff > "$HOME/out"; /bin/cat "$HOME/out"',
                 'git --no-pager diff', 'git diff -- ../file'):
        result = shell(args)
        assert marker not in result and b'+after' in re.sub(rb'\x1b\[[0-9;]*m', b'', result), (args, result)
    assert marker not in shell('git diff 2>/dev/null; :', work)
    print('git diff shell tests passed')
