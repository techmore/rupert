"""Every RUPERT_* variable that code reads is listed in
docs/ops/environment-reference.md.

Add a new variable to that page (with its default and purpose) in the same
change that starts reading it.
"""
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[3]
DOC = ROOT / 'docs/ops/environment-reference.md'
# A name, not part of a longer one (ASK_RUPERT_MODE, EXPO_PUBLIC_RUPERT_URL).
NAME = re.compile(r'(?<![A-Za-z0-9_])RUPERT_[A-Z0-9_]*[A-Z0-9](_\*)?')
# RUPERT_* identifiers that are not environment variables.
NOT_ENV = {
    'RUPERT_SOURCES': 'Ruby constant in web/app/services/swipesimple_tender_match.rb',
}
SKIP_SUFFIXES = ('.md', '.html', '.png', '.jpg', '.svg', '.ico', '.lock', '.pdf')


def code_files():
    listed = subprocess.run(['git', 'ls-files'], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    for name in listed.splitlines():
        parts = Path(name).parts
        if parts[0] == 'docs' or name.endswith(SKIP_SUFFIXES):
            continue
        if 'test' in parts or 'tests' in parts:
            continue
        path = ROOT / name
        if path.is_file():
            yield name, path


class EnvironmentReferenceTest(unittest.TestCase):
    def test_every_rupert_variable_is_documented(self):
        documented = set(m.group(0) for m in NAME.finditer(DOC.read_text()))
        missing = {}
        for name, path in code_files():
            try:
                text = path.read_text(errors='ignore')
            except OSError:
                continue
            for match in NAME.finditer(text):
                var = match.group(0)
                if var in NOT_ENV or var in documented:
                    continue
                if var.endswith('_*'):
                    # A family (RUPERT_SQLITE_DATABASE_*): some member must be listed.
                    if any(d.startswith(var[:-1]) for d in documented):
                        continue
                missing.setdefault(var, name)
        self.assertEqual({}, missing, f'Document these in {DOC.relative_to(ROOT)} (variable: first file)')

    def test_not_env_names_are_still_used(self):
        for var, where in NOT_ENV.items():
            with self.subTest(var=var):
                path = ROOT / where.split(' in ')[-1]
                self.assertIn(var, path.read_text(), f'{var} is gone; drop it from NOT_ENV')


if __name__ == '__main__':
    unittest.main()
