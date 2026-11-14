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
