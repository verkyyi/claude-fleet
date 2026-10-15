#!/usr/bin/env python3
"""Shared Codex trust read/fill using Fleet's TOML reader, including Python 3.9."""
import fcntl
import json
import os
from pathlib import Path
import runpy
import stat
import subprocess
import sys
import tempfile

TOML=runpy.run_path(str(Path(__file__).with_name('fleet-agent-defaults.py')))


def read_level(text, target):
    parser=TOML['_toml']
    if parser:
        data=parser.loads(text)
        return data.get('projects',{}).get(target,{}).get('trust_level')
    scan=TOML['TomlScan'](text)
    path=('projects',target,'trust_level')
    for size in (3,2,1):
        key=path[:size]
        if key in scan.values:
            value,rest=TOML['parse_value'](scan.values[key])
            if rest.strip() and not rest.lstrip().startswith('#'):
                raise ValueError('invalid trust value')
            for child in path[size:]:
                value=value.get(child) if isinstance(value,dict) else None
            return value
    return None


def read(path):
    try:
        info=path.stat()
        return path.read_text(), (info.st_ino,info.st_mtime_ns,info.st_size), stat.S_IMODE(info.st_mode)
    except FileNotFoundError:
        return '', None, 0o600


def filled(text,target):
    if read_level(text,target) is not None:
        return text
    scan=TOML['TomlScan'](text)
    lines=scan.lines[:]
    table=('projects',target)
    if table in scan.keys or ('projects',) in scan.keys:
        raise ValueError('cannot extend an inline projects table safely; retain the existing config')
    for i,line in enumerate(lines):
        header=TOML['_HDR'].match(line)
        if header and TOML['split_key'](header.group(2))==table:
            lines.insert(i+1,'trust_level = "trusted"')
            break
    else:
        if lines and lines[-1].strip(): lines.append('')
        lines += ['[projects.'+json.dumps(target,ensure_ascii=False)+']','trust_level = "trusted"']
    result='\n'.join(lines)+'\n'
    if read_level(result,target) != 'trusted':
        raise ValueError('resulting trust entry could not be verified')
    return result


def destination(config, create=False):
    path = config.resolve()
    if not path.parent.is_dir():
        if path.parent != Path.home().resolve()/'.codex':
            raise ValueError('Codex home does not exist; no config created')
        if create:
            path.parent.mkdir(mode=0o700, exist_ok=True)
    parent = path.parent if path.parent.exists() else path.parent.parent
    if not os.access(parent, os.W_OK | os.X_OK):
        raise ValueError('Codex config directory is not writable')
    return path


def grant(config,target):
    # Resolve the durable target, including an existing dangling config symlink.
    path=destination(config, create=True)
    text,_,_=read(path)
    if read_level(text,target) is not None:
        return False
    lock=path.with_name('.'+path.name+'.fleet-trust.lock')
    fd=os.open(str(lock),os.O_CREAT|os.O_RDWR,0o600)
    with os.fdopen(fd,'w') as guard:
        fcntl.flock(guard,fcntl.LOCK_EX)
        for _ in range(10):
            text,before,mode=read(path)
            result=filled(text,target)
            if result==text: return False
            fd,tmp=tempfile.mkstemp(prefix='.'+path.name+'.fleet-',dir=str(path.parent))
            try:
                with os.fdopen(fd,'w') as out:
                    out.write(result)
                    out.flush(); os.fsync(out.fileno())
                os.chmod(tmp,mode)
                if config.resolve()!=path:
                    raise ValueError('Codex config symlink changed during pre-trust')
                if read(path)[1]!=before: continue
                os.replace(tmp,path)
                return True
            finally:
                if os.path.exists(tmp): os.unlink(tmp)
    raise ValueError('Codex config kept changing; no trust overwrite attempted')


def eligible():
    if os.environ.get('FLEET_PRETRUST','1')=='0':
        raise ValueError('HOME pre-trust is opted out')
    result=subprocess.run(['sh',str(Path(__file__).with_name('fleet-trust.sh')),'node'],
                          stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=10)
    if result.returncode:
        raise ValueError('HOME pre-trust requires a currently trusted node')


def main():
    action,target,*flags=sys.argv[1:]
    target=str(Path(target).resolve())
    config=Path(os.environ.get('CODEX_HOME',str(Path.home()/'.codex')))/'config.toml'
    text,_,_=read(config.resolve())
    level=read_level(text,target)
    if action=='check':
        print(level if level in ('trusted','untrusted') else 'missing' if level is None else 'unknown')
        return 0 if level=='trusted' else 1 if level=='untrusted' else 2
    if action=='ready':
        if level=='trusted': print('trusted'); return 0
        if level is not None: raise ValueError('HOME has an explicit trust choice: '+str(level))
        eligible()
        destination(config)
        if '--apply' not in flags: print('pretrust-ready'); return 0
    if action=='grant-home':
        eligible()
    if action not in ('grant','grant-home','ready'):
        raise ValueError('unknown Codex trust operation')
    if grant(config,target): print(target)
    if action=='ready' and read_level(read(config.resolve())[0],target)!='trusted':
        raise ValueError('HOME trust could not be established')
    return 0

if __name__=='__main__':
    try: sys.exit(main())
    except (OSError,ValueError,TypeError,subprocess.SubprocessError) as error:
        print('fleet-trust: '+str(error),file=sys.stderr); sys.exit(5)
