# Pinterest reference collection

## Current collection

`current/` contains **1,000 unique Pin candidates**, collected with solo, Instagram-style candid/editorial searches: streetwear, outfit photo dumps, mirror selfies, cafes, direct flash, warm film, and natural light. The collection spans ten setting intents. Search terms describe discovery intent, not verified image contents.

- [Review page](current/pinterest-review.html)
- [JSON records](current/pinterest-candidates.json)
- [CSV inventory](current/pinterest-candidates.csv)
- [Collection summary](current/collection-summary.md)
- [Query plan](current/queries.json)

Each record has a description and thumbnail URL. Identical-thumbnail candidates are flagged. Other visual duplicates may remain. No original images or cached thumbnails are included. No source rights, exact person counts, or style approvals have been confirmed; all candidates remain unapproved.

Final acceptance requires exactly one visible person, the intended Instagram-style aesthetic, and documented permission/license evidence. Reject couples, groups, collages, product-only images, and formal studio headshots. `personCount: 1` in an unreviewed record is a placeholder; only `personConfirmed: true` establishes a review decision.

## Archive

`archive/` preserves the initial general-discovery run for provenance and recovery. It includes older searches for couples/multiple people and does **not** follow the current solo-only direction. Use `current/` for active curation.

## Resume and curate

Follow the [workflow guide](../../Tools/ReferenceLibrary/PINTEREST.md). To resume on this machine, use the local `.reference-work/pinterest` working directory, which retains the browser session. On another machine, copy the current JSON/checkpoint/query files to that working directory and sign in manually in a new collector profile. Never copy or commit browser profiles or authentication files.

Review files use local previews only. Use the Pin links to inspect candidates, or add thumbnails you are permitted to retain locally. The review page downloads an edited JSON file; replace the working JSON deliberately before importing approved originals. Session data, passwords, cookies, Python environments, and browser caches are intentionally absent from this repository.

Approved image exports are staging artifacts. Integrating those assets into the app’s current ReferenceCatalog/Xcode resources is a separate step; this discovery commit does not replace the app’s bundled examples.
