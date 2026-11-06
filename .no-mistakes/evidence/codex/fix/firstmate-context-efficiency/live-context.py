import os, subprocess, pathlib, json, hashlib, time
R=pathlib.Path.cwd(); V=R/'.validation'; E=pathlib.Path('/home/ryzengrind/.no-mistakes/evidence/01M6QR5909YJ3WYB48FAM10J1M')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_','HERDR_'))}
env.update(TMPDIR=str(V/'tmp'), FM_BACKEND='tmux')
log=[]
def run(args,home=None,name=None,extra=None,ok=True,seconds=150):
 e=env.copy()
 if home:e['FM_HOME']=str(home)
 if extra:e.update(extra)
 t=time.monotonic(); p=subprocess.run([str(x) for x in args],cwd=R,env=e,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=seconds)
 log.append({'command':[str(x) for x in args],'exit':p.returncode,'seconds':round(time.monotonic()-t,3),'stdout_bytes':len(p.stdout),'stderr_bytes':len(p.stderr)})
 if name:
  (E/(name+'.out')).write_bytes(p.stdout); (E/(name+'.err')).write_bytes(p.stderr)
 if ok:assert p.returncode==0,(args,p.returncode,p.stderr[-2000:])
 return p

def home(name):
 h=V/name
 for d in ['data','state','config','projects']: (h/d).mkdir(parents=True,exist_ok=True)
 (h/'.tasks.toml').write_bytes((R/'.tasks.toml').read_bytes())
 (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
 return h

def task(h,*args):
 return run(['tasks-axi',*args,'--file',h/'data/backlog.md'])

h=home('live-recovery')
task(h,'add','overlap-task','Preserve title, comma and authority','--kind','ship','--repo','firstmate','--start','--body','Durable detail: never trim this source.')
task(h,'hold','overlap-task','--kind','captain','--reason','Preserve full decision '+('durable nuance ' * 100))
task(h,'add','blocked-task','Keep blocked membership','--kind','scout','--repo','firstmate','--blocked-by','overlap-task')
src=h/'data/backlog.md'; before=hashlib.sha256(src.read_bytes()).hexdigest()
fields='blocked_by,hold_kind,hold_reason'
def tables(suffix):
 files=[]
 for group,args in [('flight',['--state','in_flight']),('held',['--state','held']),('blocked',['--state','queued','--blocked'])]:
  p=run(['tasks-axi','list','--file',src,*args,'--fields',fields],name=suffix+'-'+group)
  f=E/(suffix+'-'+group+'.out'); files.append(f)
 return files
files=tables('recovery-populated')
p=run([R/'bin/fm-startup-backlog-dedup.sh',*files],name='recovery-deduplicated')
assert b'same record as 1:1' in p.stdout
assert b'blocked-task' in p.stdout
assert p.stdout.count(b'durable nuance')==100
assert hashlib.sha256(src.read_bytes()).hexdigest()==before
# Consume a full startup digest through the actual real toolchain in this isolated home.
p=run([R/'bin/fm-session-start.sh'],h,'live-startup-digest',extra={'FM_ROOT_OVERRIDE':str(R),'FM_SESSION_START_TIMEOUT':'90'},seconds=110)
assert b'same record as 1:1' in p.stdout and b'blocked-task' in p.stdout
assert b'invalid tasks-axi recovery tables' not in p.stdout
assert hashlib.sha256(src.read_bytes()).hexdigest()==before
# Empty final, then empty middle, then all-empty real supported CLI responses.
task(h,'unblock','blocked-task','--by','overlap-task')
files=tables('recovery-empty-last'); p=run([R/'bin/fm-startup-backlog-dedup.sh',*files],name='recovery-empty-last-rendered'); assert b'same record as 1:1' in p.stdout
empty=home('live-empty')
emptyfiles=[]
for g,args in [('flight',['--state','in_flight']),('held',['--state','held']),('blocked',['--state','queued','--blocked'])]:
 p=run(['tasks-axi','list','--file',empty/'data/backlog.md',*args,'--fields',fields],name='recovery-all-empty-'+g)
 emptyfiles.append(E/('recovery-all-empty-'+g+'.out'))
p=run([R/'bin/fm-startup-backlog-dedup.sh',files[0],emptyfiles[1],files[1]],name='recovery-empty-middle-rendered'); assert b'same record as 1:1' in p.stdout
p=run([R/'bin/fm-startup-backlog-dedup.sh',*emptyfiles],name='recovery-all-empty-rendered'); assert p.stdout.count(b'count: 0')==3
# Adversarial input to the public renderer: byte/schema differences must stay complete, contradiction must emit nothing.
original=files[0].read_bytes(); different=V/'different-table'; different.write_bytes(original.replace(b'Preserve full decision',b'Changed full decision'))
p=run([R/'bin/fm-startup-backlog-dedup.sh',files[0],different,emptyfiles[2]],name='recovery-differing-field'); assert b'same record as' not in p.stdout and b'Changed full decision' in p.stdout
schema=V/'schema-table'; schema.write_bytes(original.replace(b'hold_reason}',b'hold_until}'))
p=run([R/'bin/fm-startup-backlog-dedup.sh',files[0],schema,emptyfiles[2]],name='recovery-differing-schema'); assert b'same record as' not in p.stdout
bad=V/'contradiction'; bad.write_text('count: 1\ntasks: 0 held tasks in this backlog\n')
p=run([R/'bin/fm-startup-backlog-dedup.sh',files[0],bad,emptyfiles[2]],name='recovery-contradiction',ok=False); assert p.returncode!=0 and not p.stdout

big=home('live-large-contribution')
body='## Queued\n'+''.join(f'- [ ] retained-{i:04} - Retained title {i:04} (repo: alpha) (kind: ship) (since 2026-11-06)\n  Keep detail {i:04}: preserve ordering, authority and https://example.invalid/proof/{i:04}.\n' for i in range(1,401))
(big/'data/backlog.md').write_text(body)
meta=big/'state/retained-0001.meta'; meta.write_text('kind=ship\nproject=alpha\nwindow=\n')
hashes=[hashlib.sha256(f.read_bytes()).hexdigest() for f in [big/'data/backlog.md',meta]]
p=run([V/'baseline/bin/fm-fleet-snapshot.sh','--contribution-input'],big,'contribution-baseline',ok=False)
assert p.returncode==0 and not p.stdout and b'Argument list too long' in p.stderr
p=run([R/'bin/fm-fleet-snapshot.sh','--contribution-input'],big,'contribution-fixed')
d=json.loads(p.stdout); assert len(p.stdout)>131072
assert [t['id'] for t in d['backlog']['records']]==[f'retained-{i:04}' for i in range(1,401)]
assert d['backlog']['records'][-1]['title']=='Retained title 0400'
assert 'Keep detail 0400' in d['backlog']['records'][-1]['body_excerpt']
assert d['tasks'][0]['id']=='retained-0001'
assert hashes==[hashlib.sha256(f.read_bytes()).hexdigest() for f in [big/'data/backlog.md',meta]]
assert not list((V/'tmp').glob('fm-fleet-snapshot.*'))
# No mock endpoints: actual tmux client queries nonexistent disposable targets; home-summary must preserve unknown, general JSON must report absent.
hs=home('live-summary'); (hs/'.fm-secondmate-home').write_text('isolated\n')
for i in range(1,32):
 (hs/f'state/mate-{i:02}.meta').write_text(f'backend=tmux\nwindow=fm-validation-nonexistent-{os.getpid()}:mate-{i}\nworktree={hs}/absent-{i}\nproject=firstmate\nharness=claude\nkind=secondmate\nmode=secondmate\nhome={hs}/absent-{i}\nprojects=alpha\n')
p=run([R/'bin/fm-home-summary-refresh.sh'],hs,'live-home-summary-refresh',extra={'FM_SNAPSHOT_SECONDMATE_CHILDREN':'40','FM_HOME_SUMMARY_TIMEOUT':'60'})
d=json.loads((hs/'state/home-summary.json').read_bytes()); (E/'live-home-summary.json').write_text(json.dumps(d,indent=2)+'\n')
assert len(d['endpoints'])==31 and d['invalidity']['kind']=='child_current_unavailable'
assert all(t['endpoint']['exists'] is None and t['endpoint']['agent_alive']=='not_checked' and t['endpoint']['status']=='unknown' for t in d['endpoints'])
p=run([R/'bin/fm-fleet-snapshot.sh','--json'],hs,'live-general-snapshot',extra={'FM_SNAPSHOT_SECONDMATES':'0'})
d=json.loads(p.stdout); assert len(d['tasks'])==31 and all(t['endpoint']['exists'] is False for t in d['tasks'])
# Real coverage CLI only inventories tests; it executes no suite, linter or static analyzer.
for label,script,locale in [('base-nonc',V/'baseline/bin/fm-test-run.sh','en_US.utf8'),('fixed-c',R/'bin/fm-test-run.sh','C'),('fixed-nonc',R/'bin/fm-test-run.sh','en_US.utf8')]:
 p=run([script,'--check-coverage'],name='coverage-'+label,extra={'LC_ALL':locale},ok=(label!='base-nonc'))
 if label=='base-nonc': assert p.returncode!=0 and b'not in sorted order' in p.stderr
 else: assert not p.stderr and b'FM_TEST_COVERAGE ok' in p.stdout
assert (E/'coverage-fixed-c.out').read_bytes()==(E/'coverage-fixed-nonc.out').read_bytes()
(E/'live-commands.json').write_text(json.dumps(log,indent=2)+'\n')
(E/'live-results.json').write_text(json.dumps({'recovery_source_sha256':before,'contribution_source_sha256':hashes,'contribution_output_bytes':len((E/'contribution-fixed.out').read_bytes()),'summary_endpoints':31,'source_records_unchanged':True,'coverage_outputs_identical':True},indent=2)+'\n')
print('Live executable scenarios completed; actual CLI documents and command transcript captured.')
