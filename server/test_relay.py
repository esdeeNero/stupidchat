import base64,json,os,subprocess,tempfile,time,unittest,urllib.request,urllib.error
class RelayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(); cls.proc=subprocess.Popen(['python3',os.path.join(os.path.dirname(__file__),'server.py')],env={**os.environ,'PORT':'18787','TIHO_DB':cls.temp.name+'/db','TIHO_ACCESS_KEY':'test-relay-access'},stdout=subprocess.DEVNULL)
        for _ in range(50):
            try: cls.call('health'); break
            except Exception: time.sleep(.1)
    @classmethod
    def tearDownClass(cls): cls.proc.terminate(); cls.proc.wait(); cls.temp.cleanup()
    @staticmethod
    def call(path,body=None,token=''):
        req=urllib.request.Request('http://127.0.0.1:18787/'+path,data=json.dumps(body).encode() if body is not None else None,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json','X-Tiho-Access':'test-relay-access'})
        with urllib.request.urlopen(req) as r: return json.load(r)
    def test_delivery_auth_ack_and_idempotency(self):
        a=self.call('register',{}); b=self.call('register',{})
        envelope={'id':'unique','body':base64.b64encode(os.urandom(64)).decode()}
        self.call('send/'+b['id'],envelope); self.call('send/'+b['id'],envelope)
        with self.assertRaises(urllib.error.HTTPError) as error: self.call('inbox/'+b['id'],token=a['token'])
        self.assertEqual(error.exception.code,401); error.exception.close()
        self.assertEqual(self.call('inbox/'+b['id'],token=b['token'])['messages'],[envelope])
        self.call('ack/'+b['id'],{'ids':['unique']},b['token'])
        self.assertEqual(self.call('inbox/'+b['id'],token=b['token'])['messages'],[])
    def test_private_gate_and_session(self):
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:18787/register',data=b'{}'))
        self.assertEqual(error.exception.code,401); error.exception.close()
        a=self.call('register',{})
        self.assertTrue(self.call('session/'+a['id'],token=a['token'])['ok'])
        with self.assertRaises(urllib.error.HTTPError) as error: self.call('session/'+a['id'],token='wrong')
        self.assertEqual(error.exception.code,401); error.exception.close()
    def test_invalid_ciphertext(self):
        a=self.call('register',{})
        with self.assertRaises(urllib.error.HTTPError) as error: self.call('send/'+a['id'],{'id':'bad','body':'!!!'})
        self.assertEqual(error.exception.code,400); error.exception.close()
if __name__=='__main__': unittest.main()
