"""opn_settings_plan — compare an OPNsense MVC settings page (its `get` response) with the values
the role pins, and build the minimal `set` body. Used by roles/opnsense-system (FU-297).

A `get` response renders a select field as options with a `selected` flag — a dict keyed by the
stored value (`{"lan": {"value": "LAN", "selected": 1}, ...}`) or, for some core pages, a list
whose INDEX is the stored value. Plain fields are strings. The pinned values (`want`) are nested
dicts of strings, or lists for multi-selects (compared as sets; order is not config).

Multi-select entries the box does not offer (an interface the hardware lacks) are dropped from
the body and reported, never posted: the API would reject the whole page. The drill's realism
score still counts the difference, which is where it belongs.
"""


def _is_opts(v):
    if isinstance(v, dict):
        return bool(v) and all(isinstance(o, dict) and "selected" in o for o in v.values())
    if isinstance(v, list):
        return bool(v) and all(isinstance(o, dict) and "selected" in o for o in v)
    return False


def _selected(v):
    items = v.items() if isinstance(v, dict) else enumerate(v)
    return [str(k) for k, o in items if str(o.get("selected", 0)) == "1"]


def _walk(cur, want, path, out):
    body = {}
    for k, w in want.items():
        c = (cur or {}).get(k) if isinstance(cur, dict) else None
        p = f"{path}.{k}" if path else k
        if isinstance(w, dict):
            sub = _walk(c, w, p, out)
            if sub:
                body[k] = sub
            continue
        if isinstance(w, list):
            offered = set(str(x) for x in (c.keys() if isinstance(c, dict) else range(len(c or []))))
            keep = [str(x) for x in w if not _is_opts(c) or str(x) in offered]
            out["unavailable"] += [f"{p}={x}" for x in w if str(x) not in keep]
            have = set(_selected(c)) if _is_opts(c) else set(filter(None, str(c or "").split(",")))
            if have != set(keep):
                out["drift"].append(p)
                body[k] = ",".join(keep)
            continue
        have = ",".join(_selected(c)) if _is_opts(c) else ("" if c is None else str(c))
        if have != str(w):
            out["drift"].append(p)
            body[k] = str(w)
    return body


def opn_settings_plan(current, want):
    """current: the page's `get` response under its root key; want: the pinned values.
    -> {"drift": [dotted keys that differ], "data": the set body (drifted keys only),
        "unavailable": [multi-select entries this box does not offer]}"""
    out = {"drift": [], "unavailable": []}
    out["data"] = _walk(current, want, "", out)
    return out


class FilterModule(object):
    def filters(self):
        return {"opn_settings_plan": opn_settings_plan}
