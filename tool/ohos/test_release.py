"""Exercise unsigned HAP integrity and additive release publication."""
import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import urllib.parse
import zipfile

from release import (BEGIN, CHECKSUMS, REPOSITORY, digest, note, prepare,
                     publish, release_files, resolve, verified_artifact)

TAG = 'v0.6.21-beta.1'
SOURCE = 'a' * 40
COMMIT = 'b' * 40
NAME = 'tsukuyomi-space-0.6.21-28-ohos-arm64-unsigned.hap'


class FakeGitHub:
    def __init__(self):
        self.commit = COMMIT
        self.writes = []
        self.release = {'id': 123, 'tag_name': TAG, 'draft': False, 'body': '本次版本的更新说明。\n',
                        'html_url': f'https://github.com/{REPOSITORY}/releases/tag/{TAG}',
                        'assets': [{'id': 50, 'name': 'existing-android.apk', 'size': 1234,
                                    'digest': 'sha256:' + 'f' * 64, 'state': 'uploaded'}]}

    def tag_commit(self, tag):
        return self.commit

    def request(self, path, method='GET', payload=None, file=None):
        if method == 'GET':
            return copy.deepcopy(self.release)
        self.writes.append((path, method))
        if method == 'PATCH':
            self.release.update(payload)
            return copy.deepcopy(self.release)
        name = urllib.parse.parse_qs(urllib.parse.urlparse(path).query)['name'][0]
        asset = {'id': len(self.release['assets']) + 100, 'name': name, 'size': file.stat().st_size,
                 'digest': 'sha256:' + digest(file), 'state': 'uploaded'}
        self.release['assets'].append(asset)
        return copy.deepcopy(asset)


class HAPReleaseTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.artifact = self.root / 'artifact'
        self.artifact.mkdir()
        self.output = self.root / 'release'
        self.hap = self.artifact / NAME
        self.app = {'versionName': '0.6.21', 'versionCode': 28, 'debug': False,
                    'buildMode': 'release', 'bundleName': 'space.tsukuyomi.tsukuyomi_space_app',
                    'minAPIVersion': 60002022, 'compileSdkVersion': '26.0.0.105'}
        self.make_hap()
        (self.artifact / 'THIRD_PARTY_NOTICES.md').write_text('感谢 HelloZeroNick\n', encoding='utf-8')
        self.info = {'source': SOURCE, 'signed': False, 'file': NAME}
        self.manifest()
        self.api = FakeGitHub()

    def make_hap(self):
        with zipfile.ZipFile(self.hap, 'w') as archive:
            archive.writestr('module.json', json.dumps({'app': self.app}))
            for lib in ('flutter', 'app', 'tsukuyomi_live2d'):
                archive.writestr(f'libs/arm64-v8a/lib{lib}.so', b'ELF fixture')
            archive.writestr('resources/rawfile/flutter_assets/assets/live2d/character.moc3', b'moc')
            archive.writestr('resources/rawfile/flutter_assets/assets/live2d/character.model3.json',
                             json.dumps({'FileReferences': {'Textures': ['texture.webp']}}))
            archive.writestr('resources/rawfile/flutter_assets/assets/live2d/texture.webp', b'texture')
            archive.writestr('resources/rawfile/flutter_assets/NOTICES.Z', b'licenses')

    def manifest(self):
        self.info['sha256'] = digest(self.hap)
        (self.artifact / 'build-info.json').write_text(json.dumps(self.info), encoding='utf-8')
        (self.artifact / 'SHA256SUMS').write_text(f'{self.info["sha256"]}  {NAME}\n', encoding='utf-8')

    def prepare(self):
        with patch('release.git', return_value=COMMIT), patch('release.version_at', return_value=('0.6.21', 28)):
            return prepare(self.artifact, self.output, TAG, SOURCE)

    def publish(self):
        with contextlib.redirect_stdout(io.StringIO()):
            publish(self.api, self.output, TAG)

    def test_source_version_signature_guide_and_checksums_are_complete(self):
        result = self.prepare()
        info, hashes = release_files(self.output, TAG)
        self.assertEqual(result, info)
        self.assertEqual(info['source'], SOURCE)
        self.assertEqual(info['release_commit'], COMMIT)
        self.assertEqual(len(hashes), 5)
        text = (self.output / 'OHOS-INSTALL.md').read_text(encoding='utf-8')
        self.assertIn('未签名', text)
        self.assertIn('HelloZeroNick', text)
        self.assertIn(COMMIT, text)
        self.assertEqual((self.output / NAME).read_bytes(), self.hap.read_bytes())

    def test_wrong_source_or_package_digest_is_rejected(self):
        self.info['source'] = COMMIT
        self.manifest()
        with self.assertRaisesRegex(ValueError, 'provenance'):
            self.prepare()
        self.info['source'] = SOURCE
        self.manifest()
        self.hap.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_internal_version_mismatch_is_rejected_even_with_correct_digest(self):
        self.app['versionCode'] = 27
        self.make_hap()
        self.manifest()
        with self.assertRaisesRegex(ValueError, 'app identity'):
            self.prepare()

    def test_tag_and_build_source_version_must_match(self):
        with patch('release.git', return_value=COMMIT), patch('release.version_at', side_effect=[('0.6.21', 28), ('0.6.22', 29)]):
            with self.assertRaisesRegex(ValueError, 'source version'):
                prepare(self.artifact, self.output, TAG, SOURCE)

    def test_adds_five_files_preserves_existing_installer_and_is_idempotent(self):
        self.prepare()
        original = copy.deepcopy(self.api.release['assets'][0])
        self.publish()
        self.assertEqual(self.api.release['assets'][0], original)
        self.assertEqual(len(self.api.release['assets']), 6)
        self.assertEqual(len(self.api.writes), 6)  # Five uploads, one notes edit.
        self.assertTrue(self.api.release['body'].startswith('本次版本的更新说明。'))
        self.assertIn('未签名', self.api.release['body'])
        self.publish()
        self.assertEqual(len(self.api.writes), 6)
        self.assertEqual(self.api.release['body'].count(BEGIN), 1)

    def test_partial_upload_can_resume_without_replacing_assets(self):
        self.prepare()
        self.api.request('releases/123/assets?name=' + NAME, 'POST', file=self.output / NAME)
        first = copy.deepcopy(self.api.release['assets'][-1])
        self.publish()
        self.assertEqual(self.api.release['assets'][1], first)
        self.assertEqual(len(self.api.release['assets']), 6)

    def test_conflicting_asset_is_preserved_before_any_write(self):
        self.prepare()
        self.api.release['assets'].append({'name': NAME, 'size': 1, 'digest': 'sha256:wrong'})
        with self.assertRaisesRegex(ValueError, 'preserved'):
            self.publish()
        self.assertEqual(self.api.writes, [])

    def test_changed_checksum_or_moved_tag_prevents_any_write(self):
        self.prepare()
        self.api.commit = SOURCE
        with self.assertRaisesRegex(ValueError, 'tag moved'):
            self.publish()
        self.api.commit = COMMIT
        checksum = self.output / CHECKSUMS
        checksum.write_text(checksum.read_text(encoding='utf-8') + '0' * 64 + '  ../bad\n', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'checksum manifest'):
            self.publish()
        self.assertEqual(self.api.writes, [])

    def test_concurrent_release_note_edit_is_preserved(self):
        self.prepare()
        request = self.api.request

        def edit(path, method='GET', **kwargs):
            if path == 'releases/123' and method == 'GET':
                self.api.release['body'] = '另一个维护者的说明'
            return request(path, method, **kwargs)

        with patch.object(self.api, 'request', side_effect=edit):
            with self.assertRaisesRegex(ValueError, 'concurrently'):
                self.publish()
        self.assertEqual(self.api.release['body'], '另一个维护者的说明')
        self.assertFalse(any(method == 'PATCH' for _, method in self.api.writes))

    def test_notes_do_not_accumulate_and_reject_ambiguous_markers(self):
        body = note('当版内容', TAG, NAME)
        self.assertEqual(note(body, TAG, NAME), body)
        with self.assertRaises(ValueError):
            note(body + BEGIN, TAG, NAME)


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeGitHub()
        self.event = {'repository': {'full_name': REPOSITORY}, 'workflow_run': {
            'name': 'Release installers', 'path': '.github/workflows/release.yml',
            'conclusion': 'success', 'status': 'completed', 'head_sha': COMMIT,
            'event': 'workflow_dispatch', 'head_repository': {'full_name': REPOSITORY}}}

    def resolve(self, event=None, kind='workflow_run', tag=''):
        def git(*args):
            if args[0] == 'show' and args[1].endswith('app_release.dart'):
                return f"const appReleaseTag = '{TAG}';"
            return COMMIT
        with patch('release.git', side_effect=git), patch('release.version_at', return_value=('0.6.21', 28)):
            return resolve(self.api, kind, event or self.event, tag)

    def test_successful_first_party_release_uses_tag_commit(self):
        self.assertEqual(self.resolve(), {'ready': 'true', 'ref': COMMIT, 'tag': TAG})
        self.assertEqual(self.resolve(kind='workflow_dispatch', tag=TAG)['ref'], COMMIT)

    def test_foreign_failed_and_mismatched_source_runs_are_rejected(self):
        for key, value in [('head_repository', {'full_name': 'other/repo'}), ('conclusion', 'failure'),
                           ('event', 'pull_request'), ('head_sha', SOURCE)]:
            event = copy.deepcopy(self.event)
            event['workflow_run'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.resolve(event)

    def test_build_only_run_skips_and_manual_tag_requires_published_release(self):
        with patch.object(self.api, 'request', side_effect=urllib.error.HTTPError('fixture', 404, 'missing', {}, None)):
            self.assertEqual(self.resolve(), {'ready': 'false'})
            with self.assertRaises(urllib.error.HTTPError):
                self.resolve(kind='workflow_dispatch', tag=TAG)
        self.api.release['draft'] = True
        self.assertEqual(self.resolve(), {'ready': 'false'})
        with self.assertRaisesRegex(ValueError, 'published release'):
            self.resolve(kind='workflow_dispatch', tag=TAG)


class ArtifactReuseTests(unittest.TestCase):
    def setUp(self):
        self.run = {'id': 321, 'head_sha': SOURCE, 'head_branch': 'ohos', 'run_attempt': 1,
                    'repository': {'id': 123, 'full_name': REPOSITORY},
                    'head_repository': {'id': 123, 'full_name': REPOSITORY},
                    'path': '.github/workflows/ohos.yml', 'name': 'HarmonyOS adaptation',
                    'event': 'workflow_dispatch', 'status': 'completed', 'conclusion': 'success'}
        self.jobs = {'total_count': 2, 'jobs': [
            {'name': name, 'run_id': 321, 'head_sha': SOURCE, 'run_attempt': 1,
             'status': 'completed', 'conclusion': 'success'} for name in ('quality', 'build')]}
        self.artifacts = {'total_count': 1, 'artifacts': [
            {'id': 456, 'name': 'tsukuyomi-space-ohos-unsigned', 'expired': False,
             'expires_at': '2050-01-01T00:00:00Z', 'size_in_bytes': 1000000,
             'digest': 'sha256:' + 'a' * 64, 'workflow_run': {'id': 321, 'head_sha': SOURCE,
                 'head_branch': 'ohos', 'repository_id': 123, 'head_repository_id': 123}}]}
        self.api = FakeGitHub()

    def verify(self):
        def request(path):
            if '/jobs?' in path:
                return self.jobs
            if '/artifacts?' in path:
                return self.artifacts
            return self.run
        with patch.object(self.api, 'request', side_effect=request), patch('release.version_at', return_value=('0.6.21', 28)):
            return verified_artifact(self.api, '321', COMMIT)

    def test_verified_previous_build_can_supply_historical_supplement(self):
        self.assertEqual(self.verify(), {'ref': SOURCE, 'artifact_id': '456', 'run_id': '321'})

    def test_failed_regression_or_foreign_run_is_rejected(self):
        self.jobs['jobs'][0]['conclusion'] = 'failure'
        with self.assertRaisesRegex(ValueError, 'prerequisite'):
            self.verify()
        self.jobs['jobs'][0]['conclusion'] = 'success'
        self.run['head_repository']['id'] = 999
        with self.assertRaisesRegex(ValueError, 'official ohos'):
            self.verify()

    def test_wrong_artifact_source_and_expired_artifact_are_rejected(self):
        artifact = self.artifacts['artifacts'][0]
        artifact['workflow_run']['head_sha'] = COMMIT
        with self.assertRaisesRegex(ValueError, 'provenance'):
            self.verify()
        artifact['workflow_run']['head_sha'] = SOURCE
        artifact['expires_at'] = '2020-01-01T00:00:00Z'
        with self.assertRaisesRegex(ValueError, 'expired'):
            self.verify()

    def test_incomplete_or_duplicate_artifacts_are_rejected(self):
        self.artifacts['total_count'] = 2
        with self.assertRaisesRegex(ValueError, 'listing'):
            self.verify()
        self.artifacts['artifacts'].append(copy.deepcopy(self.artifacts['artifacts'][0]))
        with self.assertRaisesRegex(ValueError, 'one OHOS artifact'):
            self.verify()


if __name__ == '__main__':
    unittest.main()
