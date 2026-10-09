"""Tests for bin/apple-music-bridge (the native-messaging host).

Run: python3 -m unittest discover -s tests -p 'test_*.py'
"""
import importlib.machinery, importlib.util, io, json, os, stat, struct, subprocess, sys, tempfile, time, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIDGE = os.path.join(ROOT, "bin", "apple-music-bridge")

loader = importlib.machinery.SourceFileLoader("bridge", BRIDGE)
spec = importlib.util.spec_from_loader("bridge", loader)
bridge = importlib.util.module_from_spec(spec)
loader.exec_module(bridge)


def frame(obj):
    data = json.dumps(obj).encode()
    return struct.pack("=I", len(data)) + data


def unframe(buf):
    out = []
    while buf:
        (n,) = struct.unpack("=I", buf[:4])
        out.append(json.loads(buf[4:4 + n]))
        buf = buf[4 + n:]
    return out


class Sanitize(unittest.TestCase):
    def test_valid(self):
        s = bridge.sanitize_command
        self.assertEqual(s({"action": "rate", "value": -1, "x": 1}), {"action": "rate", "value": -1})
        self.assertEqual(s({"action": "repeat"}), {"action": "repeat"})
        self.assertEqual(s({"action": "repeat", "mode": 1}), {"action": "repeat", "mode": 1})
        self.assertEqual(s({"action": "search", "term": " colony ", "id": 7}), {"action": "search", "term": "colony", "id": 7})
        self.assertEqual(s({"action": "playItem", "kind": "library-playlists", "id": "p.AbC", "mode": "later"}),
                         {"action": "playItem", "kind": "library-playlists", "id": "p.AbC", "mode": "later"})
        self.assertEqual(s({"action": "addToLibrary"}), {"action": "addToLibrary"})

    def test_invalid(self):
        s = bridge.sanitize_command
        for bad in [None, [], "x", {}, {"action": 1}, {"action": "exec"},
                    {"action": "rate", "value": True}, {"action": "rate", "value": 5},
                    {"action": "repeat", "mode": False}, {"action": "shuffle", "on": 1},
                    {"action": "seek", "seconds": -2}, {"action": "seek", "seconds": "3"},
                    {"action": "playIndex", "index": -1}, {"action": "search", "term": "   ", "id": 1},
                    {"action": "search", "term": "a" * 201, "id": 1}, {"action": "search", "term": "ok", "id": "1"},
                    {"action": "playItem", "kind": "songs", "id": "a/b", "mode": "now"},
                    {"action": "playItem", "kind": "songs", "id": "1", "mode": "shuffle"}]:
            self.assertIsNone(s(bad), bad)

    def test_same_rules_as_extension(self):
        """The Python and JS validators must agree (defence in depth)."""
        with open(os.path.join(ROOT, "tests", "fixtures", "commands.json")) as f:
            cases = json.load(f)
        self.assertGreater(len(cases), 40)
        js = ("const C=require(%r);const cases=%s;"
              "process.stdout.write(JSON.stringify(cases.map(c=>C.sanitizeCommand(c))))") % (
            os.path.join(ROOT, "chromium", "extension", "core.js"), json.dumps(cases))
        out = json.loads(subprocess.check_output(["node", "-e", js]))
        self.assertEqual(out, [bridge.sanitize_command(c) for c in cases])


class WriteFailure(unittest.TestCase):
    def test_unwritable_state_dir_does_not_raise(self):
        with tempfile.TemporaryDirectory() as d:
            b = bridge.Bridge(d, 4242, io.BytesIO())
            b.state_dir = os.path.join(d, "missing")      # never created -> OSError on write
            b.state_file = os.path.join(b.state_dir, "queue.json")
            b.search_file = os.path.join(b.state_dir, "search.json")
            real, sys.stderr = sys.stderr, io.StringIO()
            try:
                self.assertIsNone(b.handle_message({"type": "queue", "state": {"a": 1}}))
                self.assertIsNone(b.handle_message({"type": "search", "results": {"a": 1}}))
                self.assertIn("cannot write", sys.stderr.getvalue())
            finally:
                sys.stderr = real


class Frames(unittest.TestCase):
    def test_roundtrip(self):
        self.assertEqual(bridge.read_frame(io.BytesIO(frame({"a": 1}))), {"a": 1})

    def test_bad_json_is_skipped(self):
        self.assertIsNone(bridge.read_frame(io.BytesIO(struct.pack("=I", 3) + b"{x}")))

    def test_oversized_is_refused_before_reading(self):
        with self.assertRaises(EOFError):
            bridge.read_frame(io.BytesIO(struct.pack("=I", bridge.MAX_MESSAGE + 1)))

    def test_truncated(self):
        with self.assertRaises(EOFError):
            bridge.read_frame(io.BytesIO(struct.pack("=I", 10) + b"{}"))
        with self.assertRaises(EOFError):
            bridge.read_frame(io.BytesIO(b"\x01"))


class BridgeFiles(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = io.BytesIO()
        self.b = bridge.Bridge(self.tmp.name, 4242, self.out)
        self.b.prepare()

    def tearDown(self):
        self.tmp.cleanup()

    def test_state_dir_is_private(self):
        mode = stat.S_IMODE(os.stat(self.b.state_dir).st_mode)
        self.assertEqual(mode, 0o700)
        self.assertTrue(stat.S_ISFIFO(os.stat(self.b.cmd_fifo).st_mode))
        self.assertEqual(stat.S_IMODE(os.stat(self.b.cmd_fifo).st_mode), 0o600)

    def test_replaces_non_fifo_command_path(self):
        os.remove(self.b.cmd_fifo)
        with open(self.b.cmd_fifo, "w") as f:
            f.write('{"action":"refresh"}\n')
        self.b.prepare()
        self.assertTrue(stat.S_ISFIFO(os.lstat(self.b.cmd_fifo).st_mode))

    def test_refuses_symlinked_state_dir(self):
        with tempfile.TemporaryDirectory() as rt, tempfile.TemporaryDirectory() as elsewhere:
            os.symlink(elsewhere, os.path.join(rt, "omarchy-apple-music"))
            with self.assertRaises(SystemExit):
                bridge.Bridge(rt, 1, io.BytesIO()).prepare()

    def test_queue_and_search_messages_write_files(self):
        self.assertEqual(self.b.handle_message({"type": "queue", "state": {"position": 3}}), self.b.state_file)
        with open(self.b.state_file) as f:
            self.assertEqual(json.load(f), {"position": 3})
        self.assertEqual(stat.S_IMODE(os.stat(self.b.state_file).st_mode), 0o600)
        self.assertEqual(self.b.handle_message({"type": "search", "results": {"id": 1}}), self.b.search_file)
        with open(self.b.search_file) as f:
            self.assertEqual(json.load(f), {"id": 1})

    def test_unknown_messages_are_ignored(self):
        for m in [None, [], {"type": "queue", "state": "x"}, {"type": "exec", "cmd": "rm"}, {"type": "search"}]:
            self.assertIsNone(self.b.handle_message(m))
        self.assertFalse(os.path.exists(self.b.state_file))

    def test_command_lines_are_sanitized_and_framed(self):
        self.assertIsNone(self.b.handle_command_line("not json"))
        self.assertIsNone(self.b.handle_command_line('{"action":"exec","cmd":"rm -rf ~"}'))
        self.assertIsNone(self.b.handle_command_line("   "))
        cmd = self.b.handle_command_line('{"action":"rate","value":1,"sneaky":"x"}\n')
        self.assertEqual(cmd, {"action": "rate", "value": 1, "type": "command"})
        self.assertEqual(unframe(self.out.getvalue()), [{"action": "rate", "value": 1, "type": "command"}])

    def test_cleanup_removes_everything(self):
        self.b.handle_message({"type": "queue", "state": {}})
        self.b.handle_message({"type": "search", "results": {}})
        self.b.cleanup()
        for p in (self.b.state_file, self.b.search_file, self.b.cmd_fifo):
            self.assertFalse(os.path.exists(p), p)


class EndToEnd(unittest.TestCase):
    """Run the real executable the way Chromium does: frames on stdin,
    commands through the FIFO, frames back on stdout."""

    def test_process(self):
        with tempfile.TemporaryDirectory() as rt:
            env = dict(os.environ, XDG_RUNTIME_DIR=rt)
            p = subprocess.Popen([sys.executable, BRIDGE], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
            d = os.path.join(rt, "omarchy-apple-music")
            state = os.path.join(d, "queue-%d.json" % os.getpid())
            fifo = os.path.join(d, "commands-%d" % os.getpid())
            p.stdin.write(frame({"type": "queue", "state": {"current": {"title": "Colony"}}}))
            p.stdin.flush()
            for _ in range(50):
                if os.path.exists(state) and os.path.exists(fifo):
                    break
                time.sleep(0.05)
            with open(state) as f:
                self.assertEqual(json.load(f)["current"]["title"], "Colony")
            with open(fifo, "w") as f:
                f.write('{"action":"exec"}\n{"action":"repeat","mode":1}\n')
            (n,) = struct.unpack("=I", p.stdout.read(4))
            self.assertEqual(json.loads(p.stdout.read(n)), {"action": "repeat", "mode": 1, "type": "command"})
            p.stdin.close()
            p.wait(timeout=5)
            p.stdout.close()
            self.assertFalse(os.path.exists(state), "state removed when the browser disconnects")

    def test_refuses_without_runtime_dir(self):
        env = {k: v for k, v in os.environ.items() if k != "XDG_RUNTIME_DIR"}
        r = subprocess.run([sys.executable, BRIDGE], env=env, stdin=subprocess.DEVNULL, capture_output=True)
        self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
