#!/usr/bin/env python3
"""Build the PlayChain fixture (PlayTools f2bfbd7) and the game-local shim dylib, then replay Firebase-shaped
launches, each a separate process on a throwaway SQLite DB (GAKU_POC_DB). Synthetic data only: the real
PlayChain DB and the game are never touched. Writes test-results.txt; exits non-zero on any FAIL."""
from collections import defaultdict
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile

root = Path(__file__).resolve().parent
build = root / 'build'
build.mkdir(exist_ok=True)
source = root / 'PlayTools-source'
src = root / 'src'
expected = 'f2bfbd76ff55f4737c959fa2eac07f9ada2e6d7e'
results, logs = [], []


def record(ok, label, detail=''):
    line = ('PASS: ' if ok else 'FAIL: ') + label + ('' if ok or not detail else f'  [{detail}]')
    results.append(line)
    print(line, flush=True)
    return ok


def finish():
    failed = sum(line.startswith('FAIL') for line in results)
    summary = f'SUMMARY: {len(results) - failed} passed, {failed} failed'
    print(summary)
    (root / 'test-results.txt').write_text('\n'.join(results + [summary, '', '==== launch logs ===='] + logs) + '\n')
    raise SystemExit(1 if failed else 0)


# ---- PlayChain sources at the pinned commit, DB path taken from GAKU_POC_DB --------------
head = subprocess.run(['git', '-C', str(source), 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
if head != expected:
    raise SystemExit(f'PlayTools-source must be a clone checked out at {expected}; see README.md.')
record(True, f'PlayTools-source pinned at {expected[:7]}')
PLAYTOOLS = ['PlayedApple.swift', 'PlayedAppleDB.swift', 'PlayedAppleDBConstants.swift', 'PlaySettings.swift']
for name in PLAYTOOLS[:3]:
    text = (source / 'PlayTools/MysticRunes' / name).read_text()
    if name == 'PlayedApple.swift':
        text = text.replace('public class PlayKeychain:', '@objc(PlayKeychainFixture)\npublic class PlayKeychain:', 1)
    elif name == 'PlayedAppleDB.swift':
        start = text.index('        let bundleID = Bundle.main.infoDictionary?')
        end = text.index('\n\n        let alreadyCreated', start)
        text = text[:start] + '        let keychainDB = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GAKU_POC_DB"]!)' + text[end:]
    else:
        text = 'import Security\n' + text
    (build / name).write_text(text)
(build / 'PlaySettings.swift').write_text('import Foundation\nclass PlaySettings { static let shared = PlaySettings(); let settingsData = Settings() }\nstruct Settings { let playChainDebugging = false }\n')

# ---- toolchain: Xcode with an unaccepted license makes xcrun exit 69 -> Command Line Tools ----
env = dict(os.environ)


def xcrun(*args):
    return subprocess.run(['xcrun', *map(str, args)], env=env, capture_output=True, text=True)


toolchain = env.get('DEVELOPER_DIR', 'xcode-select default')
if xcrun('clang', '--version').returncode:
    env['DEVELOPER_DIR'] = toolchain = '/Library/Developer/CommandLineTools'
if not record(xcrun('clang', '--version').returncode == 0, f'toolchain: {toolchain}'):
    finish()
sdk = xcrun('--sdk', 'macosx', '--show-sdk-path').stdout.strip()
clang, swiftc = (xcrun('--find', tool).stdout.strip() for tool in ('clang', 'swiftc'))
shim = src / 'PlayChainCompat.m'
dylib = build / 'GakuPlayChainCompat.dylib'
probe = build / 'persistence-probe'
for stale in (dylib, probe):
    stale.unlink(missing_ok=True)
with (build / 'compile.log').open('w') as log:
    def compile(label, args):
        log.write('$ ' + ' '.join(map(str, args)) + '\n')
        log.flush()
        ok = subprocess.run(list(map(str, args)), env=env, stdout=log, stderr=log).returncode == 0
        return record(ok, 'build ' + label, 'see build/compile.log')

    mac = [clang, '-isysroot', sdk, '-mmacosx-version-min=14.0', '-fobjc-arc', '-Wall', '-Werror', '-I', src, '-c']
    built = compile('fixture shim object', [*mac, '-DGAKU_POC_FIXTURE', shim, '-o', build / 'PlayChainCompat.o'])
    built = compile('fixture router object', [*mac, src / 'fixture-router.m', '-o', build / 'fixture-router.o']) and built
    built = built and compile('fixture executable', [
        swiftc, '-sdk', sdk, '-target', 'arm64-apple-macosx14.0', '-module-cache-path', build / 'module-cache',
        '-module-name', 'PlayChainFixture', '-import-objc-header', src / 'fixture-bridge.h', *[build / n for n in PLAYTOOLS],
        src / 'main.swift', build / 'PlayChainCompat.o', build / 'fixture-router.o', '-o', probe])
    # (i) the game dylib: Mac Catalyst, no fixture code.
    if compile('(i) Catalyst dylib (arm64-apple-ios14.0-macabi)', [
            clang, '-target', 'arm64-apple-ios14.0-macabi', '-isysroot', sdk, '-fobjc-arc', '-Wall', '-Werror', '-dynamiclib',
            '-framework', 'Foundation', '-framework', 'Security', '-install_name', '@rpath/GakuPlayChainCompat.dylib', shim, '-o', dylib]):
        uuid = next((l.split()[1] for l in xcrun('otool', '-l', dylib).stdout.splitlines() if l.strip().startswith('uuid ')), '?')
        record(xcrun('otool', '-D', dylib).stdout.split()[-1:] == ['@rpath/GakuPlayChainCompat.dylib']
               and '_GakuInstallPlayChainCompat' in xcrun('nm', '-gU', dylib).stdout.split(),
               f'(i) install name @rpath/GakuPlayChainCompat.dylib, exports _GakuInstallPlayChainCompat (LC_UUID {uuid})')
if not built:
    finish()

# ---- synthetic launches -----------------------------------------------------------------
# Each scenario gets its own DB; each step is one launch: (commands, expected OUT values, fb rows afterwards).
# Rows are item values in rowid order -- the order PlayChain's unordered SELECT scans.
SCENARIOS = {
    '(a) first login then a second save in the same session: SecItemAdd, then SecItemUpdate, 1 row': [
        ('fb-get fb-set:A1 fb-set:A2', {'fb-get': ['nil'], 'fb-set': ['SecItemAdd:0', 'SecItemUpdate:0']}, ['A2']),
        ('fb-get', {'fb-get': ['A2']}, ['A2'])],
    '(b) token refresh x2 across restarts: SecItemUpdate, still 1 row, refreshed value read back': [
        ('fb-get fb-set:A1', {}, ['A1']),
        ('fb-get fb-set:A2', {'fb-get': ['A1'], 'fb-set': ['SecItemUpdate:0']}, ['A2']),
        ('fb-get fb-set:A3', {'fb-get': ['A2'], 'fb-set': ['SecItemUpdate:0']}, ['A3']),
        ('fb-get', {'fb-get': ['A3']}, ['A3'])],
    '(c) account switch A -> B: 1 row, B read back after restart': [
        ('fb-get fb-set:A1', {}, ['A1']),
        ('fb-get fb-set:B1', {'fb-get': ['A1'], 'fb-set': ['SecItemUpdate:0']}, ['B1']),
        ('fb-get', {'fb-get': ['B1']}, ['B1'])],
    '(d) sign-out: SecItemDelete returns errSecSuccess (not errSecIO), 0 rows': [
        ('fb-get fb-set:A1', {}, ['A1']),
        ('fb-get fb-remove', {'fb-get': ['A1'], 'fb-remove': ['0']}, []),
        ('fb-get', {'fb-get': ['nil']}, [])],
    '(e) two same-account rows from older builds: read returns one item, add appends, nothing overwritten': [
        ('raw-add:A1 raw-add:A2', {}, ['A1', 'A2']),
        ('fb-get fb-set:A3', {'fb-get': ['A1'], 'fb-set': ['SecItemAdd:0']}, ['A1', 'A2', 'A3'])],
    '(f) row appearing after a not-found read: new login appended, original kept and restored': [
        ('fb-get raw-add:R1 fb-set:G1', {'fb-get': ['nil'], 'fb-set': ['SecItemAdd:0']}, ['R1', 'G1']),
        ('fb-get', {'fb-get': ['R1']}, ['R1', 'G1'])],
    '(g) blind double add: second is errSecDuplicateItem, value unchanged': [
        ('add:P1 add:P2 fb-get', {'add': ['0', 'errSecDuplicateItem'], 'fb-get': ['P1']}, ['P1'])],
    '(h) delete of a missing item: errSecItemNotFound': [
        ('fb-remove fb-get', {'fb-remove': ['errSecItemNotFound'], 'fb-get': ['nil']}, [])],
}
tmp = Path(tempfile.mkdtemp(prefix='gaku-playchain-'))


def launch(db, commands):
    result = subprocess.run([probe, *commands.split()], env=env | {'GAKU_POC_DB': str(db)}, text=True, capture_output=True, cwd=tmp)
    logs.append(f'LAUNCH {db.name} {commands}\n{result.stdout}{result.stderr}')
    outs = defaultdict(list, rc=[str(result.returncode)])
    for line in result.stdout.splitlines():
        if line.startswith('OUT ') and '=' in line:
            key, value = line[4:].split('=', 1)
            outs[key].append(value)
    return outs


def rows(db):
    con = sqlite3.connect(f'file:{db}?mode=ro', uri=True)
    try:
        return [bytes(v).decode() for (v,) in con.execute('SELECT v_Data FROM genp ORDER BY rowid')]
    finally:
        con.close()


try:
    for label, steps in SCENARIOS.items():
        db = tmp / f'{label[1]}.db'
        db.touch()
        problems = []
        for n, (commands, want, want_rows) in enumerate(steps, 1):
            outs = launch(db, commands)
            want = {'rc': ['0'], 'install': ['7'], **want}  # install 7 = read+add+delete swizzled
            got = {key: outs[key] for key in want}
            if got != want or rows(db) != want_rows:
                problems.append(f'launch {n} {commands}: {got} rows={rows(db)}')
        record(not problems, label, '; '.join(problems))
except Exception as error:  # still write test-results.txt
    record(False, 'harness', repr(error))
finally:
    shutil.rmtree(tmp, ignore_errors=True)
finish()
