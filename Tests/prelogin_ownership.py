from pathlib import Path
import tempfile, subprocess, os
src=(Path(__file__).resolve().parents[1] / 'prelogin-guard/caffeine-prelogin-guard').read_text()
with tempfile.TemporaryDirectory(prefix='caffeine-guard-test-') as tmp:
 root=Path(tmp); bin=root/'bin';bin.mkdir(); d=root/'Caffeine';d.mkdir(); prefs=root/'prefs';prefs.touch()
 script=root/'guard';script.write_text(src.replace('PATH=/usr/bin:/bin:/usr/sbin:/sbin',f'PATH={bin}:/usr/bin:/bin:/usr/sbin:/sbin').replace('/usr/libexec/PlistBuddy',str(bin/'plistbuddy')))
 stubs={
 'stat':'#!/bin/sh\necho root\n',
 'sysctl':'#!/bin/sh\necho "{ sec = 123456, usec = 0 }"\n',
 'logger':'#!/bin/sh\nexit 0\n',
 'plistbuddy':'''#!/bin/sh
case "$2" in *wantAwake*) cat "$TEST_DIR/want";; *allowOnBattery*) cat "$TEST_DIR/allow";; *minBatteryPercent*) cat "$TEST_DIR/cutoff";; esac
''',
 'pmset':'''#!/bin/sh
case "$2" in batt) cat "$TEST_DIR/battery";; therm) echo 'No thermal warning';; *) echo "SleepDisabled $(cat "$TEST_DIR/flag")";; esac
''',
 'sudo':'''#!/bin/sh
printf '%s' "$5" > "$TEST_DIR/flag"
printf '%s\\n' "$5" >> "$TEST_DIR/writes"
'''
 }
 for name,code in stubs.items(): p=bin/name;p.write_text(code);p.chmod(0o755)
 env=dict(os.environ,TEST_DIR=str(root))
 def run(want,flag,owned,*,ac=True,allow=True,pct=80,cutoff=15):
  for n,v in [('want',str(want).lower()),('flag',str(flag)),('allow',str(allow).lower()),('cutoff',str(cutoff)),('battery',"Now drawing from '%s Power'\n -InternalBattery-0 %s%%"%(('AC' if ac else 'Battery'),pct)),('writes','')]: (root/n).write_text(v)
  owner=d/'sleep-override.owner'
  if owner.exists():owner.unlink()
  if owned:owner.write_text('123456\n')
  x=subprocess.run(['/bin/sh',str(script),'--locked',str(prefs),str(d),'',''],env=env,text=True,capture_output=True)
  assert x.returncode==0,(x.stderr,x.stdout)
  return (root/'flag').read_text(),owner.exists(),(root/'writes').read_text()
 assert run(False,1,False)==('1',False,'')
 assert run(False,1,True)==('0',False,'0\n')
 assert run(False,0,True)==('0',False,'')
 assert run(True,1,False)==('1',False,'')
 assert run(True,0,False)==('1',True,'1\n')
 assert run(True,0,False,ac=False,allow=True,pct=16)==('1',True,'1\n')
 assert run(True,0,False,ac=False,allow=True,pct=15)==('0',False,'')
 assert run(True,0,False,ac=False,allow=False,pct=80)==('0',False,'')
 print('PASS pre-login ownership, battery preference and cutoff integration checks')
