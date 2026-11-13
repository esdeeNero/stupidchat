#!/usr/bin/env python3
"""Tiho opaque relay. Use HTTPS reverse proxy for Internet deployment."""
import base64, hashlib, json, os, secrets, sqlite3, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
DB = os.environ.get('TIHO_DB', os.path.join(os.path.dirname(__file__), 'relay.sqlite3'))
LIMIT = 28 * 1024 * 1024
ACCESS_KEY = os.environ.get('TIHO_ACCESS_KEY', '')
QUOTA = 256 * 1024 * 1024
lock = threading.Lock()
def connect():
    db = sqlite3.connect(DB)
    db.execute('PRAGMA secure_delete=ON')
    return db
with connect() as db:
    db.executescript('CREATE TABLE IF NOT EXISTS accounts(id TEXT PRIMARY KEY, token TEXT); CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY, recipient TEXT, body TEXT, created REAL);')
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass # Never log capabilities or ciphertext
    def reply(self, code, obj):
        data=json.dumps(obj).encode(); self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self): self.handle_request('GET')
    def do_POST(self): self.handle_request('POST')
    def handle_request(self, method):
        try:
            path=self.path.strip('/').split('/')
            if ACCESS_KEY and path != ['health'] and not secrets.compare_digest(self.headers.get('X-Tiho-Access',''), ACCESS_KEY):
                return self.reply(401, {'error':'Private relay access required'})
            size=int(self.headers.get('Content-Length',0))
            if size<0 or size>LIMIT: return self.reply(413, {'error':'Maximum payload 28 MB'})
            payload=json.loads(self.rfile.read(size)) if size else {}
            if not isinstance(payload,dict): return self.reply(400, {'error':'Object expected'})
            with lock, connect() as db:
                db.execute('DELETE FROM messages WHERE created < ?', (time.time()-7*86400,))
                if path==['health'] and method=='GET': return self.reply(200,{'ok':True})
                if path==['register'] and method=='POST':
                    if db.execute('SELECT count(*) FROM accounts').fetchone()[0]>=64: return self.reply(429,{'error':'Account limit'})
                    ident=secrets.token_urlsafe(24); token=secrets.token_urlsafe(32)
                    db.execute('INSERT INTO accounts VALUES (?,?)',(ident,hashlib.sha256(token.encode()).hexdigest())); db.commit()
                    return self.reply(200,{'id':ident,'token':token})
                if len(path)!=2: return self.reply(404,{'error':'Not found'})
                action, ident=path
                account=db.execute('SELECT token FROM accounts WHERE id=?',(ident,)).fetchone()
                if not account: return self.reply(404,{'error':'Unknown mailbox'})
                if action=='send' and method=='POST':
                    body=payload['body']; mid=payload['id']
                    if not isinstance(body,str) or not isinstance(mid,str) or len(mid)>64: return self.reply(400,{'error':'Invalid envelope'})
                    base64.b64decode(body,validate=True)
                    if db.execute('SELECT coalesce(sum(length(body)),0) FROM messages').fetchone()[0] + len(body) > QUOTA: return self.reply(429,{'error':'Relay storage quota'})
                    if db.execute('SELECT count(*) FROM messages WHERE recipient=?',(ident,)).fetchone()[0]>=100: return self.reply(429,{'error':'Mailbox full'})
                    db.execute('INSERT OR IGNORE INTO messages VALUES (?,?,?,?)',(mid,ident,body,time.time())); db.commit()
                    return self.reply(200,{'ok':True})
                supplied=self.headers.get('Authorization','').removeprefix('Bearer ')
                if not secrets.compare_digest(account[0],hashlib.sha256(supplied.encode()).hexdigest()): return self.reply(401,{'error':'Unauthorized'})
                if action=='session' and method=='GET': return self.reply(200,{'ok':True})
                if action=='inbox' and method=='GET':
                    rows=db.execute('SELECT id,body FROM messages WHERE recipient=? ORDER BY created LIMIT 10',(ident,)).fetchall()
                    return self.reply(200,{'messages':[{'id':r[0],'body':r[1]} for r in rows]})
                if action=='ack' and method=='POST':
                    for mid in payload.get('ids',[])[:100]: db.execute('DELETE FROM messages WHERE id=? AND recipient=?',(mid,ident))
                    db.commit(); return self.reply(200,{'ok':True})
                return self.reply(404,{'error':'Not found'})
        except (ValueError,KeyError,TypeError): self.reply(400,{'error':'Invalid request'})
        except Exception: self.reply(500,{'error':'Internal error'})
if __name__=='__main__':
    print('Tiho relay listening on port '+os.environ.get('PORT','8787'),flush=True)
    class Server(ThreadingHTTPServer):
        daemon_threads=True
        def get_request(self):
            sock, address=super().get_request(); sock.settimeout(60); return sock,address
    Server((os.environ.get('TIHO_BIND','127.0.0.1'),int(os.environ.get('PORT','8787'))),Handler).serve_forever()
