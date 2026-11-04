"""Bound child process lifetimes for release credentials."""
import os
import signal
import subprocess


def command(args, cwd=None, timeout=180, capture=True, env=None):
    # Keep the lock until detached build descendants have stopped, including when
    # launchd/logout sends SIGTERM to this owner-session worker.
    process = None
    interrupted = None
    def stop():
        if process is None:
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=2)
    def terminate(signum, frame):
        nonlocal interrupted
        interrupted = signum
        if process is not None:
            raise SystemExit(128 + signum)
    previous = {sig: signal.signal(sig, terminate) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        process = subprocess.Popen(list(map(str, args)), cwd=cwd, text=True, env=env,
                                   stdout=subprocess.PIPE if capture else None,
                                   stderr=subprocess.PIPE if capture else None,
                                   start_new_session=True)
        if interrupted is not None:
            raise SystemExit(128 + interrupted)
        stdout, stderr = process.communicate(timeout=timeout)
        result = subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
        result.check_returncode()
        return result
    finally:
        # Prevent a second signal from interrupting the process-group cleanup.
        for sig in previous:
            signal.signal(sig, signal.SIG_IGN)
        try:
            stop()
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
