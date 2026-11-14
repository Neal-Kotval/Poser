import unittest

from Tools.PoseEvaluation.evaluate_pairs import evaluate


class PosePairEvaluationTests(unittest.TestCase):
    def test_ranking_coverage_false_matches_and_cues(self):
        records = [
            {"reference_id": "a", "match": True, "score": 92,
             "expected_cue": "hold", "predicted_cue": "hold", "tags": {"view": "front"}},
            {"reference_id": "a", "match": False, "score": 88,
             "expected_cue": "arm", "predicted_cue": "camera", "tags": {"view": "front"}},
            {"reference_id": "b", "match": True, "score": 75,
             "expected_cue": "hold", "predicted_cue": "hold", "tags": {"view": "side"}},
            {"reference_id": "b", "match": False, "score": None,
             "expected_cue": "stance", "predicted_cue": None, "tags": {"view": "side"}},
        ]
        result = evaluate(records)
        overall = result["overall"]
        self.assertEqual(overall["pairs"], 4)
        self.assertEqual(overall["score_coverage"], 0.75)
        self.assertEqual(overall["reference_top1"], 1.0)
        self.assertEqual(overall["ranked_references"], 1)
        self.assertEqual(overall["ranking_auc"], 1.0)
        self.assertEqual(overall["false_matches"], 1)
        self.assertEqual(overall["cue_accuracy"], 2 / 3)
        self.assertEqual(result["slices"]["view=side"]["score_coverage"], 0.5)


if __name__ == "__main__":
    unittest.main()
