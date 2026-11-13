#!/usr/bin/env python3
"""Install a per-user relay service, preserving the supplied private runtime folder."""
import argparse,os,pathlib,plistlib,shutil,signal,subprocess,time
p=argparse.ArgumentParser();p.add_argument('--runtime',type=pathlib.Path,required=True);p.add_argument('--repo',required=True);args=p.parse_args()
runtime=args.runtime.resolve();runtime.mkdir(parents=True,exist_ok=True)
label='app.stupidchat.relay';domain='gui/'+str(os.getuid());target=domain+'/'+label
service=pathlib.Path.home()/'Library/LaunchAgents'/f'{label}.plist';service.parent.mkdir(parents=True,exist_ok=True)
# Replace this same service, or the development supervisor recorded in its private PID file.
subprocess.run(['launchctl','bootout',target],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
pidfile=runtime/'supervisor.pid'
if pidfile.exists():
    pid=int(pidfile.read_text()); command=subprocess.run(['ps','-p',str(pid),'-o','command='],capture_output=True,text=True).stdout
    if 'server/internet.py' in command:
        try:os.kill(pid,signal.SIGTERM)
        except ProcessLookupError:pass
        time.sleep(2)
script=pathlib.Path(__file__).resolve().parent/'internet.py'
config={'Label':label,'ProgramArguments':[shutil.which('python3'),str(script),'--runtime',str(runtime),'--discovery-repo',args.repo],
        'WorkingDirectory':str(script.parent),'EnvironmentVariables':{'PATH':os.environ.get('PATH','/opt/homebrew/bin:/usr/bin:/bin')},
        'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':10,'StandardOutPath':str(runtime/'service.log'),'StandardErrorPath':str(runtime/'service.log')}
service.write_bytes(plistlib.dumps(config));service.chmod(0o600)
subprocess.run(['launchctl','bootstrap',domain,str(service)],check=True)
print('Installed user service '+label+'; it starts at login and restarts after failures.')
