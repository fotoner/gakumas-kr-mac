#!/usr/bin/env python3
"""Build an isolated PlayTools fixture and the game-local shim, then replay synthetic launches
and run the built game dylib in Mac Catalyst processes (e2e).

Synthetic data only: every launch is a separate fixture process on a throwaway SQLite DB
(GAKU_POC_DB) in a temp dir; the real PlayChain DB and the game bundle are never touched.
Writes test-results.txt, prints PASS/FAIL lines and exits non-zero on any failure.
"""
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parent
build = root / 'build'
build.mkdir(exist_ok=True)
source = root / 'PlayTools-source'
src = root / 'src'
expected = 'f2bfbd76ff55f4737c959fa2eac07f9ada2e6d7e'
results, logs, failures = [], [], []


def record(ok, label, detail=''):
    line = ('PASS: ' if ok else 'FAIL: ') + label + ('' if ok or not detail else f'  [{detail}]')
    results.append(line)
    print(line, flush=True)
    if not ok:
        failures.append(label)
    return ok


def finish():
    summary = f'SUMMARY: {len(results) - len(failures)} passed, {len(failures)} failed'
    print(summary)
    (root / 'test-results.txt').write_text('\n'.join(results + [summary, '', '==== launch logs ===='] + logs) + '\n')
    raise SystemExit(1 if failures else 0)


# ---- PlayTools fixture sources at the pinned commit ------------------------------------
if not (source / '.git').exists():
    raise SystemExit('Fetch PlayTools-source at the pinned commit first; see README.md.')
if subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() != expected:
    raise SystemExit('PlayTools-source must be checked out at ' + expected)
record(True, f'PlayTools-source pinned at {expected[:7]}')
PLAYTOOLS = ['PlayedApple.swift', 'PlayedAppleDB.swift', 'PlayedAppleDBConstants.swift', 'PlaySettings.swift']


def prepare_playtools(dest, rename):
    """PlayChain sources with the DB path taken from GAKU_POC_DB (never the PlayCover container)."""
    dest.mkdir(exist_ok=True)
    for name in PLAYTOOLS[:3]:
        text = (source / 'PlayTools/MysticRunes' / name).read_text()
        if name == 'PlayedApple.swift' and rename:
            text = text.replace('public class PlayKeychain:', '@objc(PlayKeychainFixture)\npublic class PlayKeychain:', 1)
        elif name == 'PlayedAppleDB.swift':
            start = text.index('        let bundleID = Bundle.main.infoDictionary?')
            end = text.index('\n\n        let alreadyCreated', start)
            text = text[:start] + '        let keychainDB = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GAKU_POC_DB"]!)' + text[end:]
            if 'io.playcover.PlayCover' in text:
                raise SystemExit('PlayedAppleDB.swift still names the PlayCover container')
        elif name == 'PlayedAppleDBConstants.swift':
            text = 'import Security\n' + text
        (dest / name).write_text(text)
    (dest / 'PlaySettings.swift').write_text('import Foundation\nclass PlaySettings { static let shared = PlaySettings(); let settingsData = Settings() }\nstruct Settings { let playChainDebugging = false }\n')


prepare_playtools(build, rename=True)
e2e_dir = build / 'e2e'
prepare_playtools(e2e_dir, rename=False)

# ---- toolchain (Xcode with an unaccepted license fails with exit 69) -------------------
env = dict(os.environ)


def xcrun_works():
    try:
        return subprocess.run(['xcrun', 'clang', '--version'], env=env, capture_output=True).returncode == 0
    except OSError:
        return False


toolchain = env.get('DEVELOPER_DIR', 'xcode-select default')
if not xcrun_works():
    env['DEVELOPER_DIR'] = '/Library/Developer/CommandLineTools'
    toolchain = 'DEVELOPER_DIR=/Library/Developer/CommandLineTools (fallback)'
    if not xcrun_works():
        record(False, 'usable toolchain (xcrun clang)')
        finish()
record(True, f'toolchain: {toolchain}')


def xcrun(*args):
    return subprocess.check_output(['xcrun', *args], env=env, text=True).strip()


sdk = xcrun('--sdk', 'macosx', '--show-sdk-path')
clang, swiftc, nm, otool = (xcrun('--find', tool) for tool in ('clang', 'swiftc', 'nm', 'otool'))
shim = src / 'PlayChainCompat.m'
dylib = build / 'GakuPlayChainCompat.dylib'
probe = build / 'persistence-probe'
e2e_playtools = e2e_dir / 'libPlayTools.dylib'
e2e_plist = e2e_dir / 'app-info.plist'  # embedded only; a loose Info.plist beside a binary would be used too
e2e_bins = {'game': [e2e_dir / 'game' / 'playtools-first', e2e_dir / 'game' / 'shim-first'],
            'nobundle': [e2e_dir / 'nobundle' / 'playtools-first']}
for stale in (dylib, probe, e2e_playtools, *e2e_bins['game'], *e2e_bins['nobundle']):
    stale.unlink(missing_ok=True)
e2e_plist.write_text('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
                     '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>CFBundleIdentifier</key>'
                     '<string>jp.co.bandainamcoent.BNEI0421</string></dict></plist>\n')
with (build / 'compile.log').open('w') as log:
    def compile(label, args):
        log.write('$ ' + ' '.join(map(str, args)) + '\n')
        log.flush()
        ok = subprocess.run(list(map(str, args)), env=env, stdout=log, stderr=log).returncode == 0
        return record(ok, 'build ' + label, 'see build/compile.log')

    built = compile('fixture shim object', [clang, '-isysroot', sdk, '-mmacosx-version-min=14.0', '-fobjc-arc', '-Wall', '-Werror',
                                            '-DGAKU_POC_FIXTURE', '-c', shim, '-o', build / 'PlayChainCompat.o'])
    built = compile('fixture router object', [clang, '-isysroot', sdk, '-mmacosx-version-min=14.0', '-fobjc-arc', '-Wall', '-Werror',
                                              '-I', src, '-c', src / 'fixture-router.m', '-o', build / 'fixture-router.o']) and built
    built = built and compile('fixture executable', [
        swiftc, '-sdk', sdk, '-target', 'arm64-apple-macosx14.0', '-module-cache-path', build / 'module-cache',
        '-module-name', 'PlayChainFixture', '-import-objc-header', src / 'fixture-bridge.h',
        *[build / name for name in ['PlayedApple.swift', 'PlayedAppleDB.swift', 'PlayedAppleDBConstants.swift', 'PlaySettings.swift']],
        src / 'main.swift', build / 'PlayChainCompat.o', build / 'fixture-router.o', '-o', probe])
    # (j) the game dylib: Mac Catalyst, no fixture code, no SQLite.
    dylib_built = compile('(j) Catalyst dylib (arm64-apple-ios14.0-macabi)', [
        clang, '-target', 'arm64-apple-ios14.0-macabi', '-isysroot', sdk, '-fobjc-arc', '-Wall', '-Werror', '-dynamiclib',
        '-framework', 'Foundation', '-framework', 'Security', '-install_name', '@rpath/GakuPlayChainCompat.dylib', shim, '-o', dylib])
    # (e2e) that dylib in a Catalyst process: unrenamed PlayTools.PlayKeychain, constructor install, bundle-id gate.
    e2e_built = dylib_built and compile('(e2e) Catalyst libPlayTools.dylib (module PlayTools)', [
        swiftc, '-sdk', sdk, '-target', 'arm64-apple-ios14.0-macabi', '-module-cache-path', build / 'module-cache-e2e',
        '-module-name', 'PlayTools', '-emit-library', '-Xlinker', '-install_name', '-Xlinker', '@rpath/libPlayTools.dylib',
        *[e2e_dir / name for name in PLAYTOOLS], '-o', e2e_playtools])
    for kind, binaries in e2e_bins.items():
        for binary in binaries:
            order = [dylib, e2e_playtools] if binary.name == 'shim-first' else [e2e_playtools, dylib]
            plist = ['-Wl,-sectcreate,__TEXT,__info_plist,' + str(e2e_plist)] if kind == 'game' else []
            binary.parent.mkdir(exist_ok=True)
            e2e_built = e2e_built and compile(f'(e2e) Catalyst {kind}/{binary.name} executable', [
                clang, '-target', 'arm64-apple-ios14.0-macabi', '-isysroot', sdk, '-fobjc-arc', '-Wall', '-Werror',
                src / 'e2e-main.m', '-framework', 'Foundation', '-framework', 'Security', *order,
                '-Wl,-rpath,' + str(e2e_dir), '-Wl,-rpath,' + str(build), *plist, '-o', binary])

if dylib_built:
    def tool(*args):
        return subprocess.run([*map(str, args)], env=env, capture_output=True, text=True).stdout
    exported = tool(nm, '-gU', dylib).split()
    undefined = tool(nm, '-u', dylib)
    record('_GakuInstallPlayChainCompat' in exported, '(j) nm shows GakuInstallPlayChainCompat')
    record(not any(s.startswith(('_GakuFixture', '_fx_')) for s in exported), '(j) no fixture-only symbols in the dylib')
    record(tool(otool, '-D', dylib).strip().splitlines()[-1:] == ['@rpath/GakuPlayChainCompat.dylib'],
           '(j) install name @rpath/GakuPlayChainCompat.dylib')
    record('sqlite' not in tool(otool, '-L', dylib).lower() and '_sqlite3' not in undefined,
           '(j) no SQLite linkage or sqlite3_* imports (no SQL inside the game process)')
    record(re.search(r'platform (6|MACCATALYST)\b', tool(otool, '-l', dylib)) is not None, '(j) LC_BUILD_VERSION platform is Mac Catalyst')
if not built:
    finish()

# ---- synthetic launches -----------------------------------------------------------------
FB = 'firebase_auth_1___FIRAPP_DEFAULT_firebase_user'
SHORT = {FB: 'fb', '1:000000000000:ios:fakefakefake__FIRAPP_DEFAULT': 'gul', 'adjust_uuid': 'adj', '_pfo': 'pfo', 'race': 'race'}
tmp = Path(tempfile.mkdtemp(prefix='gaku-playchain-v2-', dir=os.environ.get('GAKU_POC_TMP')))
all_stderr = []


class Launch:
    def __init__(self, result):
        self.rc, self.stdout, self.stderr = result.returncode, result.stdout, result.stderr
        self.outs = [line[4:].split('=', 1) for line in self.stdout.splitlines() if line.startswith('OUT ') and '=' in line]

    def out(self, key, index=0):
        values = [v for k, v in self.outs if k == key]
        return values[index] if index < len(values) else None

    def all(self, key):
        return [v for k, v in self.outs if k == key]


def new_db(name, create=True):
    db = tmp / f'{name}.db'
    if create:
        db.touch()
    return db


def launch(scenario, db, shim_mode, *commands):
    result = subprocess.run([probe, 'run', f'--{shim_mode}', *commands], env=env | {'GAKU_POC_DB': str(db)},
                            text=True, capture_output=True, cwd=tmp)
    return launched(scenario, db, shim_mode, commands, result)


def blind_launch(scenario, db, shim_mode, *after):
    """Launch whose first fb-get runs while another connection holds an EXCLUSIVE lock on the DB
    (PlayChain has no busy timeout and reports the busy read as not found); `after` runs unlocked."""
    held, done, released = (tmp / f'{db.stem}.{step}' for step in ('held', 'read', 'released'))
    commands = [f'wait-file:{held}', 'fb-get', f'touch:{done}', f'wait-file:{released}', *after]
    proc = subprocess.Popen([probe, 'run', f'--{shim_mode}', *commands], env=env | {'GAKU_POC_DB': str(db)},
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=tmp)
    con = sqlite3.connect(db, isolation_level=None, timeout=0)
    try:
        con.execute('BEGIN EXCLUSIVE')
        held.touch()
        deadline = time.monotonic() + 15
        while not done.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
    finally:
        con.close()  # rolls back, releasing the lock
    released.touch()
    stdout, stderr = proc.communicate(timeout=60)
    return launched(scenario, db, shim_mode, commands, subprocess.CompletedProcess(proc.args, proc.returncode, stdout, stderr))


def launched(scenario, db, shim_mode, commands, result):
    run = Launch(result)
    logs.append(f'LAUNCH ({scenario}) {db.name} --{shim_mode} {" ".join(commands)}\n{result.stdout}{result.stderr}')
    all_stderr.append(result.stderr)
    expected_install = {'full': '7', 'naive-add': '7', 'v1-only': '1', 'no-shim': 'none'}[shim_mode]
    if result.returncode or run.out('install') != expected_install:
        record(False, f'({scenario}) launch {db.name} {" ".join(commands)}', f'rc={result.returncode} install={run.out("install")}')
    return run


def rows(db, table='genp'):
    """[(short acct, value)] in rowid order -- the order PlayChain's unordered SELECT scans."""
    if not db.exists() or db.stat().st_size == 0:
        return []
    con = sqlite3.connect(f'file:{db}?mode=ro', uri=True)
    try:
        if not con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone():
            return []
        return [(SHORT.get(acct, acct), bytes(v).decode() if v is not None else None)
                for acct, v in con.execute(f'SELECT acct, v_Data FROM {table} ORDER BY rowid')]
    finally:
        con.close()


def vals(db, short):
    return [v for s, v in rows(db) if s == short]


def agrp_rows(db):
    """[(agrp set?, value)] of the Firebase-account rows in rowid order."""
    con = sqlite3.connect(f'file:{db}?mode=ro', uri=True)
    try:
        return [(agrp is not None, bytes(v).decode()) for agrp, v in
                con.execute('SELECT agrp, v_Data FROM genp WHERE acct = ? ORDER BY rowid', (FB,))]
    finally:
        con.close()


try:
    # legacy Sep-20 flow (agrp set), 6 processes: seed, baseline, fixed, fixed, update, refreshed
    legacy_db = new_db('legacy')
    for mode in ['seed', 'baseline', 'fixed', 'fixed', 'update', 'refreshed']:
        result = subprocess.run([probe, mode], env=env | {'GAKU_POC_DB': str(legacy_db)}, text=True, capture_output=True, cwd=tmp)
        logs.append(f'PROCESS {mode}\n{result.stdout}{result.stderr}')
        all_stderr.append(result.stderr)
        if not record(result.returncode == 0 and 'FAIL' not in result.stdout, f'legacy flow process {mode}',
                      next((l for l in result.stdout.splitlines() if l.startswith('FAIL')), f'rc={result.returncode}')):
            break

    # (a) first login on an absent / empty DB
    for variant in ('absent', 'empty'):
        db = new_db(f'a-{variant}', create=variant == 'empty')
        l1 = launch('a', db, 'full', 'fb-get', 'fb-set:A-v1')
        record(l1.out('fb-get') == 'nil' and l1.out('fb-set') == 'SecItemAdd:0',
               f'(a) {variant} DB: nothing restored, first login adds', f'{l1.out("fb-get")} {l1.out("fb-set")}')
        record(vals(db, 'fb') == ['A-v1'], f'(a) {variant} DB: 1 row after first login', str(len(vals(db, 'fb'))))
        l2 = launch('a', db, 'full', 'fb-get')
        record(l2.out('fb-get') == 'A-v1', f'(a) {variant} DB: login restored after restart', l2.out('fb-get'))
    db = new_db('a-session')
    l1 = launch('a', db, 'full', 'fb-get', 'fb-set:A-v1', 'fb-set:A-v2', 'fb-get')
    record(l1.all('fb-set') == ['SecItemAdd:0', 'SecItemUpdate:0'] and l1.all('fb-get') == ['nil', 'A-v2'] and vals(db, 'fb') == ['A-v2'],
           '(a) first login then refresh in one session: add, then update of the same row', str(l1.all('fb-set')))

    # (b) token refresh twice across restarts
    def refresh_flow(name, shim_mode):
        db = new_db(name)
        steps = [launch('b', db, shim_mode, 'fb-get', 'fb-set:A-v1')]
        counts = [len(vals(db, 'fb'))]
        for n in (2, 3):
            steps.append(launch('b', db, shim_mode, 'fb-get', f'fb-set:A-v{n}'))
            counts.append(len(vals(db, 'fb')))
        steps.append(launch('b', db, shim_mode, 'fb-get'))
        return db, steps, counts
    db, steps, counts = refresh_flow('b', 'full')
    record(counts == [1, 1, 1], '(b) refresh x2 across restarts keeps 1 row', str(counts))
    record([s.out('fb-set') for s in steps[1:3]] == ['SecItemUpdate:0'] * 2, '(b) refresh = SecItemAdd dup -> SecItemUpdate',
           str([s.out('fb-set') for s in steps[1:3]]))
    record([s.out('fb-get') for s in steps[1:]] == ['A-v1', 'A-v2', 'A-v3'], '(b) refreshed value read back after each restart',
           str([s.out('fb-get') for s in steps[1:]]))
    record(vals(db, 'fb') == ['A-v3'] and not any(s.all('fb-warn') for s in steps), '(b) final row is the latest value, no I-AUT000005')
    db, steps, counts = refresh_flow('b-control-v1', 'v1-only')
    record(counts == [1, 2, 3] and steps[-1].out('fb-get') == 'A-v1',
           '(b) control: v1 read-only shim reproduces append + stale restore', f'{counts} {steps[-1].out("fb-get")}')

    # (c) account switch A -> B
    db = new_db('c')
    launch('c', db, 'full', 'fb-get', 'fb-set:A-v1')
    l2 = launch('c', db, 'full', 'fb-get', 'fb-set:B-v1')
    l3 = launch('c', db, 'full', 'fb-get')
    record(l2.out('fb-get') == 'A-v1' and l2.out('fb-set') == 'SecItemUpdate:0', '(c) switch writes over the single row', l2.out('fb-set'))
    record(vals(db, 'fb') == ['B-v1'] and l3.out('fb-get') == 'B-v1', '(c) 1 row, account B read back after restart', l3.out('fb-get'))

    # (d) signOut -> removeData
    db = new_db('d')
    launch('d', db, 'full', 'fb-set:A-v1')
    l2 = launch('d', db, 'full', 'fb-get', 'fb-remove')
    record(l2.out('fb-remove') == 'SecItemDelete:0', '(d) removeData: SecItemDelete returns 0 (not errSecIO)', l2.out('fb-remove'))
    record('delete errSecIO remaining=0 -> errSecSuccess' in l2.stderr, '(d) shim mapped PlayChain errSecIO after verifying no rows remain')
    record(vals(db, 'fb') == [], '(d) 0 rows after signOut', str(len(vals(db, 'fb'))))
    l3 = launch('d', db, 'full', 'fb-get')
    record(l3.out('fb-get') == 'nil', '(d) next launch reads nil', l3.out('fb-get'))
    db = new_db('d-duplicates')
    launch('d', db, 'no-shim', 'raw-add:A-v1', 'raw-add:A-v2')
    l2 = launch('d', db, 'full', 'fb-remove')
    record(l2.out('fb-remove') == 'SecItemDelete:0' and vals(db, 'fb') == [], '(d) signOut with legacy duplicates removes all, status 0')
    db = new_db('d-control-v1')
    launch('d', db, 'v1-only', 'fb-set:A-v1')
    l2 = launch('d', db, 'v1-only', 'fb-remove')
    record(l2.out('fb-remove') == 'THROWS SecItemDelete errSecIO', '(d) control: without the delete fix Firebase throws errSecIO', l2.out('fb-remove'))
    db = new_db('d-fails')
    launch('d', db, 'full', 'fb-set:A-v1')
    con = sqlite3.connect(db)
    con.execute("CREATE TRIGGER keep_rows BEFORE DELETE ON genp BEGIN SELECT RAISE(ABORT, 'keep'); END")
    con.commit()
    con.close()
    l2 = launch('d', db, 'full', 'fb-remove')
    record(l2.out('fb-remove') == 'THROWS SecItemDelete errSecIO' and vals(db, 'fb') == ['A-v1']
           and 'delete errSecIO remaining=1 -> errSecIO' in l2.stderr,
           '(d) a DELETE that left its row stays errSecIO (failed signOut not reported as success)', l2.out('fb-remove'))
    db = new_db('d-switch')
    launch('d', db, 'full', 'fb-set:A-v1')
    l2 = launch('d', db, 'full', 'fb-get', 'fb-remove', 'fb-get', 'fb-set:B-v1', 'fb-set:B-v2')
    l3 = launch('d', db, 'full', 'fb-get')
    record(l2.all('fb-set') == ['SecItemAdd:0', 'SecItemUpdate:0'] and vals(db, 'fb') == ['B-v2'] and l3.out('fb-get') == 'B-v2',
           '(d) signOut then new login in one session: insert, refresh updates, restored after restart', str(l2.all('fb-set')))

    # (e) two pre-existing duplicate rows of the same account
    db = new_db('e')
    l0 = launch('e', db, 'no-shim', 'raw-add:A-v1', 'raw-add:A-v2')
    l1 = launch('e', db, 'full', 'fb-get', 'fb-set:A-v3')
    record(l0.all('raw-add') == ['0', '0'] and vals(db, 'fb') == ['A-v1', 'A-v2', 'A-v3'],
           '(e) count>1: add stays an append, existing rows not overwritten', str(vals(db, 'fb')))
    record(l1.out('fb-get') == 'A-v1' and not l1.all('fb-warn') and 'read rows=2 items=1' in l1.stderr,
           '(e) read returns one item per identity (first row), no I-AUT000005', l1.out('fb-get'))
    record(l1.out('fb-set') == 'SecItemAdd:0' and 'WARNING add existing=2' in l1.stderr and 'playchain-recover.py' in l1.stderr,
           '(e) warning names playchain-recover.py', l1.out('fb-set'))

    # (f) duplicates: stale guest first, real account later
    db = new_db('f')
    launch('f', db, 'no-shim', 'raw-add:G-v1', 'raw-add:R-v1')
    l1 = launch('f', db, 'full', 'fb-get', 'fb-set:G-v2', 'fb-set:R-v2')
    l2 = launch('f', db, 'full', 'fb-get')
    record(vals(db, 'fb') == ['G-v1', 'R-v1', 'G-v2', 'R-v2'], '(f) real account row never overwritten', str(vals(db, 'fb')))
    record(l1.all('fb-set') == ['SecItemAdd:0', 'SecItemAdd:0'] and l1.stderr.count('WARNING add existing=') == 2,
           '(f) every add on duplicates appends and warns', str(l1.all('fb-set')))
    record(l1.out('fb-get') == 'G-v1' and l2.out('fb-get') == 'G-v1', '(f) read keeps first-row choice (recover tool resolves)', l2.out('fb-get'))
    db = new_db('f-control-naive')
    launch('f', db, 'no-shim', 'raw-add:G-v1', 'raw-add:R-v1')
    l1 = launch('f', db, 'naive-add', 'fb-get', 'fb-set:G-v2')
    record(l1.out('fb-set') == 'SecItemUpdate:0' and 'R-v1' not in vals(db, 'fb'),
           '(f) control: duplicate-on-any-match would overwrite the real account', str(vals(db, 'fb')))

    # (g) GULKeychainUtils get-then-add/update; Adjust add-when-missing
    db = new_db('g')
    l1 = launch('g', db, 'full', 'gul-get', 'gul-set:I-v1', 'adj-init:D-v1')
    l2 = launch('g', db, 'full', 'gul-get', 'gul-set:I-v2', 'adj-init:D-v2')
    l3 = launch('g', db, 'full', 'gul-get')
    record(l1.out('gul-set') == 'SecItemAdd:0' and l2.out('gul-set') == 'SecItemUpdate:0', '(g) GUL add then update',
           f'{l1.out("gul-set")} {l2.out("gul-set")}')
    record(l2.out('gul-get') == 'I-v1' and l3.out('gul-get') == 'I-v2' and vals(db, 'gul') == ['I-v2'], '(g) GUL keeps 1 row, latest value')
    record(l1.out('adj-init') == 'SecItemAdd:0' and l2.out('adj-init') == 'existing:D-v1' and vals(db, 'adj') == ['D-v1'],
           '(g) Adjust add-when-missing keeps 1 row')

    # (h) blind double add ('_pfo'-like)
    db = new_db('h')
    l1 = launch('h', db, 'full', 'pfo-add:P-v1', 'pfo-add:P-v2')
    l2 = launch('h', db, 'full', 'pfo-add:P-v3', 'pfo-get')
    record(l1.all('pfo-add') == ['0', 'errSecDuplicateItem'] and l2.out('pfo-add') == 'errSecDuplicateItem',
           '(h) second blind add returns errSecDuplicateItem', f'{l1.all("pfo-add")} {l2.out("pfo-add")}')
    record(l2.out('pfo-get') == 'P-v1' and vals(db, 'pfo') == ['P-v1'], '(h) value unchanged, 1 row')

    # (i) delete of a missing item
    db = new_db('i')
    l1 = launch('i', db, 'full', 'fb-set:A-v1', 'delete-missing', 'gul-remove')
    record(l1.out('delete-missing') == 'errSecItemNotFound' and l1.out('gul-remove') == 'errSecItemNotFound',
           '(i) delete of a missing item -> errSecItemNotFound')
    record(vals(db, 'fb') == ['A-v1'], '(i) unrelated rows untouched')

    # (k) a row hidden from the startup read is never overwritten by the next login
    db = new_db('k')
    l1 = launch('k', db, 'full', 'fb-get', 'raw-add:R-v1', 'fb-set:G-v1')
    l2 = launch('k', db, 'full', 'fb-get')
    record(l1.out('fb-get') == 'nil' and l1.out('fb-set') == 'SecItemAdd:0' and vals(db, 'fb') == ['R-v1', 'G-v1']
           and 'WARNING add existing=1 after a not-found read' in l1.stderr and 'playchain-recover.py' in l1.stderr,
           '(k) row that appeared behind a not-found read: new login appended with a warning', str(vals(db, 'fb')))
    record(l2.out('fb-get') == 'R-v1', '(k) original row restored on the next launch', l2.out('fb-get'))
    db = new_db('k-seen')
    l1 = launch('k', db, 'full', 'fb-get', 'raw-add:R-v1', 'fb-get', 'fb-set:R-v2')
    record(l1.all('fb-get') == ['nil', 'R-v1'] and l1.out('fb-set') == 'SecItemUpdate:0' and vals(db, 'fb') == ['R-v2'],
           '(k) once a later read returns the row, refresh updates it again', f'{l1.all("fb-get")} {l1.out("fb-set")}')
    db = new_db('k-busy')
    launch('k', db, 'full', 'fb-set:R-v1')
    l1 = blind_launch('k', db, 'full', 'fb-set:G-v1')
    l2 = launch('k', db, 'full', 'fb-get')
    record(l1.out('wait-file') is None and l1.out('fb-get') == 'nil' and l1.out('fb-set') == 'SecItemAdd:0'
           and vals(db, 'fb') == ['R-v1', 'G-v1'] and l2.out('fb-get') == 'R-v1',
           '(k) startup read blinded by a foreign EXCLUSIVE lock: real account kept and restored',
           f'{l1.out("fb-get")} {l1.out("fb-set")} {vals(db, "fb")} {l2.out("fb-get")}')

    # (l) access-group items (SQLite enforces the primary key once agrp is set)
    db = new_db('l')
    l1 = launch('l', db, 'full', 'agrp-set:X-v1', 'agrp-set:X-v2', 'agrp-add:X-v3', 'agrp-get')
    record(l1.all('agrp-set') == ['SecItemAdd:0', 'SecItemUpdate:0'] and l1.out('agrp-add') == 'errSecDuplicateItem'
           and l1.out('agrp-get') == 'X-v2' and agrp_rows(db) == [(True, 'X-v2')],
           '(l) agrp item: add, refresh updates, blind add is a duplicate; 1 row', f'{l1.all("agrp-set")} {l1.out("agrp-add")}')
    db = new_db('l-control')
    l1 = launch('l', db, 'no-shim', 'agrp-add:X-v1', 'agrp-add:X-v2')
    record(l1.all('agrp-add') == ['0', 'errSecIO'] and len(agrp_rows(db)) == 1,
           '(l) control: without the shim the second agrp insert hits the primary key (errSecIO)', str(l1.all('agrp-add')))
    db = new_db('l-mixed')
    l1 = launch('l', db, 'full', 'fb-set:A-v1', 'agrp-set:X-v1', 'fb-get', 'agrp-get')
    record(l1.out('agrp-set') == 'SecItemAdd:0' and agrp_rows(db) == [(False, 'A-v1'), (True, 'X-v1')]
           and l1.out('fb-get') == 'A-v1' and l1.out('agrp-get') == 'X-v1',
           '(l) NULL-agrp row + agrp item stay two items; each read returns its own value', f'{l1.out("agrp-set")} {agrp_rows(db)}')

    # (m) adds the probe cannot address keep PlayChain's plain append
    db = new_db('m-service-only')
    l1 = launch('m', db, 'full', 'raw-other:O-v1', 'svc-only-set:S-v1')
    record(l1.out('svc-only-set') == 'SecItemAdd:0' and rows(db) == [('other', 'O-v1'), (None, 'S-v1')] and 'add existing' not in l1.stderr,
           "(m) service-only add appends; the other account's item is not overwritten", f'{l1.out("svc-only-set")} {rows(db)}')
    db = new_db('m-non-utf8')
    l1 = launch('m', db, 'full', 'nonutf8-add:N-v1')
    record(l1.rc == 0 and l1.out('nonutf8-add') == '0' and len(rows(db)) == 1,
           '(m) non-UTF-8 account data: plain insert, no trap in PlayChain query()', f'rc={l1.rc} {l1.out("nonutf8-add")}')

    # extra: whole-game launch sequence, concurrency, other classes, install semantics
    db = new_db('game')
    for n in (1, 2, 3):
        launch('game', db, 'full', 'fb-get', 'gul-get', 'adj-init:D-v1', f'pfo-add:P-v{n}', f'gul-set:I-v{n}', f'fb-set:A-v{n}')
    last = launch('game', db, 'full', 'fb-get', 'gul-get', 'pfo-get')
    record(sorted(s for s, _ in rows(db)) == ['adj', 'fb', 'gul', 'pfo'] and
           [last.out('fb-get'), last.out('gul-get'), last.out('pfo-get')] == ['A-v3', 'I-v3', 'P-v1'],
           'game-like launches x3: one row per item, latest Firebase/GUL values', str(sorted(s for s, _ in rows(db))))
    db = new_db('race')
    l1 = launch('race', db, 'full', 'race')
    record(l1.out('race') == 'success=1 duplicate=15 other=0' and len(vals(db, 'race')) == 1,
           'concurrent adds are serialized: 1 insert, 15 duplicates', l1.out('race'))
    db = new_db('inet')
    l1 = launch('inet', db, 'full', 'inet-add:X-v1', 'inet-add:X-v2')
    record(l1.all('inet-add') == ['0', '0'] and len(rows(db, 'inet')) == 2 and 'add existing' not in l1.stderr,
           'non-generic classes pass through untouched')
    db = new_db('install')
    l1 = launch('install', db, 'full', 'install-again', 'fb-set:A-v1', 'fb-set:A-v2', 'fb-get')
    record(l1.out('install-again') == '7' and l1.all('fb-set') == ['SecItemAdd:0', 'SecItemUpdate:0'] and l1.out('fb-get') == 'A-v2',
           'install is idempotent (no double swizzle)', str(l1.all('fb-set')))
    result = subprocess.run([probe, 'install-check'], env=env | {'GAKU_POC_DB': str(new_db('install-check'))},
                            text=True, capture_output=True, cwd=tmp)
    logs.append(f'PROCESS install-check\n{result.stdout}{result.stderr}')
    all_stderr.append(result.stderr)
    check_outs = dict(line[4:].split('=', 1) for line in result.stdout.splitlines() if line.startswith('OUT '))
    record(check_outs == {'install-nil': '0', 'install-partial': '1', 'install-partial-again': '1', 'install-other-class': '0'}
           and '+add:result: missing' in result.stderr and '+delete: missing' in result.stderr
           and 'PlayKeychain class missing' in result.stderr,
           'missing class/selectors are logged and left off', str(check_outs))

    # (e2e) the built game dylib in Catalyst processes
    if e2e_built:
        cwd = tmp / 'e2e-cwd'  # no Info.plist anywhere near
        cwd.mkdir()
        expected_outs = {
            'game': {'bundle': 'set', 'class': 'found', 'add': '0', 'add-again': '-25299', 'update': '0',
                     'read': 'array:1:E-v2', 'delete': '0', 'delete-again': '-25300'},
            'nobundle': {'bundle': 'none', 'class': 'found', 'add': '0', 'add-again': '0', 'read': '0:dictionary',
                         'delete': '-36', 'delete-again': '-25300'}}
        for kind, binaries in e2e_bins.items():
            for binary in binaries:
                loads = [line.split()[0] for line in tool(otool, '-L', binary).splitlines() if '@rpath/' in line]
                wanted = ['@rpath/GakuPlayChainCompat.dylib', '@rpath/libPlayTools.dylib']
                if binary.name != 'shim-first':
                    wanted.reverse()
                db = new_db(f'e2e-{kind}-{binary.name}')
                result = subprocess.run([binary], env=env | {'GAKU_POC_DB': str(db)}, text=True, capture_output=True, cwd=cwd)
                logs.append(f'E2E {kind}/{binary.name}\n{result.stdout}{result.stderr}')
                all_stderr.append(result.stderr)
                outs = dict(line[4:].split('=', 1) for line in result.stdout.splitlines() if line.startswith('OUT '))
                if kind == 'game':
                    installed = '[GakuPlayChainCompat] read=1 add=1 delete=1' in result.stderr
                    label = f'(e2e) {binary.name}: constructor installs on PlayTools.PlayKeychain; add/dup/update/array read/delete 0'
                else:
                    installed = '[GakuPlayChainCompat]' not in result.stderr
                    label = '(e2e) no bundle id: nothing installed (PlayChain append, dictionary read, delete errSecIO)'
                record(result.returncode == 0 and loads == wanted and installed and outs == expected_outs[kind], label,
                       f'rc={result.returncode} loads={loads} outs={outs}')

    # never log values or identifiers
    stderr = '\n'.join(all_stderr)
    leaks = [p for p in (r'\b[A-Z]-v\d\b', 'synthetic-session', 'fakefakefake', 'firebase_auth', 'FIRInstallations',
                         'adjust_uuid', '_pfo', 'deviceInfo', 'race-\\d', 'fake.group', 'shared.svc', 'e2e-account',
                         'e2e-service') if re.search(p, stderr)]
    record(not leaks, 'shim logs carry no values or item identifiers', ', '.join(leaks))
    shim_lines = [l for l in stderr.splitlines() if '[GakuPlayChainCompat]' in l]
    record(bool(shim_lines), f'shim log lines observed ({len(shim_lines)})')
finally:
    if os.environ.get('GAKU_POC_KEEP') != '1':
        shutil.rmtree(tmp, ignore_errors=True)
finish()
