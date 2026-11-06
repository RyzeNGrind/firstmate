import os, pathlib, subprocess, time, json, signal
R=pathlib.Path.cwd(); V=R/'.validation'; E=pathlib.Path('/home/ryzengrind/.no-mistakes/evidence/01M6QR5909YJ3WYB48FAM10J1M'); H=V/'live-watcher-home'
for d in ['state','data','config','projects/task']: (H/d).mkdir(parents=True,exist_ok=True)
(H/'AGENTS.md').write_text('# Disposable home\n'); (H/'.fm-secondmate-home').write_text('watcher\n')
(H/'data/backlog.md').write_text('## In flight\n- [ ] live-watch - Preserve publication single flight (repo: firstmate) (kind: ship)\n\n## Queued\n\n## Done\n')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_','HERDR_','TMUX'))}
env.update(FM_HOME=str(H),FM_ROOT_OVERRIDE=str(V/'product'),FM_BACKEND='tmux',TMPDIR=str(V/'tmp'),FM_POLL='1',FM_HOME_SUMMARY_INTERVAL='999999',FM_HOME_SUMMARY_TIMEOUT='2',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='9999999',FM_HEARTBEAT='9999999')
sock=R/'.tv'; tmux=['tmux','-S',str(sock)]
procs=[]; files=[]; results={}
def run(a,**kw): return subprocess.run([str(x) for x in a],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True,**kw)
def wait_for(fn,seconds=20):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  if fn():return
  time.sleep(.1)
 raise AssertionError('timed out')
try:
 run([*tmux,'-f','/dev/null','new-session','-d','-s','fm-context-validation','-x','120','-y','40','exec bash --noprofile --norc'])
 env['TMUX']=run([*tmux,'display-message','-p','#{socket_path},#{pid},0']).stdout.decode().strip()
 (H/'state/live-watch.meta').write_text(f'backend=tmux\nwindow=fm-context-validation:0\nworktree={H}/projects/task\nproject=firstmate\nharness=claude\nkind=ship\nmode=ship\nspawn_gen=fm.livewatch123456\n')
 gen=run([R/'bin/fm-busy-event.sh','arm',H/'state','live-watch']).stdout.decode().strip()
 run([R/'bin/fm-busy-event.sh','apply',H/'state','live-watch','idle','--gen',gen,'--source','claude-hook','--event','stop'])
 status=H/'state/live-watch.status';status.write_text('working: ready\n')
 run(['bash','-c','. "$1/bin/fm-wake-lib.sh"; fm_wake_status_mark_current "$2/state" "$2/state/live-watch.status"','_',str(R),str(H)])
 initial=json.loads(run([R/'bin/fm-fleet-snapshot.sh','--secondmate-home-summary']).stdout)
 (E/'live-watcher-initial.json').write_text(json.dumps(initial,indent=2)+'\n'); assert initial['valid']
 marker=V/'live-publication-locked'
 holder=subprocess.Popen(['bash','-c','. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"; touch "$3"; sleep 90','_',str(R),str(H),str(marker)],env=env,start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);procs.append(holder)
 wait_for(marker.exists)
 def watcher(name):
  out=open(E/(name+'.out'),'wb');err=open(E/(name+'.err'),'wb');files.extend([out,err])
  p=subprocess.Popen([str(R/'bin/fm-watch.sh')],env=env,stdout=out,stderr=err,start_new_session=True);procs.append(p);return p
 first=watcher('live-watcher-first'); beat=H/'state/.last-watcher-beat';wait_for(beat.exists)
 with status.open('a') as f:f.write('needs-decision [key=live-publication]: Preserve this decision through restart\n')
 first.wait(timeout=30); assert b'signal:' in (E/'live-watcher-first.out').read_bytes();assert holder.poll() is None
 beat.unlink(missing_ok=True)
 second=watcher('live-watcher-restarted');wait_for(beat.exists);time.sleep(4)
 assert not (H/'state/.home-summary-refresh.log').exists() or not (H/'state/.home-summary-refresh.log').read_bytes()
 assert holder.poll() is None
 os.killpg(holder.pid,signal.SIGTERM);holder.wait(timeout=5)
 run([R/'bin/fm-home-summary-refresh.sh'],timeout=60)
 summary=json.loads((H/'state/home-summary.json').read_bytes());assert summary['valid']
 (E/'live-watcher-final.json').write_text(json.dumps(summary,indent=2)+'\n')
 results.update(first_exit=first.returncode,signal_surfaced_while_publication_lock_held=True,restarted_publication_error_bytes=0,final_summary_valid=True,terminal_grid={'rows':40,'cols':120})
finally:
 for p in procs:
  if p.poll() is None:
   try:os.killpg(p.pid,signal.SIGTERM)
   except ProcessLookupError:pass
   try:p.wait(timeout=8)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
 for f in files:f.close()
 subprocess.run([*tmux,'kill-server'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 if sock.exists():sock.unlink()
(E/'live-watcher-results.json').write_text(json.dumps(results,indent=2)+'\n')
print('Real tmux endpoint and Firstmate watcher surfaced a decision, restarted under the publication lock, and published valid JSON after lock release; all processes removed.')
