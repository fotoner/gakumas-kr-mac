#!/usr/bin/env python3
"""학원마스 PlayChain(PlayCover 키체인 SQLite) 로그인 DB 점검 / 중복 정리 / 실행 전 검사.
PlayChain 은 agrp=NULL 이라 PK 가 강제되지 않아 Firebase 가 저장할 때마다 행이 쌓이고, 조회는 가장 오래된 행을 준다.

  check [--expect-uid-hash H]        읽기 전용 보고 (exit 2 = 다음 실행 때 복원될 계정이 H 아님)
  dedup --keep-uid-hash H [--apply]  H 의 최신 행만 남김. 기본 dry-run, --apply 는 백업 후 삭제
  preflight                          make run 이 실행 직전 호출. exit 0 = 실행, 3 = 거부

옵션(서브커맨드 앞뒤 어디든, 기본값 = 실제 경로): --db --settings --backup-dir --playtools
GAKU_ALLOW_EMPTY_CHAIN=1: DB/로그인 항목이 없어도 실행 허용 (처음 설치). 토큰·uid·이메일·v_Data 는 출력 안 함.
"""
import argparse, collections, datetime as dt, hashlib, os, plistlib, re, shlex, sqlite3, subprocess, sys
from contextlib import closing
from pathlib import Path
from urllib.parse import quote

HOME = os.path.expanduser('~')
BUNDLE = 'jp.co.bandainamcoent.BNEI0421'
PC = f'{HOME}/Library/Containers/io.playcover.PlayCover'
DEFAULTS = {
    'db': f'{PC}/PlayChain/{BUNDLE}.db',
    'settings': f'{PC}/App Settings/{BUNDLE}.plist',
    'backup_dir': f'{HOME}/Library/Application Support/gakumas-kr-mac/playchain-backups',
    'playtools': f'{HOME}/Library/Frameworks/PlayTools.framework/PlayTools',
}
PLAYTOOLS_SHA8 = '548eaa72'  # PlayTools f2bfbd7 -- PlayChain 동작을 분석한 빌드
PROCS = ('idolmaster_gakuen', 'PlayCover')
KEEP_BACKUPS = 10
BACKUP_RE = re.compile(re.escape(BUNDLE) + r'\.\d{8}T\d{6}\.\d{6}\.db')
FB_ACCT = 'firebase_auth_1___FIRAPP_DEFAULT_firebase_user'
EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
SELF = shlex.quote(os.path.abspath(__file__))
Row = collections.namedtuple('Row', 'rowid svce uid last exp anon')  # uid = sha256[:8], None = 해석 불가


class Refuse(Exception):
    pass


def sha8(data):
    return hashlib.sha256(data if isinstance(data, bytes) else str(data).encode()).hexdigest()[:8]


def file_sha8(path):
    return sha8(Path(path).read_bytes()) if os.path.isfile(path) else None


def ro(path):
    return closing(sqlite3.connect(f'file:{quote(path)}?mode=ro', uri=True))


def fmt(t):
    return t.astimezone().strftime('%Y-%m-%d %H:%M') if t else '-'


def desc(r):
    return f'rowid={r.rowid} uid#{r.uid} 최근 로그인 {fmt(r.last)} 토큰 만료 {fmt(r.exp)} anonymous={r.anon}'


def uids(rows):
    return ' '.join(sorted({f'uid#{r.uid}' for r in rows})) or '-'


def decode(blob):
    """NSKeyedArchiver FIRUser -> (uid_hash, lastSignIn, tokenExp, anonymous)."""
    try:
        pl = plistlib.loads(blob)
        r = lambda x: pl['$objects'][x.data] if isinstance(x, plistlib.UID) else x
        date = lambda d: EPOCH + dt.timedelta(seconds=d['NS.time']) if isinstance(d, dict) and 'NS.time' in d else None
        user = r(next(iter(pl['$top'].values())))
        uid = r(user.get('userID'))
        meta, tok = r(user.get('metadata')) or {}, r(user.get('tokenService')) or {}
        return (sha8(uid) if isinstance(uid, str) else None, date(r(meta.get('lastSignInDate'))),
                date(r(tok.get('accessTokenExpirationDate'))), r(user.get('anonymous')))
    except Exception:  # blob 내용은 절대 출력하지 않음
        return None, None, None, None


def fb_rows(con):
    """Firebase 사용자 행, rowid 순. PlayChain 조회는 ORDER BY 없이 첫 행을 주므로 [0] 이 다음 실행 때 복원되는 행."""
    q = "SELECT rowid, svce, v_Data FROM genp WHERE acct=? AND svce LIKE 'firebase_auth_1:%' ORDER BY rowid"
    return [Row(rid, svce, *decode(v if isinstance(v, bytes) else b'')) for rid, svce, v in con.execute(q, (FB_ACCT,))]


def running():
    return [n for n in PROCS if subprocess.run(['/usr/bin/pgrep', '-x', n], capture_output=True).returncode == 0]


def guards(db, backup_dir):
    """DB 를 쓰기 전 공통 거부 조건 (읽기만 함)."""
    problems = [f'{n} 실행 중 -- 완전히 종료한 뒤 다시 실행' for n in running()]
    held = subprocess.run(['/usr/sbin/lsof', '-t', '--', db], capture_output=True, text=True).stdout.split()
    if held:
        problems.append(f'DB 를 연 프로세스 있음 (pid {" ".join(held)})')
    for suffix in ('-journal', '-wal'):
        if os.path.exists(db + suffix):
            problems.append(f'{os.path.basename(db)}{suffix} 남아 있음 (비정상 종료 흔적) -- 게임/PlayCover 완전 종료 확인')
    kc = os.path.splitext(db)[0] + '.keyCover'
    if os.path.exists(kc):
        dst = os.path.join(backup_dir, os.path.basename(kc) + dt.datetime.now().strftime('.%Y%m%d-%H%M%S'))
        state = ('오래된 스냅샷 -- PlayCover Play 버튼이 이것을 .db 위로 복호화해 로그인이 되돌아감' if os.path.exists(db) else
                 '.db 없음 = KeyCover 가 DB 를 잠근 상태 (Play 버튼/Lock all 후) -- 백업 폴더의 최신 사본을 .db 로 복원')
        problems.append(f'PlayCover KeyCover 파일 있음: {kc}\n'
                        f'    {state} (Play 버튼 쓰지 말 것).\n'
                        '    삭제하지 말고 백업 폴더로 옮긴 뒤 다시 실행:\n'
                        f'      mkdir -p -m 700 {shlex.quote(backup_dir)} && mv -n {shlex.quote(kc)} {shlex.quote(dst)}')
    return problems


def playchain_setting(path):
    try:
        v = plistlib.loads(Path(path).read_bytes()).get('playChain')
    except Exception as e:
        return False, f'읽기 실패 {type(e).__name__}'
    return v is True, f'playChain={v!r}'


def integrity(con):
    try:
        return con.execute('PRAGMA integrity_check').fetchone()[0]
    except sqlite3.DatabaseError as e:
        return str(e)[:80]


def backups(backup_dir):
    """preflight/dedup 백업 파일명, 오래된 순."""
    return sorted(n for n in os.listdir(backup_dir) if BACKUP_RE.fullmatch(n)) if os.path.isdir(backup_dir) else []


def backup(db, backup_dir):
    """읽기 전용 연결에서 sqlite backup API 로 사본(0600) + 검증, 최근 KEEP_BACKUPS 개만 유지. -> 경로."""
    os.makedirs(backup_dir, mode=0o700, exist_ok=True)
    os.chmod(backup_dir, 0o700)
    dst = os.path.join(backup_dir, f'{BUNDLE}.{dt.datetime.now().strftime("%Y%m%dT%H%M%S.%f")}.db')
    os.close(os.open(dst, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
    try:
        with ro(db) as src, closing(sqlite3.connect(dst)) as out:
            src.backup(out)
            dump = lambda c: hashlib.sha256('\n'.join(c.iterdump()).encode()).digest()  # 스키마 + 모든 행
            if integrity(out) != 'ok' or dump(out) != dump(src):
                raise Refuse(f'백업 검증 실패 -- DB 는 그대로 둠 ({backup_dir})')
    except BaseException:
        os.remove(dst)  # 실패한 사본이 정상 백업처럼 남지 않게
        raise
    for name in backups(backup_dir)[:-KEEP_BACKUPS]:
        os.remove(os.path.join(backup_dir, name))
    return dst


def plan(rows, keep_uid):
    """keep_uid 의 최신 rowid 만 남기는 계획 -> (keep, drop)."""
    if len({r.svce for r in rows}) != 1:
        raise Refuse('Firebase 로그인 항목의 svce 가 여러 개 -- 수동 확인 필요 (check)')
    mine = [r for r in rows if r.uid == keep_uid]
    if not mine:
        raise Refuse(f'uid#{keep_uid} 행 없음 (있는 것: {uids(rows)})')
    keep = mine[-1]  # rowid 최대 = Firebase 가 그 계정으로 마지막에 저장한 행
    for field in ('last', 'exp'):  # 시각이 있으면 최신 rowid 가 가장 최근 시각인지 교차 확인
        seen = [getattr(r, field) for r in mine if getattr(r, field)]
        if seen and getattr(keep, field) != max(seen):
            raise Refuse(f'uid#{keep_uid} 의 최신 rowid {keep.rowid} 가 가장 최근 로그인/토큰 시각이 아님 -- 수동 확인 필요 (check)')
    return keep, [r for r in rows if r.rowid != keep.rowid]


def apply_dedup(db, keep, drop):
    """IMMEDIATE 트랜잭션 + secure_delete 로 삭제 (VACUUM 안 함). -> integrity_check 결과."""
    with closing(sqlite3.connect(db, isolation_level=None)) as con:
        con.execute('PRAGMA secure_delete=ON')  # 지운 토큰 페이지를 0으로 덮음
        con.execute('BEGIN IMMEDIATE')
        n = con.execute('DELETE FROM genp WHERE acct=? AND svce=? AND rowid<>?', (FB_ACCT, keep.svce, keep.rowid)).rowcount
        left = con.execute('SELECT count(*), max(rowid) FROM genp WHERE acct=? AND svce=?', (FB_ACCT, keep.svce)).fetchone()
        if n != len(drop) or left != (1, keep.rowid):
            con.execute('ROLLBACK')
            raise Refuse(f'삭제 행 수가 예상과 다름 ({n}/{len(drop)}) -- 되돌림')
        con.execute('COMMIT')
        return integrity(con)


def cmd_check(a):
    ok, setting = playchain_setting(a.settings)
    kc, pt = os.path.exists(os.path.splitext(a.db)[0] + '.keyCover'), file_sha8(a.playtools)
    print(f'keyCover {"있음 (!)" if kc else "없음"}  {setting}{"" if ok else " (!)"}  '
          f'PlayTools sha256#{pt}{"" if pt == PLAYTOOLS_SHA8 else " (!= 검증 빌드 " + PLAYTOOLS_SHA8 + ")"}')
    if not os.path.isfile(a.db) or os.path.getsize(a.db) == 0:
        print(f'DB 없음/비어 있음: {a.db}')
        return 1
    with ro(a.db) as con:
        print(f'DB size={os.path.getsize(a.db)} integrity={integrity(con)}')
        for acct, n, lo, hi in con.execute('SELECT acct, count(*), min(rowid), max(rowid) FROM genp GROUP BY acct, svce ORDER BY 3'):
            label = acct if acct in (FB_ACCT, 'adjust_uuid', '_pfo') else 'acct#' + sha8(acct or '')
            print(f'  {label:<48} {n:>3}행  rowid {lo}..{hi}')
        rows = fb_rows(con)
    if not rows:
        print('Firebase 로그인 항목 없음 -> 로그아웃 상태로 시작')
        return 1
    restored = rows[0]
    print(f'  다음 실행 때 복원: {desc(restored)}')
    print(f'  최신 행          : {desc(rows[-1])}')
    print(f'  Firebase {len(rows)}행, {uids(rows)}')
    if a.expect_uid_hash:
        match = restored.uid == a.expect_uid_hash
        print(f'결과: {"OK" if match else "불일치"} (복원 uid#{restored.uid}, 기대 uid#{a.expect_uid_hash})')
        return 0 if match else 2
    return 0


def cmd_dedup(a):
    problems = guards(a.db, a.backup_dir) or ([] if os.path.isfile(a.db) else [f'DB 없음: {a.db}'])
    if problems:
        raise Refuse('\n  - ' + '\n  - '.join(problems))
    with ro(a.db) as con:
        keep, drop = plan(fb_rows(con), a.keep_uid_hash)
    print(f'남김: {desc(keep)}')
    print(f'삭제: Firebase {len(drop)}행 ({uids(drop)}), 다른 항목은 그대로')
    if not a.apply:
        print('dry-run -- 실제 삭제는 --apply')
        return 0
    path = backup(a.db, a.backup_dir)
    print(f'백업: {path} sha256#{file_sha8(path)}')
    ok = apply_dedup(a.db, keep, drop)
    print(f'완료: Firebase 1행 남음 (rowid {keep.rowid}), integrity={ok}')
    return 0 if ok == 'ok' else 4


def mixed(a, rows):
    lines = ['서로 다른 계정의 Firebase 로그인 항목이 섞여 있음 -- PlayChain 은 가장 오래된 행을 복원하므로 어느 계정으로 시작할지 모름.',
             '  남길 계정을 골라 정리한 뒤 다시 실행 (삭제 전 백업됨):']
    for h in sorted({r.uid for r in rows}):
        mine = [r for r in rows if r.uid == h]
        last = max((r.last for r in mine if r.last), default=None)
        tag = f'  <- 다음 실행 때 복원 (rowid {rows[0].rowid})' if mine[0] is rows[0] else ''
        lines += [f'    uid#{h}  {len(mine)}행  rowid {mine[0].rowid}..{mine[-1].rowid}  최근 로그인 {fmt(last)}  '
                  f'anonymous={mine[-1].anon}{tag}',
                  f'      python3 {SELF} --db {shlex.quote(a.db)} dedup --keep-uid-hash {h} --apply '
                  f'--backup-dir {shlex.quote(a.backup_dir)}']
    return '\n'.join(lines)


def cmd_preflight(a):
    """거부 조건을 모두 먼저 검사(쓰기 없음) -> 통과 시 백업 -> 같은 계정 중복이면 최신 행만 남김."""
    db, allow_empty = a.db, os.environ.get('GAKU_ALLOW_EMPTY_CHAIN') == '1'
    pt = file_sha8(a.playtools)
    if pt != PLAYTOOLS_SHA8:
        print(f'경고: PlayTools sha256#{pt} 가 검증 빌드({PLAYTOOLS_SHA8})와 다름 -- PlayChain 동작이 바뀌었을 수 있음 '
              '(tools/login-persistence-poc/build-and-test.py 로 재검증 권장)')
    problems = guards(db, a.backup_dir)
    ok, setting = playchain_setting(a.settings)
    if not ok:
        problems.append(f'PlayCover 앱 설정 playChain 이 true 가 아님 ({setting}: {a.settings}) -- 켜야 로그인이 저장됨')
    empty = not os.path.isfile(db) or os.path.getsize(db) == 0
    if empty and not allow_empty:
        last = backups(a.backup_dir)
        fix = f'마지막 백업 복원: cp {shlex.quote(os.path.join(a.backup_dir, last[-1]))} {shlex.quote(db)}\n    ' if last else ''
        problems.append(f'PlayChain DB 없음/비어 있음: {db} -- 이대로면 로그아웃(새 게스트) 상태로 시작\n'
                        f'    {fix}처음 설치면 GAKU_ALLOW_EMPTY_CHAIN=1 make run')
    if problems:
        raise Refuse('실행 전에 해결할 문제\n  - ' + '\n  - '.join(problems))
    if empty:
        print('PlayChain: DB 없음 -- GAKU_ALLOW_EMPTY_CHAIN=1 이므로 로그아웃 상태로 실행')
        return 0
    with ro(db) as con:
        res = integrity(con)
        if res != 'ok':
            raise Refuse(f'PlayChain DB 무결성 검사 실패 ({res}) -- 백업 폴더에서 복원 필요: {a.backup_dir}')
        rows = fb_rows(con)
    if not rows and not allow_empty:
        raise Refuse('Firebase 로그인 항목 없음 -- 이대로면 로그아웃(새 게스트) 상태로 시작 (의도한 것이면 GAKU_ALLOW_EMPTY_CHAIN=1 make run)')
    if any(r.uid is None for r in rows):
        raise Refuse(f'Firebase 로그인 항목을 해석하지 못함 -- 확인: python3 {SELF} --db {shlex.quote(db)} check')
    if len({r.uid for r in rows}) > 1:
        raise Refuse(mixed(a, rows))
    keep, drop = plan(rows, rows[0].uid) if rows else (None, [])

    path = backup(db, a.backup_dir)  # 어떤 변경보다 먼저
    print(f'PlayChain: 백업 {os.path.basename(path)} sha256#{file_sha8(path)} (최근 {KEEP_BACKUPS}개 유지: {a.backup_dir})')
    if drop:
        ok = apply_dedup(db, keep, drop)
        if ok != 'ok':
            raise Refuse(f'중복 정리 후 무결성 검사 실패 ({ok}) -- 백업에서 복원 필요: {path}')
        print(f'PlayChain: 같은 계정의 Firebase {len(rows)}행 -> 최신 rowid {keep.rowid} 만 남기고 {len(drop)}행 삭제')
    print(f'PlayChain: 로그인 항목 OK -- {desc(keep)}' if keep else
          'PlayChain: Firebase 로그인 항목 없음 -- GAKU_ALLOW_EMPTY_CHAIN=1 이므로 로그아웃 상태로 실행')
    return 0


def parse(argv=None):
    opts = argparse.ArgumentParser(add_help=False, argument_default=argparse.SUPPRESS)
    for key in DEFAULTS:
        opts.add_argument('--' + key.replace('_', '-'))
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter, parents=[opts])
    sub = p.add_subparsers(dest='cmd', required=True)
    sub.add_parser('check', parents=[opts]).add_argument('--expect-uid-hash')
    d = sub.add_parser('dedup', parents=[opts])
    d.add_argument('--keep-uid-hash', required=True)
    d.add_argument('--apply', action='store_true')
    sub.add_parser('preflight', parents=[opts])
    a = p.parse_args(argv)
    for key, default in DEFAULTS.items():
        setattr(a, key, os.path.expanduser(getattr(a, key, default)))
    return a


def main(argv=None):
    a = parse(argv)
    try:
        return {'check': cmd_check, 'dedup': cmd_dedup, 'preflight': cmd_preflight}[a.cmd](a)
    except Refuse as e:
        print(f'거부: {e}')
    except Exception as e:  # 예기치 못한 오류도 실행/삭제를 멈춤
        print(f'거부: 예기치 못한 오류 {type(e).__name__}: {e}')
    return 3


if __name__ == '__main__':
    sys.exit(main())
