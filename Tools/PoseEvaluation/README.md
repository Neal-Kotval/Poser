# Pose accuracy evaluation

Use measured camera setups to decide whether pose estimation changes improve accuracy.
Each line of a JSONL file is one reference photo:

```json
{"id":"shot-1","truth":{"height_m":1.2,"distance_m":2.5,"pitch_deg":-5,"yaw_deg":20},"estimate":{"height_m":1.0,"distance_m":3.0,"pitch_deg":0,"yaw_deg":15},"tags":{"body":"full","lens":"26mm","pose":"standing","depth":"none"}}
```

Measure height from the ground to the phone lens, distance horizontally from
the lens to the subject, pitch with an inclinometer (positive is up), and yaw
relative to the subject's forward direction (positive toward their left).
Use `null` for an estimate the app withheld. Include cropped and full-body
photos, different lenses, poses, and depth availability.

Run `python3 Tools/PoseEvaluation/evaluate.py path/to/shots.jsonl` to get
coverage, mean/median/90th-percentile absolute error, signed bias, and outlier
counts. Outlier thresholds are 0.2 m height, 0.5 m distance, 10° pitch, and
15° yaw. The same metrics are broken down by each tag.

## Photo-pair matching

For each reference, capture one close match and several controlled mismatches
(one arm, stance, camera distance, angle, or crop changed). Record the app's
score and first cue for each pair:

```json
{"reference_id":"street-1","candidate_id":"street-1-arm","match":false,"score":64,"expected_cue":"arm","predicted_cue":"arm","tags":{"view":"front","changed":"arm"}}
```

Use `match: true` for a human-approved close match and `false` for a mismatch.
Keep `score` or `predicted_cue` null when the app cannot produce them. Cue labels
should be a small agreed set such as `arm`, `leg`, `stance`, `turn`, `framing`,
`camera`, and `hold`. Run `python3 Tools/PoseEvaluation/evaluate_pairs.py
path/to/pairs.jsonl` for score coverage, ranking AUC, how often the highest
scored shot is the approved match, false high scores, and cue accuracy. Breakdowns
by tag reveal which poses or views need work.
