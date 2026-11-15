#!/usr/bin/env python3
"""Create the Poser `references` collection and index Pinterest library previews."""

from __future__ import annotations

import argparse
import base64
import getpass
import json
import os
import plistlib
import sys
from pathlib import Path

from io import BytesIO

COLLECTION = "references"
KEYWORD_SCHEMA = {
    "name": COLLECTION,
    "fields": [
        {"name": "title", "type": "string"},
        {"name": "pinID", "type": "string"},
        {"name": "setting", "type": "string", "facet": True, "optional": True},
        {"name": "pose", "type": "string", "facet": True, "optional": True},
        {"name": "tags", "type": "string[]", "facet": True},
        {"name": "search_text", "type": "string"},
    ],
}
CLIP_SCHEMA = {
    "name": COLLECTION,
    "fields": KEYWORD_SCHEMA["fields"] + [
        {"name": "image", "type": "image", "store": False},
        {
            "name": "embedding",
            "type": "float[]",
            "embed": {
                "from": ["title", "image"],
                "model_config": {"model_name": "ts/clip-vit-b-p32"},
            },
        },
    ],
}
VISION_SCHEMA = {
    "name": COLLECTION,
    "fields": KEYWORD_SCHEMA["fields"] + [
        {"name": "vision_embedding", "type": "float[]", "num_dim": 2048},
    ],
}


def client_from_env(prompt_for_api_key: bool = False):
    import typesense
    plist_path = Path(__file__).resolve().parents[2] / "Poser/Secrets/Typesense.plist"
    app_config = plistlib.loads(plist_path.read_bytes()) if plist_path.exists() else {}
    host = os.environ.get("TYPESENSE_HOST") or app_config.get("Host")
    api_key = getpass.getpass("Typesense import key: ").strip() if prompt_for_api_key else os.environ.get("TYPESENSE_API_KEY")
    key_file = Path(__file__).with_name(".admin-key")
    if not api_key and key_file.exists():
        api_key = key_file.read_text().strip()
    if not host or not api_key:
        sys.exit("Set TYPESENSE_HOST and TYPESENSE_API_KEY, or put a temporary admin key in Tools/Typesense/.admin-key.")
    return typesense.Client(
        {
            "nodes": [
                {
                    "host": host,
                    "port": os.environ.get("TYPESENSE_PORT") or app_config.get("Port", "443"),
                    "protocol": os.environ.get("TYPESENSE_PROTOCOL") or app_config.get("Protocol", "https"),
                }
            ],
            "api_key": api_key,
            "connection_timeout_seconds": 120,
        }
    )


def jpeg_b64(path: Path, max_side: int = 512) -> str:
    from PIL import Image
    with Image.open(path) as image:
        image = image.convert("RGB")
        image.thumbnail((max_side, max_side))
        buffer = BytesIO()
        image.save(buffer, format="JPEG", quality=72)
        return base64.b64encode(buffer.getvalue()).decode("ascii")


def tags_for(entry: dict, image_labels: list[str]) -> list[str]:
    values = []
    for key in ("setting", "pose"):
        if entry.get(key):
            values.append(entry[key])
    title = entry.get("title") or ""
    for part in title.replace("·", " ").split():
        cleaned = "".join(ch for ch in part.lower() if ch.isalnum())
        if cleaned and cleaned not in values:
            values.append(cleaned)
    for label in image_labels:
        for word in label.replace("_", " ").split():
            cleaned = "".join(ch for ch in word.lower() if ch.isalnum())
            if len(cleaned) >= 3 and cleaned not in values:
                values.append(cleaned)
    return values


def ensure_collection(client, collection: str, schema: dict, replace: bool) -> None:
    from typesense.exceptions import ObjectNotFound
    try:
        existing = client.collections[collection].retrieve()
    except ObjectNotFound:
        existing = None
    if existing and not replace:
        required = {field["name"] for field in schema["fields"]}
        present = {field["name"] for field in existing["fields"]}
        missing = required - present
        if missing:
            sys.exit(f"Collection is missing {sorted(missing)}; use --replace-collection to recreate it.")
        print(f"Updating existing collection `{collection}`")
        return
    if existing:
        client.collections[collection].delete()
        print(f"Deleted existing collection `{collection}`")
    client.collections.create(schema)
    print(f"Created collection `{collection}`")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--images", type=Path, required=True, help="Folder of preview JPGs")
    parser.add_argument("--limit", type=int, default=0, help="0 = all")
    parser.add_argument("--batch-size", type=int, default=20)
    parser.add_argument("--labels", type=Path, required=True, help="JSON from classify_previews.swift")
    parser.add_argument("--mode", choices=("keywords", "vision", "clip"), default="keywords")
    parser.add_argument("--collection", default=COLLECTION, help="Use a new name for a safe index migration")
    parser.add_argument("--vectors", type=Path, help="JSON feature vectors from classify_previews.swift")
    parser.add_argument("--dry-run", action="store_true", help="Validate documents without changing Typesense")
    parser.add_argument("--replace-collection", action="store_true", help="Delete and recreate an incompatible collection")
    parser.add_argument("--prompt-api-key", action="store_true", help="Read a temporary import key without echoing it")
    args = parser.parse_args()

    catalog = json.loads(args.catalog.read_text())
    references = catalog["references"]
    labels_by_pin = json.loads(args.labels.read_text())
    if args.mode == "vision" and not args.vectors:
        parser.error("--mode vision requires --vectors")
    vectors_by_pin = json.loads(args.vectors.read_text()) if args.vectors else {}
    if args.limit > 0:
        references = references[: args.limit]
    if args.mode == "vision":
        missing = [entry["pinID"] for entry in references
                   if len(vectors_by_pin.get(entry["pinID"], [])) != 2048]
        if missing:
            sys.exit(f"Missing 2048-dimensional vectors for {len(missing)} references; first: {missing[0]}")

    client = None if args.dry_run else client_from_env(args.prompt_api_key)
    if client:
        schema = {**{"keywords": KEYWORD_SCHEMA, "vision": VISION_SCHEMA,
                     "clip": CLIP_SCHEMA}[args.mode], "name": args.collection}
        ensure_collection(client, args.collection, schema,
                          args.replace_collection)

    batch: list[dict] = []
    indexed = 0
    skipped = 0
    for entry in references:
        pin_id = entry["pinID"]
        image_path = args.images / f"{pin_id}.jpg"
        if not image_path.exists():
            skipped += 1
            continue
        try:
            document = {
                "id": entry["id"],
                "title": entry.get("title") or pin_id,
                "pinID": pin_id,
                "tags": tags_for(entry, labels_by_pin.get(pin_id, [])),
            }
            document["search_text"] = " ".join(document["tags"])
            if args.mode == "clip":
                document["image"] = jpeg_b64(image_path)
            if args.mode == "vision":
                vector = vectors_by_pin.get(pin_id)
                if not isinstance(vector, list) or len(vector) != 2048:
                    raise ValueError(f"Missing 2048-dimensional vector for {pin_id}")
                document["vision_embedding"] = vector
            if entry.get("setting"):
                document["setting"] = entry["setting"]
            if entry.get("pose"):
                document["pose"] = entry["pose"]
        except Exception as error:
            print(f"skip {pin_id}: {error}")
            skipped += 1
            continue
        batch.append(document)
        if len(batch) >= args.batch_size:
            if args.dry_run:
                indexed += len(batch)
                batch = []
                continue
            result = client.collections[args.collection].documents.import_(batch, {"action": "upsert"})
            failures = [row for row in result if not row.get("success")]
            if failures:
                print(f"batch failures: {failures[:3]}")
            indexed += len(batch) - len(failures)
            print(f"Indexed {indexed}/{len(references)}")
            batch = []

    if batch:
        if args.dry_run:
            indexed += len(batch)
            batch = []
        else:
            result = client.collections[args.collection].documents.import_(batch, {"action": "upsert"})
            failures = [row for row in result if not row.get("success")]
            indexed += len(batch) - len(failures)
            if failures:
                print(f"batch failures: {failures[:3]}")

    print(f"Done. indexed={indexed} skipped={skipped}")


if __name__ == "__main__":
    main()
