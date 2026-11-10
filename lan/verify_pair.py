"""Cross-check both clients' rendered snapshots against the private server match log."""
import argparse
import gzip
import json
from math import dist
from pathlib import Path
import re


def closest(rows, t):
    return min(rows, key=lambda r: abs(r["t"] - t))


def peer_position(row, slot):
    if "peers" in row:
        return row["peers"][str(slot)]
    if row["peer"] and row["peer"]["n"] == slot:
        return row["peer"]["pos"]
    raise ValueError(f"No remote player {slot} in snapshot at {row['t']}")


def verify(path):
    if not __debug__:
        raise RuntimeError("Run verification without Python optimization (-O).")
    log = (path / "match.log").read_text()
    stages = re.findall(r"PAIR;stage;(\d+);(-\d+);ios=(\d+);win=(\d+)", log)
    assert len(stages) == 3 and "PAIR;both_respawned;" in log
    begin = int(stages[0][0])
    slots = {"ios": int(stages[0][2]), "windows": int(stages[0][3])}
    assert slots["ios"] != slots["windows"]
    with gzip.open(path / "ios.jsonl.gz", "rt") as ios, (path / "windows.jsonl").open() as win:
        streams = {name: [r for r in map(json.loads, f) if "pos" in r]
                   for name, f in (("ios", ios), ("windows", win))}
    result = {}
    for name, other in (("ios", "windows"), ("windows", "ios")):
        own = slots[name]
        shooter, observer = streams[name], streams[other]
        times = (1600, 5700) if name == "ios" else (6000, 10000)
        local = []
        remote = []
        for ms in times:
            r = closest(shooter, begin + ms)
            peer = closest(observer, r["t"])
            assert r["own"] == own and peer["own"] == slots[other]
            # Use the server's actual staging times. Crossing an X coordinate
            # while strafing can also change the test driver's local stage tag.
            assert begin <= min(r["t"], peer["t"]) <= max(r["t"], peer["t"]) < int(stages[1][0])
            assert abs(r["t"] - peer["t"]) <= 200 and abs(r["t"] - begin - ms) <= 200
            local.append(r["pos"])
            remote.append(peer_position(peer, own))
            assert dist(local[-1], remote[-1]) < 2
        assert dist(*remote) > 15
        # D/K record fields are victim ID/slot/team/name, then attacker ID/slot/team/name.
        hits = [m.groups() for m in re.finditer(
            r" [DK];\d+;(\d+);[^;]+;[^;]+;\d+;(\d+);[^;]+;[^;]+;([^;]+);(\d+);", log)]
        kills = re.findall(r" K;\d+;(\d+);[^;]+;[^;]+;\d+;(\d+);", log)
        assert (str(slots[other]), str(own)) in kills
        received = [r for r in observer if r["own"] == slots[other] and r["count"] > 0 and r["damage"]]
        assert received
        dead = next(r for r in observer if r["t"] >= received[0]["t"] and r["own"] == slots[other] and r["pm"] == 10)
        spawns = re.findall(r"PAIR;spawn;(\d+);(\d+);", log)
        spawn_time = min(int(t) for t, slot in spawns if int(slot) == slots[other] and int(t) > dead["t"])
        armed = next(r for r in observer if r["t"] >= spawn_time and r["own"] == slots[other] and r["pm"] == 0 and r["weapon"])
        weapon, damage = next((w, int(d)) for victim, attacker, w, d in hits
                              if victim == str(slots[other]) and attacker == str(own))
        result[name] = {"slot": own, "observed_by": other, "peer_before": remote[0],
                        "peer_after": remote[1], "peer_displacement": round(dist(*remote), 1),
                        "weapon": weapon, "hit_damage": damage, "victim_dead_ms": dead["t"],
                        "victim_spawn_ms": spawn_time, "victim_armed_ms": armed["t"]}
    return result


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("run", type=Path)
    print(json.dumps(verify(p.parse_args().run), indent=2))
