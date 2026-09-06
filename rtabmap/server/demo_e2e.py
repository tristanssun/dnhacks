#!/usr/bin/env python3
"""End-to-end demo of the collab start-tag lock and live map.

Starts a TEMP server on a free port with an empty data dir. Does not touch
the live LaunchAgent collab-data directory.
"""

from __future__ import annotations

import json
import os
import re
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from typing import Any

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SERVER_BIN = os.path.join(REPO, "build", "bin", "rtabmap-collab-server")
TAG_ID = 0
TAG_SIZE_M = 0.20

PASS = 0
FAIL = 0


def check(cond: bool, name: str, detail: str = "") -> bool:
    global PASS, FAIL
    if cond:
        PASS += 1
        line = f"PASS  {name}"
    else:
        FAIL += 1
        line = f"FAIL  {name}"
    if detail:
        line += f"  ({detail})"
    print(line, flush=True)
    return cond


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def http(
    method: str,
    url: str,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
    timeout: float = 20.0,
) -> tuple[int, dict[str, str], bytes]:
    req = urllib.request.Request(url, data=body, method=method)
    if headers:
        for k, v in headers.items():
            req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.getcode(), {k.lower(): v for k, v in resp.headers.items()}, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()


def http_json(method: str, url: str, payload: Any = None, client: str = "", timeout: float = 20.0) -> dict[str, Any]:
    body = None
    headers = {"Accept": "application/json"}
    if client:
        headers["X-Client-Id"] = client
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    status, _hdrs, raw = http(method, url, body, headers, timeout=timeout)
    try:
        obj = json.loads(raw.decode("utf-8") or "{}")
    except json.JSONDecodeError:
        obj = {"_raw": raw.decode("utf-8", "replace")}
    if isinstance(obj, dict):
        obj["_http"] = status
    return obj if isinstance(obj, dict) else {"_http": status}


def wait_up(base: str, timeout: float = 15.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            status, _, _ = http("GET", base + "/demo", timeout=1.5)
            if status == 200:
                return True
        except Exception:
            time.sleep(0.15)
    return False


def pose(tag_id: int = TAG_ID, tx: float = 0.05, ty: float = 0.0, tz: float = 0.45, detected: bool = True) -> dict[str, Any]:
    return {
        "tag_id": tag_id,
        "detected": detected,
        "tx": tx,
        "ty": ty,
        "tz": tz,
        "qx": 0.0,
        "qy": 0.0,
        "qz": 0.0,
        "qw": 1.0,
    }


def should_show_tag(demo: dict[str, Any]) -> bool:
    return demo.get("show_tag") is True and demo.get("locked") is not True


def write_delta(path: str, local_id: int, x: float, y: float, z: float) -> bool:
    cmd = [
        SERVER_BIN,
        "--write-delta",
        path,
        "--delta-id",
        str(local_id),
        "--delta-x",
        str(x),
        "--delta-y",
        str(y),
        "--delta-z",
        str(z),
    ]
    rc = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    if rc.returncode != 0:
        print(rc.stdout)
        print(rc.stderr, file=sys.stderr)
        return False
    return os.path.isfile(path) and os.path.getsize(path) > 100


def sync_delta(base: str, client: str, path: str, since_id: int = 0) -> dict[str, Any]:
    with open(path, "rb") as f:
        body = f.read()
    headers = {
        "X-Client-Id": client,
        "X-Since-Id": str(since_id),
        "Content-Type": "application/octet-stream",
    }
    status, _hdrs, raw = http("POST", base + "/sync", body, headers, timeout=60.0)
    try:
        obj = json.loads(raw.decode("utf-8") or "{}")
    except json.JSONDecodeError:
        obj = {}
    obj["_http"] = status
    return obj


def pull(base: str, client: str, since: int = 0) -> tuple[dict[str, str], bytes]:
    status, hdrs, raw = http(
        "GET",
        f"{base}/pull?since_global_id={since}",
        headers={"X-Client-Id": client, "X-Since-Global-Id": str(since)},
        timeout=30.0,
    )
    hdrs["_http"] = str(status)
    return hdrs, raw


def main() -> int:
    if not os.path.isfile(SERVER_BIN):
        print(f"missing server binary: {SERVER_BIN}", file=sys.stderr)
        print("Build with: cmake --build build --target rtabmap-collab-server", file=sys.stderr)
        return 2

    port = free_port()
    work = tempfile.mkdtemp(prefix="rtabmap-demo-e2e-")
    leftover = os.path.join(work, "clients.json")
    now = int(time.time())
    with open(leftover, "w", encoding="utf-8") as f:
        json.dump(
            {
                "next_global_id": 10,
                "next_map_id_base": 2,
                "global_nodes": 8,
                "room_locked": True,
                "locked_tag_id": 0,
                "clients": {
                    "85998EDD-LEFTOVER": {
                        "last_seen": now,
                        "calibrated": True,
                        "tag_id": 0,
                    },
                    "ED4D51E2-LEFTOVER": {
                        "last_seen": now,
                        "calibrated": True,
                        "tag_id": 0,
                    },
                },
            },
            f,
        )
    log_path = os.path.join(work, "server.log")
    print(f"temp server port={port} data={work}", flush=True)
    logf = open(log_path, "w")
    proc = subprocess.Popen(
        [SERVER_BIN, "--port", str(port), "--data", work],
        cwd=REPO,
        stdout=logf,
        stderr=subprocess.STDOUT,
    )
    base = f"http://127.0.0.1:{port}"
    try:
        if not wait_up(base):
            check(False, "server_up", f"no /demo on {base}")
            return 1
        check(True, "server_up", base)

        status, _hdrs, html = http("GET", base + "/")
        page = html.decode("utf-8", "replace")
        check(status == 200, "GET / html", f"status={status}")
        check("/tag.png" in page and "calib-tag" in page, "admin contains tag png")
        check("shouldShowTag" in page, "admin JS hide helper present")
        check("reset-btn" in page and "/reset" in page, "admin Reset button present")
        check("hideTagFromDom" not in page, "admin keeps tag in DOM")
        check(f"{TAG_SIZE_M:.2f}" in page or "0.20" in page, "admin documents tag size")
        check("Mesh refreshes every" not in page, "admin does not advertise 10s bake")
        check("organizedFastMesh" in page, "admin documents live organizedFastMesh")
        check("map.mesh?live=1" not in page, "admin does not fall back to bake then live")
        check("setInterval(poll, 250)" in page, "admin polls /demo at 250ms")

        admin_status, _, admin_html = http("GET", base + "/admin")
        check(admin_status == 200 and b"calib-tag" in admin_html, "GET /admin")

        demo = http_json("GET", base + "/demo")
        check(demo.get("_http") == 200, "GET /demo")
        check(demo.get("show_tag") is True, "show_tag true before lock")
        check(demo.get("locked") is False, "locked false before lock")
        check(demo.get("calibrated_count") == 0, "leftover calibrated ignored")
        check(demo.get("tag_id") == TAG_ID, f"tag_id={demo.get('tag_id')}")
        check(abs(float(demo.get("tag_size_m", 0)) - TAG_SIZE_M) < 1e-6, "tag_size_m")
        check(should_show_tag(demo), "shouldShowTag(demo) true at start")
        check(len(demo.get("calibrated") or []) == 0, "leftover lock clients not shown")

        bad = http_json("POST", base + "/calibrate", {"tag_id": 99, "detected": True, "tx": 0, "ty": 0, "tz": 0.4, "qx": 0, "qy": 0, "qz": 0, "qw": 1}, "sim-a")
        check(bad.get("ok") is False and bad.get("_http") == 400, "reject bad tag_id")
        missing = http_json("POST", base + "/calibrate", {"tag_id": 0, "tx": 0, "ty": 0, "tz": 0.4, "qx": 0, "qy": 0, "qz": 0, "qw": 1}, "sim-a")
        check(missing.get("ok") is False and missing.get("_http") == 400, "reject missing detected")
        fake = http_json("POST", base + "/calibrate", pose(detected=False), "sim-a")
        check(fake.get("ok") is False and fake.get("_http") == 400, "reject detected=false")

        join_a = http_json("POST", base + "/join", {}, "sim-a")
        check(join_a.get("ok") is True, "join sim-a")
        check(join_a.get("must_wait_for_lock") is True, "join must_wait_for_lock")
        check(join_a.get("locked") is False and join_a.get("show_tag") is True, "join not locked")

        cal_a = http_json("POST", base + "/calibrate", pose(tx=0.04, tz=0.42), "sim-a")
        check(cal_a.get("ok") is True, "calibrate A")
        demo = http_json("GET", base + "/demo")
        check(demo.get("locked") is False, "still unlocked after A")
        check(demo.get("show_tag") is True, "tag still shown after A")
        check(int(demo.get("calibrated_count") or 0) == 1, f"calibrated_count={demo.get('calibrated_count')}")
        check(should_show_tag(demo), "shouldShowTag true with one phone")

        cal_b = http_json("POST", base + "/calibrate", pose(tx=-0.03, tz=0.40), "sim-b")
        check(cal_b.get("ok") is True, "calibrate B")
        check(cal_b.get("locked") is True, "calibrate B locks room")
        check(cal_b.get("show_tag") is False, "show_tag false after lock")
        demo = http_json("GET", base + "/demo")
        check(demo.get("locked") is True, "GET /demo locked")
        check(demo.get("mesh_kind") == "live", "demo mesh_kind live")
        pose_live = http_json("POST", base + "/pose", {
            "tx": 0.20, "ty": 0.05, "tz": 0.80,
            "qx": 0.0, "qy": 0.2588, "qz": 0.0, "qw": 0.9659,
        }, "sim-a")
        check(pose_live.get("ok") is True, "POST /pose after lock")
        demo = http_json("GET", base + "/demo")
        clients = demo.get("clients") or []
        a = next((c for c in clients if c.get("id") == "sim-a"), None)
        check(a is not None, "demo has sim-a after /pose")
        if a:
            check(abs(float(a.get("qx", 0))) + abs(float(a.get("qy", 0))) + abs(float(a.get("qz", 0))) + abs(float(a.get("qw", 0))) > 0.5, "pose quat present")
            check("yaw" in a, "pose yaw present")
        mesh_status, mesh_hdrs, _ = http("GET", base + "/map.mesh")
        check(mesh_status == 200, "GET /map.mesh")
        check((mesh_hdrs.get("x-mesh-kind") or "") == "live", f"X-Mesh-Kind={mesh_hdrs.get('x-mesh-kind')}")
        check(demo.get("show_tag") is False, "GET /demo show_tag false")
        check(demo.get("show_tag") is False and demo.get("locked") is True, "show_tag false iff locked")
        check(not should_show_tag(demo), "JS shouldShowTag hides tag")
        check(int(demo.get("calibrated_count") or 0) >= 2, "calibrated_count >= 2")

        join_b = http_json("POST", base + "/join", {}, "sim-b")
        check(join_b.get("locked") is True and join_b.get("must_wait_for_lock") is False, "join after lock allows mapping")

        # Stay locked if A walks away (no new calibrate, just heartbeat).
        hb = http_json("POST", base + "/heartbeat", {}, "sim-a")
        demo = http_json("GET", base + "/demo")
        check(demo.get("locked") is True and demo.get("show_tag") is False, "stay locked after walk-away heartbeat")

        reset_mid = http_json("POST", base + "/reset", {})
        check(reset_mid.get("ok") is True, "POST /reset after first lock")
        demo_reset = http_json("GET", base + "/demo")
        check(demo_reset.get("locked") is False and demo_reset.get("show_tag") is True, "reset unlocks")
        check(demo_reset.get("calibrated_count") == 0, "reset calibrated_count 0")
        http_json("POST", base + "/join", {}, "sim-a")
        http_json("POST", base + "/calibrate", pose(tx=0.04, tz=0.42), "sim-a")
        http_json("POST", base + "/calibrate", pose(tx=-0.03, tz=0.40), "sim-b")

        delta_a = os.path.join(work, "delta-a.db")
        delta_b = os.path.join(work, "delta-b.db")
        made_a = write_delta(delta_a, 1, 0.25, 0.0, 0.10)
        made_b = write_delta(delta_b, 1, -0.20, 0.0, 0.18)
        check(made_a and made_b, "write demo deltas")

        # Mapping + lag: A syncs, B pulls immediately, /demo trail grows.
        lags_pull: list[float] = []
        lags_demo: list[float] = []
        demo_before = http_json("GET", base + "/demo")
        trail_a0 = 0
        for c in demo_before.get("clients") or []:
            if c.get("id") == "sim-a":
                trail_a0 = len(c.get("trail") or [])

        t0 = time.perf_counter()
        sync_a = sync_delta(base, "sim-a", delta_a, 0)
        check(sync_a.get("ok") is True and sync_a.get("_http") == 200, "POST /sync A", str(sync_a.get("accepted")))
        hdrs, raw = pull(base, "sim-b", 0)
        pull_ms = (time.perf_counter() - t0) * 1000.0
        lags_pull.append(pull_ms)
        nodes = int(hdrs.get("x-nodes-count") or 0)
        check(hdrs.get("_http") == "200", "GET /pull B after A sync")
        check(nodes > 0 or sync_a.get("accepted", 0) == 0, f"pull saw nodes={nodes} bytes={len(raw)}")

        t1 = time.perf_counter()
        demo = http_json("GET", base + "/demo")
        demo_ms = (time.perf_counter() - t1) * 1000.0
        lags_demo.append(demo_ms + pull_ms)
        trail_a1 = 0
        for c in demo.get("clients") or []:
            if c.get("id") == "sim-a":
                trail_a1 = len(c.get("trail") or [])
        check(trail_a1 >= trail_a0, f"A trail grew {trail_a0} -> {trail_a1}")

        t0 = time.perf_counter()
        sync_b = sync_delta(base, "sim-b", delta_b, 0)
        check(sync_b.get("ok") is True and sync_b.get("_http") == 200, "POST /sync B", str(sync_b.get("accepted")))
        hdrs, raw = pull(base, "sim-a", 0)
        pull_ms = (time.perf_counter() - t0) * 1000.0
        lags_pull.append(pull_ms)
        demo = http_json("GET", base + "/demo")
        demo_ms = (time.perf_counter() - t0) * 1000.0
        lags_demo.append(demo_ms)
        nodes = int(hdrs.get("x-nodes-count") or 0)
        check(hdrs.get("_http") == "200", "GET /pull A after B sync")
        check(nodes > 0 or sync_b.get("accepted", 0) == 0, f"pull A saw nodes={nodes}")
        trails = 0
        for c in demo.get("clients") or []:
            trails += len(c.get("trail") or [])
        check(trails >= 2, f"demo trails total points={trails}")

        def pct(values: list[float], p: float) -> float:
            if not values:
                return 0.0
            s = sorted(values)
            k = min(len(s) - 1, max(0, int(round((p / 100.0) * (len(s) - 1)))))
            return s[k]

        extra_pulls = []
        for i in range(6):
            extra = os.path.join(work, f"delta-lag-{i}.db")
            if not write_delta(extra, 2 + i, 0.3 + 0.05 * i, 0.0, 0.12 + 0.03 * i):
                continue
            t0 = time.perf_counter()
            sync_delta(base, "sim-a", extra, 0)
            pull(base, "sim-b", 0)
            extra_pulls.append((time.perf_counter() - t0) * 1000.0)
            http_json("GET", base + "/demo")
        lags_pull.extend(extra_pulls)
        p50 = statistics.median(lags_pull) if lags_pull else 0.0
        p95 = pct(lags_pull, 95)
        print(f"LAG   pull p50={p50:.1f}ms p95={p95:.1f}ms n={len(lags_pull)}", flush=True)
        print(f"LAG   demo-after-sync p50={statistics.median(lags_demo):.1f}ms n={len(lags_demo)}", flush=True)
        check(p95 < 5000.0, "lag p95 under 5s", f"p95={p95:.1f}ms")
        check(p50 < 3000.0, "lag p50 under 3s", f"p50={p50:.1f}ms")

        # 10x lock reliability with pose noise.
        locks = 0
        hides = 0
        for i in range(10):
            reset = http_json("POST", base + "/reset", {})
            if reset.get("ok") is not True:
                continue
            a = f"sim-a-{i}"
            b = f"sim-b-{i}"
            http_json("POST", base + "/join", {}, a)
            noise = 0.01 * (i + 1)
            r1 = http_json("POST", base + "/calibrate", pose(tx=0.02 + noise, tz=0.40 + noise), a)
            demo1 = http_json("GET", base + "/demo")
            if demo1.get("locked") is True or demo1.get("show_tag") is not True:
                check(False, f"lock-repeat {i+1} early lock", str(demo1.get("calibrated_count")))
                continue
            r2 = http_json("POST", base + "/calibrate", pose(tx=-0.02 - noise, tz=0.41 + noise * 0.5), b)
            demo2 = http_json("GET", base + "/demo")
            if r2.get("locked") is True and demo2.get("locked") is True and demo2.get("show_tag") is False:
                locks += 1
                hides += 1
        check(locks == 10, "10/10 lock with pose noise", f"{locks}/10")
        check(hides == 10, "10/10 hide tag after lock", f"{hides}/10")

        admin_reset_status, _, admin_reset_html = http("GET", base + "/admin?reset=1")
        check(admin_reset_status == 200 and b"calib-tag" in admin_reset_html, "GET /admin?reset=1")
        demo = http_json("GET", base + "/demo")
        check(demo.get("locked") is False and demo.get("show_tag") is True, "admin?reset=1 unlocks")
        check(demo.get("calibrated_count") == 0, "admin?reset=1 calibrated_count 0")

        # Unit-test the admin JS condition against the last /demo.
        demo = http_json("GET", base + "/demo")
        js_match = re.search(r"function shouldShowTag\(demo\) \{\s*return demo\.show_tag === true && demo\.locked !== true;\s*\}", page)
        check(js_match is not None, "admin JS hide condition")
        check(should_show_tag(demo) is True, "condition shows tag after reset")

    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        logf.close()

    print(f"\nRESULT  pass={PASS} fail={FAIL}", flush=True)
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
