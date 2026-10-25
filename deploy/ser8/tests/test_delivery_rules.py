"""The parallel-delivery rule (docs/development-and-deployment-workflow.md §6)
matches the workflow files, the SER8 updater and the page budget test.

If one of these fails, either the code drifted from the documented rule or the
rule changed: update the code and the doc section together.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
WORKFLOWS = ROOT / '.github/workflows'
DOC = (ROOT / 'docs/development-and-deployment-workflow.md').read_text()
UPDATER = (ROOT / 'deploy/ser8/rupert-autodeploy.sh').read_text()
REQUIRED_MAIN_CHECKS = ['CI (sqlite3)', 'Product site consistency', 'Dependency and static scan']
PR_ONLY_CANCEL = "cancel-in-progress: ${{ github.event_name == 'pull_request' }}"


class DeliveryRulesTest(unittest.TestCase):
    def test_main_runs_are_never_cancelled(self):
        for name in ('ci.yml', 'security.yml', 'employee-mobile.yml'):
            text = (WORKFLOWS / name).read_text()
            with self.subTest(workflow=name):
                self.assertIn(PR_ONLY_CANCEL, text)
                group = re.search(r'^\s*group:\s*(.+)$', text, re.M)
                self.assertIsNotNone(group, 'concurrency group missing')
                # PR runs share a group per PR; main runs fall back to their own SHA.
                self.assertIn('github.event.pull_request.number || github.sha', group.group(1))

    def test_push_runs_only_on_main(self):
        for name in ('ci.yml', 'security.yml', 'employee-mobile.yml'):
            text = (WORKFLOWS / name).read_text()
            push = re.search(r'^  push:\n((?:    .*\n)+)', text, re.M)
            with self.subTest(workflow=name):
                self.assertIsNotNone(push, 'push trigger missing')
                self.assertRegex(push.group(1), r'branches:\s*\[main\]')

    def test_updater_gates_the_documented_checks(self):
        self.assertIn(f'gate "$NEW" "{",".join(REQUIRED_MAIN_CHECKS)}"', UPDATER)
        for check in REQUIRED_MAIN_CHECKS:
            self.assertIn(f'`{check}`', DOC)

    def test_mobile_gate_reads_the_newest_mobile_commit(self):
        self.assertRegex(UPDATER, r'mobile_sha=\$\(git log -1 --format=%H "\$CUR\.\.\$NEW" -- mobile ')
        self.assertIn('gate "$mobile_sha" validate', UPDATER)
        self.assertIn('green `validate` on the newest mobile commit', DOC)

    def test_doc_names_the_branch_update_command(self):
        self.assertIn('gh api -X PUT repos/techmore/rupert/pulls/<number>/update-branch', DOC)
        self.assertIn('strict=false', DOC)

    def test_page_budget_runs_on_a_fixed_sunday(self):
        text = (ROOT / 'web/test/integration/page_budget_test.rb').read_text()
        match = re.search(r"travel_to Time\.zone\.parse\('(\d{4})-(\d{2})-(\d{2})", text)
        self.assertIsNotNone(match, 'page budget test must pin its clock')
        import datetime
        day = datetime.date(*map(int, match.groups()))
        self.assertEqual(day.weekday(), 6, f'{day} is not a Sunday')


if __name__ == '__main__':
    unittest.main()
