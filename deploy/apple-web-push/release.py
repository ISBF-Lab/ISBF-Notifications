#!/usr/bin/env python3
"""Guarded configuration activation; no rebuild, database writes, or push requests."""

import argparse
import base64
from datetime import datetime, timezone
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
import urllib.request

import config

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("push_install", ROOT / "install.py")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)
RUN = "/etc/service/unicorn/run"


def command(*args, data=None, timeout=40):
    result = subprocess.run(args, input=data, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError("scoped command failed")
    return result.stdout


def inside(container, source, payload=None):
    return json.loads(command("docker", "exec", "-i", container, "python3", "-I", "-c", source,
                              data=json.dumps(payload).encode() if payload is not None else None))


def atomic(path, data, metadata):
    installer._atomic(path, data, metadata.st_mode, metadata.st_uid, metadata.st_gid)


def snapshot(container):
    return inside(container, r"""
import hashlib,json,pathlib,subprocess
root=pathlib.Path('/var/www/discourse')
plugins={}
for item in sorted((root/'plugins').iterdir()):
 if item.name.startswith('.') or not item.is_dir():continue
 content={}
 for file in sorted(item.resolve(strict=True).rglob('*')):
  relative=file.relative_to(item.resolve()).as_posix()
  if '.git' in file.relative_to(item.resolve()).parts or '__pycache__' in file.parts:continue
  if file.is_symlink():content[relative]='link:'+str(file.readlink())
  elif file.is_file():content[relative]=hashlib.sha256(file.read_bytes()).hexdigest()
 plugins[item.name]={'target':str(item.resolve()),'files':content}
core=subprocess.run(['git','-c','safe.directory=/var/www/discourse','-C',str(root),'rev-parse','HEAD'],capture_output=True,check=True).stdout.decode().strip()
print(json.dumps({'plugin_count':len(plugins),'plugin_fingerprint':hashlib.sha256(json.dumps(plugins,sort_keys=True).encode()).hexdigest(),'core_commit':core,'manifest_sha256':hashlib.sha256((root/'public/assets/.manifest.json').read_bytes()).hexdigest()}))
""")


def install_current(container, expected_run):
    source = (ROOT / "install.py").read_bytes()
    policy = (ROOT / "env-policy.sh").read_bytes()
    return inside(container, r"""
from pathlib import Path
import base64,hashlib,json,sys,tempfile
p=json.load(sys.stdin)
source=base64.b64decode(p['source'])
if hashlib.sha256(source).hexdigest()!=p['source_sha']:raise ValueError('source mismatch')
namespace={'__name__':'push_release_install'}
exec(compile(source,'apple-web-push/install.py','exec'),namespace)
with tempfile.TemporaryDirectory(prefix='isbf-apple-push-') as folder:
 path=Path(folder)/'policy.sh';path.write_bytes(base64.b64decode(p['policy']))
 result=namespace['install'](Path('/etc/service/unicorn/run'),path,p['policy_sha'],p['run_sha'])
print(json.dumps(result))
""", {"source":base64.b64encode(source).decode(), "source_sha":config.sha(source),
       "policy":base64.b64encode(policy).decode(), "policy_sha":config.sha(policy), "run_sha":expected_run})


def restore_run(container, before, expected_after, policy_sha):
    return inside(container, r"""
from pathlib import Path
import base64,hashlib,json,os,stat,sys,tempfile
p=json.load(sys.stdin);run=Path('/etc/service/unicorn/run');current=run.read_bytes();before=base64.b64decode(p['before'])
if hashlib.sha256(current).hexdigest()!=p['after_sha'] and current!=before:raise ValueError('launcher changed')
if run.is_symlink():raise ValueError('launcher became a symlink')
for parent in run.parents:
 meta=parent.lstat()
 if parent.is_symlink() or meta.st_uid!=0 or meta.st_mode & 0o022:raise ValueError('launcher ancestry changed')
meta=run.stat()
if meta.st_uid!=0 or meta.st_mode & 0o022:raise ValueError('launcher protection changed')
policy=Path('/etc/isbf/apple-web-push/env-policy.sh')
if policy.exists() or policy.is_symlink():
 if policy.is_symlink() or hashlib.sha256(policy.read_bytes()).hexdigest()!=p['policy_sha']:raise ValueError('policy changed')
if current!=before:
 fd,name=tempfile.mkstemp(prefix='.apple-push-rollback-',dir=run.parent)
 with os.fdopen(fd,'wb') as stream:
  os.fchown(stream.fileno(),meta.st_uid,meta.st_gid);os.fchmod(stream.fileno(),stat.S_IMODE(meta.st_mode));stream.write(before);stream.flush();os.fsync(stream.fileno())
 os.replace(name,run)
if policy.exists():policy.unlink()
print(json.dumps({'launcher_restored':True,'owned_policy_removed':True}))
""", {"before":base64.b64encode(before).decode(),"after_sha":expected_after,"policy_sha":policy_sha})


def reload_and_health(container, origin):
    command("docker", "exec", container, "sv", "-w", "60", "restart", "unicorn", timeout=80)
    for attempt in range(35):
        try:
            statuses = {}
            for path in ("/", "/login", "/isbf/calendar"):
                with urllib.request.urlopen(origin + path, timeout=8) as response:
                    statuses[path] = response.status
            if all(code == 200 for code in statuses.values()):
                return statuses
        except Exception:
            pass
        time.sleep(2)
    raise RuntimeError("HTTP readiness failed")


def write_json(path, value):
    installer._atomic(path, json.dumps(value, indent=2).encode(), 0o600, 0, 0)


def acquire_lock():
    descriptor = os.open("/tmp/isbf-production-release.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    metadata = os.fstat(descriptor)
    if metadata.st_uid != 0 or metadata.st_mode & 0o022:
        raise ValueError("release lock ownership requires review")
    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    return descriptor


def rollback(backup, config_path, container, origin, restart=True):
    audit = json.loads((backup / "audit.json").read_text())
    if audit['container'] != container or audit['config_path'] != str(config_path):
        raise ValueError("rollback target mismatch")
    before = (backup / "config.before").read_bytes()
    after = (backup / "config.after").read_bytes()
    old_run = (backup / "run.before").read_bytes()
    if config.sha(before) != audit['config_before_sha256'] or config.sha(after) != audit['config_after_sha256'] or config.sha(old_run) != audit['run_before_sha256']:
        raise ValueError("backup digest mismatch")
    hook = config.hook_for((ROOT / "install.py").read_bytes(), (ROOT / "env-policy.sh").read_bytes())
    current = config_path.read_bytes()
    restored = before if current == before else config.rollback_config(current, before, after, hook)
    # Never change a different/newly replaced container during conditional rollback.
    identifier = json.loads(command('docker','inspect',container))[0]['Id']
    if identifier != audit['container_id']:
        raise ValueError("container changed since backup")
    restored_run = restore_run(container, old_run, audit['run_after_sha256'], audit['policy_sha256'])
    if current != restored:
        atomic(config_path, restored, config_path.stat())
    result = {"rollback":True,"backup":str(backup),"config_sha256":config.sha(restored),**restored_run}
    if restart:
        result['http'] = reload_and_health(container, origin)
    write_json(backup / 'rollback.json', result)
    return result


def apply(args):
    config_path = args.config
    if config_path.is_symlink() or not config_path.is_file():
        raise ValueError("configuration must be a regular file")
    raw = config_path.read_bytes()
    if config.sha(raw) != args.expected_config_sha:
        raise ValueError("configuration changed since preflight")
    info = json.loads(command('docker','inspect',args.container))[0]
    if not info['State']['Running']:
        raise ValueError("container not running")
    current_run = command('docker','exec',args.container,'cat',RUN)
    if config.sha(current_run) != args.expected_run_sha:
        raise ValueError("launcher changed since preflight")
    patched = installer.patch_run(current_run)
    hook = config.hook_for((ROOT/'install.py').read_bytes(),(ROOT/'env-policy.sh').read_bytes())
    if config.owned_hook(config.load(raw)[1]) is not None:
        raise ValueError("release is already configured")
    after = config.patch_config(raw,hook)
    if config.rollback_config(after,raw,after,hook) != raw:
        raise ValueError("configuration inverse failed")
    baseline = snapshot(args.container)
    installer._ancestry(args.backup_root,create=True)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    backup = args.backup_root / stamp
    backup.mkdir(mode=0o700)
    for name, data in [('config.before',raw),('config.after',after),('run.before',current_run)]:
        installer._atomic(backup/name, data, 0o600, 0, 0)
    audit = {'commit':args.commit,'container':args.container,'container_id':info['Id'],'image_id':info['Image'],
             'config_path':str(config_path),'config_before_sha256':config.sha(raw),'config_after_sha256':config.sha(after),
             'run_before_sha256':config.sha(current_run),'run_after_sha256':config.sha(patched),
             'policy_sha256':config.sha((ROOT/'env-policy.sh').read_bytes()),'baseline':baseline}
    write_json(backup/'audit.json',audit)
    installed = False
    config_written = False
    reloaded = False
    try:
        if config_path.read_bytes() != raw:
            raise ValueError("configuration changed during backup")
        result = install_current(args.container,args.expected_run_sha)
        installed = True
        if result['run_after_sha256'] != audit['run_after_sha256']:
            raise ValueError("unexpected installed startup bytes")
        if config_path.read_bytes() != raw:
            raise ValueError("configuration changed before write")
        atomic(config_path,after,config_path.stat())
        config_written = True
        if snapshot(args.container) != baseline:
            raise ValueError("unrelated runtime sources changed")
        reloaded = True
        statuses = reload_and_health(args.container,args.origin)
        if snapshot(args.container) != baseline:
            raise ValueError("unrelated runtime sources changed after reload")
        receipt = {'ok':True,'commit':args.commit,'backup':str(backup),'http':statuses,
                   'config_sha256':config.sha(after),'run_sha256':config.sha(patched),'baseline':baseline,
                   'unrelated_sources_preserved':True,'database_changed':False,'push_sent':False,
                   'worker_transport_verification_pending':True}
        write_json(backup/'applied.json',receipt)
        return receipt
    except Exception:
        if installed or config_written:
            rollback(backup,config_path,args.container,args.origin,restart=reloaded)
        else:
            # A hash conflict may have installed only the unused policy. Guarded removal
            # accepts the unchanged original launcher as well as the known patched one.
            restore_run(args.container,current_run,audit['run_after_sha256'],audit['policy_sha256'])
        raise


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['apply','rollback'])
    parser.add_argument('--config',type=Path,required=True)
    parser.add_argument('--container',required=True)
    parser.add_argument('--origin',required=True)
    parser.add_argument('--expected-config-sha')
    parser.add_argument('--expected-run-sha')
    parser.add_argument('--commit')
    parser.add_argument('--backup-root',type=Path,default=Path('/root/isbf-apple-web-push-backups'))
    parser.add_argument('--backup',type=Path)
    args=parser.parse_args()
    if os.geteuid()!=0 or not re.fullmatch(r'[a-zA-Z0-9_-]+',args.container):
        raise ValueError('root and a valid existing container name required')
    descriptor=acquire_lock()
    try:
        if args.action=='apply':
            if not re.fullmatch('[0-9a-f]{40}',args.commit or '') or not all(re.fullmatch('[0-9a-f]{64}',value or '') for value in [args.expected_config_sha,args.expected_run_sha]):
                raise ValueError('verified release hashes required')
            result=apply(args)
        else:
            installer._ancestry(args.backup)
            result=rollback(args.backup,args.config,args.container,args.origin)
        print(json.dumps(result))
    finally:
        os.close(descriptor)


if __name__=='__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'ok':False,'error_type':type(error).__name__}),file=sys.stderr)
        sys.exit(1)
