#!/usr/bin/env python3
"""Compare shot estimates with measured reference setups in a JSONL file."""

import argparse
import json
import math
from collections import defaultdict
from pathlib import Path

METRICS = {
    "height_m": 0.20,
    "distance_m": 0.50,
    "pitch_deg": 10.0,
    "yaw_deg": 15.0,
}
ANGLE_METRICS = {"pitch_deg", "yaw_deg"}


def difference(estimate, truth, metric):
    delta = estimate - truth
    if metric in ANGLE_METRICS:
        delta = (delta + 180) % 360 - 180
    return delta


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return None
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def summarize(records):
    result = {}
    for metric, tolerance in METRICS.items():
        truth_count = 0
        errors = []
        relative_errors = []
        for record in records:
            truth = record.get("truth", {}).get(metric)
            estimate = record.get("estimate", {}).get(metric)
            if isinstance(truth, bool) or not isinstance(truth, (int, float)) or not math.isfinite(truth):
                continue
            truth_count += 1
            if isinstance(estimate, bool) or not isinstance(estimate, (int, float)) or not math.isfinite(estimate):
                continue
            error = difference(estimate, truth, metric)
            errors.append(error)
            if metric == "distance_m" and truth > 0:
                relative_errors.append(abs(error) / truth)
        absolute = [abs(error) for error in errors]
        result[metric] = {
            "measured": truth_count,
            "estimated": len(errors),
            "coverage": len(errors) / truth_count if truth_count else None,
            "mae": sum(absolute) / len(absolute) if absolute else None,
            "median_absolute_error": percentile(absolute, 0.5),
            "p90_absolute_error": percentile(absolute, 0.9),
            "bias": sum(errors) / len(errors) if errors else None,
            "outliers": sum(error > tolerance for error in absolute),
            "tolerance": tolerance,
        }
        if metric == "distance_m":
            result[metric]["mape"] = sum(relative_errors) / len(relative_errors) if relative_errors else None
    return result


def evaluate(records):
    grouped = defaultdict(list)
    for record in records:
        for tag, value in record.get("tags", {}).items():
            grouped[f"{tag}={value}"].append(record)
    return {
        "shots": len(records),
        "overall": summarize(records),
        "slices": {name: {"shots": len(group), "metrics": summarize(group)}
                   for name, group in sorted(grouped.items())},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=Path, help="JSONL with id, truth, estimate, and optional tags")
    args = parser.parse_args()
    with args.dataset.open(encoding="utf-8") as source:
        records = [json.loads(line) for line in source if line.strip()]
    print(json.dumps(evaluate(records), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
