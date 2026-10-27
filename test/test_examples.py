"""Integration checks in disposable repositories; one bounded JSON report."""
import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--pwsh', required=True)
p.add_argument('--skip-bash', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
checks = []


def run(argv, cwd=None):
    return subprocess.run(argv, cwd=cwd, capture_output=True, text=True,
                          encoding='utf-8', timeout=30)


def missing_dependency(tool):
    print(json.dumps({'Outcome': 'Unsupported', 'Passed': 0, 'Failed': 0,
                      'Skipped': 0, 'Checks': [],
                      'Error': {'Code': 'MissingDependency', 'Tool': tool}},
                     separators=(',', ':')))
    raise SystemExit(2)


try:
    version = run([a.pwsh, '-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
                   '[pscustomobject]@{Core=($PSVersionTable.PSEdition -eq "Core");'
                   'Supported=($PSVersionTable.PSVersion -ge [version]"7.4")} | ConvertTo-Json -Compress'])
    info = json.loads(version.stdout)
    if version.returncode or not info['Core'] or not info['Supported']:
        missing_dependency('PowerShell Core 7.4+')
    if not shutil.which('git') or run(['git', '--version']).returncode:
        missing_dependency('Git')
except (OSError, subprocess.SubprocessError, ValueError, KeyError):
    missing_dependency('PowerShell Core 7.4+ and Git')

# Windows exercises the Git scenarios with PowerShell. The Linux matrix covers Bash.
skip_bash = a.skip_bash or os.name == 'nt'
if not skip_bash:
    try:
        deps = run(['bash', '-c',
                    'for dep in awk jq timeout; do command -v "$dep" >/dev/null || exit 1; done'])
        if deps.returncode:
            missing_dependency('Bash, awk, jq and GNU timeout')
    except (OSError, subprocess.SubprocessError):
        missing_dependency('Bash, awk, jq and GNU timeout')


def native(argv, cwd):
    if run(argv, cwd).returncode:
        raise RuntimeError('Fixture setup failed')


def check(name, body):
    try:
        body()
        checks.append({'Name': name, 'Passed': True})
    except Exception as error:
        checks.append({'Name': name, 'Passed': False, 'Exception': type(error).__name__})


def inspect_result(result, expected='Success'):
    assert not result.stderr, 'Unexpected agent-facing stderr'
    assert len(result.stdout.strip().splitlines()) == 1
    assert len(result.stdout.strip().encode('utf-8')) <= 2048
    obj = json.loads(result.stdout)
    assert obj['Outcome'] == expected
    return obj


def overview(repo, expected='Success'):
    return inspect_result(run([a.pwsh, '-NoLogo', '-NoProfile', '-NonInteractive', '-File',
                               str(root / 'examples/Generated-GitOverview.ps1'),
                               '-Repository', str(repo)]), expected)


def exercise_repositories():
    with tempfile.TemporaryDirectory(prefix='quiet-cli-repo-') as temp:
        repo = Path(temp) / 'repo with spaces'
        repo.mkdir()
        native(['git', 'init', '--initial-branch=main'], repo)
        (repo / 'tracked.txt').write_text('initial\n', encoding='utf-8')
        native(['git', 'add', '--', 'tracked.txt'], repo)
        native(['git', '-c', 'user.name=QuietCli Test', '-c', 'user.email=test@example.invalid',
                '-c', 'commit.gpgsign=false', '-c', f'core.hooksPath={repo / "no-hooks"}',
                'commit', '-m', 'fixture'], repo)

        def clean_pwsh():
            obj = overview(repo)
            assert obj['Data']['Clean'] and obj['Data']['Changed'] == 0
            assert obj['Data']['Branch'] == 'main'
        check('PowerShell clean Git repository', clean_pwsh)

        native(['git', 'mv', '--', 'tracked.txt', 'renamed with spaces.txt'], repo)
        unusual = 'untracked é with spaces.txt' if os.name == 'nt' else 'untracked é with newline\nname.txt'
        (repo / unusual).write_text('untracked\n', encoding='utf-8')

        def changed_pwsh():
            obj = overview(repo)
            assert obj['Data']['Changed'] == 1 and obj['Data']['Untracked'] == 1
            assert not obj['Data']['Clean'] and obj['Execution']['Steps'] == 2
        check('PowerShell Git rename and unusual untracked path', changed_pwsh)

        if skip_bash:
            for name in ('Bash reducer matches the selected Git counts',
                         'Bash native failure emits one structured result'):
                checks.append({'Name': name, 'Skipped': True, 'Reason': 'Requires POSIX; covered on Linux'})
        else:
            def changed_bash():
                obj = inspect_result(run(['bash', str(root / 'examples/generated-git-status.sh'), str(repo)]))
                assert obj['Data']['Changed'] == 1 and obj['Data']['Untracked'] == 1
            check('Bash reducer matches the selected Git counts', changed_bash)

            def invalid_bash():
                result = run(['bash', str(root / 'examples/generated-git-status.sh'), str(repo / 'missing')])
                obj = inspect_result(result, 'Failed')
                assert result.returncode != 0 and obj['Data'] is None
                assert not obj['Execution']['AnalysisComplete']
            check('Bash native failure emits one structured result', invalid_bash)

        native(['git', 'checkout', '--detach'], repo)

        def detached_pwsh():
            obj = overview(repo)
            assert obj['Data']['Detached'] and obj['Data']['Branch'] is None
        check('PowerShell detached HEAD', detached_pwsh)

        unborn = Path(temp) / 'unborn repository'
        unborn.mkdir()
        native(['git', 'init', '--initial-branch=main'], unborn)

        def unborn_pwsh():
            obj = overview(unborn)
            assert obj['Data']['Branch'] == 'main' and obj['Data']['Clean']
            assert obj['Data']['Changed'] == 0 and obj['Data']['Untracked'] == 0
        check('PowerShell repository before its first commit', unborn_pwsh)

        def invalid_pwsh():
            obj = overview(repo / 'missing', 'Failed')
            assert obj['Data'] is None and not obj['Execution']['AnalysisComplete']
        check('PowerShell invalid repository is a failure', invalid_pwsh)


try:
    exercise_repositories()
except Exception as error:
    checks.append({'Name': 'Fixture setup and cleanup', 'Passed': False, 'Exception': type(error).__name__})
failed = sum(c.get('Passed') is False for c in checks)
passed = sum(c.get('Passed') is True for c in checks)
skipped = sum(c.get('Skipped', False) for c in checks)
print(json.dumps({'Outcome': 'Failed' if failed else 'Success', 'Platform': os.name,
                  'Passed': passed, 'Failed': failed, 'Skipped': skipped, 'Checks': checks},
                 separators=(',', ':')))
raise SystemExit(bool(failed))
