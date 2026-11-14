# Typesense reference index

Powers the For You search bar (`beach picture`, etc.).

## Current setup (free tier)

The free 0.5 GB cluster cannot load CLIP (`Memory required to load the model exceeds free memory available.`).

So Poser indexes **text metadata** (title, setting, pose, tags) for keyword search. Scan-place image matching stays on-device via `SceneMatcher` until the cluster is upgraded enough for CLIP.

Cluster host pattern: `<id>-1.a2.typesense.net`

## App config

```bash
cp Poser/Secrets/Typesense.plist.example Poser/Secrets/Typesense.plist
```

Fill Host + **search-only** API key. `Typesense.plist` is gitignored.

## Re-index metadata (optional)

If you change the catalog:

```bash
# Prefer Typesense Cloud MCP from Cursor, or:
cd Tools/Typesense
python3 - <<'PY'
# build JSONL from Poser/PinterestLibrary/catalog.json and import with a temporary import key
PY
```

## CLIP image search (later)

Needs a larger Typesense Cloud memory plan so `ts/clip-vit-b-p32` can load. Then recreate `references` with an `image` + `embedding` field and re-import previews.
