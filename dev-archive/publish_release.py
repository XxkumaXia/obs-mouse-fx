"""Publish a release and upload both archives (CN + EN).

    python dev-archive/publish_release.py build/release-notes-vX.Y.Z.md

The version is read from obs-fx/mouse-fx.lua - the same single source of truth the
build script uses - so the tag, the release title and both asset names can never
disagree. The archive names are derived from that number, the only difference
between them being the "-en" token. Re-running is safe: an existing release for
the tag is reused and already-attached assets are skipped.

Requires a token in the git credential store for github.com (OAuth or PAT with
repo scope). The token is never printed.
"""

import io, json, os, re, subprocess, sys, urllib.parse, urllib.request, urllib.error

REPO = "XxkumaXia/obs-mouse-fx"
BODY_FILE = sys.argv[1] if len(sys.argv) > 1 else None


def version():
    text = io.open("obs-fx/mouse-fx.lua", encoding="utf-8").read()
    m = re.search(r'SCRIPT_VERSION\s*=\s*"([^"]+)"', text)
    if not m:
        sys.exit("no SCRIPT_VERSION in obs-fx/mouse-fx.lua")
    return m.group(1)


VER = version()
TAG = "v" + VER
NAME = "%s — mouse-fx" % TAG
ASSETS = ["build/obs-mouse-fx-v%s.zip" % VER, "build/obs-mouse-fx-en-v%s.zip" % VER]


def token():
    out = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True, text=True, env={**os.environ, "GCM_INTERACTIVE": "never"},
    ).stdout
    for line in out.splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1]
    sys.exit("no stored github credential")


TOKEN = token()
HDR = {
    "Authorization": "Bearer " + TOKEN,
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
}


def api(method, url, payload=None, raw=None, ctype="application/json"):
    data = raw if raw is not None else (json.dumps(payload).encode() if payload is not None else None)
    req = urllib.request.Request(url, data=data, method=method, headers={**HDR, "Content-Type": ctype})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read().decode() or "{}"), r.status
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return {}, 404
        sys.exit("%s %s -> %s %s" % (method, url, e.code, e.read().decode()[:400]))


body = io.open(BODY_FILE, encoding="utf-8").read() if BODY_FILE else ""

# existing release for the tag? reuse it instead of failing
existing, _ = api("GET", "https://api.github.com/repos/%s/releases/tags/%s" % (REPO, TAG))
if existing.get("id"):
    rel = existing
    print("release exists:", rel["html_url"])
else:
    rel, _ = api("POST", "https://api.github.com/repos/%s/releases" % REPO, {
        "tag_name": TAG,
        "name": NAME,
        "body": body,
        "draft": False,
        "prerelease": False,
    })
    print("release created:", rel["html_url"])

have = {a["name"] for a in rel.get("assets", [])}
upload_url = rel["upload_url"].split("{")[0]

for path in ASSETS:
    name = os.path.basename(path)
    if name in have:
        print("skip (already attached):", name)
        continue
    if not os.path.exists(path):
        sys.exit("missing archive: " + path + " (run dev-archive/build_en_lua.py first)")
    data = io.open(path, "rb").read()
    asset, code = api("POST", "%s?name=%s" % (upload_url, urllib.parse.quote(name)),
                      raw=data, ctype="application/zip")
    print("uploaded:", asset.get("name"), asset.get("size"), "state=", asset.get("state"))

rel, _ = api("GET", "https://api.github.com/repos/%s/releases/tags/%s" % (REPO, TAG))
print("--- final ---")
print("tag:", rel["tag_name"], "| draft:", rel["draft"], "|", rel["html_url"])
for a in rel["assets"]:
    print("  ", a["name"], a["size"], "bytes  dl:", a["download_count"])
