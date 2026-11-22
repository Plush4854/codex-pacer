"""Opt-in GLM (ZCode) hook adapter. Stdout stays empty; hook decisions never
change. ZCode fires the seven events this file knows and sends the same
snake_case payload Claude hooks use, minus a prompt id: a typed request
mints one and the session's tools and stop are bound to it here.
"""
import fcntl, json, os, pathlib, sys, time

HEX = frozenset('0123456789abcdefABCDEF')
ALNUM = frozenset('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789')
def ident(value):
    # Same grammar as ^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$ without loading re;
    # Python 3.6 hosts run this file too, so avoid str.isascii().
    if not isinstance(value,str) or not 0<len(value)<=256 or value[0] not in ALNUM:return None
    if not all(ch in ALNUM or ch in '._-' for ch in value):return None
    compact=value.replace('-','')
    if len(compact)==32 and all(ch in HEX for ch in compact):
        compact=compact.lower();return compact[:8]+'-'+compact[8:12]+'-'+compact[12:16]+'-'+compact[16:20]+'-'+compact[20:]
    return value
def new_id():
    raw=bytearray(os.urandom(16));raw[6]=(raw[6]&15)|64;raw[8]=(raw[8]&63)|128;value=raw.hex()
    return value[:8]+'-'+value[8:12]+'-'+value[12:16]+'-'+value[16:20]+'-'+value[20:]
def private_open(path,flags):
    fd=os.open(str(path),flags|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
    if os.fstat(fd).st_uid!=os.getuid():os.close(fd);raise OSError('owner')
    return fd
def write_locked(path,value):
    # Callers hold events.lock. Rewriting in place avoids a directory entry
    # change, so Pacer's spool-folder watch is not woken on every event.
    fd=private_open(path,os.O_CREAT|os.O_WRONLY|os.O_TRUNC)
    try:os.write(fd,json.dumps(value,separators=(',',':')).encode())
    finally:os.close(fd)
def read_object(path):
    try:
        fd=private_open(path,os.O_RDONLY)
        with os.fdopen(fd,'rb') as handle:raw=handle.read(2*1024*1024+1)
        if len(raw)>2*1024*1024:return {}
        value=json.loads(raw);return value if isinstance(value,dict) else {}
    except (OSError,ValueError):return {}
def hook(home,value):
    session=ident(value.get('session_id'));event=value.get('hook_event_name')
    if not session or not isinstance(event,str):return
    agent=ident(value.get('agent_id'));thread=agent or session;at=time.time();folder=home/'pacer'
    if value.get('agent_id') is not None and not agent:return
    if value.get('tool_use_id') is not None and not ident(value.get('tool_use_id')):return
    statefile=folder/'hook-state.json';lockfd=private_open(folder/'events.lock',os.O_CREAT|os.O_RDWR)
    try:
        fcntl.flock(lockfd,fcntl.LOCK_EX);states=read_object(statefile)
        state=states.get(thread) if isinstance(states.get(thread),dict) else {}
        prompt=ident(value.get('prompt_id')) or state.get('promptId')
        if event=='UserPromptSubmit':prompt=ident(value.get('prompt_id')) or new_id()
        if prompt:state['promptId']=prompt
        state['at']=at;states[thread]=state
        if len(states)>128:states=dict(sorted(states.items(),key=lambda row:row[1].get('at',0),reverse=True)[:128])
        row={'origin':'hook','sessionId':thread,'at':at}
        if prompt:row['promptId']=prompt
        if agent:row['parentId']=session
        cwd=value.get('cwd')
        if isinstance(cwd,str) and len(cwd)<=4096:row['project']=os.path.basename(cwd.rstrip('/').rstrip('\\'))[:240]
        rows=[]
        if event=='SessionStart':
            meta=dict(row,kind='metadata')
            if isinstance(value.get('model'),str):meta['model']=value['model'][:256]
            if not agent and value.get('source') in ('startup','resume'):meta['sessionLaunch']=True
            rows.append(meta)
        item=ident(value.get('tool_use_id')) or 'attention'
        # PermissionRequest may carry no tool_use_id. Match the started tool by
        # a checksum of its name/input so that tool's own end clears the request.
        pending=[entry for entry in state.get('pendingTools',[]) if isinstance(entry,list) and len(entry)==4]
        if event in ('PreToolUse','PermissionRequest'):
            import zlib
            name=value.get('tool_name') if isinstance(value.get('tool_name'),str) else ''
            named=zlib.crc32(name.encode('utf-8','replace'))
            try:inputs=zlib.crc32(json.dumps([name,value.get('tool_input')],sort_keys=True,default=str).encode('utf-8','replace'))
            except (TypeError,ValueError):inputs=None
        if event=='PreToolUse' and item!='attention':
            pending=[entry for entry in pending if entry[0]!=item][-15:]+[[item,named,inputs,'input' if name=='AskUserQuestion' else 'approval']]
        if event=='PermissionRequest' and item=='attention':
            match=[entry for entry in pending if inputs is not None and entry[2]==inputs] or [entry for entry in pending if entry[1]==named] or [entry for entry in pending if entry[0]==state.get('lastToolId')]
            if match:item=match[-1][0]
        if event in ('PostToolUse','PostToolUseFailure'):pending=[entry for entry in pending if entry[0]!=item]
        if event in ('UserPromptSubmit','Stop'):pending=[]
        if pending:state['pendingTools']=pending
        else:state.pop('pendingTools',None)
        if event=='PreToolUse':state['lastToolId']=item
        row['itemId']=item
        mapping={'UserPromptSubmit':'prompt','PreToolUse':'toolStart','PostToolUse':'toolEnd','PostToolUseFailure':'toolEnd','PermissionRequest':'approval'}
        kind=mapping.get(event)
        if event=='Stop':
            # ZCode has no transcript Pacer reads, so the Stop hook is the only
            # turn ending: a stop with nothing running completes the request,
            # and one with background work keeps it open for the wake.
            tasks=value.get('background_tasks')
            agents=sum(1 for task in tasks if isinstance(task,dict)) if isinstance(tasks,list) else 0
            kind='stopRequested' if agents else 'stop'
            if kind=='stopRequested':row['agents']=min(agents,64)
        if kind:
            row['kind']=kind
            if kind=='toolStart':row['attention']='input' if value.get('tool_name')=='AskUserQuestion' else 'none'
            rows.append(row)
        write_locked(statefile,states)
        path=folder/'events.jsonl'
        if path.exists() and path.stat().st_size>2*1024*1024:
            previous=folder/'events.previous.jsonl'
            if previous.exists():previous.unlink()
            os.replace(str(path),str(previous))
        if rows:
            fd=private_open(path,os.O_CREAT|os.O_APPEND|os.O_WRONLY)
            try:os.write(fd,b''.join(json.dumps(row,separators=(',',':'),ensure_ascii=True).encode()+b'\n' for row in rows))
            finally:os.close(fd)
    finally:os.close(lockfd)
def main():
    if len(sys.argv)<3 or sys.argv[1]!='hook':return
    raw=sys.stdin.buffer.read(1024*1024+1)
    if len(raw)>1024*1024:return
    home=pathlib.Path(sys.argv[2]).expanduser()
    try:value=json.loads(raw)
    except ValueError:return
    if isinstance(value,dict):hook(home,value)
if __name__=='__main__':
    try:main()
    except (OSError,ValueError,ImportError):pass
