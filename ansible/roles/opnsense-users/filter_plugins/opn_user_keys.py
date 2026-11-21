"""opn_user_keys_plan — one API user = one key pair, identical on every router node and in the
wallet. Used by roles/opnsense-users to decide, per node, what each user's key needs.

The CARP pair has no config sync (ADR-144), and `add_api_key` generates a fresh secret on the node
it is called on — so a key is minted ONCE (on `order[0]`) and the same `key|hash` line is
installed on every other node (POST auth/user/set/<uuid> with `apikeys`, the field's update-only
setter). Anything that is not "every node holds the same single key, and the wallet holds it too"
is refused before any write: a different key on two nodes, two keys on one node, a node key the
wallet lacks or contradicts. A refusal names the nodes and key prefixes; the fix is a deliberate
rotation (docs/runbook.md §OPNsense config backup), never a silent pick.

    python3 ansible/roles/opnsense-users/filter_plugins/opn_user_keys.py --self-test
"""
import re


def _short(k):
    return (k or "")[:8] + "…"


def opn_user_keys_plan(nodes, users, order, wallet=None):
    """nodes:  {host: search_api_key rows ([{username, key}, …])} — every host of the play
    users:  the user names to manage (opnsense_api_users | map(attribute='name'))
    order:  the play's hosts in inventory order; order[0] is the mint host
    wallet: {user: public key} as the wallet holds it, or None when the caller has no wallet
            (the test-VM harness) — then only the cross-node checks apply
    -> {"errors": [str], "mint_host": host, "mint": [user],
        "actions": {host: {user: {"act": "ok"|"mint"|"install", "key": str|None, "source": host}}},
        "summary": {host: "user act · …"}}
    `key` is None for an install of a key minted in this run (the role fills it from the mint)."""
    order = list(order)
    missing = [h for h in order if h not in nodes]
    if missing:
        raise ValueError("no key rows for host(s) %s — every node must be read" % ", ".join(missing))
    mint_host = order[0]
    errors, mint = [], []
    actions = {h: {} for h in order}
    for u in users:
        held = {h: [r["key"] for r in (nodes[h] or []) if r.get("username") == u] for h in order}
        multi = ["%s holds %d keys" % (h, len(ks)) for h, ks in held.items() if len(ks) > 1]
        if multi:
            errors.append("%s: %s — one user = one key pair" % (u, ", ".join(multi)))
            continue
        keys = sorted({ks[0] for ks in held.values() if ks})
        if len(keys) > 1:
            errors.append("%s: the nodes hold DIFFERENT keys (%s) — rotate deliberately, never pick one"
                          % (u, ", ".join("%s=%s" % (h, _short(ks[0]) if ks else "none")
                                          for h, ks in held.items())))
            continue
        w = None if wallet is None else (wallet.get(u) or "")
        if keys:
            k = keys[0]
            if w is not None and w != k:
                errors.append("%s: the nodes hold %s but the wallet %s — the wallet must hold the pair "
                              "a node holds" % (u, _short(k), "holds " + _short(w) if w else "holds none"))
                continue
            source = next(h for h in order if held[h])
            for h in order:
                actions[h][u] = ({"act": "ok", "key": k, "source": h} if held[h]
                                 else {"act": "install", "key": k, "source": source})
        else:
            mint.append(u)
            for h in order:
                actions[h][u] = ({"act": "mint", "key": None, "source": h} if h == mint_host
                                 else {"act": "install", "key": None, "source": mint_host})
    summary = {h: " · ".join("%s %s" % (u, a["act"] + ("" if a["act"] != "install"
                                                       else " (from %s)" % a["source"]))
                             for u, a in actions[h].items())
               for h in order}
    return {"errors": errors, "mint_host": mint_host, "mint": mint, "actions": actions,
            "summary": summary}


def opn_user_keys_installs(plan, host, minted=None):
    """The install items for one host: [{user, key, source}]. A key minted this run comes from
    `minted` ({user: public key}, the mint host's add_api_key responses)."""
    out = []
    for u, a in plan["actions"][host].items():
        if a["act"] != "install":
            continue
        key = a["key"] or (minted or {}).get(u)
        if not key:
            raise ValueError("%s: install on %s needs the key minted on %s, which this run lacks"
                             % (u, host, a["source"]))
        out.append(dict(user=u, key=key, source=a["source"]))
    return out


def opn_user_key_lines(results):
    """uri loop results over opn_user_keys_installs items, each holding a source node's config.xml
    -> [{user, key, source, line}]: the stored `key|hash` line for the item's key ('' = not found).
    The key is 80 base64 chars of 60 random bytes (unique); the hash has no `<` or whitespace."""
    out = []
    for r in results:
        i = r["item"]
        m = re.search(re.escape(i["key"]) + r"\|[^\s<]+", r.get("content") or "")
        out.append(dict(i, line=m.group(0) if m else ""))
    return out


class FilterModule:
    def filters(self):
        return {"opn_user_keys_plan": opn_user_keys_plan, "opn_user_keys_installs": opn_user_keys_installs,
                "opn_user_key_lines": opn_user_key_lines}


def _self_test():
    A, B = "opnsense-nx02", "opnsense-pve"
    row = lambda u, k: {"username": u, "key": k}
    n = 0

    def check(name, cond):
        nonlocal n
        n += 1
        if not cond:
            raise SystemExit("FAIL %s" % name)

    # The live state of 2026-11-17 (both nodes carried from prod: one shared pair per user) plus a
    # new user `firmware` nobody holds. Contract: firmware is minted once on order[0] and installed
    # on the other node with the minted key; the carried users are ok on both.
    nodes = {A: [row("root", "R"), row("automation", "AU"), row("backup-puller", "BP")],
             B: [row("root", "R"), row("automation", "AU"), row("backup-puller", "BP")]}
    users = ["backup-puller", "automation", "firmware"]
    p = opn_user_keys_plan(nodes, users, [A, B], {"automation": "AU", "backup-puller": "BP"})
    check("pair: no errors", p["errors"] == [])
    check("pair: mint once", p["mint"] == ["firmware"] and p["mint_host"] == A)
    check("pair: mint on A", p["actions"][A]["firmware"] == {"act": "mint", "key": None, "source": A})
    check("pair: install on B from A", opn_user_keys_installs(p, B, {"firmware": "FW"}) == [{"user": "firmware", "key": "FW", "source": A}])
    try:
        opn_user_keys_installs(p, B, {})
        check("pair: install without the minted key raises", False)
    except ValueError:
        check("pair: install without the minted key raises", True)
    check("pair: nothing to install on A", opn_user_keys_installs(p, A) == [])
    check("pair: carried users ok", all(p["actions"][h][u]["act"] == "ok"
                                        for h in (A, B) for u in ("automation", "backup-puller")))

    # Re-run after the fix: every node holds the wallet's key -> nothing minted, nothing installed.
    for h in (A, B):
        nodes[h].append(row("firmware", "FW"))
    p = opn_user_keys_plan(nodes, users, [A, B], {"automation": "AU", "backup-puller": "BP", "firmware": "FW"})
    check("rerun: idempotent", p["errors"] == [] and p["mint"] == []
          and all(a["act"] == "ok" for h in (A, B) for a in p["actions"][h].values()))

    # A node rebuilt without the user's key: install the held key from the node that has it.
    p = opn_user_keys_plan({A: [row("firmware", "FW")], B: []}, ["firmware"], [A, B], {"firmware": "FW"})
    check("rebuilt: install held key", p["mint"] == [] and opn_user_keys_installs(p, B) == [{"user": "firmware", "key": "FW", "source": A}])
    # …and when only the SECOND node holds it, the source is that node (never a mint on order[0]).
    p = opn_user_keys_plan({A: [], B: [row("firmware", "FW")]}, ["firmware"], [A, B], {"firmware": "FW"})
    check("rebuilt: source is the holder", opn_user_keys_installs(p, A) == [{"user": "firmware", "key": "FW", "source": B}] and p["mint"] == [])

    # The defect this guards: two nodes with DIFFERENT keys -> refused, nothing planned to mint.
    p = opn_user_keys_plan({A: [row("firmware", "K1")], B: [row("firmware", "K2")]}, ["firmware"], [A, B], {"firmware": "K1"})
    check("split: refused", len(p["errors"]) == 1 and "DIFFERENT" in p["errors"][0] and p["mint"] == [])
    # Two keys on one node -> refused.
    p = opn_user_keys_plan({A: [row("firmware", "K1"), row("firmware", "K2")], B: []}, ["firmware"], [A, B], {})
    check("multi: refused", len(p["errors"]) == 1 and "2 keys" in p["errors"][0])
    # Nodes agree but the wallet holds another key, or none -> refused (the wallet must hold the node's pair).
    p = opn_user_keys_plan({A: [row("firmware", "K1")], B: [row("firmware", "K1")]}, ["firmware"], [A, B], {"firmware": "K9"})
    check("wallet differs: refused", len(p["errors"]) == 1 and "wallet" in p["errors"][0])
    p = opn_user_keys_plan({A: [row("firmware", "K1")], B: [row("firmware", "K1")]}, ["firmware"], [A, B], {})
    check("wallet lacks: refused", len(p["errors"]) == 1 and "holds none" in p["errors"][0])
    # No wallet at all (the test-VM harness): only the cross-node checks apply.
    p = opn_user_keys_plan({A: [row("firmware", "K1")]}, ["firmware"], [A], None)
    check("no wallet: ok", p["errors"] == [] and p["actions"][A]["firmware"]["act"] == "ok")
    # A wallet pair no node holds is dead: mint (the script overwrites the wallet entries).
    p = opn_user_keys_plan({A: [], B: []}, ["firmware"], [A, B], {"firmware": "OLD"})
    check("dead wallet pair: mint", p["errors"] == [] and p["mint"] == ["firmware"])
    # Single node (the test VM): mint, nothing to install.
    p = opn_user_keys_plan({A: []}, ["automation"], [A], None)
    check("single: mint only", p["mint"] == ["automation"] and opn_user_keys_installs(p, A) == [])
    # A host of the play with no rows read is a hard error, never "holds nothing".
    try:
        opn_user_keys_plan({A: []}, ["automation"], [A, B], None)
        check("unread host raises", False)
    except ValueError:
        check("unread host raises", True)
    # The stored line, found by its key in a config.xml (the form ApiKeyField writes: one
    # `key|crypt-hash` per line inside <apikeys>); a key absent from the config yields ''.
    cfg = "<user><name>firmware</name><apikeys>K+/1=|$6$$abc./XYZ\nK2=|$6$$def</apikeys></user>"
    got = opn_user_key_lines([{"item": {"user": "firmware", "key": "K+/1=", "source": A}, "content": cfg},
                              {"item": {"user": "x", "key": "K3=", "source": A}, "content": cfg}])
    check("line: found by key", got[0]["line"] == "K+/1=|$6$$abc./XYZ")
    check("line: absent key", got[1]["line"] == "")
    print("opn_user_keys self-test: %d checks passed" % n)


if __name__ == "__main__":
    import sys
    if sys.argv[1:] == ["--self-test"]:
        _self_test()
    else:
        raise SystemExit(__doc__)
