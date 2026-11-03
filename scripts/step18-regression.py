#!/usr/bin/env python3
"""Bounded, no-install regression for the exclusively assigned polish phone."""
import argparse, hashlib, importlib.util, json, os, re, shutil, statistics, subprocess, sys, time, urllib.request
from pathlib import Path
from types import SimpleNamespace
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
SET = (Path.home() / "Library/Caches/dsh-ios-port-E/simdevices")
UDID = '7258CB6D-4C1E-42AE-BFF6-7D3AB90BCD29'
NAME = 'dsh-portE-iPhone-polish'
BUNDLE = 'local.dshportc.app'
PORT = 19718
ENV = {**os.environ, 'DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer', 'DSHPORTE_DEVICE':'phone-polish', 'MOCK_PORT':str(PORT), 'PYTHONDONTWRITEBYTECODE':'1'}
OUT = ROOT/'logs/step18/regression'
OUT.mkdir(parents=True,exist_ok=True)
STATE = OUT/'state.json'

def save(name, data):
    p=OUT/name
    p.write_text(json.dumps(data,ensure_ascii=False,indent=2))
    return p

def command(args,timeout=45,env=None,check=True):
    started=time.time()
    try:
        r=subprocess.run([str(x) for x in args],capture_output=True,text=True,env=env or ENV,timeout=timeout)
    except subprocess.TimeoutExpired:
        with (OUT/'commands.jsonl').open('a') as f:f.write(json.dumps({'args':[str(x) for x in args],'timeout':timeout,'timedOut':True})+'\n')
        raise
    with (OUT/'commands.jsonl').open('a') as f:f.write(json.dumps({'at':started,'args':[str(x) for x in args],'returncode':r.returncode,'stdout':r.stdout,'stderr':r.stderr,'elapsedSeconds':time.time()-started},ensure_ascii=False)+'\n')
    if check and r.returncode:raise RuntimeError(f'command failed: {args}: {r.stderr[:500]}')
    return r

def sim(*args,**kw):
    if args[0] in ('uninstall','install','delete','erase','shutdown','create'):raise RuntimeError('forbidden sim operation')
    if args[0] not in ('list',) and (len(args)<2 or args[1]!=UDID) and not (args[0]=='io' and args[1]==UDID):raise RuntimeError('wrong device')
    return command(['xcrun','simctl','--set',SET,*args],**kw)

def getjson(path):
    try:return json.loads(path.read_text())
    except (OSError,ValueError):return {}

def health():
    with urllib.request.urlopen(f'http://127.0.0.1:{PORT}/healthz',timeout=4) as r:return json.load(r)

def validate():
    listing=json.loads(sim('list','devices','--json').stdout)
    devices=[d for values in listing['devices'].values() for d in values if d['udid']==UDID]
    assert len(devices)==1 and devices[0]['name']==NAME and devices[0]['state']=='Booted',devices
    c=Path(sim('get_app_container',UDID,BUNDLE,'data').stdout.strip())
    a=Path(sim('get_app_container',UDID,BUNDLE,'app').stdout.strip())
    assert c.resolve().is_relative_to(SET/UDID) and a.resolve().is_relative_to(SET/UDID)
    h=health();assert h['port']==PORT and h['ok']
    return c,a,h,devices[0]

def roots(c):return [c/'Documents',c/'Library/Application Support/DSH']

def metadata_tree(p):
    records=[]
    def visit(d):
        for x in sorted(d.iterdir()):
            s=x.lstat(); records.append({'path':str(x.relative_to(p)),'size':s.st_size,'mode':s.st_mode,'mtimeNs':s.st_mtime_ns,'inode':s.st_ino})
            if x.is_dir() and not x.is_symlink():visit(x)
    visit(p)
    return records

def setup():
    if STATE.exists():raise RuntimeError('state already exists; do not overwrite')
    c,a,h,d=validate()
    source_files=['sim/ios-app-entry.mjs','sim/step7-acceptance.mjs','sim/step8-acceptance.mjs','sim/step9-acceptance.mjs','sim/subprocess-acceptance.mjs']
    hashes=[]
    for f in source_files:
        source=hashlib.sha256((ROOT/f).read_bytes()).hexdigest();installed=hashlib.sha256((a/f).read_bytes()).hexdigest()
        hashes.append({'path':f,'source':source,'installed':installed,'matches':source==installed})
    assert all(x['matches'] for x in hashes),hashes
    save('preflight.json',{'device':d,'deviceSet':str(SET),'udid':UDID,'mock':h,'installedApp':str(a),'moduleHashes':hashes,'sourceStatus':command(['git','status','--short'],timeout=15).stdout})
    sim('terminate',UDID,BUNDLE,check=False)
    time.sleep(1)
    stamp=time.strftime('%Y%m%dT%H%M%S')
    state={'container':str(c),'app':str(a),'stamp':stamp,'originals':[],'restored':False}
    save('state.json',state)
    for p in roots(c):
        assert p.is_dir() and not p.is_symlink()
        target=p.with_name(p.name+'.step18-regression-original-'+stamp)
        assert not target.exists()
        inventory=metadata_tree(p)
        state['originals'].append({'path':str(p),'saved':str(target),'inventory':inventory})
        save('state.json',state)
        p.rename(target)
    save('state.json',state)
    print(json.dumps({'setup':'isolated by same-container rename; no credentials read or copied','container':str(c),'originals':[x['saved'] for x in state['originals']]}),flush=True)

def context():
    st=getjson(STATE);assert st and not st['restored'],'no active isolated state'
    c,a,h,d=validate();assert str(c)==st['container']
    return c,a,st

def archive_runtime(c,label):
    dest=OUT/label;dest.mkdir(exist_ok=True)
    for n in ['DSHPortC-node.log','DSHPortC-uidrive.json','DSHPortE-step7-acceptance.json','DSHPortE-step8-acceptance.json','DSHPortE-step9-acceptance.json','DSHPortE-subprocess-acceptance.json','DSHPortE-session-migrate.json']:
        p=c/'Documents'/n
        if p.exists():shutil.copy2(p,dest/n)
    status=getjson(c/'Documents/DSHPortC-status.json')
    # Never read or copy the session URL file, or serialize authenticated URLs.
    safe={k:status[k] for k in ['phase','secondsSinceLaunch','background','guest','node','detail','error','guestError'] if k in status}
    (dest/'status.json').write_text(json.dumps(safe,ensure_ascii=False,indent=2))
    return status

def stop():sim('terminate',UDID,BUNDLE,check=False);time.sleep(1)

def preserve_file(c,name,label):
    p=c/'Documents'/name
    if p.exists():
        q=p.with_name(p.name+'.step18-regression-'+label+'-'+str(time.time_ns()))
        p.rename(q)

def launch(args=(),env=None):
    return sim('launch',UDID,BUNDLE,'-DSHPortCMockPort',str(PORT),*args,env=env)

def wait_ready(c,timeout=120):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        s=getjson(c/'Documents/DSHPortC-status.json')
        if s.get('phase')=='webViewReady':return s
        if s.get('phase')=='failed':raise RuntimeError('app phase failed')
        time.sleep(.2)
    raise TimeoutError('webViewReady not reached')

def warning_scan(text):
    patterns={'warning_lines':r'(?i)\bwarn(?:ing)?\b','unhandled_rejection':r'(?i)unhandled(?:PromiseRejection| rejection| exception)','unknown_plugin':r'(?i)(?:unknown|unresolved|missing) plugin','unsupported':r'(?i)(?:not supported on ios|unsupported platform)','did_not_activate':r'(?i)did not activate','inconsistent':r'(?i)inconsistent','corrupt':r'(?i)corrupt','pending_service':r'(?i)pending service'}
    return {k:[l for l in text.splitlines() if re.search(v,l)] for k,v in patterns.items()}

def shot(label):
    # CoreSimulator cannot write screenshot files directly to this external volume.
    temp=Path('/tmp')/('step18-regression-'+label+'-'+str(time.time_ns())+'.png')
    r=sim('io',UDID,'screenshot',str(temp),timeout=25,check=False)
    if r.returncode==0 and temp.exists():
        shutil.copy2(temp,OUT/(label+'.png'))
        return str(OUT/(label+'.png'))
    return None

def cold():
    c,a,st=context();runs=[]
    for i in range(1,4):
        stop()
        preserve_file(c,'DSHPortC-status.json',f'cold{i}')
        preserve_file(c,'DSHPortC-node.log',f'cold{i}')
        started=time.monotonic();r=launch()
        status=wait_ready(c);elapsed=time.monotonic()-started
        time.sleep(2)
        archive_runtime(c,f'cold-{i}')
        log=(c/'Documents/DSHPortC-node.log').read_text(errors='replace')
        warnings=warning_scan(log)
        run={'run':i,'wallSeconds':round(elapsed,3),'appSeconds':status.get('secondsSinceLaunch'),'phase':status.get('phase'),'launch':r.stdout.strip(),'warnings':warnings,'warningMatches':sum(len(x) for x in warnings.values()),'screenshot':shot(f'cold-{i}')}
        runs.append(run);print(json.dumps(run,ensure_ascii=False),flush=True)
        save('coldstart.json',{'runs':runs,'medianSeconds':statistics.median([x['wallSeconds'] for x in runs]),'passed':len(runs)==3 and all(x['phase']=='webViewReady' and x['warningMatches']==0 for x in runs),'metric':'app process terminated before each launch; fresh status and node log; launch to webViewReady; simulator not rebooted'})

def acceptance(kind):
    c,a,st=context();stop()
    name={'7':'DSHPortE-step7-acceptance.json','8':'DSHPortE-step8-acceptance.json','9':'DSHPortE-step9-acceptance.json','provider':'DSHPortE-subprocess-acceptance.json'}[kind]
    preserve_file(c,name,kind)
    args=[];env=None
    if kind=='provider':env={**ENV,'SIMCTL_CHILD_DSHPORTE_GUEST_CHANNEL':'1','SIMCTL_CHILD_DSHPORTE_SUBPROCESS_ACCEPTANCE':'1'}
    else:args=['-DSHPortCTestStep'+kind+'Acceptance','1']
    if kind=='8':
        docs=c/'Documents';docs.mkdir(exist_ok=True)
        for src,dst in [('prompts/17-step8-rmtest.txt','step18-regression-step8-prompt.txt'),('mock/replies.mjs','step18-regression-step8-replies.mjs')]:
            target=docs/dst;assert not target.exists();shutil.copy2(ROOT/src,target)
        args+=['-DSHPortCTestStep8PromptFile',str(docs/'step18-regression-step8-prompt.txt'),'-DSHPortCTestStep8MockReplies',str(docs/'step18-regression-step8-replies.mjs')]
    started=time.time();launch(args,env)
    deadline=time.monotonic()+650
    p=c/'Documents'/name;report={}
    while time.monotonic()<deadline:
        report=getjson(p)
        if isinstance(report.get('summary'),dict):break
        time.sleep(2)
    archive_runtime(c,'step-'+kind)
    summary=report.get('summary');result={'kind':kind,'elapsedSeconds':round(time.time()-started,2),'complete':isinstance(summary,dict),'summary':summary,'passed':False}
    if isinstance(summary,dict):
        values=summary.get('results',summary)
        result['actualPassed']=sum(v is True for v in values.values());result['actualTotal']=len(values)
        result['passed']=len(values)>0 and all(v is True for v in values.values())
    save('step-'+kind+'.json',result);print(json.dumps(result,ensure_ascii=False),flush=True)

def import_script(name,path):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m

def events(c):
    all_events=[]
    for p in sorted((c/'Library/Application Support/DSH/sessions').rglob('*.jsonl.zstd')):
        raw=command(['zstd','-dc',p],timeout=20).stdout
        for line in raw.splitlines():
            try:all_events.append(json.loads(line))
            except ValueError:pass
    return all_events

def images():
    c,a,st=context();stop()
    names=['photo.heic','big-4608.jpg','alpha-2600.png']
    workspace=c/'Documents/workspace/deepseek-harness/default-workspace';workspace.mkdir(parents=True,exist_ok=True)
    for n in names:
        p=workspace/n;assert not p.exists();shutil.copy2(ROOT/'logs/step5/imgtest/fixtures'/n,p)
    before=time.time()
    h=health();requestlog=Path(h['logs']['requests']);assert requestlog==ROOT/'logs/step18/mock-requests.jsonl'
    offset=requestlog.stat().st_size
    launch(['-DSHPortCTestDrive','1','-DSHPortCTestPrompt','IMAGETEST step18 regression three fixtures','-DSHPortCTestKeyword','IMAGETEST-DONE','-DSHPortCTestAttachments',','.join(names)])
    deadline=time.monotonic()+240;new=[]
    while time.monotonic()<deadline:
        new=[e for e in events(c) if e.get('time',0)/1000>=before]
        if any(e.get('type')=='turn/end' for e in new):break
        time.sleep(3)
    time.sleep(2)
    with requestlog.open() as f:f.seek(offset);lines=f.read().splitlines()
    records=[]
    for l in lines:
        try:r=json.loads(l)
        except ValueError:continue
        # Only selected safe fields; the full request bodies are unnecessary.
        records.append({k:r.get(k) for k in ['t','request','script','selection','images','finishReason','requestBytes','streamDurationMs']})
    save('images-mock-requests.json',records)
    sys.path.insert(0,str(ROOT/'scripts'))
    im=import_script('regression_image_helpers',ROOT/'scripts/image-acceptance.py')
    userimages=im.user_image_parts(new)
    result={'mode':'real WebKit File input attachment driver; mock only','fixtures':names,'userImages':userimages,'turnEnds':sum(e.get('type')=='turn/end' for e in new),'mockRequests':records,'driver':getjson(c/'Documents/DSHPortC-uidrive.json'),'screenshot':shot('images'),'passed':len(userimages)==3 and any(len(r.get('images') or [])==3 for r in records) and any(e.get('type')=='turn/end' for e in new)}
    archive_runtime(c,'images');save('images.json',result);print(json.dumps({k:v for k,v in result.items() if k not in ['driver','mockRequests']},ensure_ascii=False),flush=True)

def idle():
    c,a,st=context();stop();preserve_file(c,'DSHPortC-status.json','idle');preserve_file(c,'DSHPortC-node.log','idle')
    sys.path.insert(0,str(ROOT/'scripts'));os.environ.update({'DSHPORTE_DEVICE':'phone-polish','MOCK_PORT':str(PORT)})
    m=import_script('regression_step13',ROOT/'scripts/step13-acceptance.py')
    m.LOGS=OUT/'idle';m.APP_PATH=a;m.SIMSET=SET;m.ENV=ENV;m.MOCK_PORT=PORT
    m.device_pick.device_udid=lambda create_phone=False: UDID
    m.device_pick.boot=lambda udid: None if udid==UDID else (_ for _ in ()).throw(RuntimeError('wrong idle device'))
    suppressed=[]
    def guarded(*args,**kw):
        if args[0] in ['uninstall','install']:
            assert args[1]==UDID and args[2] in [BUNDLE,str(a)]
            suppressed.append(args[0]);return SimpleNamespace(returncode=0,stdout='',stderr='')
        kw.setdefault('check',False)
        return sim(*args,**kw)
    m.simctl=guarded
    # Preserve the exact existing idle logic while intercepting its direct launch.
    original_run=subprocess.run
    def bounded_run(args,**kw):
        if args[:2]==['xcrun','simctl']:
            assert str(args[3])==str(SET) and args[5]==UDID
            assert args[4]=='launch'
        kw['timeout']=min(kw.get('timeout',45),45)
        return original_run(args,**kw)
    m.subprocess=SimpleNamespace(run=bounded_run)
    rc=m.run_idle(SimpleNamespace(name='step18-idle'))
    result=getjson(m.LOGS/'step18-idle.json')
    result.update({'exitCode':rc,'suppressedOperations':suppressed,'adaptation':'original run_idle logic; installation/uninstallation skipped; exact assigned device/set/port and installed app; output redirected','passed':rc==0 and result.get('busy') is False and result.get('submissions')==0 and not result.get('submitted') and bool(result.get('backgroundLogLines'))})
    archive_runtime(c,'idle');save('idle.json',result)
    sim('launch',UDID,BUNDLE,'-DSHPortCMockPort',str(PORT))
    print(json.dumps(result,ensure_ascii=False),flush=True)

def fresh7():
    c,a,st=context();stop()
    moved=[]
    for p in [c/'Library/Application Support/DSH', c/'Documents/workspace']:
        assert p.is_dir() and not p.is_symlink()
        target=p.with_name(p.name+'.step18-regression-before-fresh7-'+st['stamp'])
        assert not target.exists();p.rename(target);moved.append({'from':str(p),'saved':str(target)})
    for p in [OUT/'step-7.json',OUT/'step-7']:
        if p.exists():
            target=p.with_name(p.name+'-first-run');assert not target.exists();p.rename(target)
    save('fresh7-isolation.json',{'reason':'normal cold-start session at default-workspace is classified stale by step7 project_key, which expects no sessions or only root workspace keys','preserved':moved})
    acceptance('7')

def restore():
    st=getjson(STATE);assert st and not st['restored']
    c,a,_,_=validate();assert str(c)==st['container'];stop()
    restored=[]
    for item in st['originals']:
        p=Path(item['path']);saved=Path(item['saved']);assert saved.is_dir() and not saved.is_symlink()
        assert metadata_tree(saved)==item['inventory'],'original evidence changed'
        retained=p.with_name(p.name+'.step18-regression-results-'+st['stamp'])
        assert not retained.exists()
        if p.exists():p.rename(retained)
        saved.rename(p)
        assert metadata_tree(p)==item['inventory']
        restored.append({'path':str(p),'regressionRetained':str(retained),'metadataVerified':True})
    st['restored']=True;st['restore']=restored;save('state.json',st)
    # The original log and status must survive this final ordinary launch too.
    for n in ['DSHPortC-node.log','DSHPortC-status.json']:
        p=c/'Documents'/n
        if p.exists():
            dest=p.with_name(p.name+'.step18-regression-pre-restore-launch-'+st['stamp']);assert not dest.exists();p.rename(dest)
    launch();wait_ready(c)
    archive_runtime(c,'final-restored');save('restore.json',{'restored':restored,'appReady':True,'deviceLeftRunning':True,'mockHealth':health(),'note':'original Documents and DSH inventories checked unchanged before restart; original boot log/status also preserved beside originals before normal restart'})
    print(json.dumps({'restored':True,'deviceLeftRunning':True,'appReady':True}),flush=True)

def finalapp():
    # Invoke only after the parent has explicitly declared the final build ready.
    assert getjson(OUT/'final-buildready.json').get('confirmedByParent') is True
    st=getjson(STATE);assert st.get('restored') is True
    c,oldapp,h,device=validate()
    candidate=ROOT/'DerivedData-xct18/Build/Products/Debug-iphonesimulator/DSHPortC.app'
    assert candidate.is_dir() and candidate.resolve().is_relative_to(ROOT)
    stop()
    before={str(p.relative_to(c)):metadata_tree(p) for p in roots(c)}
    save('final-before-install-inventory.json',before)
    installed_hash=hashlib.sha256((candidate/'DSHPortC.debug.dylib').read_bytes()).hexdigest()
    command(['xcrun','simctl','--set',SET,'install',UDID,candidate],timeout=90)
    afterc,afterapp,h,device=validate()
    assert hashlib.sha256((afterapp/'DSHPortC.debug.dylib').read_bytes()).hexdigest()==installed_hash
    def stable(records):return [{k:v for k,v in x.items() if k!='inode'} for x in records]
    after={str(p.relative_to(afterc)):metadata_tree(p) for p in roots(afterc)}
    same=all(stable(before[k])==stable(after.get(k,[])) for k in before)
    save('final-install.json',{'candidate':str(candidate),'installedApp':str(afterapp),'sha256DebugDylib':installed_hash,'containerBefore':str(c),'containerAfter':str(afterc),'dataMetadataPreserved':same,'installOnly':True,'uninstallPerformed':False})
    assert same,'data metadata changed during covering install; inspect before launching'
    c=afterc
    # Preserve the original probe command/status before registration overwrites them.
    records=[]
    for i in range(1,4):
        stop()
        for n in ['DSHPortC-status.json','DSHPortC-node.log','step18-cmd.json','step18-probe-status.json']:
            preserve_file(c,n,f'final-cold-{i}')
        started=time.monotonic()
        launch(['-DSHPortEStep18','1','-DSHPortEStep18Tag',f'regression-final-{i}'])
        status=wait_ready(c)
        elapsed=time.monotonic()-started
        time.sleep(2)
        import uuid
        command_id='regression-'+uuid.uuid4().hex
        expression="JSON.stringify({stylePresent:!!document.getElementById('dsh-mobile-polish'),styleTextLength:document.getElementById('dsh-mobile-polish')?.textContent.length||0,cssRuleCount:document.getElementById('dsh-mobile-polish')?.sheet?.cssRules.length||0,composerPresent:!!document.querySelector('[data-composer-input]'),width:innerWidth,htmlWidth:document.documentElement.scrollWidth})"
        cmd=c/'Documents/step18-cmd.json';assert not cmd.exists()
        cmd.write_text(json.dumps({'id':command_id,'script':expression}))
        reply=c/'Documents'/('step18-out-'+command_id+'.json')
        deadline=time.monotonic()+30
        while not reply.exists() and time.monotonic()<deadline:time.sleep(.15)
        raw=getjson(reply);value=raw.get('value')
        if isinstance(value,str):
            try:value=json.loads(value)
            except ValueError:pass
        save(f'final-cold-{i}-dom.json',raw)
        archive_runtime(c,f'final-cold-{i}')
        warnings=warning_scan((c/'Documents/DSHPortC-node.log').read_text(errors='replace'))
        row={'run':i,'wallSeconds':round(elapsed,3),'appSeconds':status.get('secondsSinceLaunch'),'phase':status.get('phase'),'warnings':warnings,'warningMatches':sum(len(x) for x in warnings.values()),'dom':value,'probeOk':raw.get('ok') is True,'screenshot':shot(f'final-cold-{i}')}
        row['passed']=row['phase']=='webViewReady' and row['warningMatches']==0 and row['probeOk'] and isinstance(value,dict) and value.get('stylePresent') is True and value.get('cssRuleCount',0)>0 and value.get('composerPresent') is True
        records.append(row)
        save('final-coldstart.json',{'bundle':str(candidate),'debugDylibSHA256':installed_hash,'runs':records,'medianSeconds':statistics.median(x['wallSeconds'] for x in records),'passed':len(records)==3 and all(x['passed'] for x in records),'allDataRestoredBeforeInstall':True,'deviceLeftRunning':True,'mock':health()})
        print(json.dumps(row,ensure_ascii=False),flush=True)
    assert all(x['passed'] for x in records),'final boot or style gate failed'

def summary():
    files=['coldstart.json','step-7.json','step-8.json','step-9.json','step-provider.json','images.json','idle.json','restore.json']
    data={f.removesuffix('.json'):getjson(OUT/f) for f in files}
    data['step-7-first-run']=getjson(OUT/'step-7.json-first-run')
    data['final-coldstart']=getjson(OUT/'final-coldstart.json')
    data['final-install']=getjson(OUT/'final-install.json')
    final_ok=data['final-coldstart'].get('passed') is True and data['final-install'].get('dataMetadataPreserved') is True
    checks=['coldstart','step-7','step-8','step-9','step-provider','images','idle']
    save('result.json',{'overallStatus':'passed_with_build_split' if final_ok else 'partial','allChecksPassedOnInstalledApp':all(data[k].get('passed') is True for k in checks),'finalStartupAndInjectionValidated':final_ok,'functionalRegressionRerunOnFinalSwiftBuild':False,'binaryIdentityEvidence':'app-debug-binary-identity.json and binary-section-comparison.json','initialIdleHarnessError':'idle-runner.log: adapter initially used check=True for duplicate terminate; corrected to original check=False and rerun succeeded.','device':NAME,'deviceSet':str(SET),'udid':UDID,'mockPort':PORT,'results':data,'limits':['Functional regressions ran on original installed Swift build. As explicitly requested by parent, final covering install was followed by three cold launches and DOM/CSS injection checks, not a second full functional suite.','Simulator only; no real-device or signing tests.','Cold launch means terminated app process, not rebooted simulator.','step8 is its existing functional harness; not a separate RMTEST UI turn.','Existing run_idle reused with no-install adaptation.','No UI screenshot visual judgement performed; screenshots retained for parent review.']})
    print(json.dumps({k:({'passed':v.get('passed'),'summary':v.get('summary')} if k!='restore' else {'restored':bool(v),'appReady':v.get('appReady')}) for k,v in data.items()},ensure_ascii=False,indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['setup','cold','7','8','9','provider','images','idle','fresh7','restore','finalapp','summary']);args=parser.parse_args()
    try:
        if args.action in ['7','8','9','provider']:acceptance(args.action)
        else:globals()[args.action]()
    except BaseException as e:
        save('error-'+args.action+'-'+str(time.time_ns())+'.json',{'error':type(e).__name__,'message':str(e)})
        raise
