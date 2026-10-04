"""Disposable loopback-only fake bridge for the iOS simulator smoke app."""
import json
from pathlib import Path
import signal
import sys
import tempfile
import threading

from test_link import FakeBridge, Interfaces, LoopbackV4Server, LinkServer, UPSTREAM, ipaddress

directory = tempfile.TemporaryDirectory()
bridge = FakeBridge()
net = Interfaces(('127.0.0.1',), (), (ipaddress.ip_network('127.0.0.0/8'),))
v4 = LoopbackV4Server(('127.0.0.1', 0), bridge, UPSTREAM / 'web', directory.name, net, confirm=lambda *_: True)
v6 = LinkServer(('::1', v4.server_port), bridge, UPSTREAM / 'web', directory.name, net)
v6.auth, v6.devices = v4.auth, v4.devices
for server in (v4, v6):
    threading.Thread(target=server.serve_forever, daemon=True).start()
Path(sys.argv[1]).write_text(json.dumps({'port': v4.server_port, 'pin': v4.pin, 'id': v4.identity['id']}))
stop = threading.Event()
signal.signal(signal.SIGTERM, lambda *_: stop.set())
signal.signal(signal.SIGINT, lambda *_: stop.set())
try:
    stop.wait()
finally:
    for server in (v4, v6):
        server.shutdown()
        server.server_close()
    directory.cleanup()
