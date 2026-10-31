from pathlib import Path
import os, subprocess, tempfile

source = (Path(__file__).resolve().parents[1] / 'prelogin-guard/caffeine-scheduled-restart').read_text()
with tempfile.TemporaryDirectory(prefix='caffeine-restart-test-') as tmp:
    root = Path(tmp); binaries = root / 'bin'; binaries.mkdir()
    state = root / 'state'
    home = root / 'home'; preferences = home / 'Library/Preferences/local.caffeine.plist'
    preferences.parent.mkdir(parents=True); preferences.touch()
    config = root / 'restart.plist'; config.touch()
    source = (source.replace('PATH=/usr/bin:/bin:/usr/sbin:/sbin', f'PATH={binaries}:/usr/bin:/bin:/usr/sbin:/sbin')
              .replace('/Library/Preferences/local.caffeine.restart.plist', str(config))
              .replace('/var/db/local.caffeine', str(state))
              .replace('/usr/libexec/PlistBuddy', str(binaries / 'plistbuddy'))
              .replace('/sbin/shutdown', str(binaries / 'shutdown')))
    script = root / 'daemon'; script.write_text(source)
    stubs = {
      'id': '#!/bin/sh\ncase "$1" in -u) echo 0;; -nu) echo testuser;; esac\n',
      'stat': '#!/bin/sh\necho 501\n',
      'logger': '#!/bin/sh\nexit 0\n',
      'sysctl': '#!/bin/sh\necho "{ sec = $(cat "$TEST_DIR/boot"), usec = 0 }"\n',
      'date': '''#!/bin/sh
case "$1" in
  +%s) cat "$TEST_DIR/now";;
  +%Y-%m-%d) echo 2026-10-30;;
  +%H) echo 05;;
  +%M) echo 00;;
  -j) echo 100000;;
  -v+1d) echo 2026-10-31;;
  -r) echo '10/31/26 05:00:00';;
esac
''',
      'plistbuddy': '''#!/bin/sh
case "$2" in
 'Print :PreferencesPath') printf '%s' "$TEST_PREFS";;
 'Print :Enabled') cat "$TEST_DIR/enabled";;
 'Print :Hour') echo 5;;
 'Print :Minute') echo 0;;
 'Print :EnabledAt') cat "$TEST_DIR/enabled_at";;
 'Print :thermalStopPending') cat "$TEST_DIR/thermal";;
 *) exit 1;;
esac
''',
      'sudo': '#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_DIR/preference_writes"\nexit 0\n',
      'pmset': '#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_DIR/power_calls"\nexit 0\n',
      'shutdown': '#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_DIR/shutdowns"\nexit 0\n',
    }
    for name, body in stubs.items():
        path = binaries / name; path.write_text(body); path.chmod(0o755)
    env = dict(os.environ, TEST_DIR=str(root), TEST_PREFS=str(preferences))
    for key, value in [('boot','100'), ('now','100000'), ('enabled','true'), ('enabled_at','99900'), ('thermal','false'), ('preference_writes',''), ('power_calls',''), ('shutdowns','')]:
        (root / key).write_text(value)
    def run():
        result = subprocess.run(['/bin/sh', str(script), '--locked'], env=env, text=True, capture_output=True)
        assert result.returncode == 0, (result.stdout, result.stderr)
    run()
    assert (root/'shutdowns').read_text() == '-r now\n'
    assert (state/'restart-pending').read_text().strip() == '100'
    assert 'schedule wake ' in (root/'power_calls').read_text()
    run()
    assert (root/'shutdowns').read_text() == '-r now\n', 'must not restart twice in a day'
    (root/'boot').write_text('101')
    run()
    assert (root/'preference_writes').read_text() == '', 'restart must preserve saved Caffeine state'
    assert not (state/'restart-pending').exists()
    (state/'restart-pending').write_text('100\n'); (root/'thermal').write_text('true'); (root/'preference_writes').write_text('')
    run()
    assert (root/'preference_writes').read_text() == '' and not (state/'restart-pending').exists(), 'thermal safety must not be bypassed'
    (root/'enabled').write_text('false')
    run()
    assert 'schedule cancel wake ' in (root/'power_calls').read_text()
    assert (root/'shutdowns').read_text() == '-r now\n'
    (root/'enabled').write_text('true'); (root/'enabled_at').write_text('99999')
    (state/'last-restart-date').unlink(missing_ok=True)
    run()
    assert (root/'shutdowns').read_text() == '-r now\n', 'saving a schedule must not cause an immediate reboot'
    print('PASS forced restart timing, one-per-day, wake ownership and preserved Caffeine state')
