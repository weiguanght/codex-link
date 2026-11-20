"""Local app-server WebSocket used by the explicitly launched desktop."""
from concurrent.futures import Future, TimeoutError
import json
import logging
import os
from pathlib import Path
import stat
import threading

from bridge.ipc import IPCError

LOG = logging.getLogger(__name__)

METHODS = {
    'thread/read', 'thread/resume', 'thread/turns/list', 'thread/unsubscribe',
    'thread/start', 'thread/name/set', 'thread/settings/update',
    'thread/archive', 'thread/unarchive',
    'turn/start', 'turn/steer', 'turn/interrupt',
}


class RPCRejected(IPCError):
    def __init__(self, method, error):
        self.empty_history = method in ('thread/read', 'thread/turns/list') and (
            error.get('message') == 'list_turns is not supported yet')
        super().__init__(f'桌面运行时拒绝了 {method} 操作，请检查会话状态。')


def private_socket(path):
    resolved = Path(path).resolve(strict=True)
    node, directory = resolved.stat(), resolved.parent.stat()
    if (not stat.S_ISSOCK(node.st_mode) or node.st_uid != os.getuid()
            or directory.st_uid != os.getuid() or directory.st_mode & 0o077):
        raise OSError('App Server socket 必须属于当前用户并位于私有目录')
    return resolved


def unix_connect(path):
    try:
        from websockets.sync.client import unix_connect as connect
    except ImportError as exc:
        raise IPCError('共享桌面模式需要 Python websockets 15。') from exc
    return connect(str(private_socket(path)), uri='ws://localhost/rpc',
                   open_timeout=3, close_timeout=1, max_size=32 * 1024 * 1024)


class SharedRPC:
    def __init__(self, path, home, event, disconnect, running):
        self.path, self.home = path, Path(home).resolve()
        self.event, self.disconnect, self.running = event, disconnect, running
        self.lock, self.connect_lock = threading.RLock(), threading.Lock()
        self.socket = None
        self.client_id = None
        self.counter = 0
        self.pending = {}

    def connect(self):
        with self.connect_lock:
            if not self.running():
                raise IPCError('共享桌面进程已退出，请从网关重新启动桌面。')
            if self.client_id:
                return
            try:
                ws = unix_connect(self.path)
                with self.lock:
                    self.socket = ws
                threading.Thread(target=self._read, args=(ws,), daemon=True).start()
                result = self._request('initialize', {
                    'clientInfo': {'name': 'codex_link', 'version': '0.1.0'},
                    'capabilities': {'experimentalApi': True},
                }, 5)
                if Path(result['codexHome']).resolve() != self.home:
                    raise IPCError('共享 App Server 的 Codex 数据目录不一致。')
                ws.send('{"method":"initialized"}')
                with self.lock:
                    if self.socket is not ws:
                        raise IPCError('共享 App Server 已断开。')
                    self.client_id = 'shared-app-server'
            except IPCError:
                self.close()
                raise
            except Exception as exc:
                self.close()
                raise IPCError('无法连接本机共享 App Server。') from exc

    def _read(self, ws):
        from websockets.exceptions import ConnectionClosed
        try:
            for raw in ws:
                message = json.loads(raw)
                if 'method' in message:
                    self.event(message)
                else:
                    with self.lock:
                        future = self.pending.pop(message.get('id'), None)
                        if future is not None:
                            future.set_result(message)
        except ConnectionClosed:
            pass
        except (KeyError, TypeError, ValueError):
            LOG.warning('Invalid message from shared App Server')
        finally:
            with self.lock:
                if self.socket is ws:
                    self.socket = self.client_id = None
                    for future in self.pending.values():
                        future.set_exception(IPCError('共享 App Server 已断开，请检查会话后再决定是否重发。'))
                    self.pending.clear()
                    lost = True
                else:
                    lost = False
            if lost:
                self.disconnect()
            ws.close()

    def _request(self, method, params, timeout):
        future = Future()
        with self.lock:
            if not self.socket:
                raise IPCError('共享 App Server 未连接。')
            ws = self.socket
            self.counter += 1
            identifier = self.counter
            self.pending[identifier] = future
        try:
            ws.send(json.dumps({'id': identifier, 'method': method, 'params': params}, ensure_ascii=False))
            message = future.result(timeout)
        except TimeoutError as exc:
            raise IPCError('共享 App Server 响应超时，请检查会话后再决定是否重发。') from exc
        except OSError as exc:
            raise IPCError('共享 App Server 已断开。') from exc
        except Exception as exc:
            if isinstance(exc, IPCError):
                raise
            raise IPCError('共享 App Server 通信失败。') from exc
        finally:
            with self.lock:
                self.pending.pop(identifier, None)
        if 'error' in message:
            raise RPCRejected(method, message['error'])
        return message['result']

    def request(self, method, params, timeout=10):
        if method not in METHODS:
            raise IPCError('共享桌面模式不支持此操作。')
        self.connect()
        return self._request(method, params, timeout)

    def follow(self, session_id, owner=None, subscribe=True, host='local'):
        if not subscribe and self.client_id:
            self.request('thread/unsubscribe', {'threadId': session_id}, timeout=3)

    def close(self):
        with self.lock:
            ws = self.socket
        if ws is not None:
            ws.close()
