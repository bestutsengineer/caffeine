from pathlib import Path
import tempfile, subprocess, os
src=(Path(__file__).resolve().parents[1] / 'prelogin-guard/caffeine-prelogin-guard').read_text()
with tempfile.TemporaryDirectory(prefix='caffeine-guard-test-') as tmp:
 root=Path(tmp); bin=root/'bin';bin.mkdir(); d=root/'Caffeine';d.mkdir(); prefs=root/'prefs';prefs.touch()
 script=root/'guard';script.write_text(src.replace('PATH=/usr/bin:/bin:/usr/sbin:/sbin',f'PATH={bin}:/usr/bin:/bin:/usr/sbin:/sbin').replace('/usr/libexec/PlistBuddy',str(bin/'plistbuddy')))
 stubs={
 'stat':'#!/bin/sh\nif [ "$3" = /dev/console ]; then cat "$TEST_DIR/console"; else /usr/bin/id -u; fi\n',
 'pgrep':'#!/bin/sh\ncase "$(cat "$TEST_DIR/running")" in 1) exit 0;; error) exit 2;; *) exit 1;; esac\n',
 'date':'#!/bin/sh\ncat "$TEST_DIR/now"\n',
 'sysctl':'#!/bin/sh\necho "{ sec = 123456, usec = 0 }"\n',
 'logger':'#!/bin/sh\nexit 0\n',
 'plistbuddy':'''#!/bin/sh
case "$2" in *PreferencesPath*) printf '%s' "$TEST_PREFS";; *wantAwake*) cat "$TEST_DIR/want";; *allowOnBattery*) cat "$TEST_DIR/allow";; *minBatteryPercent*) cat "$TEST_DIR/cutoff";; esac
''',
 'pmset':'''#!/bin/sh
case "$2" in batt) cat "$TEST_DIR/battery";; therm) echo 'No thermal warning';; *) echo "SleepDisabled $(cat "$TEST_DIR/flag")";; esac
''',
 'sudo':'''#!/bin/sh
if [ "$1" = -n ] && [ "$2" = -u ]; then shift 3; exec "$@"; fi
printf '%s' "$5" > "$TEST_DIR/flag"
printf '%s\\n' "$5" >> "$TEST_DIR/writes"
'''
 }
 for name,code in stubs.items(): p=bin/name;p.write_text(code);p.chmod(0o755)
 env=dict(os.environ,TEST_DIR=str(root))
 def run(want,flag,owned,*,ac=True,allow=True,pct=80,cutoff=15,console='root',running=False,now=1000,since=None,preferences=True,absent_boot='123456',expected_exit=0):
  for n,v in [('want',str(want).lower()),('flag',str(flag)),('allow',str(allow).lower()),('cutoff',str(cutoff)),('battery',"Now drawing from '%s Power'\n -InternalBattery-0 %s%%"%(('AC' if ac else 'Battery'),pct)),('writes',''),('console',console),('running','error' if running=='error' else '1' if running else '0'),('now',str(now))]: (root/n).write_text(v)
  if preferences: prefs.touch()
  else: prefs.unlink(missing_ok=True)
  absence=d/'guard-app-absent-since'
  if since is None: absence.unlink(missing_ok=True)
  else: absence.write_text(f'{absent_boot} {since}\n')
  owner=d/'sleep-override.owner'
  if owner.exists():owner.unlink()
  if owned:owner.write_text((str(owned) if isinstance(owned, int) and not isinstance(owned, bool) else '123456')+'\n')
  x=subprocess.run(['/bin/sh',str(script),'--locked',str(prefs),str(d),'',''],env=env,text=True,capture_output=True)
  assert x.returncode==expected_exit,(x.stderr,x.stdout)
  return (root/'flag').read_text(),owner.exists(),(root/'writes').read_text()
 assert run(False,1,False)==('1',False,'')
 assert run(False,1,True)==('0',False,'0\n')
 assert run(False,1,123455)==('0',False,'0\n'), 'prior boot ownership must be recoverable'
 assert run(True,1,123455)==('1',True,''), 'saved on state must remain awake after reboot'
 assert run(False,1,123457)==('1',True,''), 'future ownership record must be ignored'
 assert run(False,0,True)==('0',False,'')
 assert run(True,1,False)==('1',False,'')
 assert run(True,0,False)==('1',True,'1\n')
 assert run(True,0,False,ac=False,allow=True,pct=16)==('1',True,'1\n')
 assert run(True,0,False,ac=False,allow=True,pct=15)==('0',False,'')
 assert run(True,0,False,ac=False,allow=False,pct=80)==('0',False,'')
 assert run(True,1,True,preferences=False)==('0',False,'0\n')
 assert run(True,1,False,preferences=False)==('1',False,'')
 assert run(True,1,True,console='user',running=True,since=800)==('1',True,'')
 assert not (d/'guard-app-absent-since').exists()
 assert run(True,1,True,console='user',since=None)==('1',True,'')
 assert (d/'guard-app-absent-since').read_text().strip()=='123456 1000'
 assert run(True,1,True,console='user',since=911)==('1',True,'')
 assert run(True,1,True,console='user',since=910)==('0',False,'0\n')
 assert run(True,1,False,console='user',since=800)==('1',False,'')
 assert run(True,1,True,console='user',running='error',since=800,expected_exit=1)==('1',True,'')
 assert run(True,1,True,console='user',since=800,absent_boot='999')==('1',True,'')
 assert (d/'guard-app-absent-since').read_text().strip()=='123456 1000'
 assert run(True,1,True,console='user',since=1100)==('1',True,'')
 assert (d/'guard-app-absent-since').read_text().strip()=='123456 1000'
 # Exercise the outer root-helper path: missing preferences must still identify
 # the user from their home, drop privileges, lock, and release an owned flag.
 home=root/'home'; home.mkdir()
 guard_dir=home/'Library/Application Support/Caffeine'; guard_dir.mkdir(parents=True)
 (guard_dir/'sleep-override.owner').write_text('123456\n')
 outer_prefs=home/'Library/Preferences/local.caffeine.plist'
 env['TEST_PREFS']=str(outer_prefs)
 (root/'console').write_text('root'); (root/'flag').write_text('1'); (root/'writes').write_text('')
 result=subprocess.run(['/bin/sh',str(script)],env=env,text=True,capture_output=True)
 assert result.returncode==0,(result.stderr,result.stdout)
 assert (root/'flag').read_text()=='0' and not (guard_dir/'sleep-override.owner').exists()
 print('PASS pre-login ownership, missing preferences, crash recovery and battery checks')
