import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parents[1]))
import check_installed_drift as m


class InstalledDriftTest(unittest.TestCase):
    def test_every_manifest_source_exists_in_the_repository(self):
        for _scope, repo_file, _installed in m.MANIFEST:
            self.assertTrue((m.DEPLOY / repo_file).is_file(), repo_file)

    def test_manifest_scopes_are_known_and_installed_paths_unique(self):
        self.assertLessEqual({scope for scope, _, _ in m.MANIFEST}, {'host', 'container'})
        installed = [(scope, path) for scope, _, path in m.MANIFEST]
        self.assertEqual(len(installed), len(set(installed)))

    def test_compare_reports_same_drift_and_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            deploy = Path(tmp)
            (deploy / 'a').write_bytes(b'one')
            (deploy / 'b').write_bytes(b'two')
            (deploy / 'c').write_bytes(b'three')
            manifest = (('host', 'a', '/x/a'), ('host', 'b', '/x/b'), ('container', 'c', '/x/c'))
            files = {'/x/a': b'one', '/x/b': b'old'}
            readers = {'host': files.get, 'container': files.get}
            self.assertEqual(
                [status for status, _, _ in m.compare(manifest, readers, deploy)],
                ['same', 'drift', 'missing'],
            )

    def run_main(self, readers, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = m.main(list(argv), readers)
        return code, out.getvalue()

    def test_exit_zero_when_everything_matches(self):
        contents = {path: (m.DEPLOY / repo).read_bytes() for _, repo, path in m.MANIFEST}
        readers = {'host': contents.get, 'container': contents.get}
        code, output = self.run_main(readers)
        self.assertEqual(code, 0)
        self.assertIn('all', output)

    def test_exit_one_and_names_the_file_when_one_differs(self):
        contents = {path: (m.DEPLOY / repo).read_bytes() for _, repo, path in m.MANIFEST}
        contents['/usr/local/sbin/rupert-backup-frequent.sh'] = b'old'
        readers = {'host': contents.get, 'container': contents.get}
        code, output = self.run_main(readers, '--quiet')
        self.assertEqual(code, 1)
        self.assertEqual(output.count('DRIFT'), 1)
        self.assertIn('/usr/local/sbin/rupert-backup-frequent.sh', output)

    def test_unreadable_container_exits_two(self):
        def broken(_path):
            raise m.ContainerError('no such instance')
        code, _ = self.run_main({'host': lambda _p: None, 'container': broken})
        self.assertEqual(code, 2)


if __name__ == '__main__':
    unittest.main()
