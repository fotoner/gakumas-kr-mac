#!/usr/bin/env python3
"""Build an isolated upstream fixture and the game-local PoC; use synthetic data only."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent
build = root / 'build'
build.mkdir(exist_ok=True)
source = root / 'PlayTools-source'
expected = 'f2bfbd76ff55f4737c959fa2eac07f9ada2e6d7e'
if not (source / '.git').exists():
    raise SystemExit('Fetch PlayTools-source at the pinned commit first; see README.md.')
if subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() != expected:
    raise SystemExit('PlayTools-source must be checked out at ' + expected)
for name in ['PlayedApple.swift', 'PlayedAppleDB.swift', 'PlayedAppleDBConstants.swift']:
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
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
clang = subprocess.check_output(['xcrun', '--find', 'clang'], text=True).strip()
swiftc = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
shim = root / 'src/PlayChainCompat.m'
with (build / 'compile.log').open('w') as log:
    def compile(args):
        subprocess.run(list(map(str, args)), check=True, stdout=log, stderr=log)
    compile([clang, '-isysroot', sdk, '-mmacosx-version-min=14.0', '-fobjc-arc', '-DGAKU_POC_FIXTURE', '-c', shim, '-o', build / 'PlayChainCompat.o'])
    compile([swiftc, '-sdk', sdk, '-target', 'arm64-apple-macosx14.0', '-module-cache-path', build / 'module-cache', '-module-name', 'PlayChainFixture',
             *[build / name for name in ['PlayedApple.swift', 'PlayedAppleDB.swift', 'PlayedAppleDBConstants.swift', 'PlaySettings.swift']],
             root / 'src/main.swift', build / 'PlayChainCompat.o', '-o', build / 'persistence-probe'])
    compile([clang, '-target', 'arm64-apple-ios14.0-macabi', '-isysroot', sdk, '-fobjc-arc', '-dynamiclib', '-framework', 'Foundation', '-framework', 'Security',
             '-install_name', '@rpath/GakuPlayChainCompat.dylib', shim, '-o', build / 'GakuPlayChainCompat.dylib'])
logs = []
with tempfile.TemporaryDirectory(prefix='gaku-keychain-poc-') as directory:
    db = Path(directory) / 'synthetic.db'
    db.touch()
    for mode in ['seed', 'baseline', 'fixed', 'fixed', 'update', 'refreshed']:
        result = subprocess.run([build / 'persistence-probe', mode], env=os.environ | {'GAKU_POC_DB': str(db)}, text=True, capture_output=True)
        logs.append('PROCESS ' + mode + '\n' + result.stdout + result.stderr)
        if result.returncode:
            break
(root / 'test-results.txt').write_text('\n'.join(logs))
print('\n'.join(logs))
raise SystemExit(result.returncode)
