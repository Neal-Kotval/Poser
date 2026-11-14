# One-time Pinterest discovery workflow

This is a small collection script, not an AI agent or a Pinterest API integration. It reads rendered search cards and Pin pages with headed Playwright, saves discovery metadata, and hands locally saved images to the offline app catalog. It needs no API key or paid AI service. Login or CAPTCHA screens stop collection; sign in manually in the tool's separate browser profile when needed.

Browser automation does not grant collection or redistribution rights. Use it only where permitted by Pinterest and image owners. Metadata discovery, thumbnail retention, and original-image use are separate steps. This tool does not download original images or bypass access restrictions. See [Pinterest guidelines](https://policy.pinterest.com/en/developer-guidelines).

## Current curation brief: solo + Instagram core

Every approved image must show exactly one person. Aim for casual, attainable Instagram portraits: outfit photo dumps, candid streetwear, cafe moments, mirror selfies, direct flash, warm film color, and natural window/golden-hour light. Include men and women with varied poses and backgrounds. `interacting` means holding or using a prop (coffee, sunglasses, a book), not interacting with a second person.

Reject couple/group photos, extra visible background people, collages, flat lays/product-only images, formal corporate/studio headshots, and images that do not fit this look. Search descriptions that explicitly mention multiple people are rejected during discovery. Local Vision flags detections of two or more people; neither search text nor a one-person detection proves the full frame is solo. Set `personConfirmed`, `personCount: 1`, and `styleConfirmed` only after reviewing the image yourself. Packaging enforces these fields; the approved export accepts only records whose confirmed person count is one.

The previous general collection is preserved under `.reference-work/pinterest/archive/`. The current collection uses the revised 30-query plan; old general/couple candidates are not mixed into it.

## 1. Install and choose 30 searches

From the repository root:

```sh
python3 -m venv .venv
.venv/bin/pip install -r Tools/ReferenceLibrary/requirements-browser.txt
.venv/bin/python -m playwright install chromium
.venv/bin/python Tools/ReferenceLibrary/pinterest.py queries
open .reference-work/pinterest/searches.html
```

The starting plan is `pinterest-queries.json`: ten settings, three variations each, covering standing, sitting, walking, leaning, crouching, turning, and interacting with a prop. Every query targets a solo person with an Instagram-style candid/editorial aesthetic; no couple or group searches are used. `queries` also writes an editable copy at `.reference-work/pinterest/queries.json`. Pass `--queries .reference-work/pinterest/queries.json` to browse with your edits. Search wording supplies discovery intent, not verified image labels.

## 2. Sign in manually, then collect

```sh
.venv/bin/python Tools/ReferenceLibrary/pinterest.py login
```

Sign in yourself in the browser window. Do not send passwords or verification codes to the script or chat. When finished, press Enter in Terminal. To return to an affected search for manual challenge resolution, use `login --url "https://www.pinterest.com/search/pins/?q=your+query"`. The dedicated profile is kept under the ignored `.reference-work/pinterest/browser-profile` directory with restricted directory permissions. It is not your everyday browser profile and must not be committed or shared.

Start with a small pass:

```sh
.venv/bin/python Tools/ReferenceLibrary/pinterest.py browse --max-queries 1 --per-query 20 --detail-limit 5
```

Then collect more:

```sh
.venv/bin/python Tools/ReferenceLibrary/pinterest.py browse --limit 1000 --max-queries 5 --per-query 40 --detail-limit 25
```

Each invocation visits at most five unfinished searches, scrolls at most twelve times per search, and reads at most 25 Pin detail pages. Rerun to continue through remaining searches and detail pages. Progress is saved after every extraction; duplicate Pin IDs merge query provenance and preserve review edits. `--refresh` revisits completed queries/details; use it deliberately. The total candidate limit is shared across runs. These are browsing limits, not a guarantee of 1,000 unique relevant photos.

The script never calls private endpoints, reads application state, changes cookies, uses stealth techniques, solves challenges, or clicks through login forms. A login prompt, CAPTCHA, access error, navigation failure, or missing card layout stops the run with progress saved. Exit code 2 means attention is needed; inspect `pinterest-last-run.json`. Layout adapters are fixture-tested but Pinterest may change its markup.

Outputs:

- `pinterest-candidates.json`: IDs, Pin URLs, descriptions, thumbnail URLs, possible source links, discovery queries, and review fields.
- `pinterest-candidates.csv`: a spreadsheet-friendly inventory with source, categories, pose, and approval information. Edit JSON for round-tripping; CSV export protects text beginning with spreadsheet formula characters.
- `pinterest-progress.json`: completed query checkpoints.
- `pinterest-last-run.json`: counts and any blocking condition.

Visible external links are listed as **possible sources**, not automatically treated as the original photographer. Confirm the source during review. The default collection records thumbnail URLs without retaining thumbnails.

## 3. Analyze permitted thumbnails locally

If you have permission to retain thumbnails:

```sh
.venv/bin/python Tools/ReferenceLibrary/pinterest.py cache-thumbnails --limit 1000
.venv/bin/python Tools/ReferenceLibrary/pinterest.py analyze
```

Alternatively place permitted, manually saved previews at `.reference-work/pinterest/previews/pin-<numeric-id>.jpg` and run `analyze` without thumbnail downloading. Neither command uses a paid cloud model.

Apple Vision suggests scene categories, detects people/body landmarks, and records unavailable-model errors. The script prioritizes references with a detected body and flags perceptually similar previews as possible duplicates. Missing detection does not automatically reject a photograph, and similarity does not automatically delete one. These are review aids: posing categories, source rights, and final human presence still require visual confirmation. Near-duplicate thresholds are conservative and may flag unrelated images with simple backgrounds.

## 4. Review and manually save approved originals

```sh
.venv/bin/python Tools/ReferenceLibrary/pinterest.py review
open .reference-work/pinterest/pinterest-review.html
```

The contact sheet uses local previews only and links to Pins and possible original sources. Review each candidate and edit its JSON:

- Verify exactly one person is visible and set `personCount: 1` and `personConfirmed: true`. Confirm the Instagram-style candid/editorial aesthetic with `styleConfirmed: true`. Reject couples, groups, collages, product shots, and formal studio headshots; then confirm setting/feature tags and pose category.
- Confirm the original `sourceURL`, `creator`, and `rights` evidence. Open the source and **manually save a permitted image** under `.reference-work/pinterest/originals/`.
- Set `localImage` to the work-relative path, e.g. `originals/my-photo.jpg`.
- Write photo-specific camera, pose, light, framing, and distance instructions using the same catalog vocabulary as the general collection guide.
- Resolve duplicate candidates and set `approved: true` only for final selections.

Download the edited `pinterest-candidates.json` and replace the file in the work directory. Review reruns preserve your saved edits. Nothing is approved based on an AI score alone.

## 5. Import local originals and package

```sh
.venv/bin/python Tools/ReferenceLibrary/pinterest.py import-local
.venv/bin/python Tools/ReferenceLibrary/library.py validate
.venv/bin/python Tools/ReferenceLibrary/library.py package --output ReferenceCollection/pinterest/approved-catalog
```

`import-local` uses only local files. It normalizes images, strips metadata, makes thumbnails, rejects duplicates/incomplete approvals, and preserves existing library records. Accepted assets are grouped under `images/<setting>/` and `thumbnails/<setting>/`. Failed imports leave a report at `pinterest-local-import-errors.json` and do not approve or replace existing records. Repeating the command is safe for previously imported IDs.

The release validator still targets 1,000 approved references with setting/pose coverage. For a reviewed 500-image release, use `--target 500` on validate/package; coverage requirements still apply. For a small development subset use `--target N --development`. See [the main guide](README.md) for taxonomy and validation details.

## Tests and limits

```sh
.venv/bin/python -m unittest discover -s Tests -p 'test_*.py' -v
```

Browser fixture tests use local HTML, not Pinterest accounts. They verify card extraction, hidden-link exclusion, detail links, login/challenge detection, and progress preservation. Pipeline tests cover query coverage, stable IDs, duplicate merging, review escaping, local-only image import, rejection of incomplete approvals, path validation, and compatibility with catalog validation.

Live end-to-end collection requires your manual Pinterest sign-in and permitted access. It has not been validated against 500–1,000 live Pins. No collected images are shipped until reviewed and packaged.

The current app uses a separate asset catalog. Exporting an approved JSON/image bundle does not automatically wire it into the app; integrate approved assets with the current app catalog before release.
