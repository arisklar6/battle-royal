"""Run the published Battle Royal rules and baseline through the training bridge."""

import json
import subprocess
import sys


process = subprocess.Popen(
    [sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
)
assert process.stdin is not None and process.stdout is not None


def request(command):
    process.stdin.write(json.dumps(command) + "\n")
    process.stdin.flush()
    return json.loads(process.stdout.readline())


try:
    observation = request({"kind": "reset", "seed": "training-full-game", "players": 1})
    assert observation["kind"] == "decision"
    assert observation["engine_seat"] in range(16)
    rejected = request({
        "kind": "step", "decision_id": observation["decision_id"],
        "response": json.dumps({"type": "action", "do": "drop", "slot": -1}),
    })
    assert rejected["kind"] == "rejected"
    decisions = 0
    while observation["kind"] == "decision":
        if decisions % 100 == 0:
            encoding = request({"kind": "encode"})
            assert encoding["decision_id"] == observation["decision_id"]
            assert len(encoding["values"]) == 357
            assert len(encoding["actions"]) == 29
            assert encoding["actions"][0] == {"type": "action", "do": "none"}
        response = request({"kind": "teacher"})["response"]
        result = request({
            "kind": "step", "decision_id": observation["decision_id"],
            "response": response,
        })
        assert result["kind"] == "accepted", result
        observation = result["observation"]
        decisions += 1
        assert decisions <= 9120
    assert observation["kind"] == "terminal"
    assert 0 <= observation["scores"]["0"] <= 25
    assert -1 <= observation["utilities"]["0"] <= 1
    print(f"complete game: {decisions} decisions, score {observation['scores']['0']}")
finally:
    process.stdin.close()
    assert process.wait() == 0
