#!/usr/bin/env python3
"""Spec-only bounded-command acceptance. Deterministic seed 20261011.
Budgets: 10 seconds per case; 5 seconds synchronization. No live services.
"""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

parser=argparse.ArgumentParser()
parser.add_argument('--app-dir',type=Path,default=Path(__file__).resolve().parents[1]/'app')
args,rest=parser.parse_known_args()
HELPER=args.app_dir.resolve()/'scripts/run_bounded.py'

class BoundedCommandTests(unittest.TestCase):
 def run_helper(self,timeout,code):
  return subprocess.run([sys.executable,str(HELPER),str(timeout),sys.executable,'-c',code],capture_output=True,text=True,timeout=10)
 def test_success_and_error_status(self):
  for status in (0,7,42):
   with self.subTest(status=status): self.assertEqual(self.run_helper(5,f'raise SystemExit({status})').returncode,status)
 def test_invalid_deadline(self):
  for deadline in ('','0','3601','-1','1.5','abc'):
   with self.subTest(deadline=deadline): self.assertNotEqual(self.run_helper(deadline,'raise SystemExit(0)').returncode,0)
 def test_timeout(self):
  started=time.monotonic()
  r=self.run_helper(1,'import time; time.sleep(30)')
  self.assertEqual(r.returncode,124,r.stderr)
  self.assertLess(time.monotonic()-started,5)
 def tree_case(self,interrupt=None):
  with tempfile.TemporaryDirectory(prefix='bounded-contract-') as tmp:
   root=Path(tmp); marker=root/'late'; ready=root/'ready'
   # A delayed observable write proves descendants cannot continue useful work.
   child="import time; from pathlib import Path; time.sleep(2); Path("+repr(str(marker))+").touch()"
   code="import subprocess,sys,time; from pathlib import Path; subprocess.Popen([sys.executable,'-c',"+repr(child)+"]); Path("+repr(str(ready))+").touch(); time.sleep(30)"
   with tempfile.TemporaryFile() as output:
    p=subprocess.Popen([sys.executable,str(HELPER),'10' if interrupt else '1',sys.executable,'-c',code],stdout=output,stderr=output)
    try:
     deadline=time.monotonic()+5
     while not ready.exists() and p.poll() is None and time.monotonic()<deadline: time.sleep(.01)
     self.assertTrue(ready.exists(),'Child tree did not start')
     if interrupt: p.send_signal(interrupt)
     status=p.wait(timeout=5)
     if interrupt: self.assertNotEqual(status,0)
     else: self.assertEqual(status,124)
     time.sleep(2.2)
     self.assertFalse(marker.exists(),'Descendant survived and performed delayed write')
    finally:
     if p.poll() is None: p.kill(); p.wait()
 def test_timeout_kills_descendants(self): self.tree_case()
 def test_sigterm_kills_descendants(self): self.tree_case(signal.SIGTERM)
 def test_sigint_kills_descendants(self): self.tree_case(signal.SIGINT)

if __name__=='__main__': unittest.main(argv=[__file__]+rest)
