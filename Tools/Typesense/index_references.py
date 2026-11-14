#!/usr/bin/env python3
"""Create the Poser `references` collection and index Pinterest library previews."""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
from pathlib import Path

import typesense
from PIL import Image
from io import BytesIO

COLLECTION = "references"
SCHEMA = {
    "name": COLLECTION,
    "fields": [
        {"name": "title", "type": "string"},
        {"name": "pinID", "type": "string"},
        {"name": "setting", "type": "string", "facet": True, "optional": True},
        {"name": "pose", "type": "string", "facet": True, "optional": True},
        {"name": "tags", "type": "string[]", "facet": True},
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


def client_from_env() -> typesense.Client:
    host = os.environ.get("TYPESENSE_HOST")
    api_key = os.environ.get("TYPESENSE_API_KEY")
    if not host or not api_key:
        sys.exit("Set TYPESENSE_HOST and TYPESENSE_API_KEY (admin key).")
    return typesense.Client(
        {
            "nodes": [
                {
                    "host": host,
                    "port": os.environ.get("TYPESENSE_PORT", "443"),
                    "protocol": os.environ.get("TYPESENSE_PROTOCOL", "https"),
                }
            ],
            "api_key": api_key,
            "connection_timeout_seconds": 120,
        }
    )


def jpeg_b64(path: Path, max_side: int = 512) -> str:
    with Image.open(path) as image:
        image = image.convert("RGB")
        image.thumbnail((max_side, max_side))
        buffer = BytesIO()
        image.save(buffer, format="JPEG", quality=72)
        return base64.b64encode(buffer.getvalue()).decode("ascii")


def tags_for(entry: dict) -> list[str]:
    values = []
    for key in ("setting", "pose"):
        if entry.get(key):
            values.append(entry[key])
    title = entry.get("title") or ""
    for part in title.replace("·", " ").split():
        cleaned = "".join(ch for ch in part.lower() if ch.isalnum())
        if cleaned and cleaned not in values:
            values.append(cleaned)
    return values


def ensure_collection(client: typesense.Client) -> None:
    try:
        client.collections[COLLECTION].delete()
        print(f"Deleted existing collection `{COLLECTION}`")
    except Exception:
        pass
    client.collections.create(SCHEMA)
    print(f"Created collection `{COLLECTION}`")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--images", type=Path, required=True, help="Folder of preview JPGs")
    parser.add_argument("--limit", type=int, default=0, help="0 = all")
    parser.add_argument("--batch-size", type=int, default=20)
    args = parser.parse_args()

    catalog = json.loads(args.catalog.read_text())
    references = catalog["references"]
    if args.limit > 0:
        references = references[: args.limit]

    client = client_from_env()
    ensure_collection(client)

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
                "tags": tags_for(entry),
                "image": jpeg_b64(image_path),
            }
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
            result = client.collections[COLLECTION].documents.import_(batch, {"action": "upsert"})
            failures = [row for row in result if not row.get("success")]
            if failures:
                print(f"batch failures: {failures[:3]}")
            indexed += len(batch) - len(failures)
            print(f"Indexed {indexed}/{len(references)}")
            batch = []

    if batch:
        result = client.collections[COLLECTION].documents.import_(batch, {"action": "upsert"})
        failures = [row for row in result if not row.get("success")]
        indexed += len(batch) - len(failures)
        if failures:
            print(f"batch failures: {failures[:3]}")

    print(f"Done. indexed={indexed} skipped={skipped}")


if __name__ == "__main__":
    main()
