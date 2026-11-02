"""Real local PTY fragmentation regression for the current terminal's one-reader adapter."""
import os,pty,tty,subprocess,time,select,json,sys,pathlib
root=pathlib.Path(__file__).resolve().parents[1]
julia=sys.argv[1];evidence=pathlib.Path(sys.argv[2]);evidence.mkdir(parents=True,exist_ok=True)
master,slave=pty.openpty();tty.setraw(slave)
result=evidence/'pty-result.json'
env=os.environ.copy();env.update(JULIA_NUM_THREADS='2',TACHIKOMA_GFX='none',TERM='xterm-256color')
proc=subprocess.Popen([julia,'--project='+str(root/'test'),str(root/'test/theme_input_pty_probe.jl'),str(result)],stdin=slave,stdout=slave,stderr=slave,env=env,cwd=root);os.close(slave)
raw=bytearray();deadline=time.monotonic()+30
while b'\x1b]10;?\x07' not in raw and proc.poll() is None and time.monotonic()<deadline:
    if select.select([master],[],[],.1)[0]:
        try:raw.extend(os.read(master,65536))
        except OSError:break
assert b'\x1b]10;?\x07' in raw,raw[-2000:]
# Header completes promptly; color bodies and ST deliberately exceed the parser's old 50ms timeout.
fragments=[(b'a',.01),(b'\x1b',.003),(b']10;rgb:',.15),(b'eeee/eeee/eeee\x07',.01),(b'\x1b]11;',.15),(b'#112233\x1b',.15),(b'\\\x1b[?1;',.01),(b'2c',.01),(b'\x1b[<0;',.02),(b'12;8M',.02),(b'\x1b[A',.02),(b'z',.15),(b'q',.01)]
for data,delay in fragments:os.write(master,data);time.sleep(delay)
while proc.poll() is None and time.monotonic()<deadline:
    if select.select([master],[],[],.05)[0]:
        try:raw.extend(os.read(master,65536))
        except OSError:break
if proc.poll() is None:proc.terminate();proc.wait(timeout=5)
while select.select([master],[],[],0)[0]:
    try:raw.extend(os.read(master,65536))
    except OSError:break
os.close(master);(evidence/'pty-terminal-output.bin').write_bytes(raw)
assert proc.returncode==0,(proc.returncode,raw[-3000:]);value=json.loads(result.read_text())
assert value['attached'] and value['restored'] and value['inputClosed'] and value['upstreamOpen'] and value['lifecycleClosed'] and value['watcherClosed'],value
assert value['pendingQueries']==0 and value['background']==[17,34,51],value
assert [e['raw'] for e in value['events']]==['a','\x1b[<0;12;8M','\x1b[A','z','q'],value
assert b'\x1b[?2031l' in raw,'Scheme notifications not disabled'
print(json.dumps({'pty':'passed','readers':'one shared adapter; framework owns source','fragmentDelaysMs':[round(d*1000) for _,d in fragments],'result':value},indent=2))
