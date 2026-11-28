import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from PIL import Image

spec = importlib.util.spec_from_file_location('library', Path(__file__).parents[1] / 'Tools/ReferenceLibrary/library.py')
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)


class LibraryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.record = dict(id='pin-123', title='Portrait', image='images/123.jpg', thumbnail='thumbnails/123.jpg',
                           settings=['street'], features=['wall'], pose='standing', personCount=1, lighting='shade',
                           sourceURL='https://www.pinterest.com/pin/123/', creator='Photographer', rights='Written license: example.txt',
                           cameraInstruction='Chest height', poseInstruction='Lean slightly', lightInstruction='Open shade',
                           framingInstruction='Upper third', poseTemplate='street', distanceLabel='ABOUT 2.5 M', sample=False,
                           approved=True, personConfirmed=True, styleConfirmed=True)
        for field in ('image', 'thumbnail'):
            path = self.root / self.record[field]
            path.parent.mkdir(exist_ok=True)
            Image.new('RGB', (400, 600), 'red').save(path)

    def test_validation_and_release_coverage(self):
        approved, errors, _ = lib.validate([self.record], self.root, 1, False)
        self.assertEqual(len(approved), 1)
        self.assertFalse(errors)
        self.assertTrue(lib.validate([self.record], self.root, 1000, True)[1])

    def test_unreviewed_and_sample_never_ship(self):
        for override in ({'approved': False}, {'sample': True}, {'personConfirmed': False}, {'rights': ''}, {'personCount': 2}, {'styleConfirmed': False}):
            record = self.record | override
            self.assertEqual(lib.validate([record], self.root, 1, False)[0], [])

    def test_assets_and_duplicates(self):
        for override in ({'image': '../escape.jpg'}, {'image': str(self.root / self.record['image'])}, {'pose': 'invalid'}):
            self.assertTrue(lib.validate([self.record | override], self.root, 1, False)[1])
        self.assertTrue(lib.validate([self.record, self.record | {'id': 'another'}], self.root, 2, False)[1])
        (self.root / self.record['image']).write_text('broken image')
        self.assertTrue(lib.validate([self.record], self.root, 1, False)[1])

    def test_normalization_strips_exif_and_bounds_size(self):
        source = self.root / 'source.jpg'
        image = Image.new('RGB', (1400, 2000), 'blue')
        exif = image.getexif()
        exif[270] = 'private metadata'
        image.save(source, exif=exif)
        target = self.root / 'normalized.jpg'
        self.assertEqual(len(lib.normalize(source, target, 1024)), 16)
        with Image.open(target) as result:
            self.assertLessEqual(max(result.size), 1024)
            self.assertFalse(result.getexif())

    def search_args(self, **overrides):
        defaults = dict(work=self.root, command='search', provider='openverse', query=['standing street', 'sitting cafe'], queries=None,
                        pages=1, max_searches=1, limit=1000, refresh=False)
        return SimpleNamespace(**(defaults | overrides))

    def test_search_cache_budget_and_resume(self):
        args = self.search_args()
        with patch.object(lib, 'search_page', return_value={'candidates': [], 'hasMore': False}) as search, patch.object(lib.time, 'sleep'):
            lib.import_web(args)
            self.assertEqual(search.call_count, 1)
            lib.import_web(args)
            self.assertEqual(search.call_count, 2)  # First query cached, second query newly fetched.
            lib.import_web(args)
            self.assertEqual(search.call_count, 2)
            args.refresh = True
            lib.import_web(args)
            self.assertEqual(search.call_count, 3)
        self.assertEqual(len(list((self.root / 'search').glob('*.json'))), 2)

    def test_download_failure_and_manifest_retry(self):
        candidate = {'imageURL': 'https://images.example.com/photo.jpg', 'sourceURL': 'https://example.com/photo', 'title': 'Portrait'}
        manifest = self.root / 'manifest.json'
        lib.save(manifest, [candidate])
        args = self.search_args(command='import', manifest=manifest)
        with patch.object(lib, 'require_web_url'), patch.object(lib, 'request', side_effect=RuntimeError('HTTP 403')):
            lib.import_web(args)
        self.assertEqual(len(json.loads((self.root / 'import-errors.json').read_text())), 1)
        image_data = (self.root / self.record['image']).read_bytes()
        with patch.object(lib, 'require_web_url'), patch.object(lib, 'request', return_value=image_data) as request:
            lib.import_web(args)
            lib.import_web(args)
            self.assertEqual(request.call_count, 1)
        records = json.loads((self.root / 'records.json').read_text())
        self.assertEqual(len(records), 1)
        self.assertFalse(records[0]['approved'])
        self.assertFalse(records[0]['personConfirmed'])
        self.assertTrue((self.root / records[0]['thumbnail']).exists())

    def test_provider_adapters_preserve_sources_and_hide_keys(self):
        payload = {'images_results': [{'original': 'https://images.example.com/a.jpg', 'link': 'https://example.com/a', 'title': 'A', 'source': 'Publisher'}],
                   'search_metadata': {'url': 'https://serpapi.com/?api_key=secret'}, 'serpapi_pagination': {'next': 'next'}}
        with patch.object(lib, 'request', return_value=json.dumps(payload).encode()) as request:
            result = lib.search_page('person standing', 1, 'secret', 'serpapi')
        self.assertIn('safe=active', request.call_args.args[0])
        self.assertIn('ijn=1', request.call_args.args[0])
        self.assertEqual(result['candidates'][0]['sourceURL'], 'https://example.com/a')
        self.assertNotIn('secret', json.dumps(result))
        self.assertEqual(result['candidates'][0]['creator'], '')  # Publisher is not necessarily the photographer.
        payload = {'results': [{'url': 'https://images.example.com/a.jpg', 'foreign_landing_url': 'https://example.com/a', 'creator': 'Artist', 'license': 'by', 'license_url': 'https://creativecommons.org/licenses/by/2.0/'}], 'next': None}
        with patch.object(lib, 'request', return_value=json.dumps(payload).encode()) as request:
            result = lib.search_page('portrait', 0)
        self.assertIn('page_size=20', request.call_args.args[0])
        self.assertIn('license=cc0%2Cby%2Cpdm', request.call_args.args[0])
        self.assertEqual(result['candidates'][0]['creator'], 'Artist')
        self.assertIn('creativecommons.org', result['candidates'][0]['rights'])

    def test_query_plan_and_no_key_behavior(self):
        args = self.search_args(query=None)
        plan = lib.query_plan(args)
        self.assertEqual(len(plan), 30)
        self.assertEqual({entry['pose'] for entry in plan}, lib.POSES)
        self.assertEqual({entry['settings'][0] for entry in plan}, lib.SETTINGS)
        args = self.search_args(provider='serpapi')
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, 'SERPAPI_API_KEY'):
                lib.import_web(args)
        args.provider = 'openverse'
        with patch.dict(os.environ, {}, clear=True), patch.object(lib, 'search_page', return_value={'candidates': [], 'hasMore': False}), patch.object(lib.time, 'sleep'):
            lib.import_web(args)

    def test_media_url_validation(self):
        import socket
        for url in ('http://example.com/a.jpg', 'file:///private/a.jpg', 'https://user:pass@example.com/a.jpg', 'https://example.com:8443/a.jpg'):
            with self.assertRaises(ValueError):
                lib.require_web_url(url)
        with patch.object(socket, 'getaddrinfo', return_value=[(0, 0, 0, '', ('127.0.0.1', 443))]):
            with self.assertRaisesRegex(ValueError, 'private-network'):
                lib.require_web_url('https://example.com/a.jpg')
        with patch.object(socket, 'getaddrinfo', return_value=[(0, 0, 0, '', ('8.8.8.8', 443))]):
            self.assertEqual(lib.require_web_url('https://example.com/a.jpg'), 'https://example.com/a.jpg')
        with patch.object(lib, 'require_web_url', side_effect=ValueError('blocked')):
            with self.assertRaises(ValueError):
                lib.PublicMediaRedirect().redirect_request(None, None, 302, '', {}, 'https://localhost/secret')

    def test_network_retry_and_access_failure(self):
        import urllib.error
        error = urllib.error.HTTPError('https://example.com', 429, 'Limited', {'Retry-After': '0'}, None)
        with patch.object(lib.urllib.request, 'urlopen', side_effect=error) as call, patch.object(lib.time, 'sleep'):
            with self.assertRaises(RuntimeError):
                lib.request('https://example.com')
            self.assertEqual(call.call_count, 4)
        error.code = 401
        with patch.object(lib.urllib.request, 'urlopen', side_effect=error) as call:
            with self.assertRaises(RuntimeError):
                lib.request('https://example.com')
            self.assertEqual(call.call_count, 1)

    def test_non_numeric_content_length_is_ignored(self):
        class FakeResponse:
            headers = {'Content-Length': 'unknown'}
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def read(self, n=-1): return b'ok'
        with patch.object(lib.urllib.request, 'urlopen', return_value=FakeResponse()):
            self.assertEqual(lib.request('https://example.com'), b'ok')

    def test_review_escapes_metadata(self):
        lib.save(self.root / 'records.json', [self.record | {'title': '</textarea><script>bad()</script>'}])
        lib.review(SimpleNamespace(work=self.root))
        self.assertNotIn('<script>bad()</script>', (self.root / 'review.html').read_text())

    def test_package_integration(self):
        lib.save(self.root / 'records.json', [self.record])
        output = self.root.parent / (self.root.name + '-output')
        self.addCleanup(lambda: lib.shutil.rmtree(output, ignore_errors=True))
        with patch('sys.argv', ['library.py', '--work', str(self.root), 'package', '--target', '1', '--development', '--output', str(output)]):
            lib.main()
        catalog = json.loads((output / 'catalog.json').read_text())
        self.assertEqual(catalog['references'][0]['id'], 'pin-123')
        self.assertTrue((output / self.record['image']).exists())
        self.assertNotIn('approved', catalog['references'][0])


if __name__ == '__main__':
    unittest.main()
