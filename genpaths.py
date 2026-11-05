"""Super JinX: per-install secret paths.
Every fork / every deploy gets its own random config paths on first boot (saved on the volume),
so no two panels share the same paths. Old installs keep their paths so existing configs never break.
Location services (JINX_MODE=node) get the panel's paths from JINX_CODE, so the same configs work there too."""
import json, os, re, secrets, uuid

DATA = os.getenv("JINX_DATA", "/var/lib/pasarguard")
OUT_JSON = f"{DATA}/paths.json"
OUT_INC = f"{DATA}/inbounds.inc"
# tag -> (local port, path prefix)
SLOTS = {"JX-VLESS-WS-1": (10001, "/ws/"), "JX-VLESS-WS-2": (10002, "/stream/"),
         "JX-TROJAN-WS": (10003, "/live/"), "JX-VMESS-WS": (10004, "/gw/"), "JX-VLESS-HU": (10005, "/cdn/"),
         # clean IP twins (group "◈ JinX Phantom"): same configs, reached through a clean IP
         "JX-VLESS-WS-1-IP": (10011, "/edge/"), "JX-VLESS-WS-2-IP": (10012, "/flow/"),
         "JX-TROJAN-WS-IP": (10013, "/pulse/"), "JX-VMESS-WS-IP": (10014, "/node/"), "JX-VLESS-HU-IP": (10015, "/up/")}
BASE_TAGS = ("JX-VLESS-WS-1", "JX-VLESS-WS-2", "JX-TROJAN-WS", "JX-VMESS-WS", "JX-VLESS-HU")
# paths used by v6.0 and older: kept for panels that were already running before this version
LEGACY = {"JX-VLESS-WS-1": "/ws/7a5a21d9-60f9-4542-943e-7838b90169e1",
          "JX-VLESS-WS-2": "/stream/4868e537-9fd8-46e9-b63a-f36459d18a81",
          "JX-TROJAN-WS": "/live/b1dfa4cc-0ed6-4956-b330-8ccb51dc0828",
          "JX-VMESS-WS": "/gw/3d801b12-a333-452c-b9d5-90ece1a8d68c",
          "JX-VLESS-HU": "/cdn/cc046fa3-78ec-4619-ac8f-9d6c7a5d0755"}

def _rand(pre): return pre + str(uuid.UUID(bytes=secrets.token_bytes(16), version=4))

def _valid_path(tag, value):
    prefix = SLOTS[tag][1]
    return isinstance(value, str) and value.startswith(prefix) and re.fullmatch(re.escape(prefix) + r"[0-9a-fA-F-]{36}", value) is not None

def load():
    """Existing paths are NEVER changed; reject unsafe persisted values before nginx interpolation."""
    try:
        with open(OUT_JSON, encoding="utf-8") as f: p = json.load(f)
        if not isinstance(p, dict): raise ValueError("paths.json must contain an object")
        invalid = [t for t in p if t in SLOTS and not _valid_path(t, p[t])]
        if invalid: raise ValueError("unsafe path value(s): " + ", ".join(invalid))
        if not all(_valid_path(t, p.get(t)) for t in BASE_TAGS): return None
        added = [t for t in SLOTS if not _valid_path(t, p.get(t))]
        for t in added: p[t] = _rand(SLOTS[t][1])
        values = [p[t] for t in SLOTS]
        if len(set(values)) != len(values): raise ValueError("duplicate config paths")
        if added:
            tmp = OUT_JSON + ".tmp"
            with open(tmp, "w") as f: json.dump(p, f, indent=1)
            os.replace(tmp, OUT_JSON); print(f"[paths] {len(added)} new config path(s) added, old ones kept")
        return p
    except FileNotFoundError: return None
    except ValueError as e:
        print(f"[paths] refusing unsafe paths.json: {e}", flush=True)
        raise SystemExit(1)
    except Exception: return None

def main():
    os.makedirs(DATA, exist_ok=True)
    p = load()
    if p is None:
        if os.getenv("JINX_MODE", "panel").lower() == "node":
            print("[paths] location mode: paths missing in JINX_CODE, copy a fresh code from the panel"); raise SystemExit(1)
        if os.path.exists(f"{DATA}/.owner_initialized") or os.path.exists(f"{DATA}/db.sqlite3"):
            p = dict(LEGACY); print("[paths] existing panel detected, keeping old config paths")
            for t, (_, pre) in SLOTS.items(): p.setdefault(t, _rand(pre))
        else:
            p = {t: _rand(pre) for t, (_, pre) in SLOTS.items()}
            print("[paths] new install: unique config paths generated")
        tmp = OUT_JSON + ".tmp"
        with open(tmp, "w") as f: json.dump(p, f, indent=1)
        os.replace(tmp, OUT_JSON)
    if len(set(p[t] for t in SLOTS)) != len(SLOTS): raise SystemExit("[paths] duplicate config paths")
    lines = [f"location = {p[t]} {{ proxy_pass http://127.0.0.1:{port}; include /etc/nginx/ws.inc; }}"
             for t, (port, _) in SLOTS.items()]
    tmp_inc = OUT_INC + ".tmp"
    with open(tmp_inc, "w", encoding="utf-8") as f: f.write(chr(10).join(lines) + chr(10))
    os.replace(tmp_inc, OUT_INC)

if __name__ == "__main__":
    main()
