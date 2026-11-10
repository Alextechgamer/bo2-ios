"""Verify a private TranZit match using both clients' snapshots and stock game events."""
import argparse
import gzip
import json
from math import dist
from pathlib import Path


def verify(run):
    if not __debug__:
        raise RuntimeError("Run verification without Python optimization (-O).")
    records = [line.split("ZPAIR;", 1)[1].split(";") for line in
               (run / "match.log").read_text().splitlines() if "ZPAIR;" in line]
    def events(kind):
        return [r[1:] for r in records if r[0] == kind]
    sight, = events("sightline")
    slots = {"ios":int(sight[1]), "windows":int(sight[2])}
    with gzip.open(run / "ios.jsonl.gz", "rt") as ios, (run / "windows.jsonl").open() as win:
        streams = {name:[s for s in map(json.loads, fp) if "pos" in s]
                   for name, fp in (("ios",ios),("windows",win))}
    assert slots["ios"] != slots["windows"]
    checks = {}
    for who, peer in (("ios","windows"),("windows","ios")):
        def nearest(name, t):
            row = min(streams[name], key=lambda r:abs(r["t"]-t))
            assert abs(row["t"]-t)<=300 and row["own"]==slots[name]
            return row
        # Match timestamps from before/after the other client's movement.
        positions = []
        for label in ("photo_before","photo_after"):
            stamp, = [int(t) for t,p,a in events("cue") if (p,a)==(peer,label)]
            own = nearest(who, stamp)
            remote = nearest(peer, own["t"])["peers"][str(slots[who])]
            assert dist(own["pos"],remote)<3, (who, own["pos"], remote)
            positions.append(remote)
        moved=round(dist(*positions),1)
        assert moved>10,(who,"movement",moved)
        kill = next(r for r in events("kill") if int(r[1])==slots[who])
        assert int(kill[2]) not in slots.values() and kill[3] not in ("none","undefined","")
        assert any(a[1]==who and a[2].startswith("actor_zm_transit_basic") and a[5]==kill[2]
                   and a[6]==kill[3] and 0<=int(kill[0])-int(a[0])<3500 for a in events("aim"))
        assert any(r["pressed"] in ("fire","attack") and abs(r["t"]-int(kill[0]))<=650 for r in streams[who])
        attempt = next(r for r in events("down") if int(r[1])==slots[peer])
        revive = next(r for r in events("revived") if int(r[1])==slots[peer] and int(r[2])==slots[who] and int(r[0])>int(attempt[0]))
        use = [r for r in events("use") if int(r[1])==slots[who] and int(attempt[0])<=int(r[0])<=int(revive[0]) and r[2:4]==["1","1"]]
        assert len(use)>=2 and int(revive[3])>max(int(r[5]) for r in use)
        assert any(r["pressed"] in ("use","activate") and int(use[0][0])-150<=r["t"]<=int(use[-1][0])+150 for r in streams[who])
        assert any(r["pm"] in (7,8) and int(use[0][0])-300<=r["t"]<=int(revive[0]) for r in streams[peer])
        assert any(r["pm"]==0 and r["weapon"] and int(revive[0])<=r["t"]<=int(revive[0])+3500 for r in streams[peer])
        checks[who]={"slot":slots[who],"movement_seen_by_peer":moved,"zombie_entity":int(kill[2]),
                     "weapon":kill[3],"zombie_death_ms":int(kill[0]),"revived":peer,"revive_ms":int(revive[0])}
    return checks


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run",type=Path)
    print(json.dumps(verify(parser.parse_args().run),indent=2))
