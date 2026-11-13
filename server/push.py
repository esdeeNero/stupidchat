"""Optional APNs certificate provider. Only a generic alert leaves the relay."""
import os
import queue
import subprocess
import threading

pending = queue.Queue(maxsize=512)
cert = os.getenv("APNS_CERT")
key = os.getenv("APNS_KEY")
host = "api.push.apple.com" if os.getenv("APNS_ENV") == "production" else "api.sandbox.push.apple.com"


def enqueue(token):
    if cert and key:
        try:
            pending.put_nowait(token)
        except queue.Full:
            print("Push queue full", flush=True)


def deliver():
    while True:
        token = pending.get()
        try:
            result = subprocess.run([
                "curl", "--silent", "--fail", "--http2", "--max-time", "12",
                "--cert", cert, "--key", key, "-H", "apns-topic: app.tiho.privatechat",
                "-H", "apns-push-type: alert", "--data-binary",
                '{"aps":{"alert":"Новое сообщение","sound":"default"}}',
                f"https://{host}/3/device/{token}"
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if result.returncode:
                print("APNs delivery failed", flush=True)
        except OSError:
            print("APNs transport unavailable", flush=True)
        finally:
            pending.task_done()


if cert and key:
    threading.Thread(target=deliver, daemon=True).start()
