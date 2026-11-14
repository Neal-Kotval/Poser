# Typesense reference index

Indexes the bundled Pinterest library into Typesense for:

- For You text search (`beach picture`)
- Scan-place image similarity

## 1. Create a cluster

Use [Typesense Cloud](https://cloud.typesense.org) (easiest) or a local Docker node with ML models enabled.

Create a **search-only** API key for the iOS app and keep the admin key on this machine only.

## 2. Configure the app

```bash
cp Poser/Secrets/Typesense.plist.example Poser/Secrets/Typesense.plist
```

Fill in Host / SearchAPIKey. `Typesense.plist` is gitignored.

## 3. Index references

```bash
cd Tools/Typesense
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

export TYPESENSE_HOST=xxx.a1.typesense.net
export TYPESENSE_PORT=443
export TYPESENSE_PROTOCOL=https
export TYPESENSE_API_KEY=ADMIN_KEY_HERE

python index_references.py \
  --catalog ../../Poser/PinterestLibrary/catalog.json \
  --images ../../Poser/PinterestLibrary/previews \
  --limit 0
```

`--limit 50` is useful for a smoke test. Re-running recreates the `references` collection.

## 4. Verify

```bash
curl "https://$TYPESENSE_HOST/multi_search" \
  -H "X-TYPESENSE-API-KEY: $TYPESENSE_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"searches":[{"collection":"references","q":"beach","query_by":"embedding","per_page":5}]}'
```
