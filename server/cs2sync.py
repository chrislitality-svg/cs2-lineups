#!/usr/bin/env python3
# CS2 战术沙盘 — 云同步服务（单数据集，last-write-wins）
# 监听 127.0.0.1:8094，由 nginx 反代到 /cs2/sync/
#
# 2026-08-18 改为图片增量同步：
#   旧版把 255 张图塞在一个 80MB 的 imgs.json 里，改一张图要整包重传，
#   而且 base64 还额外撑大 33%，已经顶到 nginx 的 100m 上限。
#   现在一图一文件存二进制，客户端先拉 17KB 的索引比对，只传差异。
#
# 端点
#   GET  /health              健康探针
#   GET  /                    读 meta（道具/点位/地名…）
#   PUT  /                    写 meta
#   GET  /imgs/index          图片索引 {key:{sz,sha,ts}}，约 17KB
#   GET  /imgs/<key>          取单张图（二进制）
#   PUT  /imgs/<key>          存单张图（二进制 body）
#   DELETE /imgs/<key>        删单张图
#   GET|PUT /imgs             旧的整包端点，已停用 → 410，
#                             免得没刷新的老页面拿整包把新库冲掉
import json, os, re, threading, hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA_DIR = "/opt/cs2sync"
META = os.path.join(DATA_DIR, "meta.json")
IMGDIR = os.path.join(DATA_DIR, "imgs")
INDEX = os.path.join(DATA_DIR, "imgs-index.json")
LOCK = threading.Lock()
MAX_IMG = 12 * 1024 * 1024                      # 单图上限 12MB，挡住误传大文件
SAFE = re.compile(r"^[A-Za-z0-9_.-]{1,120}$")   # key 白名单，杜绝路径穿越


def _read(p, dflt=b""):
    try:
        with open(p, "rb") as f:
            return f.read()
    except Exception:
        return dflt


def _atomic(path, data):
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def _load_index():
    try:
        return json.loads(_read(INDEX, b"{}") or b"{}")
    except Exception:
        return {}


def _save_index(idx):
    _atomic(INDEX, json.dumps(idx, separators=(",", ":")).encode())


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,PUT,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def _key(self):
        """/imgs/<key> → key；不是单图路径就返回 None。"""
        p = self.path.split("?", 1)[0].rstrip("/")
        m = re.match(r"^/imgs/(.+)$", p)
        if not m:
            return None
        k = m.group(1)
        return k if SAFE.match(k) else False   # False = 非法 key

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
        except Exception:
            n = 0
        return self.rfile.read(n) if n else b""

    def do_OPTIONS(self):
        self._send(204)

    def do_GET(self):
        p = self.path.split("?", 1)[0].rstrip("/")
        if p.endswith("/health") or p == "/health":
            return self._send(200, b'{"ok":true}')
        if p == "/imgs/index":
            return self._send(200, json.dumps(
                {"imgs": _load_index()}, separators=(",", ":")).encode())
        if p == "/imgs":
            return self._send(410, b'{"error":"whole-blob endpoint retired, use /imgs/index"}')
        k = self._key()
        if k is False:
            return self._send(400, b'{"error":"bad key"}')
        if k:
            data = _read(os.path.join(IMGDIR, k), None)
            if data is None:
                return self._send(404, b'{"error":"not found"}')
            return self._send(200, data, "image/webp")
        return self._send(200, _read(META) or b"{}")

    def do_PUT(self):
        p = self.path.split("?", 1)[0].rstrip("/")
        if p == "/imgs":
            return self._send(410, b'{"error":"whole-blob endpoint retired, use PUT /imgs/<key>"}')
        k = self._key()
        if k is False:
            return self._send(400, b'{"error":"bad key"}')
        body = self._body()
        if k:
            if not body:
                return self._send(400, b'{"error":"empty body"}')
            if len(body) > MAX_IMG:
                return self._send(413, b'{"error":"image too large"}')
            with LOCK:
                os.makedirs(IMGDIR, exist_ok=True)
                _atomic(os.path.join(IMGDIR, k), body)
                idx = _load_index()
                idx[k] = {"sz": len(body),
                          "sha": hashlib.sha256(body).hexdigest()[:16],
                          "ts": int(self.headers.get("X-Sync-At", "0") or 0)}
                _save_index(idx)
            return self._send(200, b'{"ok":true}')
        with LOCK:
            _atomic(META, body)
        return self._send(200, b'{"ok":true}')

    def do_DELETE(self):
        k = self._key()
        if not k:
            return self._send(400, b'{"error":"bad key"}')
        with LOCK:
            try:
                os.remove(os.path.join(IMGDIR, k))
            except FileNotFoundError:
                pass
            idx = _load_index()
            idx.pop(k, None)
            _save_index(idx)
        return self._send(200, b'{"ok":true}')

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    os.makedirs(IMGDIR, exist_ok=True)
    ThreadingHTTPServer(("127.0.0.1", 8094), H).serve_forever()
