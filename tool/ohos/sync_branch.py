#!/usr/bin/env python3
"""Merge origin/main into ohos; conflicts and concurrent pushes fail safely."""
import argparse
import os
from pathlib import Path
import subprocess


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


def sync(push=True):
    if git('status', '--porcelain'):
        raise RuntimeError('Refusing to sync a dirty checkout')
    git('fetch', 'origin', 'main', 'ohos')
    before = git('rev-parse', 'origin/ohos')
    # Do not reset any developer branch. CI uses a fresh detached checkout.
    git('checkout', '--detach', 'origin/ohos')
    try:
        git('merge', '--no-edit', 'origin/main')
    except subprocess.CalledProcessError:
        git('merge', '--abort')
        raise RuntimeError('main → ohos conflicts; resolve manually. Remote ohos was not changed.') from None
    changed = git('rev-parse', 'HEAD') != before
    if push and changed:
        # No force: a concurrent contributor push must never be discarded.
        git('push', 'origin', 'HEAD:refs/heads/ohos')
    if os.environ.get('GITHUB_OUTPUT'):
        with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
            output.write(f'changed={str(changed).lower()}\n')
    print('ohos includes current main' + (' (updated)' if changed else ' (already synchronized)'))
    return changed


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--no-push', action='store_true')
    sync(push=not parser.parse_args().no_push)
