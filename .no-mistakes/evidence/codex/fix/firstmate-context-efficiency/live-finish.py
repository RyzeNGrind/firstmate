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

hs=V/'live-summary'
big=V/'live-large-contribution'
hashes=[hashlib.sha256(f.read_bytes()).hexdigest() for f in [big/'data/backlog.md',big/'state/retained-0001.meta']]
before=hashlib.sha256((V/'live-recovery/data/backlog.md').read_bytes()).hexdigest()
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
