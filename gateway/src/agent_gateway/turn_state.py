"""Bounded, upstream-issued routing state; no caller chooses account identity."""
from collections import OrderedDict

HEADER = "x-codex-turn-state"
MAX_STATE = 4096
MAX_TURNS = 1024


def bounded(value, limit):
    return isinstance(value, str) and 0 < len(value) <= limit and all(32 <= ord(c) < 127 for c in value)


class TurnStates:
    def __init__(self):
        self.entries = OrderedDict()

    def request(self, session, account, doc, supplied):
        metadata = doc.get("client_metadata", {})
        turn = metadata.get("turn_id") if isinstance(metadata, dict) else None
        if not bounded(turn, 128):
            self.entries.pop(session, None)
            if supplied is not None:
                raise ValueError("turn-state-invalid")
            return None
        key = (account, turn)
        previous = self.entries.get(session)
        if previous is None or previous[0] != key:
            self.entries[session] = (key, None)
        self.entries.move_to_end(session)
        while len(self.entries) > MAX_TURNS:
            self.entries.popitem(last=False)
        stored = self.entries[session][1]
        if supplied is not None and (not bounded(supplied, MAX_STATE) or supplied != stored):
            raise ValueError("turn-state-invalid")
        return key

    def response(self, session, key, value):
        if key is None or not bounded(value, MAX_STATE):
            return None
        current = self.entries.get(session)
        if current is None or current[0] != key:
            return None
        if current[1] is None:
            self.entries[session] = (key, value)
        return self.entries[session][1]
