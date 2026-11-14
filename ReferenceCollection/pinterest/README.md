# Pinterest reference collection

## Current collection

`current/` contains **1,000 unique Pin candidates**, collected with solo, Instagram-style candid/editorial searches: streetwear, outfit photo dumps, mirror selfies, cafes, direct flash, warm film, and natural light. The collection spans ten setting intents. Search terms describe discovery intent, not verified image contents.

- [Review page](current/pinterest-review.html)
- [JSON records](current/pinterest-candidates.json)
- [CSV inventory](current/pinterest-candidates.csv)
- [Collection summary](current/collection-summary.md)
- [Query plan](current/queries.json)

Each record has a description and thumbnail URL. Identical-thumbnail candidates are flagged. Other visual duplicates may remain. The 1,000-record collection itself has no approved originals or confirmed reuse rights.

## Development app library

A local download pass retrieved 999 of the 1,000 Pin images and normalized 997 distinct files. The [image inventory](image-inventory.json) records their Pin links, image hashes, dimensions, and local Vision person counts. The app bundles 816 references: 815 had one body detected by Vision, and one extra mirror portrait was visually checked. The other 181 files remain in the ignored `.reference-work/pinterest/` folder for review. Vision detection is a suggestion, not confirmation that every frame contains exactly one person. The [initial visual selection](app-selection.json) records the smaller first review pass.

The former seven bundled examples have been removed from the app catalog. A separate `InspirationPortrait` asset remains for the simulator camera example. The original creators, original source pages, and reuse rights are unverified; this is a local development library and is not cleared for distribution. These images do not mark the 1,000 candidate records approved or satisfy the release catalog validator.

Final acceptance requires exactly one visible person, the intended Instagram-style aesthetic, and documented permission/license evidence. Reject couples, groups, collages, product-only images, and formal studio headshots. `personCount: 1` in an unreviewed record is a placeholder; only `personConfirmed: true` establishes a review decision.

## Archive

`archive/` preserves the initial general-discovery run for provenance and recovery. It includes older searches for couples/multiple people and does **not** follow the current solo-only direction. Use `current/` for active curation.

## Resume and curate

Follow the [workflow guide](../../Tools/ReferenceLibrary/PINTEREST.md). To resume on this machine, use the local `.reference-work/pinterest` working directory, which retains the browser session. On another machine, copy the current JSON/checkpoint/query files to that working directory and sign in manually in a new collector profile. Never copy or commit browser profiles or authentication files.

Review files use local previews only. Use the Pin links to inspect candidates, or add thumbnails you are permitted to retain locally. The review page downloads an edited JSON file; replace the working JSON deliberately before importing approved originals. Session data, passwords, cookies, Python environments, and browser caches are intentionally absent from this repository.

Approved image exports are staging artifacts. They require a separate integration into the app's ReferenceCatalog and Xcode resources. The development library is separate from the approved-image export workflow.
