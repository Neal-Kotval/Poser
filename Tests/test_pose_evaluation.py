import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "Tools" / "PoseEvaluation" / "evaluate.py"
SPEC = importlib.util.spec_from_file_location("pose_evaluation", MODULE_PATH)
EVALUATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVALUATOR)


class PoseEvaluationTests(unittest.TestCase):
    def test_coverage_errors_outliers_and_slices(self):
        records = [
            {"truth": {"distance_m": 2, "yaw_deg": 179},
             "estimate": {"distance_m": 2.4, "yaw_deg": -179},
             "tags": {"body": "full"}},
            {"truth": {"distance_m": 4, "yaw_deg": 0},
             "estimate": {"distance_m": 5, "yaw_deg": None},
             "tags": {"body": "cropped"}},
            {"truth": {"distance_m": 3}, "estimate": {}, "tags": {"body": "cropped"}},
        ]
        result = EVALUATOR.evaluate(records)
        distance = result["overall"]["distance_m"]
        self.assertEqual(result["shots"], 3)
        self.assertEqual(distance["estimated"], 2)
        self.assertAlmostEqual(distance["coverage"], 2 / 3)
        self.assertAlmostEqual(distance["mae"], 0.7)
        self.assertEqual(distance["outliers"], 1)
        self.assertAlmostEqual(result["overall"]["yaw_deg"]["mae"], 2)
        self.assertEqual(result["slices"]["body=cropped"]["shots"], 2)


if __name__ == "__main__":
    unittest.main()
