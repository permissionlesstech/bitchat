"""Bounded local commands and failure diagnostics shared by composer runners."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time


class Interrupted(Exception):
    pass


def install_signal_handlers():
    def interrupt(signum, _frame):
        raise Interrupted(f'interrupted by signal {signum}')
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def manifest(root):
    ignored = {'.git', '.build', 'build', '__pycache__'}
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob('*')) if p.is_file()
            and not ignored.intersection(p.relative_to(root).parts)}


def stop_group(process):
    # The new session belongs to this command, never another chat's build.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    # Also remove descendants whose parent exited promptly on TERM.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)


def bounded(command, cwd, env, output, name, timeout, separate_stderr=False):
    save(output / (name + '-command.json'), {'argv': command, 'cwd': str(cwd),
                                           'timeout_seconds': timeout})
    started = time.monotonic()
    path = output / (name + '.log')
    code, reason, process = 2, 'setup failure', None
    try:
        with path.open('w') as log, (output / (name + '-stderr.log')).open('w') as error_log:
            process = subprocess.Popen(command, cwd=cwd, env=env, stdout=log,
                                       stderr=error_log if separate_stderr else subprocess.STDOUT, start_new_session=True)
            try:
                code = process.wait(timeout=timeout)
                reason = 'passed' if code == 0 else 'command failed'
            except subprocess.TimeoutExpired:
                code, reason = 124, 'deadline exceeded'
            except (Interrupted, KeyboardInterrupt):
                code, reason = 130, 'interrupted'
                raise
            finally:
                if process.poll() is None or code in (124, 130):
                    stop_group(process)
    finally:
        save(output / (name + '-result.json'), {'exit': code, 'reason': reason,
             'seconds': time.monotonic() - started,
             'log_sha256': hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None})
        if code:
            print(f'{name}: {reason} (exit {code})', flush=True)
            for diagnostic in (path, output / (name + '-stderr.log')):
                if diagnostic.exists() and diagnostic.stat().st_size:
                    print('\n'.join(diagnostic.read_text(errors='replace').splitlines()[-60:]), flush=True)
    return code


def require(command, cwd, env, output, name, timeout=60):
    code = bounded(command, cwd, env, output, name, timeout)
    if code:
        raise RuntimeError(f'{name} failed with exit {code}')
    return (output / (name + '.log')).read_text()


def require_json(command, cwd, env, output, name, timeout=60):
    code = bounded(command, cwd, env, output, name, timeout, separate_stderr=True)
    if code:
        raise RuntimeError(f'{name} failed with exit {code}')
    return json.loads((output / (name + '.log')).read_text())
