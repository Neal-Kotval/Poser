# Building the offline reference library

This development tool searches the web, downloads permitted candidates, prepares review files, and exports an approved-image staging catalog. The tracked discovery collection contains **1,000 solo-targeted Pin candidates**, all awaiting image/content/rights review. The app currently uses its existing bundled examples; this tooling does not replace its asset catalog.

## Pinterest-assisted discovery

For the one-time Pinterest browser workflow—30 searches, Playwright browsing, local AI review, manual original-image saves, and category-grouped import—follow [the Pinterest workflow guide](PINTEREST.md). It reuses the same catalog validation and packaging below. General web search remains available as an alternative.

## Free collection: no account or API key

From the repository root:

```sh
python3 -m venv .venv
.venv/bin/pip install -r Tools/ReferenceLibrary/requirements.txt
.venv/bin/python Tools/ReferenceLibrary/library.py search --query 'person standing street' --limit 20 --max-searches 1
```

The default provider is [Openverse](https://api.openverse.org/v1/), a search index of openly licensed web images. Anonymous searches use 20 results per page and respect provider rate limits. The tool requests CC0, CC BY, and public-domain candidates, preserving creator, source page, and reported license information. Verify the license at the original source before approval; search results do not establish that people are visible or the license metadata is correct.

For the broader collection, use the bundled 30-query plan spanning ten settings and seven pose categories:

```sh
.venv/bin/python Tools/ReferenceLibrary/library.py search --limit 1000 --pages 2 --max-searches 20
```

Queries cycle across settings before moving to the next pose category. The script makes at most 20 new search requests per run, saves normalized search results to disk, and reuses them on subsequent runs. Rerun to continue through remaining queries. `--limit` is the total candidate ceiling, not an approval target; duplicates, inaccessible images, and irrelevant results mean collecting 1,000 useful references may require more queries and manual sourcing. Increase `--limit` when more review candidates are needed. Openverse rate limits may require spreading runs out over time. No subscription or cloud inference is required.

## Optional broader Google Images discovery

[SerpApi](https://serpapi.com/google-images-api) is an optional provider and needs only `SERPAPI_API_KEY`; Pinterest registration, approval, OAuth, and boards are no longer part of the collection workflow.

```sh
export SERPAPI_API_KEY='your key'
.venv/bin/python Tools/ReferenceLibrary/library.py search --provider serpapi --query 'person leaning brick wall portrait pose' --limit 100 --max-searches 1
```

SerpApi offers a free allowance and paid plans; check [current pricing](https://serpapi.com/pricing). `--max-searches` caps requests for this invocation only, not monthly account usage or billing. Cached pages do not count toward this local cap. Do not enable paid renewal unless you intend to pay. General search results have no assumed license; fill in creator and rights evidence during review.

## Manual web search: no search service needed

Search in your browser and collect direct image URLs plus their original page URLs into a JSON list. Copy `Tools/ReferenceLibrary/manifest.example.json` into your ignored work directory and replace its example URLs:

```json
[
  {
    "imageURL": "https://images.example.com/portrait.jpg",
    "sourceURL": "https://example.com/photographer/portrait",
    "title": "Standing portrait by a wall",
    "creator": "Photographer name",
    "rights": "License or permission reference"
  }
]
```

Then run:

```sh
.venv/bin/python Tools/ReferenceLibrary/library.py import --manifest .reference-work/manifest.json
```

Use the original image, not the search engine thumbnail. `imageURL` and `sourceURL` must be HTTPS; downloads and redirects to private networks or local files are rejected. Existing work records and approvals are preserved, including previously imported Pinterest candidates. No old credentials are read or deleted.

## Analyze and review

```sh
swift Tools/ReferenceLibrary/analyze.swift .reference-work/images > .reference-work/vision.json
.venv/bin/python Tools/ReferenceLibrary/library.py review
open .reference-work/review.html
```

Search and manifest imports save each successful candidate, normalize orientation, strip EXIF, generate thumbnails, and flag near duplicates. Original and normalized image hashes avoid exact duplicates. Downloads are bounded to 25 MB, images to 40 megapixels, and useful images must be at least 240 pixels on each side. Every candidate starts unapproved and requires visible-person confirmation. Query-derived setting and pose hints are retained separately from verified tags.

Check `import-errors.json` for failed candidate identifiers. URLs may contain signed credentials, so errors use a hash rather than the URL. Rerunning retries downloads from cached results without repeating successful imports. Use `--refresh` only when you want new provider requests for already cached pages. Search caches are separated by provider and contain normalized results rather than API keys or raw search metadata.

The Vision tool proposes scene labels, detected person counts, and landmarks. Suggestions appear in each contact sheet record; they never automatically approve a photo. Missing body landmarks do not prove a photo lacks people. Confirm visually.

In the contact sheet, edit each JSON record and then download `records.json` to replace `.reference-work/records.json`. Keep the images in the same work directory. Review and fill:

- `settings`: one or more of `street`, `wall`, `stairs`, `cafe`, `window`, `park`, `garden`, `beach`, `waterfront`, `landscape`.
- `features`: visible `wall`, `stairs`, `bench`, `trees`, `window`, `table`, `railing`, `water`, `flowers`, `path`.
- `pose`: `standing`, `sitting`, `walking`, `leaning`, `crouching`, `turning`, or `interacting`.
- `personCount`: must be exactly 1; `personConfirmed`: true only after visually checking the entire frame. `styleConfirmed`: true only after confirming an Instagram-style candid/editorial look.
- `lighting`: descriptive label or `unknown`; `creator`, `sourceURL`, `originalSourceURL`, and `rights`: attribution and a reference to license/permission evidence retained with your collection.
- `cameraInstruction`, `poseInstruction`, `lightInstruction`, `framingInstruction`, and `distanceLabel`: practical, photo-specific directions. Distances are estimates, not measurements.
- `poseTemplate`: `standing`, `street`, or `sitting`; used only as a clearly labeled example when body detection fails. Detected pose landmarks take priority.
- `nearDuplicates`: inspect flagged pairs and retain distinct images. Set `approved` to true only after reviewing the image, instructions, and rights. Unapproved candidates are excluded.

Do not describe an unverified identity, infer sensitive traits, remove watermarks, or claim an image is licensed without evidence. The tool preserves the full curation metadata in the work directory; the runtime catalog contains only the fields used by the app.

## Validate and package

```sh
.venv/bin/python Tools/ReferenceLibrary/library.py validate
.venv/bin/python Tools/ReferenceLibrary/library.py package --output ReferenceCollection/pinterest/approved-catalog
```

Production defaults require exactly 1,000 accepted, unique photos, at least 50 per setting (target about 100), at least 50 per pose category, exactly one visible person per image, valid images and metadata, and a package under 200 MiB. Small human-reviewed subsets can be exported explicitly:

```sh
.venv/bin/python Tools/ReferenceLibrary/library.py package --target 20 --development
```

This skips coverage quotas only; person confirmation, attribution, rights, uniqueness, and valid assets remain required. Use `--output ReferenceCollection/pinterest/approved-catalog` to create a staging export. Integrating approved images and metadata into the app’s current asset catalog and Xcode resources is a separate implementation step. Keep collection evidence outside the release bundle and preserve a backup of your work directory.

## Checks

```sh
.venv/bin/python -m unittest discover -s Tests -p 'test_*.py' -v
```

Before release, evaluate 50 held-out surroundings photos: at least 80% should produce three feasible references in the first 12. Verify scan → browse → selection → pose guide → capture → comparison in airplane mode on a physical iPhone, including weak scenes, missing images, rescan/reset, and Dynamic Type. Target warm p95 scan-to-gallery latency below five seconds. These physical-device and relevance checks cannot be established with the one-photo sample catalog.
