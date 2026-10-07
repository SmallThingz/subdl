#!/usr/bin/env python3
"""Native POSIX terminal integration test. Uses only its own PTY child and cache."""
from pathlib import Path
import os,pty,fcntl,termios,struct,select,time,json,signal,sys,hashlib,tempfile,re
if len(sys.argv) < 2 or len(sys.argv) > 3:
 raise SystemExit('usage: test_tui_pty.py BINARY [normal|burst]')
name=sys.argv[2] if len(sys.argv)>2 else 'normal'
if name not in ('normal','burst'):
 raise SystemExit('mode must be normal or burst')
Path('.tmp').mkdir(exist_ok=True)
temporary=tempfile.TemporaryDirectory(prefix='scrapers-pty-',dir='.tmp')
lane=Path(temporary.name)
binary=Path(sys.argv[1]).resolve()
cache=lane/(name+'-cache');home=lane/(name+'-home');downloads=cache/'subdl/cache/downloads'
downloads.mkdir(parents=True,exist_ok=True)
home.mkdir()
for i in range(2000):
 path=downloads/f'fixture-{i:04d}.srt'
 if not path.exists():path.write_text('1\n00:00:00,000 --> 00:00:01,000\nSynthetic test\n')
master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',32,120,0,0));before=termios.tcgetattr(slave)
fcntl.fcntl(master,fcntl.F_SETFL,fcntl.fcntl(master,fcntl.F_GETFL)|os.O_NONBLOCK)
pid=os.fork()
if pid==0:
 os.setsid();fcntl.ioctl(slave,termios.TIOCSCTTY,0)
 for fd in (0,1,2):os.dup2(slave,fd)
 os.close(master)
 env=dict(os.environ,TERM='xterm-256color',XDG_CACHE_HOME=str(cache.resolve()),HOME=str(home.resolve()))
 os.execve(str(binary),[str(binary),'--tui'],env)
output=bytearray()
max_output_bytes=32*1024*1024
csi_pattern=re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]')
def require(condition,message):
 if not condition:raise AssertionError(message)
def visible_output(data):
 return csi_pattern.sub(b'',data)
def write_pty(data,timeout=3):
 pending=memoryview(data);end=time.monotonic()+timeout
 while pending:
  remaining=end-time.monotonic()
  if remaining<=0:raise RuntimeError('Timed out writing PTY input')
  _,writable,_=select.select([],[master],[],remaining)
  if not writable:raise RuntimeError('Timed out writing PTY input')
  try:written=os.write(master,pending)
  except BlockingIOError:continue
  if written<=0:raise RuntimeError('PTY input stream closed')
  pending=pending[written:]
query_tail=b''
def answer_terminal_queries(data):
 global query_tail
 combined=query_tail+data
 for query,response in ((b'\x1b[6n',b'\x1b[1;1R'),(b'\x1b[5n',b'\x1b[0n')):
  for _ in range(combined.count(query)):write_pty(response)
 query_tail=combined[-3:]
def read_for(seconds,stop_when=None):
 end=time.monotonic()+seconds;received=bytearray()
 while time.monotonic()<end:
  ready,_,_=select.select([master],[],[],min(.05,max(0,end-time.monotonic())))
  if ready:
   try:data=os.read(master,65536)
   except BlockingIOError:continue
   except OSError:break
   if not data:break
   received.extend(data);output.extend(data)
   if len(output)>max_output_bytes:raise RuntimeError('TUI output exceeded fixture limit')
   answer_terminal_queries(data)
   if stop_when is not None and stop_when(received):break
 return bytes(received)
def terminate_child():
 try:os.kill(pid,signal.SIGTERM)
 except ProcessLookupError:pass
 end=time.monotonic()+1
 while time.monotonic()<end:
  try:got,observed=os.waitpid(pid,os.WNOHANG)
  except ChildProcessError:return None
  if got:return observed
  time.sleep(.02)
 try:os.kill(pid,signal.SIGKILL)
 except ProcessLookupError:pass
 try:return os.waitpid(pid,0)[1]
 except ChildProcessError:return None
status=None
try:
 read_for(3)
 require(b'\x1b[?1049h' in output,'TUI did not enter the alternate screen during startup')
 require(b'\x1b[?2004h' in output,'TUI did not enable bracketed-paste mode during startup')
 active=termios.tcgetattr(slave)
 require((active[3]&termios.ECHO)==0,'TUI left terminal echo enabled while active')
 require((active[3]&termios.ICANON)==0,'TUI left canonical input enabled while active')
 require(b'SEARCH' in visible_output(output),'TUI did not render the initial search view')
 (lane/(name+'-startup.raw')).write_bytes(output)
 samples=[]
 for tab_index in range(12):
  expected_view=b'DOWNLOADS' if tab_index%2==0 else b'SEARCH'
  start=time.monotonic();write_pty(b'\t')
  data=read_for(3,lambda value,marker=expected_view,need_fixture=tab_index==0:
                marker in visible_output(value) and (not need_fixture or b'fixture-' in visible_output(value)))
  require(expected_view in visible_output(data),f'Tab did not enter expected {expected_view.decode()} view')
  if tab_index==0:require(b'fixture-' in visible_output(data),'Downloads view did not render cached fixtures')
  samples.append(time.monotonic()-start)
  read_for(.05)
 fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',16,50,0,0));os.kill(pid,signal.SIGWINCH)
 resized=read_for(2)
 positions=[(int(row),int(col)) for row,col in re.findall(rb'\x1b\[(\d+);(\d+)H',resized)]
 require(positions and all(1<=row<=16 and 1<=col<=50 for row,col in positions),'Resize did not render within the new terminal dimensions')
 write_pty(b'\x1b[200~fixture\nquery\x1b[201~')
 pasted=read_for(2,lambda value:b'fixture query' in visible_output(value))
 visible=visible_output(pasted)
 require(b'fixture query' in visible,'Bracketed paste did not render the normalized query')
 write_pty(b'\x04' + (b'x' * 4096 if name=='burst' else b''))
 end=time.monotonic()+5
 while time.monotonic()<end:
  read_for(.1)
  got,observed=os.waitpid(pid,os.WNOHANG)
  if got:
   status=observed
   break
 else:raise RuntimeError('TUI did not exit')
 after=termios.tcgetattr(slave)
 require(os.WIFEXITED(status) and os.WEXITSTATUS(status)==0,f'TUI exited with wait status {status}')
 require(before==after,'Terminal flags not restored')
 paste_transitions=re.findall(rb'\x1b\[\?2004[hl]',output)
 require(paste_transitions and paste_transitions[-1]==b'\x1b[?2004l','Bracketed-paste mode not restored')
 screen_transitions=re.findall(rb'\x1b\[\?1049[hl]',output)
 require(screen_transitions and screen_transitions[-1]==b'\x1b[?1049l','Alternate screen not restored')
 report=dict(status='passed',binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),cache_files=2000,tab_first_output_seconds=samples,terminal_restored=True,resize_verified=True,paste_verified=True,timing_policy='dirty-host first-output diagnostic; not full-frame performance qualification')
 (lane/(name+'-report.json')).write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps(report))
finally:
 if status is None:
  terminate_child()
 os.close(master);os.close(slave)
 (lane/(name+'-all.raw')).write_bytes(output)

 temporary.cleanup()
