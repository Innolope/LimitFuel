#!/usr/bin/env python3
"""Frozen black-box release contract. Seed: 20261011; no Apple/network calls.
Budget: 20 seconds per process, 5 seconds for concurrency synchronization.
Skipped: live Keychain/Apple, property framework and sustained load (stdlib-only).
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import unittest

PARSER = argparse.ArgumentParser()
PARSER.add_argument('--app-dir', type=Path, default=Path(__file__).resolve().parents[1]/'app')
ARGS, UNIT_ARGS = PARSER.parse_known_args()
APP_DIR = ARGS.app_dir.resolve()
COMMIT = 'a' * 40
IDENTITY = 'Developer ID Application: Innolope LLC (MQD26CY5MA)'

STUB = r'''#!/usr/bin/env python3
import os,sys,json,time
from pathlib import Path
name=Path(sys.argv[0]).name
if name=='xcrun-python': name='xcrun'
args=sys.argv[1:]
with open(os.environ['CALL_LOG'],'a') as f:
 f.write(json.dumps([name]+args)+'\n')
mode=os.environ.get('MODE','')
if name=='git':
 if mode=='concurrent' and 'rev-parse' in args:
  Path(os.environ['GATE']+'.entered').touch()
  while not Path(os.environ['GATE']).exists(): time.sleep(.02)
 if 'rev-parse' in args: print('b'*40 if mode=='commit_mismatch' else 'a'*40)
 elif 'status' in args and mode=='git_dirty': print(' M source.swift')
 sys.exit(0)
if name=='codesign':
 if '-dv' in args or '-d' in args:
  print('flags=0x0' if mode=='no_runtime' else 'flags=0x10000(runtime)',file=sys.stderr)
  print('TeamIdentifier='+('OTHER12345' if mode=='wrong_team' else 'MQD26CY5MA'),file=sys.stderr)
  if mode=='adhoc': print('Signature=adhoc',file=sys.stderr)
 if mode=='strict_failure' and ('--verify' in args or '-v' in args): sys.exit(1)
 if mode=='dmg_sign_failure' and any(x.endswith('.dmg') for x in args): sys.exit(1)
if name=='hdiutil':
 if mode=='hdiutil_failure': sys.exit(1)
 if 'create' in args: Path(args[-1]).write_bytes(b'fixture dmg bytes\n')
if name=='xcrun' and 'notarytool' in args and 'submit' in args:
 if mode=='timeout':
  Path(os.environ['GATE']+'.notary-start').write_text(str(time.monotonic()))
  time.sleep(5)
 if mode=='notary_failure': sys.exit(1)
 if mode=='malformed': print('not json')
 elif mode=='oversize': print('x'*1048577)
 elif mode=='missing_status': print(json.dumps({'id':'00000000-0000-0000-0000-000000000001'}))
 else: print(json.dumps({'id':'00000000-0000-0000-0000-000000000001','status': {'rejected':'Rejected','pending':'In Progress'}.get(mode,'Accepted')}))
if name=='xcrun' and 'stapler' in args:
 if mode=='staple_failure' and 'staple' in args: sys.exit(1)
 if mode=='validate_failure' and 'validate' in args: sys.exit(1)
if name=='spctl' and mode=='gatekeeper_failure': sys.exit(1)
if name in ('open','osascript'): sys.exit(99)
'''

class ReleaseWorkflowTests(unittest.TestCase):
 def setUp(self):
  self.tmp = tempfile.TemporaryDirectory(prefix='limitfuel-contract-')
  self.addCleanup(self.tmp.cleanup)
  self.root = Path(self.tmp.name)
  self.app = self.root/'app'
  self.app.mkdir()
  shutil.copy2(APP_DIR/'create_dmg.sh', self.app/'create_dmg.sh')
  for name in ('scripts',):
   if (APP_DIR/name).is_dir(): shutil.copytree(APP_DIR/name,self.app/name)
  self.bundle = self.app/'build/LimitFuel.app/Contents'
  (self.bundle/'Resources').mkdir(parents=True)
  self.plist = {'CFBundleShortVersionString':'1.3.4','CFBundleVersion':'9'}
  self.provenance = {'commit':COMMIT,'dirty':False}
  self.write_metadata()
  self.bin = self.root/'bin'
  self.bin.mkdir()
  for name in ('git','codesign','hdiutil','xcrun','spctl','open','osascript'):
   p = self.bin/name
   p.write_text(STUB)
   p.chmod(0o755)
  self.log = self.root/'calls.jsonl'
  self.env = {k:v for k,v in os.environ.items() if k not in ('DEVELOPER_ID','NOTARY_PROFILE','NOTARY_TIMEOUT_SECONDS')}
  self.env.update(PATH=str(self.bin)+os.pathsep+os.environ['PATH'],CALL_LOG=str(self.log),GATE=str(self.root/'gate'))
  audit=self.root/'audit'
  audit.mkdir()
  (audit/'sitecustomize.py').write_text("""import sys, os, json, time
def record(event, details):
 if event != 'subprocess.Popen': return
 argv=details[1]
 if isinstance(argv, (list, tuple)) and 'notarytool' in argv and 'submit' in argv:
  with open(os.environ['GATE']+'.attempts', 'a') as f: f.write(str(time.clock_gettime(time.CLOCK_MONOTONIC))+'\\n')
sys.addaudithook(record)
""")
  self.env['PYTHONPATH']=str(audit)
  self.final = self.app/'dist/LimitFuel-1.3.4-9'
 def write_metadata(self):
  with (self.bundle/'Info.plist').open('wb') as f: plistlib.dump(self.plist,f)
  (self.bundle/'Resources/build-info.json').write_text(json.dumps(self.provenance))
 def run_release(self, mode='', **env):
  return subprocess.run(['bash',str(self.app/'create_dmg.sh')],cwd=self.root,env=dict(self.env,MODE=mode,**env),capture_output=True,text=True,timeout=20)
 def calls(self):
  return [json.loads(x) for x in self.log.read_text().splitlines()] if self.log.exists() else []
 def submitted(self):
  return [c for c in self.calls() if c[0]=='xcrun' and 'notarytool' in c and 'submit' in c]
 def assert_failed_clean(self,result,preflight=False):
  self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
  self.assertFalse(self.final.exists())
  self.assertFalse((self.app/'.release-lock').exists())
  if (self.app/'dist').exists(): self.assertEqual(list((self.app/'dist').iterdir()),[])
  if preflight: self.assertFalse(self.submitted())
 def test_success_defaults(self):
  self.assert_success(self.run_release(),IDENTITY,'LimitFuel')
 def assert_success(self,r,identity,profile):
  self.assertEqual(r.returncode,0,r.stdout+r.stderr)
  dmg=self.final/'LimitFuel-Installer.dmg'
  info=json.loads((self.final/'release-info.json').read_text())
  for k,v in dict(commit=COMMIT,version='1.3.4',build='9',notarizationID='00000000-0000-0000-0000-000000000001',sha256=hashlib.sha256(dmg.read_bytes()).hexdigest()).items(): self.assertEqual(info[k],v)
  self.assertFalse((self.app/'.release-lock').exists())
  self.assertEqual(sorted(p.name for p in (self.app/'dist').iterdir()),[self.final.name])
  calls=self.calls()
  self.assertTrue(any(c[0]=='codesign' and identity in c for c in calls))
  submit=self.submitted()
  self.assertEqual(len(submit),1)
  self.assertIn(profile,submit[0])
  self.assertFalse(any(c[0] in ('open','osascript') for c in calls))
  self.assertFalse(any(a in ('--password','--apple-id','--key','--key-id','--issuer') for c in calls for a in c))
 def test_overrides(self):
  identity='Developer ID Application: Équipe Test (MQD26CY5MA)'
  self.assert_success(self.run_release(DEVELOPER_ID=identity,NOTARY_PROFILE='Équipe Profile'),identity,'Équipe Profile')
 def test_invalid_environment(self):
  for key,values in {'DEVELOPER_ID':['','bad','X (SHORT)','X (MQD26CY5MA)\n','X\r (MQD26CY5MA)'],'NOTARY_PROFILE':['','bad\nprofile','bad\rprofile'],'NOTARY_TIMEOUT_SECONDS':['','0','3601','-1','1.5','abc']}.items():
   for value in values:
    with self.subTest(key=key,value=value): self.assert_failed_clean(self.run_release(**{key:value}),True)
 def test_invalid_versions(self):
  for key in self.plist:
   for value in ('','../escape','a/b','a\\b','é','a'*65):
    with self.subTest(key=key,value=value):
     original=self.plist[key]; self.plist[key]=value; self.write_metadata()
     self.assert_failed_clean(self.run_release(),True)
     self.plist[key]=original; self.write_metadata()
 def test_preflight_boundary_failures(self):
  for mode in ('git_dirty','commit_mismatch','adhoc','wrong_team','no_runtime','strict_failure'):
   with self.subTest(mode=mode): self.assert_failed_clean(self.run_release(mode),True)
 def test_dirty_provenance(self):
  self.provenance['dirty']=True; self.write_metadata()
  self.assert_failed_clean(self.run_release(),True)
 def test_missing_inputs(self):
  for target in (self.bundle/'Info.plist',self.bundle/'Resources/build-info.json',self.app/'build/LimitFuel.app'):
   with self.subTest(target=target.name):
    backup=target.with_name(target.name+'.saved'); target.rename(backup)
    self.assert_failed_clean(self.run_release(),True)
    backup.rename(target)
 def test_publish_boundary_failures(self):
  for mode in ('hdiutil_failure','dmg_sign_failure','notary_failure','rejected','pending','missing_status','malformed','oversize','staple_failure','validate_failure','gatekeeper_failure'):
   with self.subTest(mode=mode): self.assert_failed_clean(self.run_release(mode))
 def test_timeout_unknown_no_retry(self):
  r=self.run_release('timeout',NOTARY_TIMEOUT_SECONDS='1')
  attempts=(self.root/'gate.attempts').read_text().splitlines()
  self.assertEqual(len(attempts),1)
  started=float(attempts[0])
  self.assert_failed_clean(r)
  self.assertLess(time.clock_gettime(time.CLOCK_MONOTONIC)-started,4.5)
  self.assertLessEqual(len(self.submitted()),1)
  self.assertIn('unknown',(r.stdout+r.stderr).lower())
 def test_existing_release_unchanged(self):
  self.final.mkdir(parents=True); marker=self.final/'sentinel'; marker.write_bytes(b'preserve')
  r=self.run_release(); self.assertNotEqual(r.returncode,0)
  self.assertEqual(list(self.final.iterdir()),[marker]); self.assertEqual(marker.read_bytes(),b'preserve')
  self.assertFalse(self.submitted()); self.assertFalse((self.app/'.release-lock').exists())
 def test_existing_lock_untouched(self):
  lock=self.app/'.release-lock'; lock.mkdir(); marker=lock/'sentinel'; marker.write_bytes(b'preserve')
  r=self.run_release(); self.assertNotEqual(r.returncode,0)
  self.assertEqual(marker.read_bytes(),b'preserve'); self.assertFalse(self.final.exists()); self.assertFalse(self.submitted())
 def test_concurrent_callers(self):
  with tempfile.TemporaryFile() as out:
   p=subprocess.Popen(['bash',str(self.app/'create_dmg.sh')],cwd=self.root,env=dict(self.env,MODE='concurrent'),stdout=out,stderr=out)
   try:
    deadline=time.monotonic()+5
    while not (self.root/'gate.entered').exists() and p.poll() is None and time.monotonic()<deadline: time.sleep(.02)
    self.assertTrue((self.root/'gate.entered').exists(),'First release did not reach delayed boundary')
    second=self.run_release(); self.assertNotEqual(second.returncode,0)
    self.assertTrue((self.app/'.release-lock').exists())
    (self.root/'gate').touch(); self.assertEqual(p.wait(timeout=15),0)
    self.assertEqual(len(self.submitted()),1)
    self.assertTrue((self.final/'release-info.json').exists())
    self.assertFalse((self.app/'.release-lock').exists())
   finally:
    if p.poll() is None: p.kill(); p.wait()

if __name__=='__main__': unittest.main(argv=[__file__]+UNIT_ARGS)
