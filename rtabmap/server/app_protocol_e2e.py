#!/usr/bin/env python3
"""Faithful CollabSync HTTP protocol test against a TEMP collab server.

Mirrors app/ios/RTABMapApp/CollabSync.swift:
  POST /join (X-Client-Id) -> mode new|join, must_download
  POST /heartbeat
  POST /sync (X-Client-Id, X-Since-Id, raw delta .db)
  GET  /pull?since_global_id= (X-Client-Id) -> X-Max-Global-Id, X-Aligned, X-Client-To-Global
  GET  /map.db, GET /status

Does not touch the live LaunchAgent on :8080 except a read-only GET /status.
Does not change live odometry.
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

REPO = Path("/Users/ian/Code/dnhacks/rtabmap")
SERVER_BIN = REPO / "build/bin/rtabmap-collab-server"
SOURCE_DIR = REPO / "collab-data"
FIXTURE_DIR = Path("/tmp/rtabmap-collab-merge-test/fixtures")
WORK = Path("/tmp/rtabmap-collab-app-protocol-test")
ROOM = WORK / "room"
PORT = 18777
CLIENT_A = "ED4D51E2-1256-4703-B3CD-8B1E9DC60803"  # first mapper, local 1-105
CLIENT_B = "85998EDD-5BB6-4F0C-938A-195180A4DA0E"  # late joiner, local 106-221


@dataclass
class Check:
    name: str
    ok: bool
    detail: str


@dataclass
class PullInfo:
    status: int
    nodes: int
    poses: int
    max_id: int
    aligned: str
    transform: str
    bytes: int
    sqlite: bool


@dataclass
class Device:
    client_id: str
    last_synced_id: int = 0
    last_pulled_global_id: int = 0
    pull_nodes_seen: int = 0
    last_pull: PullInfo | None = None


results: list[Check] = []


def check(ok: bool, name: str, detail: str = "") -> bool:
    results.append(Check(name, bool(ok), detail))
    tag = "PASS" if ok else "FAIL"
    extra = f"  ({detail})" if detail else ""
    print(f"{tag}  {name}{extra}", flush=True)
    return bool(ok)


def last_node_id(db_path: Path) -> int:
    """Match lastNodeIdFromDatabaseNative: SELECT MAX(id) FROM Node."""
    if not db_path.exists() or db_path.stat().st_size == 0:
        return 0
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        row = con.execute("SELECT MAX(id) FROM Node;").fetchone()
        if not row or row[0] is None:
            return 0
        return int(row[0])
    finally:
        con.close()


def sqlite_scalar(db_path: Path, sql: str) -> str:
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        row = con.execute(sql).fetchone()
        if not row or row[0] is None:
            return ""
        return str(row[0])
    finally:
        con.close()


def sqlite_int(db_path: Path, sql: str, default: int = 0) -> int:
    s = sqlite_scalar(db_path, sql)
    if s == "":
        return default
    try:
        return int(s)
    except ValueError:
        return default


def is_sqlite(data: bytes) -> bool:
    return data[:15] == b"SQLite format 3"


def find_free_port(preferred: int) -> int:
    import socket

    for port in [preferred, preferred + 1, preferred + 2, 19876, 19877]:
        if port == 8080:
            continue
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                s.bind(("127.0.0.1", port))
            except OSError:
                continue
            return port
    raise RuntimeError("no free temp port")


def http(
    method: str,
    url: str,
    headers: dict[str, str] | None = None,
    body: bytes | None = None,
    timeout: float = 180,
) -> tuple[int, dict[str, str], bytes]:
    req = urllib.request.Request(url, data=body, method=method)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw_headers = {k: v for k, v in resp.headers.items()}
            return resp.status, raw_headers, resp.read()
    except urllib.error.HTTPError as e:
        raw_headers = {k: v for k, v in e.headers.items()} if e.headers else {}
        return e.code, raw_headers, e.read()


def header_ci(headers: dict[str, str], name: str) -> str:
    want = name.lower()
    for k, v in headers.items():
        if k.lower() == want:
            return v
    return ""


def header_int(headers: dict[str, str], name: str) -> int:
    raw = header_ci(headers, name).strip()
    if not raw:
        return 0
    try:
        return int(raw)
    except ValueError:
        return 0


class CollabClient:
    """HTTP subset of CollabSync.swift."""

    def __init__(self, base: str, device: Device):
        self.base = base.rstrip("/")
        self.d = device

    def join(self) -> tuple[int, dict[str, Any]]:
        status, headers, body = http(
            "POST",
            f"{self.base}/join",
            headers={
                "X-Client-Id": self.d.client_id,
                "Accept": "application/json",
            },
            timeout=20,
        )
        obj: dict[str, Any] = {}
        try:
            obj = json.loads(body.decode("utf-8", "replace"))
        except json.JSONDecodeError:
            obj = {"_raw": body[:200].decode("utf-8", "replace")}
        return status, obj

    def heartbeat(self) -> int:
        status, _, _ = http(
            "POST",
            f"{self.base}/heartbeat",
            headers={"X-Client-Id": self.d.client_id},
            timeout=12,
        )
        return status

    def sync(self, delta_path: Path) -> tuple[int, dict[str, Any]]:
        body = delta_path.read_bytes()
        status, headers, resp = http(
            "POST",
            f"{self.base}/sync",
            headers={
                "X-Client-Id": self.d.client_id,
                "X-Since-Id": str(self.d.last_synced_id),
                "Content-Type": "application/octet-stream",
                "Content-Length": str(len(body)),
            },
            body=body,
            timeout=300,
        )
        obj: dict[str, Any] = {}
        try:
            obj = json.loads(resp.decode("utf-8", "replace"))
        except json.JSONDecodeError:
            obj = {"_raw": resp[:240].decode("utf-8", "replace")}
        if status == 200 and obj.get("ok") is True:
            last = obj.get("last_local_id")
            if isinstance(last, int) and last > 0:
                self.d.last_synced_id = last
        return status, obj

    def pull(self) -> PullInfo:
        since = self.d.last_pulled_global_id
        status, headers, body = http(
            "GET",
            f"{self.base}/pull?since_global_id={since}",
            headers={
                "X-Client-Id": self.d.client_id,
                "X-Since-Global-Id": str(since),
                "Accept": "application/octet-stream",
            },
            timeout=90,
        )
        info = PullInfo(
            status=status,
            nodes=header_int(headers, "X-Nodes-Count"),
            poses=header_int(headers, "X-Poses-Count"),
            max_id=header_int(headers, "X-Max-Global-Id"),
            aligned=header_ci(headers, "X-Aligned") or "0",
            transform=header_ci(headers, "X-Client-To-Global"),
            bytes=len(body),
            sqlite=is_sqlite(body),
        )
        self.d.last_pull = info
        if status == 200:
            imported_ok = info.nodes == 0 or info.sqlite
            if imported_ok and info.max_id > self.d.last_pulled_global_id:
                self.d.last_pulled_global_id = info.max_id
            self.d.pull_nodes_seen += info.nodes
        return info

    def map_db(self, dest: Path) -> tuple[int, int]:
        status, headers, body = http(
            "GET",
            f"{self.base}/map.db",
            headers={
                "X-Client-Id": self.d.client_id,
                "Accept": "application/octet-stream",
            },
            timeout=90,
        )
        if status == 200 and body:
            dest.write_bytes(body)
        return status, len(body)


def wait_listen(port: int, seconds: int) -> bool:
    import socket

    deadline = time.time() + seconds
    while time.time() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.4)
            try:
                s.connect(("127.0.0.1", port))
                return True
            except OSError:
                time.sleep(0.25)
    return False


def inspect_graph(db_path: Path) -> dict[str, Any]:
    out: dict[str, Any] = {
        "nodes": 0,
        "maps": {},
        "poses": 0,
        "loop_closures": 0,
        "neighbor": 0,
        "inter_session_lc": 0,
        "user_closures": 0,
    }
    if not db_path.exists():
        return out
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        out["nodes"] = int(con.execute("SELECT COUNT(*) FROM Node;").fetchone()[0])
        maps = {}
        for map_id, n in con.execute("SELECT map_id, COUNT(*) FROM Node GROUP BY map_id;"):
            maps[int(map_id)] = int(n)
        out["maps"] = maps
        try:
            out["poses"] = int(
                con.execute(
                    "SELECT COUNT(*) FROM Admin WHERE opt_poses IS NOT NULL AND length(opt_poses)>0;"
                ).fetchone()[0]
            )
        except sqlite3.Error:
            out["poses"] = 0
        # Unique non-neighbor closures. Types: 0 neighbor, 5 neighbor-merged,
        # 6 pose-prior, 7 gravity, 8 virtual, 9 landmark. 1=loop, 4=user.
        rows = con.execute(
            """
            SELECT MIN(from_id,to_id), MAX(from_id,to_id), type,
                   (SELECT map_id FROM Node WHERE id=from_id),
                   (SELECT map_id FROM Node WHERE id=to_id)
            FROM Link
            WHERE type NOT IN (0,5,6,7,8,9)
            GROUP BY 1,2,type
            """
        ).fetchall()
        unique = set()
        inter = 0
        user = 0
        for a, b, typ, ma, mb in rows:
            unique.add((a, b))
            if typ == 4:
                user += 1
            if ma is not None and mb is not None and ma != mb:
                inter += 1
        out["loop_closures"] = len(unique)
        out["user_closures"] = user
        out["inter_session_lc"] = inter
        out["neighbor"] = int(
            con.execute("SELECT COUNT(*) FROM Link WHERE type IN (0,5);").fetchone()[0]
        )
    finally:
        con.close()
    return out


def pose_count_from_status_or_db(status_obj: dict[str, Any], db_path: Path) -> int:
    poses = status_obj.get("poses")
    if isinstance(poses, int) and poses > 0:
        return poses
    return sqlite_int(
        db_path,
        "SELECT COUNT(*) FROM Node;",
        0,
    )


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    return json.loads(path.read_text())


def main() -> int:
    print("=== APP <-> SERVER CollabSync protocol test ===", flush=True)
    print(f"server_bin={SERVER_BIN}", flush=True)
    print(f"fixtures={FIXTURE_DIR}", flush=True)
    print(f"work={WORK}", flush=True)

    live = http("GET", "http://127.0.0.1:8080/status", timeout=5)
    live_body = live[2].decode("utf-8", "replace")[:240]
    check(
        live[0] == 200 and '"ok":true' in live_body,
        "live :8080 GET /status only (untouched)",
        live_body,
    )

    if not SERVER_BIN.is_file():
        check(False, "temp server binary exists", str(SERVER_BIN))
        return 1

    needed = [
        FIXTURE_DIR / "client0_d1.db",
        FIXTURE_DIR / "client0_d2.db",
        FIXTURE_DIR / "client1_d1.db",
        FIXTURE_DIR / "client1_d2.db",
    ]
    if not all(p.is_file() for p in needed):
        print("Existing merge-test fixtures missing; extract from collab-data.", flush=True)
        return 2

    a_d1, a_d2 = needed[0], needed[1]
    b_d1, b_d2 = needed[2], needed[3]
    print(
        f"A={CLIENT_A} chunks {a_d1.name} nodes={sqlite_int(a_d1, 'SELECT COUNT(*) FROM Node;')} "
        f"+ {a_d2.name} nodes={sqlite_int(a_d2, 'SELECT COUNT(*) FROM Node;')}",
        flush=True,
    )
    print(
        f"B={CLIENT_B} chunks {b_d1.name} nodes={sqlite_int(b_d1, 'SELECT COUNT(*) FROM Node;')} "
        f"+ {b_d2.name} nodes={sqlite_int(b_d2, 'SELECT COUNT(*) FROM Node;')}",
        flush=True,
    )

    if WORK.exists():
        shutil.rmtree(WORK)
    ROOM.mkdir(parents=True)

    port = find_free_port(PORT)
    if port == 8080:
        check(False, "refusing to bind :8080", "")
        return 2
    log_path = WORK / "server.log"
    log_f = open(log_path, "w")
    proc = subprocess.Popen(
        [str(SERVER_BIN), "--port", str(port), "--data", str(ROOM)],
        stdout=log_f,
        stderr=subprocess.STDOUT,
        cwd=str(REPO),
    )
    print(f"temp server pid={proc.pid} port={port} data={ROOM}", flush=True)
    try:
        if not wait_listen(port, 12):
            check(False, "temp server listen", f"port={port} log={log_path}")
            return 1
        check(True, "temp server listen", f"127.0.0.1:{port} pid={proc.pid}")

        base = f"http://127.0.0.1:{port}"
        a = Device(CLIENT_A)
        b = Device(CLIENT_B)
        ca = CollabClient(base, a)
        cb = CollabClient(base, b)

        # 1) Device A joins empty room.
        st, join_a = ca.join()
        check(
            st == 200 and join_a.get("ok") is True and join_a.get("mode") == "new",
            "A POST /join mode=new",
            json.dumps(join_a)[:240],
        )

        # 2) A uploads first 2s-sized chunk, then pull (CollabSync syncOnce).
        st, sync_a1 = ca.sync(a_d1)
        check(
            st == 200 and sync_a1.get("ok") is True and int(sync_a1.get("accepted") or 0) > 0,
            "A POST /sync d1 HTTP 200",
            json.dumps(sync_a1)[:240],
        )
        pull_a = ca.pull()
        check(pull_a.status == 200, "A GET /pull after A d1 HTTP 200",
              f"nodes={pull_a.nodes} max_id={pull_a.max_id} aligned={pull_a.aligned}")

        # 3) Keep A active, then B joins.
        hb = ca.heartbeat()
        check(hb == 200, "A POST /heartbeat HTTP 200", f"status={hb}")

        st, join_b = cb.join()
        # A joiner never loads the room map into its own session: its local map
        # is its own scan, other users arrive via /pull in the tag frame.
        check(
            st == 200
            and join_b.get("ok") is True
            and join_b.get("mode") == "join"
            and join_b.get("must_download") is False,
            "B POST /join mode=join must_download=false",
            json.dumps(join_b)[:240],
        )

        # The merged map is still downloadable (used by stop/save on the phone).
        map_path = WORK / "b-map.db"
        st, nbytes = cb.map_db(map_path)
        map_is_sqlite = map_path.exists() and is_sqlite(map_path.read_bytes()[:16])
        check(
            st == 200 and nbytes > 0 and map_is_sqlite,
            "B GET /map.db HTTP 200 sqlite (stop/save download)",
            f"bytes={nbytes} lastNodeId={last_node_id(map_path) if map_path.exists() else 0}",
        )
        # CollabSync.resetForNewScan: lastSyncedId = lastPulledGlobalId = 0, so the
        # first pull returns everything A has uploaded so far.
        b.last_synced_id = 0
        b.last_pulled_global_id = 0

        pull_b = cb.pull()
        check(pull_b.status == 200, "B GET /pull after join HTTP 200",
              f"nodes={pull_b.nodes} max_id={pull_b.max_id} since=0")
        check(
            pull_b.nodes > 0 and int(sync_a1.get("accepted") or 0) == pull_b.nodes,
            "B first /pull receives all of A's nodes so far",
            f"X-Nodes-Count={pull_b.nodes} A_accepted={sync_a1.get('accepted')}",
        )

        session_after_a1 = load_state(ROOM / "clients.json").get("clients", {}).get(CLIENT_A, {}).get("session_map_id", -999)

        # 4) A continues mapping (second chunk). B must receive those nodes via /pull.
        st, sync_a2 = ca.sync(a_d2)
        check(
            st == 200 and sync_a2.get("ok") is True and int(sync_a2.get("accepted") or 0) > 0,
            "A POST /sync d2 HTTP 200 (same client continuation)",
            json.dumps(sync_a2)[:240],
        )
        pull_a = ca.pull()
        check(pull_a.status == 200, "A GET /pull after A d2 HTTP 200",
              f"nodes={pull_a.nodes} max_id={pull_a.max_id}")
        pull_b = cb.pull()
        check(pull_b.status == 200, "B GET /pull after A d2 HTTP 200",
              f"nodes={pull_b.nodes} max_id={pull_b.max_id} aligned={pull_b.aligned} xf={pull_b.transform[:40]}")
        check(
            pull_b.nodes > 0,
            "After A syncs, B /pull X-Nodes-Count > 0 (A's new nodes)",
            f"X-Nodes-Count={pull_b.nodes} max_id={pull_b.max_id} sqlite={int(pull_b.sqlite)}",
        )

        session_after_a2 = load_state(ROOM / "clients.json").get("clients", {}).get(CLIENT_A, {}).get("session_map_id", -999)
        check(
            session_after_a1 is not None
            and session_after_a1 == session_after_a2
            and int(session_after_a2) >= 0,
            "Same-client later /sync does not create orphan map_id",
            f"session_after_d1={session_after_a1} session_after_d2={session_after_a2}",
        )

        # 5) B uploads its own deltas; A must receive them.
        # Late joiner lastSyncedId is map lastNodeId (~A's current last local/global).
        # B fixture local ids are 106+. export would send id > lastSyncedId.
        # POST the fixture with X-Since-Id = B.last_synced_id (CollabSync).
        st, sync_b1 = cb.sync(b_d1)
        check(
            st == 200 and sync_b1.get("ok") is True and int(sync_b1.get("accepted") or 0) > 0,
            "B POST /sync d1 HTTP 200",
            json.dumps(sync_b1)[:240],
        )
        pull_b = cb.pull()
        check(pull_b.status == 200, "B GET /pull after B d1 HTTP 200",
              f"nodes={pull_b.nodes} max_id={pull_b.max_id}")
        pull_a = ca.pull()
        check(pull_a.status == 200, "A GET /pull after B d1 HTTP 200",
              f"nodes={pull_a.nodes} max_id={pull_a.max_id} aligned={pull_a.aligned} xf={pull_a.transform[:40]}")
        a_got_b = pull_a.nodes > 0
        check(
            a_got_b,
            "After B syncs, A /pull X-Nodes-Count > 0 (B's nodes)",
            f"X-Nodes-Count={pull_a.nodes} max_id={pull_a.max_id} sqlite={int(pull_a.sqlite)}",
        )

        session_b1 = load_state(ROOM / "clients.json").get("clients", {}).get(CLIENT_B, {}).get("session_map_id", -999)
        st, sync_b2 = cb.sync(b_d2)
        check(
            st == 200 and sync_b2.get("ok") is True and int(sync_b2.get("accepted") or 0) > 0,
            "B POST /sync d2 HTTP 200",
            json.dumps(sync_b2)[:240],
        )
        pull_b = cb.pull()
        check(pull_b.status == 200, "B GET /pull after B d2 HTTP 200",
              f"nodes={pull_b.nodes} max_id={pull_b.max_id}")
        pull_a = ca.pull()
        check(pull_a.status == 200, "A GET /pull after B d2 HTTP 200",
              f"nodes={pull_a.nodes} max_id={pull_a.max_id}")
        if not a_got_b:
            check(
                pull_a.nodes > 0,
                "After B d2, A /pull X-Nodes-Count > 0 (retry)",
                f"X-Nodes-Count={pull_a.nodes}",
            )
        session_b2 = load_state(ROOM / "clients.json").get("clients", {}).get(CLIENT_B, {}).get("session_map_id", -999)
        check(
            session_b1 == session_b2 and int(session_b2) >= 0,
            "B later /sync keeps same session_map_id",
            f"after_d1={session_b1} after_d2={session_b2}",
        )

        st, _, status_body = http("GET", f"{base}/status", timeout=15)
        status_obj: dict[str, Any] = {}
        try:
            status_obj = json.loads(status_body.decode("utf-8", "replace"))
        except json.JSONDecodeError:
            status_obj = {}
        check(st == 200 and status_obj.get("ok") is True, "GET /status HTTP 200", json.dumps(status_obj)[:280])
        ids = {c.get("id") for c in status_obj.get("clients", [])}
        check(
            CLIENT_A in ids and CLIENT_B in ids,
            "/status has both clients",
            f"clients={sorted(ids)}",
        )
        global_nodes = int(status_obj.get("global_nodes") or 0)
        a_nodes = next((c.get("nodes") for c in status_obj.get("clients", []) if c.get("id") == CLIENT_A), 0)
        b_nodes = next((c.get("nodes") for c in status_obj.get("clients", []) if c.get("id") == CLIENT_B), 0)
        expected = int(a_nodes or 0) + int(b_nodes or 0)
        check(
            global_nodes >= expected - 2 and global_nodes > 0 and expected > 0,
            "/status global_nodes = A+B (or close)",
            f"global_nodes={global_nodes} A={a_nodes} B={b_nodes} sum={expected} poses={status_obj.get('poses')} lc={status_obj.get('loop_closures')}",
        )
        poses = int(status_obj.get("poses") or 0)
        check(
            poses > 0 and poses >= global_nodes - 2,
            "poses persist",
            f"poses={poses} global_nodes={global_nodes}",
        )

        global_db = ROOM / "global.db"
        graph = inspect_graph(global_db)
        check(
            graph["nodes"] >= expected - 2 and len(graph["maps"]) >= 1,
            "Merge: both node sets in one global.db",
            f"nodes={graph['nodes']} maps={graph['maps']} neighbor={graph['neighbor']} "
            f"lc={graph['loop_closures']} inter_session_lc={graph['inter_session_lc']} "
            f"user={graph['user_closures']}",
        )
        maps = graph["maps"]
        check(
            len(maps) == 2,
            "Exactly two session maps (one per client, no orphan)",
            f"map_ids={maps}",
        )

        state = load_state(ROOM / "clients.json")
        aligned_flag = bool(state.get("last_ingest_aligned"))
        last_aligned_hdr = (a.last_pull.aligned if a.last_pull else "?")
        print("\n--- merge report ---", flush=True)
        print(f"aligned_flag={int(aligned_flag)} last_pull_X-Aligned={last_aligned_hdr}", flush=True)
        print(f"status_loop_closures={status_obj.get('loop_closures')} graph_lc={graph['loop_closures']}", flush=True)
        print(f"inter_session_lc={graph['inter_session_lc']} user_closures={graph['user_closures']}", flush=True)
        print(f"map_ids={maps}", flush=True)
        if graph["inter_session_lc"] > 0:
            check(True, "Merge aligned (cross-map Link rows exist)",
                  f"inter_session_lc={graph['inter_session_lc']}")
        elif aligned_flag:
            check(True, "Merge report: aligned flag without proven visual LC",
                  "last_ingest_aligned=1 but no cross-map Link rows")
        else:
            check(True, "Merge report: not aligned (mechanical graph still valid)",
                  "no inter-session LC and last_ingest_aligned=0")

        # Confirm we never wrote the live data dir from this process.
        check(
            Path(ROOM).resolve() != (SOURCE_DIR).resolve(),
            "temp room is not live collab-data",
            f"room={ROOM}",
        )

    finally:
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=3)
        log_f.close()
        print(f"temp server stopped pid={proc.pid}", flush=True)

    passed = sum(1 for r in results if r.ok)
    failed = sum(1 for r in results if not r.ok)
    print("\n=== summary ===", flush=True)
    print(f"pass={passed} fail={failed}", flush=True)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
