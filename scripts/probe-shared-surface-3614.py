# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
import datetime,json,os,pathlib,signal,subprocess,time
root=pathlib.Path.cwd()
developer=pathlib.Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())
helper=developer/'Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper'
bundles=[p for p in root.glob('.build/**/MokumeCoreTests.xctest/Contents/MacOS/MokumeCoreTests') if 'Debug' in p.parts or 'debug' in p.parts]
assert len(bundles)==1 and helper.is_file(),(bundles,helper)
bundle=bundles[0]
frameworks=developer/'Platforms/MacOSX.platform/Developer/Library/Frameworks'
libraries=developer/'Platforms/MacOSX.platform/Developer/usr/lib'

out=pathlib.Path('out/parallel')
out.mkdir(parents=True,exist_ok=True)
processes=[]
started=time.monotonic()
try:
    for lane in (1,2):
        log=(out/f'lane-{lane}.log').open('w')
        args=['python3','scripts/gpu-slot.py','--','env',f'DYLD_FRAMEWORK_PATH={frameworks}',f'DYLD_LIBRARY_PATH={libraries}',str(helper),'--test-bundle-path',str(bundle),'--filter','FrameSyncTests/theNewestSharedSurfaceHoldsTheFrameItNames','--repetitions','10','--repeat-until','fail','--xunit-output',str(out/f'lane-{lane}.xml'),'--event-stream-output-path',str(out/f'lane-{lane}-events.jsonl'),'--event-stream-version','0',str(bundle),'--testing-library','swift-testing']
        p=subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        processes.append((lane,p,log))
    while any(p.poll() is None for _,p,_ in processes):
        if time.monotonic()-started>600:
            raise TimeoutError('2 processes exceeded 600 seconds')
        print(datetime.datetime.now().isoformat(timespec='seconds'),[(i,p.poll()) for i,p,_ in processes],flush=True)
        time.sleep(20)
    print('exits',[(i,p.returncode) for i,p,_ in processes],flush=True)
    assert all(p.returncode==0 for _,p,_ in processes)
    spans=[]
    for lane,_,_ in processes:
        points=[]
        for line in (out/f'lane-{lane}-events.jsonl').open():
            d=json.loads(line); p=d.get('payload',{})
            if 'theNewestSharedSurfaceHoldsTheFrameItNames' in p.get('testID','') and p.get('kind') in ('testStarted','testEnded'):
                points.append(p['instant']['since1970'])
        assert points, f'No actual target events for lane {lane}'
        spans.append((min(points),max(points)))
    overlap=min(b for a,b in spans)-max(a for a,b in spans)
    print('target spans',spans,'overlap seconds',overlap,flush=True)
    assert overlap>0,'SwiftPM serialized the tests; concurrency is not verified'
    (out/'result.json').write_text(json.dumps({'spans':spans,'overlap_seconds':overlap,'exits':[p.returncode for _,p,_ in processes]}))
finally:
    for _,p,log in processes:
        if p.poll() is None:
            os.killpg(p.pid,signal.SIGTERM)
            try: p.wait(timeout=5)
            except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait()
        log.close()
