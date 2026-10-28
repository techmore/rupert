import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from analyze_liquid_tax_experiment import IDS, analyze


class AnalysisTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.cohort = 'finance-cohort-1234567890abcdef'
        for db in ('baseline', 'only', 'budget'):
            with sqlite3.connect(self.root / db) as c:
                c.execute('CREATE TABLE chat_battery_runs (id INTEGER PRIMARY KEY, run_key TEXT, agent TEXT, set_name TEXT, status TEXT, tenant_id TEXT, questions INTEGER, results TEXT)')
        self.insert('baseline', 'qwen', 'qwen', 4)
        self.insert('baseline', 'liquid', 'lfm3-text', 2)
        for arm in ('only', 'budget'):
            for repeat in range(1, 4):
                key = f'{arm}-{repeat}'
                self.insert(arm, key, 'lfm3-text', 3, partial=True)
                (self.root / f'{key}.md').write_text(f'### Run {key} (finance): test\n')

    def insert(self, db, key, agent, grade, partial=False):
        results = [{'id': i, 'grade': grade, 'grader': 'judge', 'seconds': 3, 'status': 'done'} for i in IDS]
        with sqlite3.connect(self.root / db) as c:
            c.execute('INSERT INTO chat_battery_runs (run_key,agent,set_name,status,tenant_id,questions,results) VALUES (?,?,?,?,?,?,?)',
                      (key, agent, self.cohort + (' (part)' if partial else ''), 'done', 'tenant', 4, json.dumps(results)))

    def result(self):
        return analyze(self.root / 'baseline', {'only': self.root / 'only', 'budget': self.root / 'budget'}, self.root)

    def test_paired_comparison(self):
        run = self.result()['arms']['only'][0]
        self.assertEqual(run['vs_qwen']['losses'], 4)
        self.assertEqual(run['vs_original_liquid']['wins'], 4)

    def test_ungraded_is_not_imputed(self):
        with sqlite3.connect(self.root / 'only') as c:
            data = json.loads(c.execute("SELECT results FROM chat_battery_runs WHERE run_key='only-1'").fetchone()[0])
            data[0].update(grade=None, grader=None, status='failed')
            c.execute("UPDATE chat_battery_runs SET results=? WHERE run_key='only-1'", (json.dumps(data),))
        run = self.result()['arms']['only'][0]
        self.assertEqual((run['metrics']['failed'], run['vs_qwen']['paired_graded'], run['vs_qwen']['unpaired']), (1, 3, 1))

    def test_cohort_mismatch_fails(self):
        with sqlite3.connect(self.root / 'budget') as c:
            c.execute("UPDATE chat_battery_runs SET set_name='finance-cohort-ffffffffffffffff (part)'")
        with self.assertRaises(ValueError):
            self.result()

    def test_incomplete_report_fails(self):
        (self.root / 'only-1.md').write_text('incomplete')
        with self.assertRaises(ValueError):
            self.result()


if __name__ == '__main__':
    unittest.main()
