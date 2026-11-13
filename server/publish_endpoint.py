#!/usr/bin/env python3
"""Publish signed, non-secret endpoint metadata. Never publishes relay/device credentials."""
import argparse,base64,json,pathlib,shutil,subprocess,time

def run(args, data=None):
    result=subprocess.run(args,input=data,capture_output=True,check=True,timeout=30)
    return result.stdout

def configure(runtime, repo):
    if not repo or len(repo.split('/')) != 2: raise ValueError('Expected owner/repository')
    openssl=shutil.which('openssl')
    if not openssl or not shutil.which('gh'): raise RuntimeError('OpenSSL and authenticated GitHub CLI are required')
    private=runtime/'discovery-private.pem'
    if not private.exists():
        run([openssl,'genpkey','-algorithm','ED25519','-out',str(private)]); private.chmod(0o600)
    public=run([openssl,'pkey','-in',str(private),'-pubout','-outform','DER'])
    prefix=bytes.fromhex('302a300506032b6570032100')
    if not public.startswith(prefix) or len(public)!=44: raise ValueError('Unexpected Ed25519 public key encoding')
    config={'repo':repo,'url':f'https://raw.githubusercontent.com/{repo}/relay-endpoint/relay.json','publicKey':base64.b64encode(public[-32:]).decode(),'fallbackURL':f'https://api.github.com/repos/{repo}/contents/relay.json?ref=relay-endpoint'}
    (runtime/'discovery.json').write_text(json.dumps(config,indent=2))
    return config

def api(path, method='GET', obj=None):
    args=['gh','api',path,'--method',method]
    if obj is not None: args+=['--input','-']
    return json.loads(run(args,json.dumps(obj).encode() if obj is not None else None))

def publish(runtime, config, url):
    payload=json.dumps({'url':url,'issuedAt':int(time.time())},sort_keys=True,separators=(',',':')).encode()
    source=runtime/'endpoint-payload.json';source.write_bytes(payload)
    signature=run([shutil.which('openssl'),'pkeyutl','-sign','-rawin','-inkey',str(runtime/'discovery-private.pem'),'-in',str(source)])
    envelope=json.dumps({'payload':base64.b64encode(payload).decode(),'signature':base64.b64encode(signature).decode()},separators=(',',':'))
    repo=config['repo']; route=f'repos/{repo}/contents/relay.json'
    try:
        current=api(route+'?ref=relay-endpoint')
    except subprocess.CalledProcessError as error:
        if b'404' not in error.stderr: raise
        # Orphan branch: no workflow files, so endpoint rotations do not start CI jobs.
        tree=api(f'repos/{repo}/git/trees','POST',{'tree':[{'path':'relay.json','mode':'100644','type':'blob','content':envelope}]})
        commit=api(f'repos/{repo}/git/commits','POST',{'message':'chore: publish signed relay address / Публикация подписанного адреса','tree':tree['sha'],'parents':[]})
        api(f'repos/{repo}/git/refs','POST',{'ref':'refs/heads/relay-endpoint','sha':commit['sha']})
    else:
        api(route,'PUT',{'message':'chore: refresh relay address / Обновление адреса сервера','branch':'relay-endpoint','sha':current['sha'],'content':base64.b64encode(envelope.encode()).decode()})
    (runtime/'published-endpoint.json').write_text(envelope)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--runtime',type=pathlib.Path,required=True);parser.add_argument('--repo',required=True);parser.add_argument('--watch',action='store_true')
    args=parser.parse_args();config=configure(args.runtime,args.repo);last=None;published=0
    while True:
        try:
            url=json.loads((args.runtime/'connection.json').read_text())['url']
            if url!=last or time.time()-published>6*3600:
                publish(args.runtime,config,url);last=url;published=time.time();print('Published signed relay address: '+url,flush=True)
        except Exception as error: print('Endpoint publication will retry: '+type(error).__name__,flush=True)
        if not args.watch: break
        time.sleep(10)
