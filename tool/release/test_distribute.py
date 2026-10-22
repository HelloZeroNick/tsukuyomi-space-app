import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('distribution', Path(__file__).with_name('distribute.py'))
distribution = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribution)


class DistributionTests(unittest.TestCase):
    def fixture(self, tag='v0.6.27-beta.1'):
        version = tag[1:].split('-')[0]
        names = sorted({f'tsukuyomi-space-{version}-{s}' for s in distribution.BASE_SUFFIXES} | distribution.DOCS)
        return {'tag_name': tag, 'draft': False, 'html_url': f'https://github.com/{distribution.REPO}/releases/tag/{tag}',
                'assets': [{'name': n, 'state': 'uploaded', 'size': 100, 'digest': 'sha256:' + 'a' * 64,
                            'browser_download_url': f'https://github.com/{distribution.REPO}/releases/download/{tag}/{n}'} for n in names]}

    def test_complete_only_and_numeric_version_selection(self):
        release = self.fixture()
        self.assertEqual(len(distribution.selected_assets(release)), 11)
        for mutate in [lambda r: r.update(draft=True), lambda r: r['assets'].pop(),
                       lambda r: r['assets'][0].update(digest=None),
                       lambda r: r['assets'][0].update(size=2**32),
                       lambda r: r['assets'][0].update(browser_download_url='https://evil.invalid/file'),
                       lambda r: r['assets'].append(r['assets'][0])]:
            invalid = copy.deepcopy(release); mutate(invalid)
            self.assertIsNone(distribution.selected_assets(invalid))
        tags = ['v0.6.27-beta.2', 'v0.6.27-beta.10', 'v0.6.27']
        self.assertEqual(sorted(reversed(tags), key=lambda t: distribution.version_key(self.fixture(t))), tags)

    def test_partial_hap_waits_for_all_five_files(self):
        release = self.fixture()
        names = sorted(distribution.OHOS_DOCS | {'tsukuyomi-space-0.6.27-34-ohos-arm64-unsigned.hap'})
        for name in names:
            release['assets'].append({'name': name, 'state': 'uploaded', 'size': 100, 'digest': 'sha256:' + 'b' * 64,
                'browser_download_url': f'https://github.com/{distribution.REPO}/releases/download/v0.6.27-beta.1/{name}'})
            self.assertEqual(len(distribution.selected_assets(release)), 16 if name == names[-1] else 11)


if __name__ == '__main__':
    unittest.main()
