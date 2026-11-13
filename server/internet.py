#!/usr/bin/env python3
"""Run the private relay + a temporary HTTPS tunnel. Keep this process running."""
import argparse,json,os,pathlib,plistlib,re,secrets,shutil,signal,subprocess,sys,time
from publish_endpoint import configure
parser=argparse.ArgumentParser()
parser.add_argument('--runtime',type=pathlib.Path,required=True,help='Local private runtime directory')
parser.add_argument('--discovery-repo',help='Publish signed endpoint metadata in owner/repository')
args=parser.parse_args(); runtime=args.runtime.resolve(); runtime.mkdir(parents=True,exist_ok=True)
if not shutil.which('ssh'): sys.exit('OpenSSH is required')
keyfile=runtime/'access.key'
if not keyfile.exists(): keyfile.write_text(secrets.token_urlsafe(32)); keyfile.chmod(0o600)
key=keyfile.read_text().strip()
server=pathlib.Path(__file__).resolve().parent
children=[]
discovery=None
if args.discovery_repo:
    discovery=configure(runtime,args.discovery_repo)
    publisher=subprocess.Popen([sys.executable,str(server/'publish_endpoint.py'),'--runtime',str(runtime),'--repo',args.discovery_repo,'--watch'])
    children.append(publisher)
def stop(*_):
    for child in reversed(children):
        if child.poll() is None: child.terminate()
    for child in children:
        try: child.wait(timeout=5)
        except subprocess.TimeoutExpired: child.kill()
    sys.exit(0)
signal.signal(signal.SIGTERM,stop); signal.signal(signal.SIGINT,stop)
# Existing SQLite remains in place: changing the transport must not change identities.
env={**os.environ,'TIHO_ACCESS_KEY':key,'TIHO_BIND':'127.0.0.1','PORT':'8787','TIHO_DB':str(server/'relay.sqlite3')}
log=open(runtime/'relay.log','a')
relay=subprocess.Popen([sys.executable,str(server/'server.py')],env=env,stdout=log,stderr=log); children.append(relay)
time.sleep(.4)
if relay.poll() is not None: sys.exit('Relay did not start. Check relay.log; stop an existing server on port 8787 first.')
if sys.platform=='darwin': children.append(subprocess.Popen(['caffeinate','-i','-w',str(os.getpid())]))
command=['ssh','-F','/dev/null','-T','-o','BatchMode=yes','-o','ConnectTimeout=15','-o','StrictHostKeyChecking=accept-new','-o','UserKnownHostsFile='+str(runtime/'known_hosts'),'-o','IdentitiesOnly=yes','-o','IdentityFile=none','-o','ServerAliveInterval=30','-o','ServerAliveCountMax=3','-o','ExitOnForwardFailure=yes','-R','80:127.0.0.1:8787','nokey@localhost.run']
try:
    with open(runtime/'tunnel.log','a') as output:
        while True:
            tunnel=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
            children.append(tunnel)
            for line in tunnel.stdout:
                output.write(line); output.flush()
                match=re.search(r'https://[a-z0-9-]+\.app\.lhr\.life',line)
                if not match: continue
                url=match.group(0)
                configfile=runtime/'connection.json'
                old=json.loads(configfile.read_text()) if configfile.exists() else {}
                legacy=list(dict.fromkeys(old.get('legacy',[])+([old['url']] if old.get('url') else [])))
                configfile.write_text(json.dumps({'url':url,'legacy':legacy},indent=2))
                (server/'connection.txt').write_text(url+'\n')
                configuration={'ServerURL':url,'AccessKey':key,'LegacyURLs':legacy}
                if discovery: configuration.update({'DiscoveryURL':discovery['url'],'DiscoveryPublicKey':discovery['publicKey'],'DiscoveryFallbackURL':discovery['fallbackURL']})
                (server.parent/'iOS/Tiho/Connection.local.plist').write_bytes(plistlib.dumps(configuration))
                print('Tiho HTTPS: '+url,flush=True)
                print('Keep this process and Mac online. The temporary URL can rotate; see connection.json for the current URL.',flush=True)
            tunnel.wait()
            children.remove(tunnel)
            print('Tunnel disconnected; reconnecting in 3 seconds',flush=True)
            time.sleep(3)
except BaseException:
    stop()
