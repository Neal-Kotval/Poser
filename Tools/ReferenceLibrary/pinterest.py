#!/usr/bin/env python3
"""One-time Pinterest discovery and local, human-reviewed reference curation.

Only rendered page content is read. Login/CAPTCHA/access blocks stop a run;
no private endpoints, cookie imports, or automatic original-image downloads.
"""
import argparse
import csv
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from urllib.parse import urljoin, urlsplit, urlencode

import library

ROOT = Path(__file__).resolve().parent

# A small DOM adapter kept separate so fixture tests can detect layout regressions.
EXTRACT_CARDS = r"""() => Array.from(document.querySelectorAll('a[href]')).filter(a => {
  const r=a.getBoundingClientRect();
  return r.width>0 && r.height>0 && /\/pin\/\d+\/?/.test(a.pathname);
}).map(a => {
  const image=a.querySelector('img');
  return {pinURL:a.href, description:image?.alt || a.innerText || '', thumbnailURL:image?.currentSrc || image?.src || ''};
})"""
EXTRACT_DETAIL = r"""() => {
  const visible=e => {const r=e.getBoundingClientRect(); return r.width>0 && r.height>0;};
  const links=Array.from(document.querySelectorAll('a[href]')).filter(visible).map(a=>({url:a.href,text:a.innerText.trim()}));
  const heading=Array.from(document.querySelectorAll('h1')).find(visible);
  const description=document.querySelector('meta[name="description"]')?.content || '';
  return {title:heading?.innerText || '',description,links};
}"""
GATE = r"""() => {
  const visible=e => {const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0 && r.height>0 && s.visibility!=='hidden' && s.display!=='none' && Number(s.opacity)>0 && r.bottom>0 && r.right>0 && r.top<innerHeight && r.left<innerWidth;};
  const text=document.body?.innerText || '';
  if (/verify (that )?you('re| are) human|unusual traffic|access denied|temporarily blocked|too many requests/i.test(text)) return 'access challenge';
  if (Array.from(document.querySelectorAll('iframe')).some(e=>visible(e)&&/captcha|challenge/i.test(e.src))) return 'CAPTCHA';
  if (/log in to discover more ideas|welcome to pinterest/i.test(text)) return 'login required';
  if (Array.from(document.querySelectorAll('[role="dialog"]')).some(e=>visible(e)&&/log in|sign up/i.test(e.innerText))) return 'login required';
  return '';
}"""


class BrowserBlocked(RuntimeError):
    pass


def canonical_pin(value):
    if not isinstance(value, str):
        return None
    parsed = urlsplit(urljoin('https://www.pinterest.com', value))
    if parsed.scheme != 'https' or parsed.hostname not in ('pinterest.com', 'www.pinterest.com') or parsed.username or parsed.password:
        return None
    match = re.fullmatch(r'/pin/(\d+)/?', parsed.path)
    return f'https://www.pinterest.com/pin/{match[1]}/' if match else None


def safe_https(value):
    if not isinstance(value, str):
        return ''
    parsed = urlsplit(value)
    return value if parsed.scheme == 'https' and parsed.hostname and not parsed.username and not parsed.password else ''


def discovery_path(work):
    return work / 'pinterest-candidates.json'


def load_candidates(work):
    path = discovery_path(work)
    return json.loads(path.read_text()) if path.exists() else []


def describes_multiple_people(description):
    # Conservative text rejection; this never establishes that an accepted candidate is solo.
    text = description.lower()
    patterns = [r'\b(?:two|three|four|five|several|multiple|group of) (?:people|persons|women|men|girls|boys|friends|models)\b',
                r'\b(?:a |one )?man and (?:a |one )?woman\b',
                r'\b(?:a |one )?woman and (?:a |one )?man\b',
                r'\b(?:couple|group) (?:standing|sitting|walking|posing|hugging|kissing)\b']
    return any(re.search(pattern, text) for pattern in patterns)


def merge_cards(records, cards, query):
    by_id = {r['id']: r for r in records}
    changed = 0
    for card in cards:
        pin = canonical_pin(card.get('pinURL'))
        if not pin:
            continue
        key = 'pin-' + pin.split('/')[-2]
        if key in by_id:
            if query not in by_id[key]['queries']:
                by_id[key]['queries'].append(query)
            continue
        if not safe_https(card.get('thumbnailURL')) or not str(card.get('description', '')).strip():
            continue
        if describes_multiple_people(str(card.get('description', ''))):
            continue
        record = dict(id=key, pinURL=pin, sourceURL='', sourceCandidates=[], description=card.get('description', '')[:2000],
                      title='', thumbnailURL=safe_https(card.get('thumbnailURL')), previewPath='', queries=[query],
                      creator='', rights='', approved=False, personConfirmed=False, styleConfirmed=False, localImage='',
                      settings=[], features=[], pose='standing', personCount=1, lighting='unknown',
                      cameraInstruction='', poseInstruction='', lightInstruction='', framingInstruction='',
                      poseTemplate='standing', distanceLabel='STEP BACK', detailsCollected=False,
                      collectedAt=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
        records.append(record)
        by_id[key] = record
        changed += 1
    return changed


def apply_detail(record, detail):
    title = detail.get('title', '')[:500]
    record['title'] = '' if title.strip().lower() == 'pinterest' else title
    if detail.get('description'):
        record['description'] = detail['description'][:4000]
    sources = []
    for link in detail.get('links', []):
        url = safe_https(link.get('url'))
        host = (urlsplit(url).hostname or '').lower()
        # Keep possible source links for human review; don't label profile/share links as original sources.
        if not url or host == 'pinterest.com' or host.endswith('.pinterest.com') or host in ('facebook.com', 'www.facebook.com', 'twitter.com', 'x.com'):
            continue
        if url not in [entry['url'] for entry in sources]:
            sources.append({'url': url, 'text': link.get('text', '')[:200]})
    record['sourceCandidates'] = sources[:20]
    record['detailsCollected'] = True


def ensure_unblocked(page):
    gate = page.evaluate(GATE)
    if gate:
        raise BrowserBlocked(gate)


def navigate(page, url):
    response = page.goto(url, wait_until='domcontentloaded', timeout=30000)
    if response and response.status in (401, 403, 429):
        raise BrowserBlocked(f'HTTP {response.status}')
    page.wait_for_timeout(1500)
    ensure_unblocked(page)


def export_csv(work, records):
    fields = ['id', 'pinURL', 'sourceURL', 'title', 'description', 'thumbnailURL', 'creator', 'rights', 'approved', 'personConfirmed', 'styleConfirmed', 'localImage', 'settings', 'features', 'pose', 'personCount', 'queries']
    with (work / 'pinterest-candidates.csv').open('w', newline='') as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        for record in records:
            # Prevent spreadsheet formula execution in untrusted page descriptions.
            writer.writerow({key: ("'" + value if isinstance(value := record.get(key, ''), str) and value.startswith(('=', '+', '-', '@')) else value) for key in fields})


def browse(args):
    from playwright.sync_api import sync_playwright, Error as PlaywrightError
    records = load_candidates(args.work)
    plan = json.loads(args.queries.read_text())
    if not isinstance(plan, list) or not all(isinstance(q, dict) and isinstance(q.get('query'), str) and q['query'].strip() for q in plan):
        raise ValueError('Queries must be a JSON list of query objects')
    checkpoint_path = args.work / 'pinterest-progress.json'
    checkpoint = json.loads(checkpoint_path.read_text()) if checkpoint_path.exists() else {'queries': {}}
    report = {'status': 'complete', 'newCandidates': 0, 'queriesVisited': 0, 'detailsVisited': 0}
    profile = args.work / 'browser-profile'
    profile.mkdir(mode=0o700, exist_ok=True)
    os.chmod(profile, 0o700)
    with sync_playwright() as playwright:
        context = playwright.chromium.launch_persistent_context(str(profile.resolve()), headless=False)
        try:
            page = context.pages[0] if context.pages else context.new_page()
            if args.command == 'login':
                page.goto(args.url, wait_until='domcontentloaded')
                input('Sign in manually in this browser. Complete any challenges yourself, then press Enter here to close it. ')
                return
            for entry in plan:
                if len(records) >= args.limit or report['queriesVisited'] >= args.max_queries:
                    break
                query = entry['query']
                key = hashlib.sha256(query.encode()).hexdigest()[:20]
                if checkpoint['queries'].get(key, {}).get('complete') and not args.refresh:
                    continue
                navigate(page, 'https://www.pinterest.com/search/pins/?' + urlencode({'q': query}))
                report['queriesVisited'] += 1
                query_ids = set()
                stale = 0
                for _ in range(args.scrolls):
                    ensure_unblocked(page)
                    before = len(query_ids)
                    cards = page.evaluate(EXTRACT_CARDS)
                    for card in cards:
                        pin = canonical_pin(card.get('pinURL'))
                        if pin:
                            query_ids.add(pin)
                        if len(records) >= args.limit or len(query_ids) > args.per_query:
                            break
                        report['newCandidates'] += merge_cards(records, [card], query)
                    library.save(discovery_path(args.work), records)
                    stale = stale + 1 if len(query_ids) == before else 0
                    if stale >= 3 or len(query_ids) >= args.per_query or len(records) >= args.limit:
                        break
                    page.mouse.wheel(0, 900)
                    page.wait_for_timeout(1500)
                if not query_ids:
                    raise BrowserBlocked('No rendered pin links found. Check for a login prompt, empty results, or a changed page layout')
                checkpoint['queries'][key] = {'query': query, 'complete': True, 'pinsSeen': len(query_ids)}
                library.save(checkpoint_path, checkpoint)
                print(f'Collected {len(records)} total candidates after: {query}', flush=True)
            for record in records:
                if report['detailsVisited'] >= args.detail_limit:
                    break
                if record.get('detailsCollected') and not args.refresh:
                    continue
                navigate(page, record['pinURL'])
                apply_detail(record, page.evaluate(EXTRACT_DETAIL))
                report['detailsVisited'] += 1
                library.save(discovery_path(args.work), records)
        except BrowserBlocked as error:
            report['status'] = 'blocked'
            report['reason'] = str(error)
        except PlaywrightError:
            report['status'] = 'blocked'
            report['reason'] = 'Browser navigation failed or timed out; check the browser and rerun'
        except KeyboardInterrupt:
            report['status'] = 'interrupted'
            report['reason'] = 'Stopped by operator'
            raise
        finally:
            library.save(discovery_path(args.work), records)
            library.save(args.work / 'pinterest-last-run.json', report)
            export_csv(args.work, records)
            try:
                context.close()
            except PlaywrightError:
                pass
    print(json.dumps(report, indent=2))
    if report['status'] == 'blocked':
        print('Progress saved. Run the login command to sign in manually, then rerun browse. No challenge was bypassed.')
        return 2
    return 0


def cache_previews(args):
    """Explicit opt-in for thumbnails the operator is permitted to retain."""
    from PIL import Image
    records = load_candidates(args.work)
    count, failures = 0, []
    for record in records:
        if count >= args.limit:
            break
        if record.get('previewPath') or not record.get('thumbnailURL'):
            continue
        try:
            data = library.request(record['thumbnailURL'], media=True)
            relative = f'previews/{record["id"]}.jpg'
            with tempfile.NamedTemporaryFile() as temporary:
                temporary.write(data)
                temporary.flush()
                library.normalize(temporary.name, args.work / relative, 480)
            record['previewPath'] = relative
            count += 1
            library.save(discovery_path(args.work), records)
        except (ValueError, RuntimeError, OSError, Image.DecompressionBombError):
            failures.append(record['id'])
    library.save(args.work / 'pinterest-preview-errors.json', failures)
    print(f'{count} permitted thumbnails cached; {len(failures)} failures. Original images were not downloaded.')


def annotate(records, vision, work):
    """Rank AI suggestions; never turn ML predictions into human approvals."""
    from PIL import Image
    hashes = {}
    by_id = {r['id']: r for r in records}
    for record in records:
        suggestions = vision.get(record['id'], {})
        record['visionSuggestions'] = suggestions
        people = suggestions.get('detectedPeople', 0)
        record['reviewPriority'] = 'reject-multiple-people' if people > 1 else ('solo-person-detected' if people == 1 else ('needs-visual-check' if suggestions else 'not-analyzed'))
        record['nearDuplicates'] = []
        preview = record.get('previewPath')
        if not preview and (work / f'previews/{record["id"]}.jpg').is_file():
            preview = f'previews/{record["id"]}.jpg'
            record['previewPath'] = preview
        if not preview:
            continue
        path = library.safe_file(work, preview)
        with Image.open(path) as photo:
            tiny = photo.convert('L').resize((9, 8))
            pixels = list(tiny.get_flattened_data() if hasattr(tiny, 'get_flattened_data') else tiny.getdata())
            value = sum(int(pixels[y * 9 + x] > pixels[y * 9 + x + 1]) << (y * 8 + x) for y in range(8) for x in range(8))
        for other, previous in hashes.items():
            if bin(value ^ previous).count('1') <= 5:
                record['nearDuplicates'].append(other)
                by_id[other]['nearDuplicates'].append(record['id'])
        hashes[record['id']] = value
    return records


def analyze(args):
    previews = args.work / 'previews'
    if not previews.exists():
        raise ValueError('No local previews. Cache permitted thumbnails or place manually saved previews in previews/<pin-id>.jpg first.')
    output = subprocess.run(['swift', str(ROOT / 'analyze.swift'), str(previews.resolve())], capture_output=True, text=True, check=True)
    vision = json.loads(output.stdout)
    records = annotate(load_candidates(args.work), vision, args.work)
    library.save(args.work / 'pinterest-vision.json', vision)
    library.save(discovery_path(args.work), records)
    print(f'Analyzed {len(vision)} local previews with Apple Vision. Human approval is unchanged.')


def review(args):
    records = load_candidates(args.work)
    cards = []
    records.sort(key=lambda r: (r.get('reviewPriority') != 'solo-person-detected', r['id']))
    for record in records:
        preview = ''
        if record.get('previewPath'):
            library.safe_file(args.work, record['previewPath'])
            preview = f'<img loading="lazy" src="{html.escape(record["previewPath"], quote=True)}" alt="Local permitted thumbnail">'
        else:
            preview = '<p>No local preview. Open the pin to inspect it.</p>'
        pin = canonical_pin(record['pinURL'])
        if not pin:
            raise ValueError('Invalid Pin URL in candidate file')
        links = f'<a target="_blank" rel="noreferrer" href="{html.escape(pin, quote=True)}">Open pin</a>'
        for source in record.get('sourceCandidates', []):
            url = safe_https(source.get('url'))
            if url:
                links += f' · <a target="_blank" rel="noreferrer" href="{html.escape(url, quote=True)}">Possible source: {html.escape(urlsplit(url).hostname or "source")}</a>'
        cards.append(f'<article><section>{preview}<p>{links}</p><p>{html.escape(record.get("reviewPriority", "not-analyzed"))}</p></section><textarea aria-label="Candidate metadata">{html.escape(json.dumps(record, indent=2))}</textarea></article>')
    document = '''<!doctype html><meta charset="utf-8"><title>Pinterest reference review</title>
<style>body{font:16px system-ui;background:#131313;color:white;padding:24px}a{color:#ddd}article{display:grid;grid-template-columns:280px 1fr;gap:24px;margin:24px 0}img{max-width:260px;max-height:400px}textarea{height:620px;width:100%;background:#242424;color:white}button{padding:16px;position:sticky;top:0} @media(max-width:700px){article{display:block}}</style>
<h1>Pinterest reference review</h1><p>Open the original source and manually save permitted images under originals/ inside this work folder. Set localImage to that relative path. Accept only exactly one visible person with an Instagram-style candid/editorial look: outfit photo dumps, streetwear, mirrors, direct flash, or warm natural light. Reject couples, groups, collages, product-only shots, and formal studio headshots. Confirm sourceURL, creator, rights, setting, pose, instructions, personCount: 1, personConfirmed, styleConfirmed, and approved. AI suggestions and possible source links require review. Remote thumbnails are not loaded by this page.</p><button id="save">Download pinterest-candidates.json</button>'''
    document += ''.join(cards)
    document += '''<script>document.getElementById('save').onclick=()=>{try{const records=Array.from(document.querySelectorAll('textarea'),t=>JSON.parse(t.value));const u=URL.createObjectURL(new Blob([JSON.stringify(records,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=u;a.download='pinterest-candidates.json';a.click();setTimeout(()=>URL.revokeObjectURL(u),1000)}catch(e){alert('Invalid JSON: '+e.message)}};</script>'''
    (args.work / 'pinterest-review.html').write_text(document)
    export_csv(args.work, records)
    print(args.work / 'pinterest-review.html')


def import_local(args):
    from PIL import Image
    candidates = load_candidates(args.work)
    records_path = args.output / 'records.json'
    records = json.loads(records_path.read_text()) if records_path.exists() else []
    imported, failures = 0, []
    args.output.mkdir(parents=True, exist_ok=True)
    existing_hashes = {hashlib.sha256(library.safe_file(args.output, r['image']).read_bytes()).hexdigest() for r in records}
    for candidate in candidates:
        if candidate.get('approved') is not True:
            continue
        if any(r['id'] == candidate['id'] for r in records):
            continue
        created = []
        try:
            key = candidate['id']
            if not re.fullmatch(r'pin-\d+', key) or canonical_pin(candidate.get('pinURL')) != f'https://www.pinterest.com/pin/{key[4:]}/':
                raise ValueError('Invalid Pin identity')
            source = library.safe_file(args.work, candidate.get('localImage', ''))
            # Source attribution must be explicitly confirmed; pin links alone are not original sources.
            source_url = safe_https(candidate.get('sourceURL'))
            if not source_url:
                raise ValueError('Confirm the original HTTPS sourceURL')
            settings = candidate.get('settings')
            if not isinstance(settings, list) or not settings or not set(settings) <= library.SETTINGS:
                raise ValueError('Confirm controlled setting tags before importing')
            category = settings[0]
            record = {field: candidate[field] for field in library.FIELDS if field not in ('image', 'thumbnail', 'sample')}
            record.update(image=f'images/{category}/{key}.jpg', thumbnail=f'thumbnails/{category}/{key}.jpg', sample=False,
                          approved=True, personConfirmed=candidate.get('personConfirmed') is True, styleConfirmed=candidate.get('styleConfirmed') is True,
                          pinURL=candidate['pinURL'], description=candidate.get('description', ''),
                          originalSourceURL=source_url, sha256=hashlib.sha256(source.read_bytes()).hexdigest())
            for field, size in [('image', 1024), ('thumbnail', 240)]:
                destination = args.output / record[field]
                if destination.exists():
                    raise ValueError('Asset path already exists; inspect before importing')
                created.append(destination)
                library.normalize(source, destination, size)
            digest = hashlib.sha256((args.output / record['image']).read_bytes()).hexdigest()
            if digest in existing_hashes:
                raise ValueError('Duplicate image content')
            _, errors, _ = library.validate([record], args.output, target=1, coverage=False)
            if errors:
                raise ValueError('; '.join(errors))
            library.save(records_path, records + [record])
            records.append(record)
            existing_hashes.add(digest)
            imported += 1
        except (ValueError, KeyError, OSError, Image.DecompressionBombError) as error:
            for path in created:
                path.unlink(missing_ok=True)
            failures.append({'id': candidate.get('id'), 'reason': str(error)})
    library.save(args.work / 'pinterest-local-import-errors.json', failures)
    print(f'{imported} approved local images imported; {len(failures)} failures. Existing library records preserved.')
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, default=Path('.reference-work/pinterest'))
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('queries', help='Write the 30-query starting plan and clickable search links')
    for command in ('browse', 'login'):
        browse_parser = sub.add_parser(command)
        browse_parser.add_argument('--queries', type=Path, default=ROOT / 'pinterest-queries.json')
        browse_parser.add_argument('--limit', type=int, default=1000)
        browse_parser.add_argument('--max-queries', type=int, default=5)
        browse_parser.add_argument('--per-query', type=int, default=40)
        browse_parser.add_argument('--scrolls', type=int, default=12)
        browse_parser.add_argument('--detail-limit', type=int, default=25)
        browse_parser.add_argument('--refresh', action='store_true')
        if command == 'login':
            browse_parser.add_argument('--url', default='https://www.pinterest.com/', help='Pinterest page to open for manual sign-in or challenge resolution')
    previews = sub.add_parser('cache-thumbnails', help='Opt in to caching thumbnails you are permitted to retain')
    previews.add_argument('--limit', type=int, default=1000)
    sub.add_parser('analyze', help='Analyze permitted local previews using Apple Vision; no paid service')
    sub.add_parser('review')
    local = sub.add_parser('import-local', help='Normalize manually saved, approved originals into the existing catalog workflow')
    local.add_argument('--output', type=Path, default=Path('.reference-work'))
    args = parser.parse_args()
    args.work.mkdir(parents=True, exist_ok=True)
    if hasattr(args, 'limit') and args.limit < 1:
        raise ValueError('--limit must be positive')
    if args.command in ('browse', 'login'):
        if args.command == 'login' and (urlsplit(args.url).scheme != 'https' or urlsplit(args.url).hostname not in ('pinterest.com', 'www.pinterest.com')):
            raise ValueError('Manual sign-in URL must be on Pinterest over HTTPS')
        if min(args.max_queries, args.per_query, args.scrolls) < 1 or args.detail_limit < 0:
            raise ValueError('Query/scroll limits must be positive; detail limit may be zero')
        return browse(args)
    if args.command == 'queries':
        plan = json.loads((ROOT / 'pinterest-queries.json').read_text())
        library.save(args.work / 'queries.json', plan)
        links = ['<li><a target="_blank" rel="noreferrer" href="https://www.pinterest.com/search/pins/?' + html.escape(urlencode({'q': q['query']}), quote=True) + '">' + html.escape(q['query']) + '</a></li>' for q in plan]
        (args.work / 'searches.html').write_text('<!doctype html><meta charset="utf-8"><title>Poser searches</title><h1>30 reference searches</h1><ol>' + ''.join(links) + '</ol>')
        print(args.work / 'searches.html')
    elif args.command == 'cache-thumbnails':
        cache_previews(args)
    elif args.command == 'analyze':
        analyze(args)
    elif args.command == 'review':
        review(args)
    elif args.command == 'import-local':
        return import_local(args)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('Stopped. Saved candidates remain available for the next run.', file=sys.stderr)
        sys.exit(130)
    except (ValueError, RuntimeError, OSError, KeyError, subprocess.CalledProcessError, ImportError) as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)
