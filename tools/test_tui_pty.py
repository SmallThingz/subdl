#!/usr/bin/env python3
"""Native POSIX terminal integration test. Uses only its own PTY child and cache."""
from pathlib import Path
import os,pty,fcntl,termios,struct,select,time,json,signal,sys,hashlib,tempfile,re
if len(sys.argv) < 2:
 raise SystemExit('usage: test_tui_pty.py BINARY [normal|burst]')
Path('.tmp').mkdir(exist_ok=True)
temporary=tempfile.TemporaryDirectory(prefix='scrapers-pty-',dir='.tmp')
lane=Path(temporary.name)
name=sys.argv[2] if len(sys.argv)>2 else 'normal'
binary=Path(sys.argv[1]).resolve()
cache=lane/(name+'-cache');downloads=cache/'subdl/cache/downloads'
downloads.mkdir(parents=True,exist_ok=True)
for i in range(2000):
 path=downloads/f'fixture-{i:04d}.srt'
 if not path.exists():path.write_text('1\n00:00:00,000 --> 00:00:01,000\nSynthetic test\n')
master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',32,120,0,0));before=termios.tcgetattr(slave)
pid=os.fork()
if pid==0:
 os.setsid();fcntl.ioctl(slave,termios.TIOCSCTTY,0)
 for fd in (0,1,2):os.dup2(slave,fd)
 os.close(master)
 env=dict(os.environ,TERM='xterm-256color',XDG_CACHE_HOME=str(cache.resolve()),HOME=str((lane/(name+'-home')).resolve()))
 os.execve(str(binary),[str(binary),'--tui'],env)
output=bytearray()
def read_for(seconds):
 end=time.monotonic()+seconds;received=bytearray()
 while time.monotonic()<end:
  ready,_,_=select.select([master],[],[],min(.05,max(0,end-time.monotonic())))
  if ready:
   try:data=os.read(master,65536)
   except OSError:break
   if not data:break
   received.extend(data);output.extend(data)
   if b'\x1b[6n' in data:os.write(master,b'\x1b[1;1R')
   if b'\x1b[5n' in data:os.write(master,b'\x1b[0n')
 return bytes(received)
status=None
try:
 read_for(3)
 (lane/(name+'-startup.raw')).write_bytes(output)
 samples=[]
 for _ in range(12):
  start=time.monotonic();os.write(master,b'\t')
  ready,_,_=select.select([master],[],[],3)
  if not ready:raise RuntimeError('No navigation response')
  data=os.read(master,65536);output.extend(data);samples.append(time.monotonic()-start)
  read_for(.05)
 fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',16,50,0,0));os.kill(pid,signal.SIGWINCH)
 resized=read_for(.3)
 positions=[(int(row),int(col)) for row,col in re.findall(rb'\x1b\[(\d+);(\d+)H',resized)]
 assert positions and all(1<=row<=16 and 1<=col<=50 for row,col in positions),'Resize did not render within the new terminal dimensions'
 os.write(master,b'\x1b[200~fixture\nquery\x1b[201~')
 pasted=read_for(.2)
 visible=re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]',b'',pasted)
 assert b'fixture query' in visible,'Bracketed paste did not render the normalized query'
 os.write(master,b'\x04' + (b'x' * 4096 if name.endswith('burst') else b''))
 end=time.monotonic()+5
 while time.monotonic()<end:
  read_for(.1)
  got,observed=os.waitpid(pid,os.WNOHANG)
  if got:
   status=observed
   break
 else:raise RuntimeError('TUI did not exit')
 after=termios.tcgetattr(slave)
 assert os.waitstatus_to_exitcode(status)==0,status
 assert before==after,'Terminal flags not restored'
 assert b'\x1b[?1049l' in output,'Alternate screen not restored'
 report=dict(status='passed',binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),cache_files=2000,tab_first_output_seconds=samples,terminal_restored=True,resize_verified=True,paste_verified=True,timing_policy='dirty-host first-output diagnostic; not full-frame performance qualification')
 (lane/(name+'-report.json')).write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps(report))
finally:
 if status is None:
  try:os.kill(pid,signal.SIGTERM);os.waitpid(pid,0)
  except ProcessLookupError:pass
 os.close(master);os.close(slave)
 (lane/(name+'-all.raw')).write_bytes(output)

 temporary.cleanup()
