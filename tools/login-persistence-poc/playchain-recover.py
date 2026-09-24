#!/usr/bin/env python3
"""Hash-only inspection / dedup / pre-launch guard for Gakumas' PlayChain login DB.

  check     : read-only; per-group counts, the row PlayChain returns first, newest row,
              plus KeyCover / playChain setting / PlayTools hash status.
  dedup     : keep ONE Firebase-user row (newest rowid of --keep-uid-hash), delete the rest.
              Dry-run unless --apply. --apply makes a private backup first.
  preflight : run by `make run` right before launch. exit 0 = launch ok, 3 = refuse.
              Every refusal check runs first and writes nothing. On the launch path it takes a
              rotating private backup (skipped when identical to the newest one), then
              auto-dedupes when all Firebase rows are one uid, or one non-anonymous uid plus
              guests (keeps that uid's newest rowid; guests are dropped). It refuses when the
              account to be restored differs from the last launched one, unless that one was a
              guest or GAKU_ACCEPT_ACCOUNT_CHANGE=1. Non-rotating account-<uidhash>.db keeps the
              last pre-launch state of every non-anonymous account; last-launch.json the last uid.

Never prints tokens, uid, email, API key or v_Data -- only sha256[:8], lengths, times.

Paths (flags win over env): --chain-dir/GAKU_PLAYCHAIN_DIR, --settings/GAKU_PLAYCOVER_SETTINGS,
--backup-root/GAKU_PLAYCHAIN_BACKUPS, --playtools/GAKU_PLAYTOOLS_BIN.
Test only: GAKU_TEST_GUARD_PROCS replaces the process names checked by the "is it running" guard.
"""
import argparse, datetime as dt, hashlib, json, os, plistlib, re, shlex, shutil, sqlite3, subprocess, sys
from urllib.parse import quote

HOME = os.path.expanduser('~')
BUNDLE = 'jp.co.bandainamcoent.BNEI0421'
PC = f'{HOME}/Library/Containers/io.playcover.PlayCover'
DEFAULT_CHAIN = os.environ.get('GAKU_PLAYCHAIN_DIR') or f'{PC}/PlayChain'
DEFAULT_SETTINGS = os.environ.get('GAKU_PLAYCOVER_SETTINGS') or f'{PC}/App Settings/{BUNDLE}.plist'
DEFAULT_BACKUPS = os.environ.get('GAKU_PLAYCHAIN_BACKUPS') or \
    f'{HOME}/Library/Application Support/gakumas-kr-mac/playchain-backups'
DEFAULT_PLAYTOOLS = os.environ.get('GAKU_PLAYTOOLS_BIN') or f'{HOME}/Library/Frameworks/PlayTools.framework/PlayTools'
PLAYTOOLS_SHA8 = '548eaa72'  # PlayTools f2bfbd7, the build whose PlayChain behaviour was analysed
KEEP_BACKUPS = 10
GUARD_PROCS = os.environ.get('GAKU_TEST_GUARD_PROCS', '').split() or ['idolmaster_gakuen', 'PlayCover']
FB_ACCT = 'firebase_auth_1___FIRAPP_DEFAULT_firebase_user'
KST = dt.timezone(dt.timedelta(hours=9))
EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
BACKUP_RE = re.compile(re.escape(BUNDLE) + r'\.\d{8}T\d{6}\.\d{6}\.db$')
PIN_RE = re.compile(r'account-([0-9a-f]{8})\.db$')
STATE = 'last-launch.json'
H = lambda b: hashlib.sha256(b if isinstance(b, bytes) else str(b).encode()).hexdigest()[:8]


class Refuse(Exception):
    pass


def ro(path):
    return sqlite3.connect(f'file:{quote(path)}?mode=ro', uri=True)


def ts(v):
    if isinstance(v, dict) and 'NS.time' in v:
        return (EPOCH + dt.timedelta(seconds=v['NS.time'])).astimezone(KST)
    return None


def fmt(t):
    return t.strftime('%Y-%m-%d %H:%M') if t else '-'


def mtime(p):
    return fmt(dt.datetime.fromtimestamp(os.stat(p).st_mtime, KST))


def decode(blob):
    """-> (uid_hash, lastSignIn, tokenExpiry, anonymous) from the NSKeyedArchiver FIRUser blob."""
    try:
        pl = plistlib.loads(blob)
        objs = pl['$objects']
        r = lambda x: objs[x.data] if isinstance(x, plistlib.UID) else x
        user = r(next(iter(pl['$top'].values())))
        uid = r(user.get('userID'))
        meta = r(user.get('metadata')) or {}
        tok = r(user.get('tokenService')) or {}
        anon = r(user.get('anonymous'))
        return (H(uid) if isinstance(uid, str) else None,
                ts(r(meta.get('lastSignInDate'))), ts(r(tok.get('accessTokenExpirationDate'))),
                anon if isinstance(anon, bool) else None)
    except Exception as e:  # never echo the blob
        return ('decode-err:' + type(e).__name__, None, None, None)


def fb_rows(con):
    """[(rowid, svce, uid_hash, lastSignIn, tokenExp, anonymous)] in rowid order."""
    q = "SELECT rowid, svce, v_Data FROM genp WHERE acct=? AND svce LIKE 'firebase_auth_1:%' ORDER BY rowid"
    return [(rid, svce) + decode(bytes(v) if v is not None else b'') for rid, svce, v in con.execute(q, (FB_ACCT,))]


def running(name):
    return subprocess.run(['/usr/bin/pgrep', '-x', name], capture_output=True).returncode == 0


def keycover(db):
    return os.path.splitext(db)[0] + '.keyCover'


def guards(db):
    problems = [f'{n} is running -- quit it first' for n in GUARD_PROCS if running(n)]
    held = subprocess.run(['/usr/sbin/lsof', '-t', '--', db], capture_output=True, text=True).stdout.split()
    if held:
        problems.append(f'DB is open by pid(s) {" ".join(held)}')
    for suffix in ('-journal', '-wal'):
        if os.path.exists(db + suffix):
            problems.append(f'hot {suffix} file exists next to the DB')
    kc = keycover(db)
    if os.path.exists(kc):
        problems.append(f'{os.path.basename(kc)} exists beside the .db (KeyCover pair) -- resolve KeyCover first')
    return problems


def playchain_setting(path):
    """-> (ok, description)"""
    try:
        with open(path, 'rb') as f:
            v = plistlib.load(f).get('playChain')
    except FileNotFoundError:
        return False, 'settings file missing'
    except Exception as e:
        return False, f'unreadable ({type(e).__name__})'
    return v is True, f'playChain={v!r}'


def playtools_sha8(path):
    try:
        with open(path, 'rb') as f:
            return hashlib.sha256(f.read()).hexdigest()[:8]
    except OSError:
        return None


def rows_digest(con):
    """Content digest of the schema and every genp row (compared, never printed)."""
    h = hashlib.sha256()
    tables = set()
    for name, sql in con.execute("SELECT name, sql FROM sqlite_master ORDER BY name"):
        tables.add(name)
        h.update(repr((name, sql)).encode())
    if 'genp' in tables:
        for row in con.execute('SELECT rowid, * FROM genp ORDER BY rowid'):
            h.update(repr(row).encode())
    return h.hexdigest()


# --- check -------------------------------------------------------------------

def cmd_check(a):
    kc = keycover(a.db)
    ok, desc = playchain_setting(a.settings)
    pt = playtools_sha8(a.playtools)
    print(f'keyCover={"PRESENT " + mtime(kc) if os.path.exists(kc) else "absent"}'
          f'  settings: {desc}{"" if ok else " (NOT OK)"}'
          f'  PlayTools sha256#{pt or "missing"}{"" if pt == PLAYTOOLS_SHA8 else " (expected " + PLAYTOOLS_SHA8 + ")"}')
    st = load_state(a.backup_root)
    pins = sorted(m.group(1) for m in map(PIN_RE.match, os.listdir(a.backup_root) if os.path.isdir(a.backup_root) else []) if m)
    print(f'last make run: {"uid#%s anonymous=%s at %s" % (st["uid_hash"], st.get("anonymous"), st.get("time")) if st else "-"}'
          f'  account backups: {" ".join("uid#" + h for h in pins) or "-"}  ({a.backup_root})')
    if not os.path.isfile(a.db):
        print(f'NO DB at {a.db}'); return 1
    con = ro(a.db)
    st = os.stat(a.db)
    print(f'db inode={st.st_ino} size={st.st_size} mtime={mtime(a.db)}'
          f' integrity={con.execute("PRAGMA integrity_check").fetchone()[0]}')
    for acct, n, lo, hi in con.execute('SELECT acct, count(*), min(rowid), max(rowid) FROM genp GROUP BY acct, svce ORDER BY 3'):
        label = acct if acct in (FB_ACCT, 'adjust_uuid', '_pfo') else 'acct#' + H(acct or '')
        print(f'  group {label:<48} rows={n:<3} rowid {lo}..{hi}')
    rows = fb_rows(con)
    if not rows:
        print('NO Firebase user row -> the game will start signed out'); return 1
    # Exactly what PlayChain/the shim hands Firebase: first row of acct+svce, no ORDER BY.
    first = con.execute('SELECT rowid FROM genp WHERE acct=? AND svce=? LIMIT 1', (FB_ACCT, rows[0][1])).fetchone()[0]
    by = {r[0]: r for r in rows}
    for tag, rid in (('restored-on-next-launch', first), ('newest', rows[-1][0])):
        _, _, u, ls, te, an = by[rid]
        print(f'  {tag:<24} rowid={rid} uid#{u} lastSignIn={fmt(ls)} tokenExp={fmt(te)} anonymous={an}')
    print(f'  distinct uid hashes: {sorted({r[2] for r in rows}, key=str)}  firebase rows={len(rows)}')
    if a.expect_uid_hash:
        ok = by[first][2] == a.expect_uid_hash
        print('RESULT:', 'OK' if ok else 'MISMATCH', f'(restored uid#{by[first][2]}, expected uid#{a.expect_uid_hash})')
        return 0 if ok else 2
    return 0


# --- dedup (shared by `dedup` and `preflight`) ---------------------------------

def dedup_plan(db, keep_uid_hash):
    """-> (keep_row, drop_rowids, rows). Raises Refuse."""
    con = ro(db)
    rows = fb_rows(con)
    con.close()
    svces = {r[1] for r in rows}
    if len(svces) != 1:
        raise Refuse(f'expected one Firebase svce, found {len(svces)}')
    mine = [r for r in rows if r[2] == keep_uid_hash]
    if not mine:
        raise Refuse(f'no row with uid#{keep_uid_hash}; hashes present: {sorted({r[2] for r in rows}, key=str)}')
    keep = mine[-1]  # highest rowid == last write Firebase made for that account
    if keep[3] is None or keep[4] is None:
        raise Refuse(f'newest row for uid#{keep_uid_hash} (rowid {keep[0]}) has no lastSignIn/tokenExp -- inspect manually')
    if keep[4] != max((r[4] for r in mine if r[4]), default=None) or \
            keep[3] != max((r[3] for r in mine if r[3]), default=None):
        raise Refuse('newest rowid is not also the newest lastSignIn/tokenExp for that uid -- inspect manually')
    return keep, [r[0] for r in rows if r[0] != keep[0]], rows


def dedup_apply(db, keep, drop):
    """Delete `drop` inside one IMMEDIATE transaction with secure_delete. -> integrity result."""
    problems = guards(db)  # re-check right before writing
    if problems:
        raise Refuse('state changed before writing: ' + '; '.join(problems))
    con = sqlite3.connect(db, isolation_level=None)
    try:
        con.execute('PRAGMA secure_delete=ON')  # zero the freed token pages
        con.execute('BEGIN IMMEDIATE')
        cur = con.execute('DELETE FROM genp WHERE acct=? AND svce=? AND rowid<>?', (FB_ACCT, keep[1], keep[0]))
        left = con.execute('SELECT count(*), max(rowid) FROM genp WHERE acct=? AND svce=?', (FB_ACCT, keep[1])).fetchone()
        if cur.rowcount != len(drop) or left != (1, keep[0]):
            con.execute('ROLLBACK')
            raise Refuse(f'ROLLED BACK: unexpected row counts (deleted {cur.rowcount}, expected {len(drop)})')
        con.execute('COMMIT')
        return cur.rowcount, con.execute('PRAGMA integrity_check').fetchone()[0]
    finally:
        con.close()


def cmd_dedup(a):
    problems = guards(a.db)
    if problems:
        print('REFUSING:\n  ' + '\n  '.join(problems)); return 3
    try:
        keep, drop, rows = dedup_plan(a.db, a.keep_uid_hash)
    except Refuse as e:
        print(f'REFUSING: {e}'); return 3
    print(f'keep rowid={keep[0]} uid#{keep[2]} lastSignIn={fmt(keep[3])} tokenExp={fmt(keep[4])}')
    print(f'drop {len(drop)} rows (uid hashes: {sorted({r[2] for r in rows if r[0] != keep[0]}, key=str)}); other items untouched')
    if not a.apply:
        print('dry-run only; re-run with --apply --backup-dir DIR'); return 0
    if not a.backup_dir:
        print('REFUSING: --apply needs --backup-dir'); return 3
    os.umask(0o077)
    bdir = os.path.join(os.path.expanduser(a.backup_dir), dt.datetime.now(KST).strftime('%Y%m%d-%H%M%S-%f'))
    os.makedirs(bdir, mode=0o700)
    dst = os.path.join(bdir, os.path.basename(a.db))
    shutil.copy2(a.db, dst)
    os.chmod(dst, 0o600)
    src_h, dst_h = (hashlib.sha256(open(p, 'rb').read()).hexdigest() for p in (a.db, dst))
    if src_h != dst_h:
        print('REFUSING: backup hash mismatch'); return 3
    print(f'backup ok: {dst} sha256#{src_h[:8]}')
    try:
        n, ok = dedup_apply(a.db, keep, drop)
    except Refuse as e:
        print(f'REFUSING: {e}'); return 4 if 'ROLLED BACK' in str(e) else 3
    print(f'deleted {n}; firebase rows left=1 (rowid {keep[0]}); integrity={ok}')
    return 0 if ok == 'ok' else 4


# --- preflight -----------------------------------------------------------------

def private_root(root):
    os.makedirs(root, mode=0o700, exist_ok=True)
    os.chmod(root, 0o700)


def digest_of(path):
    con = ro(path)
    try:
        return rows_digest(con)
    finally:
        con.close()


def snapshot(db, dst):
    """Consistent copy via the sqlite3 backup API from a read-only connection, verified. -> sha8.
    A failed copy is removed so it can never pose as a good backup."""
    try:
        src = ro(db)
        try:
            out = sqlite3.connect(dst)
            try:
                src.backup(out)
            finally:
                out.close()
            os.chmod(dst, 0o600)
            chk = ro(dst)
            try:
                if chk.execute('PRAGMA integrity_check').fetchone()[0] != 'ok' or rows_digest(chk) != rows_digest(src):
                    raise Refuse(f'백업 검증 실패: {dst}')
            finally:
                chk.close()
        finally:
            src.close()
    except BaseException:
        if os.path.exists(dst):
            os.remove(dst)
        raise
    with open(dst, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()[:8]


def rotate_backup(db, root, keep=KEEP_BACKUPS):
    """Rotating pre-launch copy, skipped when the newest one already holds the same rows.
    Only BACKUP_RE names rotate (account-*.db pins never do). -> (path, sha8, created)."""
    old = os.umask(0o077)
    try:
        private_root(root)
        names = sorted(n for n in os.listdir(root) if BACKUP_RE.match(n))
        if names:
            newest = os.path.join(root, names[-1])
            try:
                same = digest_of(newest) == digest_of(db)
            except sqlite3.DatabaseError:
                same = False
            if same:
                with open(newest, 'rb') as f:
                    return newest, hashlib.sha256(f.read()).hexdigest()[:8], False
        dst = os.path.join(root, f'{BUNDLE}.{dt.datetime.now().strftime("%Y%m%dT%H%M%S.%f")}.db')
        if os.path.exists(dst):
            raise Refuse(f'backup name collision: {dst}')
        sha = snapshot(db, dst)
    finally:
        os.umask(old)
    for name in sorted(n for n in os.listdir(root) if BACKUP_RE.match(n))[:-keep]:
        if os.path.join(root, name) != dst:
            os.remove(os.path.join(root, name))
    return dst, sha, True


def pin_path(root, uid_hash):
    return os.path.join(root, f'account-{uid_hash}.db')


def pin_account(db, root, uid_hash):
    """account-<uid_hash>.db = starting state of this launch; replaced per launch, never rotated."""
    dst = pin_path(root, uid_hash)
    tmp = dst + '.tmp'
    old = os.umask(0o077)
    try:
        private_root(root)
        if os.path.exists(tmp):
            os.remove(tmp)
        sha = snapshot(db, tmp)
        os.replace(tmp, dst)
    finally:
        os.umask(old)
    return dst, sha


def load_state(root):
    """-> {uid_hash, anonymous, time} of the last launch preflight allowed, or None."""
    try:
        with open(os.path.join(root, STATE)) as f:
            st = json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        print(f'경고: {STATE} 읽기 실패 ({type(e).__name__}) -- 지난 실행 계정과 비교하지 않음')
        return None
    if not isinstance(st, dict) or not re.fullmatch(r'[0-9a-f]{8}', str(st.get('uid_hash'))):
        return None
    return st


def save_state(root, uid_hash, anonymous):
    old = os.umask(0o077)
    try:
        private_root(root)
        tmp = os.path.join(root, STATE + '.tmp')
        with open(tmp, 'w') as f:
            json.dump({'uid_hash': uid_hash, 'anonymous': anonymous,
                       'time': dt.datetime.now(KST).strftime('%Y-%m-%d %H:%M:%S')}, f)
        os.replace(tmp, os.path.join(root, STATE))
    finally:
        os.umask(old)


def restore_hint(root, db):
    """How to put the last launched account back (pinned copy), else the rotating backups."""
    st = load_state(root)
    pin = pin_path(root, st['uid_hash']) if st else None
    if not pin or not os.path.isfile(pin):
        return f'백업 폴더 {root} 의 최신 사본을 {db} 로 복사해 복원'
    q = shlex.quote
    moved = os.path.join(root, f'{BUNDLE}.replaced.{dt.datetime.now().strftime("%Y%m%d-%H%M%S")}.db')
    return (f'마지막으로 실행한 계정(uid#{st["uid_hash"]}, anonymous={st.get("anonymous")}) 백업: {pin}\n'
            f'      복원 (게임/PlayCover 종료 상태에서, 현재 DB 는 백업 폴더로 옮겨 보관):\n'
            f'      ( [ ! -e {q(db)} ] || mv -n {q(db)} {q(moved)} ) && cp -p {q(pin)} {q(db)}')


def check_account_change(a, launch):
    """Refuse when the row PlayChain will restore belongs to another account than the last launch,
    unless that one was a guest or GAKU_ACCEPT_ACCOUNT_CHANGE=1."""
    st = load_state(a.backup_root)
    if not st or st['uid_hash'] == launch[2]:
        return
    change = f'uid#{st["uid_hash"]}(anonymous={st.get("anonymous")}) -> uid#{launch[2]}(anonymous={launch[5]})'
    if st.get('anonymous') is True:
        print(f'PlayChain: 지난 실행은 게스트 계정 -- 계정 변경 허용 ({change})')
        return
    if os.environ.get('GAKU_ACCEPT_ACCOUNT_CHANGE') == '1':
        print(f'PlayChain: GAKU_ACCEPT_ACCOUNT_CHANGE=1 -- 계정 변경 허용 ({change})')
        return
    lines = [f'지난 실행({st.get("time", "?")})과 다른 계정으로 시작하게 됨: {change}, 최근 로그인 {fmt(launch[3])}']
    if launch[5] is not False:
        lines.append('  남은 것은 게스트(또는 판별 불가) 계정 -- 게임에서 로그아웃됐거나 오래된 키체인이 되돌려진 것일 수 있음')
    lines += ['  ' + restore_hint(a.backup_root, a.db),
              '  의도한 계정 변경이면: GAKU_ACCEPT_ACCOUNT_CHANGE=1 make run']
    raise Refuse('\n'.join(lines))


def mixed_refusal(a, rows, hashes, first):
    newest_login = max((r[3] for r in rows if r[3]), default=None)
    lines = ['서로 다른 계정의 Firebase 로그인 항목이 섞여 있음 (로그인 계정이 여러 개이거나 게스트 여부를 판별 못 함) -- '
             'PlayChain 은 가장 오래된 행을 복원하므로 어떤 계정으로 로그인될지 보장할 수 없음. 남길 계정을 골라 정리한 뒤 다시 실행:']
    dedup_dir = os.path.join(os.path.dirname(a.backup_root), 'dedup-backups')
    for h in hashes:
        mine = [r for r in rows if r[2] == h]
        last = max((r[3] for r in mine if r[3]), default=None)
        anon = {r[5] for r in mine}
        tags = ([f'<- 다음 실행 때 복원되는 행(rowid {first})'] if any(r[0] == first for r in mine) else []) + \
               (['<- 가장 최근 로그인'] if last and last == newest_login else [])
        lines.append(f'    uid#{h}  rows={len(mine)}  rowid {mine[0][0]}..{mine[-1][0]}  최근 로그인 {fmt(last)}  '
                     f'anonymous={"/".join(sorted(map(str, anon)))}  {" ".join(tags)}'.rstrip())
    lines.append('  이 계정만 남기기 (나머지 계정 행은 삭제, 실행 전 백업):')
    for h in hashes:
        lines.append(f'    python3 {shlex.quote(os.path.abspath(__file__))} --db {shlex.quote(a.db)} dedup '
                     f'--keep-uid-hash {h} --apply --backup-dir {shlex.quote(dedup_dir)}')
    return Refuse('\n'.join(lines))


def preflight(a):
    """All refusal checks first (read-only). Writes (backup, dedupe, pin, state) only on the launch path."""
    db, kc, root = a.db, keycover(a.db), a.backup_root
    q = shlex.quote
    allow_empty = os.environ.get('GAKU_ALLOW_EMPTY_CHAIN') == '1'
    if os.environ.get('GAKU_TEST_GUARD_PROCS'):
        print(f'[테스트] 실행 중 검사 대상 = {" ".join(GUARD_PROCS)}')
    busy = [n for n in GUARD_PROCS if running(n)]
    if busy:
        raise Refuse(f'{", ".join(busy)} 실행 중 -- 완전히 종료한 뒤 다시 실행')

    pt = playtools_sha8(a.playtools)
    if pt != PLAYTOOLS_SHA8:
        print(f'경고: PlayTools sha256#{pt or "없음"} (검증된 빌드 #{PLAYTOOLS_SHA8} 아님) -- PlayCover 업데이트로 '
              'PlayChain 동작이 바뀌었을 수 있음. tools/login-persistence-poc/build-and-test.py 재실행 권장')

    problems = []
    ok, desc = playchain_setting(a.settings)
    if not ok:
        problems.append(f'PlayCover 앱 설정의 playChain 이 true 가 아님 ({desc}: {a.settings}) -- '
                        'PlayChain 이 꺼져 있으면 로그인이 저장되지 않음. 설정에서 playChain 을 켠 뒤 재실행')
    if os.path.exists(kc):
        state = ('.db 가 함께 있음 -> .keyCover 는 오래된 스냅샷. PlayCover 에서 Play 를 누르면 이것이 .db 위로 '
                 '복호화되어 로그인이 과거 상태(게스트 등)로 되돌아감'
                 if os.path.exists(db) else
                 '.db 가 없음 -> KeyCover 가 DB 를 잠근 상태(암호화 후 .db 삭제). 지금 실행하면 빈 키체인 = 로그아웃')
        kc_dst = os.path.join(root, os.path.basename(kc) + '.' + dt.datetime.now().strftime('%Y%m%d-%H%M%S'))
        problems.append(
            f'PlayCover KeyCover 파일 있음: {kc} (수정 {mtime(kc)})\n    {state}.\n'
            '    PlayCover 의 Play 버튼은 누르지 말 것 (정상 종료된 PlayCover 세션은 .db 를 다시 .keyCover 로 잠그고 .db 를 삭제함).\n'
            '    해결: .keyCover 를 PlayChain 폴더 밖(백업 폴더)으로 옮겨 보관(삭제 X). 예)\n'
            f'      mkdir -p -m 700 {q(root)} && mv -n {q(kc)} {q(kc_dst)}')
    empty = not os.path.exists(db) or (os.path.isfile(db) and os.path.getsize(db) == 0)
    if os.path.islink(db) or (os.path.exists(db) and not os.path.isfile(db)):
        problems.append(f'PlayChain DB 가 일반 파일이 아님: {db}')
    elif empty and not allow_empty:
        problems.append(f'PlayChain DB 없음/비어 있음: {db} -- 이대로면 로그아웃 상태로 시작.\n'
                        f'    {restore_hint(root, db)}\n'
                        '    처음 설치라면 GAKU_ALLOW_EMPTY_CHAIN=1 로 재실행')
    for suffix in ('-journal', '-wal'):
        if os.path.exists(db + suffix):
            problems.append(f'{os.path.basename(db)}{suffix} 가 남아 있음 (비정상 종료 흔적) -- '
                            f'게임/PlayCover 가 완전히 종료됐는지 확인하고 백업({root})과 비교 후 처리')
    if problems:
        raise Refuse('실행 전에 해결할 문제' + '\n  - '.join([''] + problems))
    if empty:
        save_state(root, None, None)  # deliberate empty start: next account is not a 'change'
        print('PlayChain: DB 없음/비어 있음 -- GAKU_ALLOW_EMPTY_CHAIN=1 이므로 로그아웃 상태로 실행 허용')
        return 0

    con = ro(db)
    try:
        res = con.execute('PRAGMA integrity_check').fetchone()[0]
    except sqlite3.DatabaseError as e:
        res = f'{type(e).__name__}: {e}'
    if res != 'ok':
        raise Refuse(f'PlayChain DB 무결성 검사 실패 ({res[:80]}) -- 백업({root})에서 복원 필요')
    tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    rows = fb_rows(con) if 'genp' in tables else []
    other_dups = con.execute(
        'SELECT coalesce(sum(n - 1), 0) FROM (SELECT count(*) AS n FROM genp WHERE acct IS NOT ? '
        'GROUP BY agrp, acct, svce HAVING n > 1)', (FB_ACCT,)).fetchone()[0] if 'genp' in tables else 0
    first = None
    if rows:
        first = con.execute('SELECT rowid FROM genp WHERE acct=? AND svce=? LIMIT 1', (FB_ACCT, rows[0][1])).fetchone()[0]
    con.close()

    # --- decide (read-only): which row will be restored, and whether to dedupe first
    launch, plan, what = None, None, ''
    if not rows:
        if not allow_empty:
            raise Refuse('Firebase 로그인 항목 없음 -- 이대로면 로그아웃(새 게스트) 상태로 시작.\n'
                         f'  {restore_hint(root, db)}\n'
                         '  의도한 것이면 GAKU_ALLOW_EMPTY_CHAIN=1 로 재실행')
    else:
        hashes = sorted({r[2] for r in rows}, key=str)
        bad = [h for h in hashes if h is None or h.startswith('decode-err')]
        if bad:
            raise Refuse(f'Firebase 로그인 항목을 해석하지 못함 ({bad}) -- 수동 확인 필요: '
                         f'python3 {q(os.path.abspath(__file__))} --db {q(db)} check')
        if len({r[1] for r in rows}) != 1:
            raise Refuse('Firebase 로그인 항목의 svce 가 여러 개 -- 수동 확인 필요 (check 서브커맨드)')
        if len(rows) == 1:
            launch = rows[0]
        else:
            anon = {h: {r[5] for r in rows if r[2] == h} for h in hashes}
            real = [h for h in hashes if anon[h] == {False}]
            guests = [h for h in hashes if anon[h] == {True}]
            if len(hashes) == 1:
                keep_h, what = hashes[0], f'같은 계정(uid#{hashes[0]})의 Firebase 로그인 항목 {len(rows)}개'
            elif len(real) == 1 and len(real) + len(guests) == len(hashes):
                keep_h = real[0]
                what = (f'게스트 계정 {len(guests)}개({", ".join("uid#" + h for h in guests)}) + 로그인 계정 uid#{real[0]} 의 '
                        f'Firebase 로그인 항목 {len(rows)}개 (게스트는 버림)')
            else:
                raise mixed_refusal(a, rows, hashes, first)
            try:  # same plan + guards as `dedup`
                keep, drop, _ = dedup_plan(db, keep_h)
                held = guards(db)
                if held:
                    raise Refuse('; '.join(held))
            except Refuse as e:
                raise Refuse(f'{what} -- 자동 정리 불가: {e}\n'
                             f'  확인: python3 {q(os.path.abspath(__file__))} --db {q(db)} check')
            launch, plan = keep, (keep, drop)
        check_account_change(a, launch)

    # --- launch path: backup -> dedupe -> pin -> state
    path, sha, created = rotate_backup(db, root)
    print(f'PlayChain: 백업 {"" if created else "생략 (직전 백업과 내용 같음) "}{os.path.basename(path)} sha256#{sha} '
          f'(최근 {KEEP_BACKUPS}개 순환 + 계정별 account-<uid>.db: {root})')
    if other_dups:
        print(f'  참고: Firebase 외 항목 중복 {other_dups}행 (건드리지 않음)')
    if launch is None:
        save_state(root, None, None)
        print('PlayChain: Firebase 로그인 항목 없음 -- GAKU_ALLOW_EMPTY_CHAIN=1 이므로 로그아웃 상태로 실행 허용')
        return 0
    if plan:
        keep, drop = plan
        n, ok = dedup_apply(db, keep, drop)
        if ok != 'ok':
            raise Refuse(f'중복 정리 후 무결성 검사 실패 ({ok}) -- 백업 {path} 에서 복원 필요')
        print(f'PlayChain: {what} -> uid#{keep[2]} 의 최신 rowid {keep[0]} 만 남기고 {n}개 삭제 '
              f'(최근 로그인 {fmt(keep[3])}, 정리 전 백업 {os.path.basename(path)}, integrity={ok})')
    else:
        print(f'PlayChain: Firebase 로그인 항목 1개 OK (uid#{launch[2]} 최근 로그인 {fmt(launch[3])} '
              f'토큰 만료 {fmt(launch[4])} anonymous={launch[5]})')
    if launch[5] is False:
        pin, psha = pin_account(db, root, launch[2])
        print(f'PlayChain: 계정 백업 {os.path.basename(pin)} sha256#{psha} 갱신 (순환 삭제 안 됨)')
    save_state(root, launch[2], launch[5])
    return 0


def cmd_preflight(a):
    try:
        return preflight(a)
    except Refuse as e:
        print(f'거부: {e}')
    except Exception as e:  # anything unexpected must still stop the launch
        print(f'거부: 예기치 못한 오류 {type(e).__name__}: {e}')
    return 3


p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
p.add_argument('--chain-dir', default=DEFAULT_CHAIN, help='PlayChain folder (default: PlayCover container)')
p.add_argument('--db', help=f'DB path (default: CHAIN_DIR/{BUNDLE}.db)')
p.add_argument('--settings', default=DEFAULT_SETTINGS, help='PlayCover App Settings plist')
p.add_argument('--backup-root', default=DEFAULT_BACKUPS, help='rotating preflight backups')
p.add_argument('--playtools', default=DEFAULT_PLAYTOOLS, help='PlayTools binary to fingerprint')
sub = p.add_subparsers(dest='cmd', required=True)
c = sub.add_parser('check'); c.add_argument('--expect-uid-hash')
d = sub.add_parser('dedup'); d.add_argument('--keep-uid-hash', required=True)
d.add_argument('--apply', action='store_true'); d.add_argument('--backup-dir')
sub.add_parser('preflight')
a = p.parse_args()
a.db = a.db or os.path.join(a.chain_dir, f'{BUNDLE}.db')
a.backup_root = os.path.expanduser(a.backup_root)
sys.exit({'check': cmd_check, 'dedup': cmd_dedup, 'preflight': cmd_preflight}[a.cmd](a))
