#!/usr/bin/env python3
"""Evaluate pose-match scores and coaching cues against labeled photo pairs."""

import argparse
import json
import math
from collections import defaultdict
from pathlib import Path


def summarize(records, threshold=85):
    labeled = [item for item in records if item.get("match") in (True, False)]
    scored = [item for item in labeled if not isinstance(item.get("score"), bool)
              and isinstance(item.get("score"), (int, float))
              and math.isfinite(item["score"])]
    negatives = [item for item in scored if not item["match"]]
    by_reference = defaultdict(list)
    for item in scored:
        by_reference[item["reference_id"]].append(item)
    ranked = [group for group in by_reference.values()
              if any(item["match"] for item in group) and any(not item["match"] for item in group)]
    comparisons = [(good["score"], bad["score"]) for group in ranked
                   for good in group if good["match"] for bad in group if not bad["match"]]
    auc = (sum(1 if good > bad else 0.5 if good == bad else 0 for good, bad in comparisons)
           / len(comparisons)) if comparisons else None
    def top_match_fraction(group):
        highest = max(item["score"] for item in group)
        leaders = [item for item in group if item["score"] == highest]
        return sum(item["match"] for item in leaders) / len(leaders)

    top_one = sum(top_match_fraction(group) for group in ranked)

    cued = [item for item in labeled if item.get("expected_cue") is not None
            and item.get("predicted_cue") is not None]
    return {
        "pairs": len(labeled),
        "score_coverage": len(scored) / len(labeled) if labeled else None,
        "ranking_auc": auc,
        "reference_top1": top_one / len(ranked) if ranked else None,
        "ranked_references": len(ranked),
        "false_matches": sum(item["score"] >= threshold for item in negatives),
        "wrong_pairs_scored": len(negatives),
        "cue_accuracy": (sum(item["expected_cue"] == item["predicted_cue"] for item in cued)
                         / len(cued)) if cued else None,
        "cued_pairs": len(cued),
    }


def evaluate(records):
    grouped = defaultdict(list)
    for item in records:
        for key, value in item.get("tags", {}).items():
            grouped[f"{key}={value}"].append(item)
    return {"overall": summarize(records),
            "slices": {name: summarize(group) for name, group in sorted(grouped.items())}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=Path)
    args = parser.parse_args()
    with args.dataset.open(encoding="utf-8") as source:
        records = [json.loads(line) for line in source if line.strip()]
    print(json.dumps(evaluate(records), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
