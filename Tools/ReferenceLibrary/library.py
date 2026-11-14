#!/usr/bin/env python3
"""Development-only web image search, curation, and offline catalog packaging."""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

SETTINGS = {'street', 'wall', 'stairs', 'cafe', 'window', 'park', 'garden', 'beach', 'waterfront', 'landscape'}
POSES = {'standing', 'sitting', 'walking', 'leaning', 'crouching', 'turning', 'interacting'}
FEATURES = {'wall', 'stairs', 'bench', 'trees', 'window', 'table', 'railing', 'water', 'flowers', 'path'}
TEMPLATES = {'standing', 'street', 'sitting'}
FIELDS = ('id title image thumbnail settings features pose personCount lighting sourceURL creator rights cameraInstruction poseInstruction lightInstruction framingInstruction poseTemplate distanceLabel sample').split()


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def request(url, data=None, headers=None, attempts=4, media=False):
    """Bounded retry; never include tokens or signed image URLs in error messages."""
    headers = dict(headers or {})
    headers.setdefault('User-Agent', 'PoserReferenceLibrary/1.0')
    if media:
        require_web_url(url)
    for attempt in range(attempts):
        try:
            req = urllib.request.Request(url, data=data, headers=headers)
            opener = urllib.request.build_opener(PublicMediaRedirect()).open if media else urllib.request.urlopen
            with opener(req, timeout=30) as response:
                # Reject unexpectedly huge media before allocating it all.
                limit = 25 * 1024 * 1024
                if int(response.headers.get('Content-Length', '0')) > limit:
                    raise ValueError('Response exceeds 25 MB')
                body = response.read(limit + 1)
                if len(body) > limit:
                    raise ValueError('Response exceeds 25 MB')
                return body
        except urllib.error.HTTPError as error:
            if error.code not in (429, 500, 502, 503, 504) or attempt == attempts - 1:
                raise RuntimeError(f'HTTP {error.code}; check provider access or media availability') from None
            retry = error.headers.get('Retry-After', '')
            time.sleep(min(60, int(retry) if retry.isdigit() else 2 ** attempt))
        except (urllib.error.URLError, TimeoutError):
            if attempt == attempts - 1:
                raise RuntimeError('Network request failed after bounded retries') from None
            time.sleep(2 ** attempt)


def normalize(source, target, size):
    from PIL import Image, ImageOps
    with Image.open(source) as original:
        if original.width * original.height > 40_000_000:
            raise ValueError('Image exceeds 40 megapixels')
        image = ImageOps.exif_transpose(original).convert('RGB')
        image.thumbnail((size, size))
        target.parent.mkdir(parents=True, exist_ok=True)
        image.save(target, 'JPEG', quality=82, optimize=True)
        tiny = image.resize((9, 8)).convert('L')
        pixels = list(tiny.get_flattened_data() if hasattr(tiny, 'get_flattened_data') else tiny.getdata())
        bits = [pixels[y * 9 + x] > pixels[y * 9 + x + 1] for y in range(8) for x in range(8)]
        return f'{sum(int(b) << i for i, b in enumerate(bits)):016x}'


def require_web_url(url):
    """Only fetch public HTTPS hosts, including after redirects."""
    import ipaddress
    import socket
    if not isinstance(url, str):
        raise ValueError('Image URL must be a string')
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.port not in (None, 443):
        raise ValueError('Image and source URLs must be public HTTPS URLs')
    try:
        addresses = socket.getaddrinfo(parsed.hostname, 443, type=socket.SOCK_STREAM)
    except OSError:
        raise ValueError('Image host could not be resolved') from None
    if not addresses or any(not ipaddress.ip_address(address[4][0]).is_global for address in addresses):
        raise ValueError('Local and private-network image URLs are not supported')
    return url


class PublicMediaRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        require_web_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def search_page(query, page, key=None, provider='openverse'):
    if provider == 'openverse':
        params = dict(q=query, page=page + 1, page_size=20, mature='false', license='cc0,by,pdm')
        data = json.loads(request('https://api.openverse.org/v1/images/?' + urllib.parse.urlencode(params), attempts=1))
        candidates = []
        for result in data.get('results', []):
            if not result.get('url') or not result.get('foreign_landing_url'):
                continue
            candidates.append(dict(imageURL=result['url'], sourceURL=result['foreign_landing_url'],
                                   title=result.get('title') or 'Untitled reference', creator=result.get('creator') or '',
                                   rights=f"Reported license: {result.get('license', '')} {result.get('license_version', '')}; {result.get('license_url', '')}. Verify at original source.",
                                   query=query))
        return {'candidates': candidates, 'hasMore': bool(data.get('next'))}
    params = dict(engine='google_images', q=query, ijn=page, api_key=key,
                  image_type='photo', safe='active', hl='en')
    data = json.loads(request('https://serpapi.com/search.json?' + urllib.parse.urlencode(params), attempts=1))
    if data.get('error'):
        raise ValueError('Search provider returned an error; check your API key and search quota')
    candidates = []
    for result in data.get('images_results', []):
        if not result.get('original') or not result.get('link'):
            continue
        candidates.append(dict(imageURL=result['original'], sourceURL=result['link'],
                               title=result.get('title') or 'Untitled reference', creator='', rights='', query=query))
    # Persist only normalized results; API keys and provider request URLs are not cached.
    return {'candidates': candidates, 'hasMore': bool(data.get('serpapi_pagination', {}).get('next'))}


def query_plan(args):
    if args.query:
        return [{'query': query, 'settings': [], 'pose': ''} for query in args.query]
    path = args.queries or Path(__file__).with_name('queries.json')
    plan = json.loads(path.read_text())
    if not isinstance(plan, list) or not plan:
        raise ValueError('Query plan must be a nonempty JSON list')
    for entry in plan:
        if not isinstance(entry, dict) or not isinstance(entry.get('query'), str) or not entry['query'].strip():
            raise ValueError('Each query entry requires a query string')
        if not set(entry.get('settings', [])) <= SETTINGS or entry.get('pose', '') not in POSES | {''}:
            raise ValueError('Query plan contains invalid setting or pose hints')
    return plan


def collect_candidate(candidate, records, work):
    from PIL import Image
    image_url = candidate.get('imageURL', '')
    source_url = candidate.get('sourceURL', '')
    require_web_url(image_url)
    parsed_source = urllib.parse.urlsplit(source_url)
    if parsed_source.scheme != 'https' or not parsed_source.hostname or parsed_source.username or parsed_source.password:
        raise ValueError('Source page must be a public HTTPS URL')
    key = 'web-' + hashlib.sha256(image_url.encode()).hexdigest()[:20]
    if any(record['id'] == key for record in records):
        return False
    data = request(image_url, media=True)
    digest = hashlib.sha256(data).hexdigest()
    if any(record.get('sha256') == digest for record in records):
        return False
    image = f'images/{key}.jpg'
    thumbnail = f'thumbnails/{key}.jpg'
    try:
        with tempfile.NamedTemporaryFile() as temporary:
            temporary.write(data)
            temporary.flush()
            with Image.open(temporary.name) as photo:
                if min(photo.size) < 240:
                    raise ValueError('Image is too small for a usable pose reference')
            perceptual = normalize(temporary.name, work / image, 1024)
            normalize(temporary.name, work / thumbnail, 240)
        normalized = hashlib.sha256((work / image).read_bytes()).hexdigest()
        if any(record.get('normalizedHash') == normalized for record in records):
            (work / image).unlink(missing_ok=True)
            (work / thumbnail).unlink(missing_ok=True)
            return False
    except Exception:
        (work / image).unlink(missing_ok=True)
        (work / thumbnail).unlink(missing_ok=True)
        raise
    near = [record['id'] for record in records if record.get('perceptualHash') and
            (int(record['perceptualHash'], 16) ^ int(perceptual, 16)).bit_count() <= 5]
    # Query hints are retained separately: search wording does not prove what is visible.
    record = dict(id=key, title=candidate.get('title') or 'Untitled reference', image=image, thumbnail=thumbnail,
                  settings=[], features=[], pose='standing', personCount=1, lighting='unknown',
                  sourceURL=source_url, originalSourceURL=source_url, creator=candidate.get('creator') or '',
                  rights=candidate.get('rights') or '', cameraInstruction='', poseInstruction='',
                  lightInstruction='', framingInstruction='', poseTemplate='standing', distanceLabel='STEP BACK',
                  sample=False, approved=False, personConfirmed=False, styleConfirmed=False,
                  collectedAt=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                  sha256=digest, normalizedHash=normalized, perceptualHash=perceptual, nearDuplicates=near,
                  discovery={'imageURL': image_url, 'query': candidate.get('query', ''),
                             'settingHints': candidate.get('settings', []), 'poseHint': candidate.get('pose', '')})
    records.append(record)
    save(work / 'records.json', records)
    return True


def import_candidates(candidates, records, args, errors):
    from PIL import Image
    for candidate in candidates:
        if len(records) >= args.limit:
            break
        try:
            if not isinstance(candidate, dict):
                raise ValueError('Candidate must be an object')
            collect_candidate(candidate, records, args.work)
        except (ValueError, RuntimeError, OSError, Image.DecompressionBombError) as error:
            # URLs can carry signed credentials; use a digest for failure identification.
            identifier = hashlib.sha256(str(candidate.get('imageURL', '') if isinstance(candidate, dict) else candidate).encode()).hexdigest()[:20]
            errors.append({'candidate': identifier, 'reason': str(error) if isinstance(error, (ValueError, RuntimeError)) else 'Image download or decoding failed'})


def import_web(args):
    if args.limit < 1:
        raise ValueError('--limit must be positive')
    records_path = args.work / 'records.json'
    records = json.loads(records_path.read_text()) if records_path.exists() else []
    errors = []
    calls = 0
    if args.command == 'import':
        candidates = json.loads(args.manifest.read_text())
        if not isinstance(candidates, list):
            raise ValueError('Manifest must be a JSON list of imageURL/sourceURL objects')
        import_candidates(candidates, records, args, errors)
    else:
        if not 1 <= args.pages <= 100 or args.max_searches < 1:
            raise ValueError('--pages must be 1–100; --max-searches must be positive')
        plan = query_plan(args)
        for entry in plan:
            query_id = hashlib.sha256(entry['query'].encode()).hexdigest()[:20]
            for page in range(args.pages):
                if len(records) >= args.limit:
                    break
                cache = args.work / 'search' / f'{args.provider}-{query_id}-{page}.json'
                if cache.exists() and not args.refresh:
                    result = json.loads(cache.read_text())
                else:
                    if calls >= args.max_searches:
                        break
                    key = os.getenv('SERPAPI_API_KEY')
                    if args.provider == 'serpapi' and not key:
                        raise ValueError('Set SERPAPI_API_KEY, or use the default Openverse search without an account')
                    calls += 1
                    result = search_page(entry['query'], page, key, args.provider)
                    time.sleep(1)
                    save(cache, result)
                candidates = [candidate | {'query': entry['query'], 'settings': entry.get('settings', []), 'pose': entry.get('pose', '')}
                              for candidate in result['candidates']]
                import_candidates(candidates, records, args, errors)
                save(args.work / 'import-errors.json', errors)
                if not result['hasMore']:
                    break
            if len(records) >= args.limit:
                break
    if not records_path.exists():
        save(records_path, records)
    save(args.work / 'import-errors.json', errors)
    print(f'{len(records)} total candidates; {calls} search requests this run; {len(errors)} image failures.')
    print('Candidates require visual review and person confirmation before packaging. Rerun to resume from cached search results.')


def review(args):
    records = json.loads((args.work / 'records.json').read_text())
    vision_path = args.work / 'vision.json'
    vision = json.loads(vision_path.read_text()) if vision_path.exists() else {}
    cards = []
    for record in records:
        if record['id'] in vision:
            record['visionSuggestions'] = vision[record['id']]
        image = html.escape(record['thumbnail'], quote=True)
        value = html.escape(json.dumps(record, indent=2))
        cards.append(f'<article><img loading="lazy" src="{image}" alt="Candidate reference"><textarea aria-label="Reference metadata">{value}</textarea></article>')
    document = '''<!doctype html><meta charset="utf-8"><title>Poser reference review</title>
<style>body{background:#131313;color:white;font:16px system-ui;padding:24px}button{padding:16px;position:sticky;top:8px}article{display:flex;gap:24px;margin:24px 0}img{width:240px;object-fit:contain;align-self:start}textarea{width:100%;height:540px;background:#242424;color:white} @media(max-width:600px){article{display:block}img{width:100%}}</style>
<h1>Review reference candidates</h1><p>Inspect every photo. Confirm exactly one visible person and an Instagram-style candid/editorial look. Reject couples, groups, collages, studio headshots, and product-only images. Confirm pose, setting, attribution, rights evidence, and all four instructions. Set personCount to 1 and personConfirmed, styleConfirmed, and approved to true only after visual review. Near duplicates need a visual check. Download the reviewed JSON, then replace records.json in this work directory.</p><button id="export">Download reviewed records.json</button>'''
    document += ''.join(cards)
    document += '''<script>document.getElementById('export').onclick=()=>{try{const records=Array.from(document.querySelectorAll('textarea'),t=>JSON.parse(t.value));const u=URL.createObjectURL(new Blob([JSON.stringify(records,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=u;a.download='records.json';a.click();setTimeout(()=>URL.revokeObjectURL(u),1000)}catch(e){alert('Invalid metadata JSON: '+e.message)}};</script>'''
    (args.work / 'review.html').write_text(document)
    print(args.work / 'review.html')


def safe_file(root, name):
    if not isinstance(name, str) or Path(name).is_absolute() or ".." in Path(name).parts:
        raise ValueError("Asset path must be relative and cannot traverse directories")
    path = (root / name).resolve()
    if not path.is_relative_to(root.resolve()) or not path.is_file():
        raise ValueError('Asset missing or outside work directory: ' + name)
    return path


def validate(records, root, target=1000, coverage=True):
    errors = []
    ids, hashes = set(), set()
    accepted = []
    for r in records:
        if not r.get('approved') or r.get('sample'):
            continue
        key = r.get('id', '<missing>')
        try:
            if any(field not in r for field in FIELDS):
                raise ValueError('missing required fields')
            if not isinstance(key, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', key) or key in ids:
                raise ValueError('invalid or duplicate ID')
            ids.add(key)
            if r.get('personConfirmed') is not True or type(r['personCount']) is not int or r['personCount'] != 1:
                raise ValueError('exactly one visible person must be confirmed')
            if r.get('styleConfirmed') is not True:
                raise ValueError('Instagram-style suitability must be confirmed')
            if not r['settings'] or not set(r['settings']) <= SETTINGS or not set(r['features']) <= FEATURES or r['pose'] not in POSES:
                raise ValueError('invalid setting, feature, or pose tags')
            if r['poseTemplate'] not in TEMPLATES:
                raise ValueError('unsupported example pose template')
            for field in ('title', 'creator', 'rights', 'cameraInstruction', 'poseInstruction', 'lightInstruction', 'framingInstruction', 'distanceLabel', 'lighting'):
                if not isinstance(r[field], str) or not r[field].strip():
                    raise ValueError('empty ' + field)
            if not r['sourceURL'].startswith('https://'):
                raise ValueError('source URL must use HTTPS')
            for field in ('image', 'thumbnail'):
                path = safe_file(root, r[field])
                from PIL import Image
                with Image.open(path) as image:
                    image.verify()
                if field == 'image':
                    digest = hashlib.sha256(path.read_bytes()).hexdigest()
                    if digest in hashes:
                        raise ValueError('duplicate image content')
                    hashes.add(digest)
            accepted.append(r)
        except (ValueError, TypeError, KeyError, OSError) as error:
            errors.append(f'{key}: {error}')
    if len(accepted) != target:
        errors.append(f'Expected {target} approved images, found {len(accepted)}')
    if coverage:
        for setting in sorted(SETTINGS):
            count = sum(setting in r['settings'] for r in accepted)
            if count < 50:
                errors.append(f'Setting {setting}: {count}; minimum 50 (target approximately 100)')
        for pose in sorted(POSES):
            count = sum(r['pose'] == pose for r in accepted)
            if count < 50:
                errors.append(f'Pose {pose}: {count}; minimum 50')
    size = sum(safe_file(root, r[f]).stat().st_size for r in accepted for f in ('image', 'thumbnail'))
    if size > 200 * 1024 * 1024:
        errors.append('Image payload exceeds 200 MiB')
    return accepted, errors, size


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, default=Path('.reference-work'))
    sub = parser.add_subparsers(dest='command', required=True)
    search = sub.add_parser('search', help='Collect pose-photo candidates using free Openverse search or optional SerpApi')
    search.add_argument('--provider', choices=['openverse', 'serpapi'], default='openverse')
    search.add_argument('--query', action='append', help='Search phrase; repeat for multiple queries')
    search.add_argument('--queries', type=Path, help='JSON query plan (defaults to bundled setting/pose queries)')
    search.add_argument('--pages', type=int, default=1)
    search.add_argument('--max-searches', type=int, default=20, help='Maximum provider requests per run; cached pages do not count')
    search.add_argument('--limit', type=int, default=1000, help='Maximum total candidates in the work catalog')
    search.add_argument('--refresh', action='store_true', help='Refetch search pages instead of using disk cache')
    imp = sub.add_parser('import', help='Import a manually collected web-image URL manifest; no API key required')
    imp.add_argument('--manifest', type=Path, required=True)
    imp.add_argument('--limit', type=int, default=1000)
    sub.add_parser('review')
    for name in ('validate', 'package'):
        command = sub.add_parser(name)
        command.add_argument('--target', type=int, default=1000)
        command.add_argument('--development', action='store_true', help='Skip coverage quotas for a reviewed development subset')
        if name == 'package':
            command.add_argument('--output', type=Path, default=Path('Poser/ReferenceLibrary'))
    args = parser.parse_args()
    args.work.mkdir(parents=True, exist_ok=True)
    if args.command in ('search', 'import'):
        import_web(args)
    elif args.command == 'review':
        review(args)
    else:
        records = json.loads((args.work / 'records.json').read_text())
        approved, errors, size = validate(records, args.work, args.target, not args.development)
        print(f'{len(approved)} accepted; {size / 1024 / 1024:.1f} MiB image payload')
        if errors:
            raise ValueError('\n'.join(errors))
        if args.command == 'package':
            output = args.output.resolve()
            if output == args.work.resolve() or output in args.work.resolve().parents or args.work.resolve() in output.parents:
                raise ValueError('Output and work directories must not overlap')
            output.parent.mkdir(parents=True, exist_ok=True)
            # Stage first so validation/copy failures never destroy the installed catalog.
            with tempfile.TemporaryDirectory(dir=output.parent) as stage:
                stage = Path(stage)
                for record in approved:
                    for field in ('image', 'thumbnail'):
                        destination = stage / record[field]
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(safe_file(args.work, record[field]), destination)
                save(stage / 'catalog.json', dict(version=1, references=[{k: r[k] for k in FIELDS} for r in approved]))
                if sum(p.stat().st_size for p in stage.rglob('*') if p.is_file()) > 200 * 1024 * 1024:
                    raise ValueError('Total catalog payload exceeds 200 MiB')
                backup = output.with_name(output.name + '.previous')
                if backup.exists():
                    raise ValueError('Previous catalog backup exists; inspect it before packaging again')
                replacement = output.with_name(output.name + '.staged')
                if replacement.exists():
                    raise ValueError('Staged catalog exists; inspect it before packaging again')
                shutil.copytree(stage, replacement)
                if output.exists():
                    output.rename(backup)
                try:
                    replacement.rename(output)
                except OSError:
                    if backup.exists():
                        backup.rename(output)
                    raise
                if backup.exists():
                    shutil.rmtree(backup)
            print('Packaged ' + str(output))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, KeyError, OSError) as error:
        print('Error: ' + str(error), file=sys.stderr)
        sys.exit(1)
