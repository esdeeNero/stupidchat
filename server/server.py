#!/usr/bin/env python3
"""Opaque relay: bodies and upload/download pieces are ciphertext only."""
import re
import push
import base64, hashlib, json, os, secrets, sqlite3, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs
DB=os.environ.get('TIHO_DB',os.path.join(os.path.dirname(__file__),'relay.sqlite3'))
LIMIT=28*1024*1024;QUOTA=256*1024*1024;PIECE=32768
ACCESS_KEY=os.environ.get('TIHO_ACCESS_KEY','');lock=threading.Lock()
def connect():
    db=sqlite3.connect(DB);db.execute('PRAGMA secure_delete=ON');return db
with connect() as db:
    db.executescript('''CREATE TABLE IF NOT EXISTS accounts(id TEXT PRIMARY KEY, token TEXT);
CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY, recipient TEXT, body TEXT, created REAL);
CREATE TABLE IF NOT EXISTS devices(recipient TEXT PRIMARY KEY, token TEXT);
CREATE TABLE IF NOT EXISTS chunks(id TEXT, recipient TEXT, idx INTEGER, total INTEGER, body TEXT, created REAL, PRIMARY KEY(id,recipient,idx));
CREATE TABLE IF NOT EXISTS receipts(id TEXT, recipient TEXT, created REAL, PRIMARY KEY(id,recipient));''')
presence = {}  # Foreground polls only, cleared when the relay restarts.
def used(db):return db.execute('SELECT (SELECT coalesce(sum(length(body)),0) FROM messages)+(SELECT coalesce(sum(length(body)),0) FROM chunks)').fetchone()[0]
def dispatch(db,action,ident,method,payload,query,token):
    account=db.execute('SELECT token FROM accounts WHERE id=?',(ident,)).fetchone()
    if not account:return 404,{'error':'Unknown mailbox'}
    if action in ('send','chunk') and method=='POST':
        body=payload['body'];mid=payload['id']
        if not isinstance(body,str) or not isinstance(mid,str) or not 1<=len(mid)<=64:return 400,{'error':'Invalid envelope'}
        base64.b64decode(body,validate=True)
        if db.execute('SELECT 1 FROM receipts WHERE id=? AND recipient=?',(mid,ident)).fetchone() or db.execute('SELECT 1 FROM messages WHERE id=? AND recipient=?',(mid,ident)).fetchone():return 200,{'ok':True,'complete':True}
        if used(db)+len(body)>QUOTA:return 429,{'error':'Relay storage quota'}
        if db.execute('SELECT count(*) FROM messages WHERE recipient=?',(ident,)).fetchone()[0]>=100:return 429,{'error':'Mailbox full'}
        if action=='chunk':
            index,total=payload['index'],payload['total']
            if type(index)!=int or type(total)!=int or not 1<=total<=2048 or not 0<=index<total or not 0<len(body)<=PIECE:return 400,{'error':'Invalid piece'}
            existing=db.execute('SELECT total,body FROM chunks WHERE id=? AND recipient=? AND idx=?',(mid,ident,index)).fetchone()
            first=db.execute('SELECT total FROM chunks WHERE id=? AND recipient=? LIMIT 1',(mid,ident)).fetchone()
            if (existing and existing!=(total,body)) or (first and first[0]!=total):return 409,{'error':'Piece conflict'}
            if not first and db.execute('SELECT count(DISTINCT id) FROM chunks WHERE recipient=?',(ident,)).fetchone()[0]>=100:return 429,{'error':'Too many pending uploads'}
            current_size=db.execute('SELECT coalesce(sum(length(body)),0) FROM chunks WHERE id=? AND recipient=?',(mid,ident)).fetchone()[0]
            if current_size+(0 if existing else len(body))>LIMIT:return 413,{'error':'Upload too large'}
            db.execute('INSERT OR IGNORE INTO chunks VALUES (?,?,?,?,?,?)',(mid,ident,index,total,body,time.time()))
            rows=db.execute('SELECT body FROM chunks WHERE id=? AND recipient=? ORDER BY idx',(mid,ident)).fetchall()
            if len(rows)!=total:return 200,{'ok':True,'complete':False}
            body=''.join(r[0] for r in rows);base64.b64decode(body,validate=True)
        if len(body)>LIMIT:return 413,{'error':'Upload too large'}
        other=db.execute('SELECT recipient FROM messages WHERE id=?',(mid,)).fetchone()
        if other and other[0]!=ident:return 409,{'error':'Envelope conflict'}
        db.execute('INSERT OR IGNORE INTO messages VALUES (?,?,?,?)',(mid,ident,body,time.time()))
        db.execute('DELETE FROM chunks WHERE id=? AND recipient=?',(mid,ident))
        if query.get('silent') != ['1']:
            device=db.execute('SELECT token FROM devices WHERE recipient=?',(ident,)).fetchone()
            if device:push.enqueue(device[0])
        return 200,{'ok':True,'complete':True}
    if not secrets.compare_digest(account[0],hashlib.sha256(token.encode()).hexdigest()):return 401,{'error':'Unauthorized'}
    if action=='session' and method=='GET':return 200,{'ok':True}
    if action=='inbox' and method=='GET':
        device=query.get('_device')
        if device=='off':db.execute('DELETE FROM devices WHERE recipient=?',(ident,))
        elif device and re.fullmatch('[0-9a-f]{32,256}',device):
            db.execute('INSERT OR REPLACE INTO devices VALUES (?,?)',(ident,device))
        peer = query.get('peer', [''])[0]
        now = time.monotonic()
        presence[ident] = (peer, now)
        contact, seen = presence.get(peer, (None, 0))
        online = contact == ident and now - seen < 30
        chunked=query.get('chunked')==['1']
        order='length(body),created' if chunked else 'created'
        rows=db.execute('SELECT id,body FROM messages WHERE recipient=? ORDER BY '+order+' LIMIT 10',(ident,)).fetchall()
        return 200,{'peerOnline':online,'messages':[{'id':mid,'body':'','parts':(len(body)+PIECE-1)//PIECE} if chunked and len(body)>PIECE else {'id':mid,'body':body} for mid,body in rows]}
    if action=='piece' and method=='GET':
        mid=query['message'][0];index=int(query['index'][0])
        row=db.execute('SELECT body FROM messages WHERE id=? AND recipient=?',(mid,ident)).fetchone()
        if not row:return 404,{'error':'Unknown envelope'}
        if not 0<=index<(len(row[0])+PIECE-1)//PIECE:return 400,{'error':'Invalid piece index'}
        return 200,{'body':row[0][index*PIECE:(index+1)*PIECE]}
    if action=='ack' and method=='POST':
        for mid in payload.get('ids',[])[:100]:
            if db.execute('SELECT 1 FROM messages WHERE id=? AND recipient=?',(mid,ident)).fetchone():
                db.execute('INSERT OR IGNORE INTO receipts VALUES (?,?,?)',(mid,ident,time.time()))
                db.execute('DELETE FROM messages WHERE id=? AND recipient=?',(mid,ident))
        return 200,{'ok':True}
    return 404,{'error':'Not found'}
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def reply(self,code,obj):
        data=json.dumps(obj).encode();self.send_response(code);self.send_header('Cache-Control','no-store');self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def do_GET(self):self.handle_request('GET')
    def do_POST(self):self.handle_request('POST')
    def handle_request(self,method):
        try:
            parsed=urlsplit(self.path);path=parsed.path.strip('/').split('/');query=parse_qs(parsed.query)
            query['_device']=self.headers.get('X-Push-Device')
            if ACCESS_KEY and path!=['health'] and not secrets.compare_digest(self.headers.get('X-Tiho-Access',''),ACCESS_KEY):return self.reply(401,{'error':'Private relay access required'})
            size=int(self.headers.get('Content-Length',0))
            if not 0<=size<=LIMIT:return self.reply(413,{'error':'Maximum payload 28 MB'})
            payload=json.loads(self.rfile.read(size)) if size else {}
            if not isinstance(payload,dict):return self.reply(400,{'error':'Object expected'})
            with lock,connect() as db:
                cutoff=time.time()-7*86400
                for table in ('messages','chunks','receipts'):db.execute('DELETE FROM '+table+' WHERE created < ?',(cutoff,))
                if path==['health'] and method=='GET':result=(200,{'ok':True})
                elif path==['register'] and method=='POST':
                    if db.execute('SELECT count(*) FROM accounts').fetchone()[0]>=64:result=(429,{'error':'Account limit'})
                    else:
                        ident=secrets.token_urlsafe(24);token=secrets.token_urlsafe(32)
                        db.execute('INSERT INTO accounts VALUES (?,?)',(ident,hashlib.sha256(token.encode()).hexdigest()));result=(200,{'id':ident,'token':token})
                elif len(path)==2:result=dispatch(db,path[0],path[1],method,payload,query,self.headers.get('Authorization','').removeprefix('Bearer '))
                else:result=(404,{'error':'Not found'})
            # Slow network writes must never hold the global SQLite/dispatch lock.
            self.reply(*result)
        except (ValueError,KeyError,TypeError):self.reply(400,{'error':'Invalid request'})
        except (BrokenPipeError,ConnectionResetError,TimeoutError):pass
        except Exception:self.reply(500,{'error':'Internal error'})
if __name__=='__main__':
    print('stupidchat relay listening on port '+os.environ.get('PORT','8787'),flush=True)
    class Server(ThreadingHTTPServer):
        daemon_threads=True
        def get_request(self):
            sock,address=super().get_request();sock.settimeout(60);return sock,address
    Server((os.environ.get('TIHO_BIND','127.0.0.1'),int(os.environ.get('PORT','8787'))),Handler).serve_forever()
