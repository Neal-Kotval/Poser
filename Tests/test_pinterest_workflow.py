import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from PIL import Image

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / 'Tools/ReferenceLibrary'))
import pinterest as pins


class PinterestWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name) / 'discovery'
        self.work.mkdir()
        self.records = []
        pins.merge_cards(self.records, [{'pinURL': '/pin/123/?tracking=secret', 'description': 'Standing by a wall', 'thumbnailURL': 'https://i.pinimg.com/236x/a.jpg'}], 'street portrait')

    def candidate(self):
        record = dict(self.records[0])
        record.update(title='Portrait', sourceURL='https://photographer.example/photo', creator='Photographer', rights='Written permission example.txt',
                      approved=True, personConfirmed=True, styleConfirmed=True, settings=['street'], features=['wall'], pose='standing', personCount=1,
                      cameraInstruction='Chest height', poseInstruction='Lean on the wall', lightInstruction='Open shade', framingInstruction='Upper third',
                      localImage='originals/portrait.jpg')
        path = self.work / record['localImage']
        path.parent.mkdir(exist_ok=True)
        Image.new('RGB', (400, 600), 'blue').save(path)
        return record

    def test_query_coverage(self):
        plan = json.loads((pins.ROOT / 'pinterest-queries.json').read_text())
        self.assertEqual(len(plan), 30)
        self.assertTrue(all(q['people'] == 1 and q['aesthetic'] == 'instagram-candid-editorial' for q in plan))
        self.assertTrue(all('couple' not in q['query'] and 'group' not in q['query'] for q in plan))
        self.assertEqual(len({q['query'] for q in plan}), 30)
        self.assertEqual({q['settings'][0] for q in plan}, pins.library.SETTINGS)
        self.assertEqual({q['pose'] for q in plan}, pins.library.POSES)

    def test_pin_identity_merge_and_approval_preservation(self):
        self.assertEqual(self.records[0]['pinURL'], 'https://www.pinterest.com/pin/123/')
        self.records[0]['approved'] = True
        pins.merge_cards(self.records, [{'pinURL': 'https://www.pinterest.com/pin/123/', 'description': 'Changed'}], 'second query')
        self.assertEqual(len(self.records), 1)
        self.assertEqual(len(self.records[0]['queries']), 2)
        self.assertTrue(self.records[0]['approved'])
        for url in ('https://evil.example/pin/1/', 'https://www.pinterest.com.evil.example/pin/1/', 'javascript:alert(1)', '/pin/not-an-id/'):
            self.assertIsNone(pins.canonical_pin(url))

    def test_group_descriptions_are_rejected_and_ai_multiple_people_flagged(self):
        for description in ('two women standing outside', 'a man and a woman sitting', 'a couple posing on a beach'):
            self.assertTrue(pins.describes_multiple_people(description))
        self.assertFalse(pins.describes_multiple_people('a woman sitting with a couple of books'))
        before = len(self.records)
        pins.merge_cards(self.records, [{'pinURL': '/pin/456/', 'thumbnailURL': 'https://i.pinimg.com/a.jpg', 'description': 'two men walking'}], 'solo streetwear')
        self.assertEqual(len(self.records), before)
        result = pins.annotate(self.records, {'pin-123': {'detectedPeople': 2}}, self.work)
        self.assertEqual(result[0]['reviewPriority'], 'reject-multiple-people')
        self.assertFalse(result[0]['approved'])

    def test_source_links_are_candidates_not_automatic_attribution(self):
        pins.apply_detail(self.records[0], {'title': 'Photo', 'description': 'Description', 'links': [
            {'url': 'https://www.pinterest.com/profile', 'text': 'Profile'},
            {'url': 'https://photographer.example/photo', 'text': 'Visit'},
            {'url': 'javascript:alert(1)', 'text': 'Bad'}]})
        self.assertEqual(len(self.records[0]['sourceCandidates']), 1)
        self.assertEqual(self.records[0]['sourceURL'], '')
        self.assertTrue(self.records[0]['detailsCollected'])

    def test_gate_preserves_checkpoint_and_never_extracts(self):
        class FakePage:
            def evaluate(self, script):
                if script == pins.GATE:
                    return 'login required'
                raise AssertionError('Should stop before reading hidden cards')
        with self.assertRaises(pins.BrowserBlocked):
            pins.ensure_unblocked(FakePage())

    def test_thumbnails_are_explicit_and_analysis_does_not_approve(self):
        preview = self.work / 'previews/pin-123.jpg'
        preview.parent.mkdir()
        Image.new('RGB', (300, 400), 'red').save(preview)
        second = dict(self.records[0], id='pin-456', pinURL='https://www.pinterest.com/pin/456/')
        Image.new('RGB', (300, 400), 'red').save(preview.with_name('pin-456.jpg'))
        annotated = pins.annotate(self.records + [second], {'pin-123': {'detectedPeople': 1}}, self.work)
        self.assertEqual(annotated[0]['reviewPriority'], 'solo-person-detected')
        self.assertFalse(annotated[0]['approved'])
        self.assertFalse(annotated[0]['personConfirmed'])
        self.assertIn('pin-456', annotated[0]['nearDuplicates'])
        self.assertIn('pin-123', annotated[1]['nearDuplicates'])

    def test_review_is_local_and_escapes_content(self):
        self.records[0]['description'] = '</textarea><script>bad()</script>'
        pins.library.save(pins.discovery_path(self.work), self.records)
        pins.review(SimpleNamespace(work=self.work))
        document = (self.work / 'pinterest-review.html').read_text()
        self.assertNotIn('<script>bad()', document)
        self.assertNotIn('<img', document)  # No permission to cache => no automatic remote thumbnail loads.
        self.assertIn('Open pin', document)
        self.assertTrue((self.work / 'pinterest-candidates.csv').exists())

    def test_csv_formula_escaping(self):
        self.records[0]['title'] = '=HYPERLINK("bad")'
        pins.export_csv(self.work, self.records)
        self.assertIn("'=HYPERLINK", (self.work / 'pinterest-candidates.csv').read_text())

    def test_approved_manual_image_roundtrip_and_idempotence(self):
        record = self.candidate()
        pins.library.save(pins.discovery_path(self.work), [record])
        args = SimpleNamespace(work=self.work, output=self.work.parent / 'library')
        with patch.object(pins.library, 'request', side_effect=AssertionError('Original imports must never download')):
            self.assertEqual(pins.import_local(args), 0)
            self.assertEqual(pins.import_local(args), 0)
        imported = json.loads((args.output / 'records.json').read_text())
        self.assertEqual(len(imported), 1)
        self.assertEqual(imported[0]['pinURL'], record['pinURL'])
        accepted, errors, _ = pins.library.validate(imported, args.output, target=1, coverage=False)
        self.assertEqual(len(accepted), 1)
        self.assertEqual(errors, [])

    def test_unapproved_or_missing_rights_never_import(self):
        record = self.candidate()
        record['approved'] = False
        pins.library.save(pins.discovery_path(self.work), [record])
        args = SimpleNamespace(work=self.work, output=self.work.parent / 'library')
        self.assertEqual(pins.import_local(args), 0)
        self.assertFalse((args.output / 'records.json').exists())
        record['approved'] = True
        record['rights'] = ''
        pins.library.save(pins.discovery_path(self.work), [record])
        self.assertEqual(pins.import_local(args), 1)
        self.assertFalse((args.output / 'records.json').exists())
        self.assertFalse(list(args.output.rglob('*.jpg')))

    def test_local_path_and_identity_validation(self):
        record = self.candidate()
        args = SimpleNamespace(work=self.work, output=self.work.parent / 'library')
        for override in ({'localImage': '../escape.jpg'}, {'id': 'pin-456'}, {'localImage': str((self.work / record['localImage']).resolve())}):
            pins.library.save(pins.discovery_path(self.work), [record | override])
            self.assertEqual(pins.import_local(args), 1)
            self.assertFalse((args.output / 'records.json').exists())


class BrowserAdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            from playwright.sync_api import sync_playwright
        except ImportError:
            raise unittest.SkipTest('Install requirements-browser.txt to run browser fixture tests')
        cls.runtime = sync_playwright().start()
        try:
            cls.browser = cls.runtime.chromium.launch(headless=True)
        except Exception:
            cls.runtime.stop()
            raise

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.runtime.stop()

    def test_rendered_cards_and_login_captcha_detection(self):
        page = self.browser.new_page()
        self.addCleanup(page.close)
        page.set_content('''<a href="https://www.pinterest.com/pin/123/"><img alt="Person by a wall" width="100" height="100"></a>
<a style="display:none" href="https://www.pinterest.com/pin/456/">Hidden</a><a href="https://example.com/">Other</a>''')
        cards = page.evaluate(pins.EXTRACT_CARDS)
        self.assertEqual(len(cards), 1)
        self.assertEqual(cards[0]['description'], 'Person by a wall')
        self.assertEqual(page.evaluate(pins.GATE), '')
        page.set_content('<iframe title="reCAPTCHA" src="about:blank#captcha" style="visibility:hidden;width:256px;height:60px"></iframe>')
        self.assertEqual(page.evaluate(pins.GATE), '')
        page.set_content('<iframe title="reCAPTCHA" src="about:blank#captcha" style="width:256px;height:200px"></iframe>')
        self.assertEqual(page.evaluate(pins.GATE), 'CAPTCHA')
        page.set_content('<div role="dialog">Log in to discover more ideas</div>')
        self.assertEqual(page.evaluate(pins.GATE), 'login required')
        page.set_content('<div>Verify you are human</div>')
        self.assertEqual(page.evaluate(pins.GATE), 'access challenge')

    def test_browse_gate_reports_progress_without_extracting(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            pins.library.save(pins.discovery_path(work), [])
            args = SimpleNamespace(work=work, command='browse', queries=pins.ROOT / 'pinterest-queries.json', limit=1000,
                                   max_queries=1, per_query=40, scrolls=1, detail_limit=0, refresh=False)
            page = unittest.mock.Mock()
            context = unittest.mock.Mock()
            context.pages = [page]
            manager = unittest.mock.MagicMock()
            manager.__enter__.return_value.chromium.launch_persistent_context.return_value = context
            with patch('playwright.sync_api.sync_playwright', return_value=manager), patch.object(pins, 'navigate', side_effect=pins.BrowserBlocked('login required')):
                self.assertEqual(pins.browse(args), 2)
            page.evaluate.assert_not_called()
            self.assertEqual(json.loads((work / 'pinterest-last-run.json').read_text())['status'], 'blocked')
            self.assertEqual(json.loads(pins.discovery_path(work).read_text()), [])

    def test_detail_uses_rendered_links(self):
        page = self.browser.new_page()
        self.addCleanup(page.close)
        page.set_content('<h1>Portrait</h1><meta name="description" content="A person standing"><a href="https://photographer.example/photo">Visit</a><a style="display:none" href="https://hidden.example/">Hidden</a>')
        detail = page.evaluate(pins.EXTRACT_DETAIL)
        self.assertEqual(detail['title'], 'Portrait')
        self.assertEqual(len(detail['links']), 1)


if __name__ == '__main__':
    unittest.main()
