"""Read exact process argv (never shell-split ps output).

The environment is read only through process_env, which hands back names and
the few values a caller asks for — never the whole block (issue #4537).

Persist only restart options; initial prompts, images and session selectors must
not be replayed. Unknown syntax defers hibernation rather than weakening policy.
"""
import ctypes
import os
from pathlib import Path
import struct
import sys


def process_executable(pid):
    """Kernel executable path, independent of a process's chosen argv[0]."""
    if sys.platform == 'darwin':
        libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        buf = ctypes.create_string_buffer(4096)
        if libproc.proc_pidpath(int(pid), buf, len(buf)) <= 0:
            raise OSError(ctypes.get_errno(), 'cannot read process executable')
        return Path(os.fsdecode(buf.value)).resolve()
    return Path('/proc/%s/exe' % pid).resolve(strict=True)


def process_argv(pid):
    if sys.platform=='darwin':
        libc=ctypes.CDLL(None,use_errno=True)
        mib=(ctypes.c_int*3)(1,49,int(pid))  # CTL_KERN, KERN_PROCARGS2
        size=ctypes.c_size_t(1024*1024)
        buf=ctypes.create_string_buffer(size.value)
        if libc.sysctl(mib,3,buf,ctypes.byref(size),None,0):
            raise OSError(ctypes.get_errno(),'cannot read native argv')
        raw=buf.raw[:size.value]
        argc=struct.unpack_from('i',raw)[0]
        offset=raw.index(b'\0',4)+1
        while raw[offset:offset+1]==b'\0': offset+=1
        # Stop at argc. Bytes following argv are the process environment and
        # must never be parsed, logged, or persisted by this reader.
        result=raw[offset:].split(b'\0',argc)[:argc]
    else:
        result=Path('/proc/%s/cmdline'%pid).read_bytes().rstrip(b'\0').split(b'\0')
    return [value.decode('utf-8') for value in result]


def process_birth(pid):
    """The kernel's start time for <pid>: an opaque, ordered token that changes
    when the number is reused."""
    if sys.platform=='darwin':
        libproc=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
        buf=ctypes.create_string_buffer(136)  # struct proc_bsdinfo
        if libproc.proc_pidinfo(int(pid),3,ctypes.c_uint64(0),buf,136)!=136:  # PROC_PIDTBSDINFO
            raise OSError(ctypes.get_errno(),'cannot read process start')
        return struct.unpack_from('QQ',buf.raw,120)  # pbi_start_tvsec, pbi_start_tvusec
    stat=Path('/proc/%s/stat'%pid).read_text()
    return (int(stat.rsplit(')',1)[1].split()[19]),)  # field 22, starttime


def stdin_is_socket(pid):
    """Is <pid>'s fd 0 a socket? exec keeps fd 0, so this is also the stdin of
    whatever exec'd into <pid> — bash reads ~/.bashrc when it is (issue #4537)."""
    if sys.platform=='darwin':
        libproc=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
        buf=ctypes.create_string_buffer(8*4096)
        size=libproc.proc_pidinfo(int(pid),1,ctypes.c_uint64(0),buf,len(buf))  # PROC_PIDLISTFDS
        if size<=0:raise OSError(ctypes.get_errno(),'cannot list process descriptors')
        for offset in range(0,size,8):
            fd,kind=struct.unpack_from('iI',buf.raw,offset)  # struct proc_fdinfo
            if fd==0:return kind==2  # PROX_FDTYPE_SOCKET
        return False
    try:return os.readlink('/proc/%s/fd/0'%pid).startswith('socket:')
    except FileNotFoundError:return False


def process_env(pid, names):
    """What <pid>'s environment block says, narrowed to <names>: a dict of
    names (every variable present), values ({name: value} for <names> only),
    functions (names whose value is an exported shell function body), stdin_socket
    and birth. The block is what execve() was handed unless the process has
    since rewritten it itself, so it is evidence to check against something
    else, never history on its own (issue #4537).

    No other value leaves this function: the environment carries credentials
    and is never logged or persisted.
    """
    birth=process_birth(pid)
    if sys.platform=='darwin':
        libc=ctypes.CDLL(None,use_errno=True)
        mib=(ctypes.c_int*3)(1,49,int(pid))  # CTL_KERN, KERN_PROCARGS2
        size=ctypes.c_size_t(1024*1024)
        buf=ctypes.create_string_buffer(size.value)
        if libc.sysctl(mib,3,buf,ctypes.byref(size),None,0):
            raise OSError(ctypes.get_errno(),'cannot read native environment')
        raw=buf.raw[:size.value]
        argc=struct.unpack_from('i',raw)[0]
        offset=raw.index(b'\0',4)+1
        while raw[offset:offset+1]==b'\0': offset+=1
        fields=raw[offset:].split(b'\0')
        # argv, then the environment up to the first empty string (the apple[] strings follow).
        entries=[]
        for field in fields[argc:]:
            if not field: break
            entries.append(field)
    else:
        entries=[e for e in Path('/proc/%s/environ'%pid).read_bytes().split(b'\0') if e]
    present=set();values={};functions=set()
    for entry in entries:
        key,sep,value=entry.partition(b'=')
        if not sep: raise ValueError('malformed native environment entry')
        key=key.decode('utf-8','surrogateescape')
        present.add(key)
        if value.startswith(b'() {'): functions.add(key)
        if key in names: values[key]=value.decode('utf-8')
    socket=stdin_is_socket(pid)
    if process_birth(pid)!=birth: raise OSError(3,'process changed while reading its environment')
    return dict(names=frozenset(present),values=values,functions=frozenset(functions),
                stdin_socket=socket,birth=birth)


def restart_options(argv,agent):
    args=list(argv[1:])
    if args and args[0].endswith(('.js','.py')): args.pop(0)
    values={'--model','-m','--permission-mode','--allowedTools','--allowed-tools',
            '--disallowedTools','--disallowed-tools','--tools','--add-dir','--agent',
            '--agents','--system-prompt','--append-system-prompt','--settings',
            '--setting-sources','--mcp-config','--effort','--fallback-model',
            '-c','--config','-p','--profile','-s','--sandbox','-a','--ask-for-approval',
            '--enable','--disable','--search-mode'}
    booleans={'--dangerously-skip-permissions','--allow-dangerously-skip-permissions',
              '--strict-mcp-config','--chrome','--no-chrome','--disable-slash-commands',
              '--verbose','--debug','--no-alt-screen','--search','--oss','--strict-config',
              '--dangerously-bypass-approvals-and-sandbox','--dangerously-bypass-hook-trust'}
    discard_values={'--resume','-r','--session-id','--remote','--remote-auth-token-env',
                    '--image','-i','--name','-n'}
    discard_flags={'--continue','--fork-session','--last','--all'}
    result=[];prompts=0;i=0
    while i<len(args):
        arg=args[i];key=arg.split('=',1)[0]
        if agent=='codex' and arg in ('resume','fork'):
            i+=1
            if i<len(args) and not args[i].startswith('-'):i+=1
            continue
        if key in discard_flags:i+=1;continue
        if key in values|discard_values:
            count=1 if '=' in arg else 2
            if i+count>len(args):raise ValueError('incomplete launch option '+key)
            if key in values:result.extend(args[i:i+count])
            i+=count;continue
        if key in booleans:
            # Native resume has its own flag scope. Preserve these after the
            # resume selector too; root-level hook trust does not carry across.
            if arg not in result: result.append(arg)
            i+=1;continue
        if arg=='--':
            prompts+=len(args)-i-1;break
        if arg.startswith('-'):raise ValueError('unsupported restart option '+key)
        prompts+=1;i+=1
    if prompts>1:raise ValueError('ambiguous positional launch arguments')
    # Each resume adds launcher defaults before saved overrides. Collapse those
    # duplicates so repeated sleep cycles do not grow argv or repeat scalar flags.
    groups=[];last={};i=0
    repeatable={'--add-dir','--allowedTools','--allowed-tools','--disallowedTools','--disallowed-tools'}
    while i<len(result):
        arg=result[i];key=arg.split('=',1)[0]
        count=2 if key in values and '=' not in arg else 1
        group=result[i:i+count]
        if key in ('-c','--config'):
            value=arg.split('=',1)[1] if '=' in arg else group[1]
            identity='config:'+value.split('=',1)[0]
        elif key in repeatable:identity=None
        else:identity={'-m':'--model','-p':'--profile','-s':'--sandbox','-a':'--ask-for-approval'}.get(key,key)
        if identity is not None and identity in last:groups[last[identity]]=[]
        if identity is not None:last[identity]=len(groups)
        groups.append(group);i+=count
    return [arg for group in groups for arg in group]
