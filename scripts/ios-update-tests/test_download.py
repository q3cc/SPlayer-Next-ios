"""在 macOS Actions 使用本地 HTTP 服务测试生产下载器，不访问用户账号。"""
import hashlib
import http.server
import pathlib
import subprocess
import tempfile
import threading
import time
import uuid

payload = b"PK\x03\x04" + bytes(range(256)) * 8192
requests = []
active = 0
maximum = 0
lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        global active, maximum
        header = self.headers.get("Range")
        with lock:
            requests.append((self.path, header))
            active += 1
            maximum = max(maximum, active)
        try:
            start, end = (0, len(payload) - 1)
            if header and self.path != "/single":
                start, end = map(int, header.removeprefix("bytes=").split("-"))
                self.send_response(206)
                if self.path == "/bad-range":
                    self.send_header("Content-Range", "bytes 0-0/1")
                else:
                    self.send_header("Content-Range", f"bytes {start}-{end}/{len(payload)}")
            else:
                self.send_response(200)
            data = payload[start:end + 1]
            if self.path == "/truncated":
                data = data[:-1]
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            for offset in range(0, len(data), 16384):
                self.wfile.write(data[offset:offset + 16384])
                self.wfile.flush()
                time.sleep(0.012)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with lock:
                active -= 1


with tempfile.TemporaryDirectory(prefix="splayer-ipa-test-") as directory:
    root = pathlib.Path(directory)
    binary = root / "download-test"
    subprocess.run([
        "swiftc", "-swift-version", "5",
        "src-tauri/plugins/ipa-update/ios/Sources/IpaDownload.swift",
        "scripts/ios-update-tests/main.swift", "-o", str(binary),
    ], check=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    digest = hashlib.sha256(payload).hexdigest()
    previous = root / str(uuid.uuid4())
    previous.mkdir()
    (previous / "old.ipa").write_bytes(b"old")
    unrelated = root / "keep.txt"
    unrelated.write_text("keep")
    for endpoint, checksum, expected in [
        ("range", digest, 0), ("single", digest, 0),
        ("bad-range", digest, 1), ("truncated", digest, 1),
        ("checksum", "0" * 64, 1),
    ]:
        folder = root / str(uuid.uuid4())
        result = subprocess.run([
            str(binary), f"http://127.0.0.1:{server.server_port}/{endpoint}",
            str(len(payload)), checksum, str(folder),
        ], text=True, capture_output=True, timeout=40)
        print(endpoint, result.stdout, result.stderr)
        assert result.returncode == expected, (endpoint, result.returncode)
        if expected == 0:
            assert (folder / "SPlayer-Next-iOS-unsigned.ipa").read_bytes() == payload
            assert f"progress {len(payload)} {len(payload)}" in result.stdout
            assert not previous.exists(), "成功下载后应清理旧的更新目录"
            previous = folder
        else:
            assert not folder.exists(), "失败下载不应残留半成品"
            assert previous.exists(), "失败下载不能清除之前完整的更新包"
        assert unrelated.read_text() == "keep", "不得清理非下载任务文件"
    server.shutdown()
    assert maximum >= 4, f"没有实际并行下载：{maximum}"
    assert len([r for r in requests if r[0] == "/range"]) == 5
    assert ("/single", None) in requests
    print("五组原生下载测试通过，最大并发：", maximum)
