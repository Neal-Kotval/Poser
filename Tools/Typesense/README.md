# Typesense reference index

Powers the For You search bar (`beach picture`, etc.).

## Current setup (free tier)

The free 0.5 GB cluster cannot load CLIP (`Memory required to load the model exceeds free memory available.`). Manually generated vectors avoid loading a model on the Typesense server. The 816-photo vector index must still be validated on the live cluster before enabling it in the app.

The keyword index stores the title, setting, pose, and Vision detected objects and scene labels from each reference photo. A scan detects labels on the phone and searches those words in Typesense, then ranks the returned photos by visual similarity. This supports more than the fixed setting list (for example, chair, flower, or car). The user's scan image stays on the phone in this mode. Results are still limited to objects that Vision recognizes and reference photos actually present in the catalog. If classification or the network fails, the local matcher remains available.

Cluster host pattern: `<id>-1.a2.typesense.net`

## App config

```bash
cp Poser/Secrets/Typesense.plist.example Poser/Secrets/Typesense.plist
```

Fill Host + **search-only** API key. `Typesense.plist` is gitignored.

## Re-index searchable image labels

Run this after changing the catalog, and once to upgrade an existing keyword-only index. The first command creates `vision_labels.json` from the bundled photos and a temporary file of Vision revision 1 feature vectors. The second validates all documents without contacting Typesense.

```bash
swift Tools/Typesense/classify_previews.swift Poser/PinterestLibrary/catalog.json Poser/PinterestLibrary/previews Tools/Typesense/vision_labels.json /tmp/poser-reference-vectors.json
python3 Tools/Typesense/index_references.py --catalog Poser/PinterestLibrary/catalog.json --images Poser/PinterestLibrary/previews --labels Tools/Typesense/vision_labels.json --vectors /tmp/poser-reference-vectors.json --mode vision --collection references_vision --dry-run
```

To update the live cluster, install `Tools/Typesense/requirements.txt` and provide a temporary **admin/import** key as `TYPESENSE_API_KEY` or in the gitignored `Tools/Typesense/.admin-key`. The script reads the host from the app's local Typesense plist. Repeat the Python command without `--dry-run`. Using `references_vision` creates a separate collection and leaves the current `references` available. After querying the new collection to confirm results, add `<key>Collection</key><string>references_vision</string>` and `<key>VisionVectorSearchEnabled</key><string>true</string>` to the local `Poser/Secrets/Typesense.plist`, then rebuild. Never put the admin key in the app plist or commit it.

For keyword-only indexing without feature vectors, omit the vector output from the Swift command and use the Python command with `--mode keywords` and no `--vectors`. This can update a compatible collection without recreating it.

## CLIP image search (later)

Vision feature vectors provide image-to-image retrieval without a server-side model, but they are general visual features rather than CLIP's semantic image/text embeddings. For stronger semantic matching, Typesense's built-in `ts/clip-vit-b-p32` needs more memory than the free 0.5 GB cluster. After upgrading, re-index with `--mode clip --replace-collection` to add `image` + `embedding` fields.

After that collection is ready, add `<key>ImageSearchEnabled</key><string>true</string>` to the local `Typesense.plist` to enable image-to-image queries. Leave it unset on the keyword-only cluster.
