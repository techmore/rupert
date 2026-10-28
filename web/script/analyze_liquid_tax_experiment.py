#!/usr/bin/env python3
"""Compare the isolated Liquid tax trials with their frozen-cohort baselines."""
import argparse
import json
import re
import sqlite3
from pathlib import Path
from statistics import mean

IDS = {"f15", "f16", "f31", "f32"}


def read_run(db, *, run_key=None, agent=None, cohort=None):
    with sqlite3.connect(f"file:{Path(db).resolve()}?mode=ro", uri=True) as connection:
        connection.row_factory = sqlite3.Row
        if run_key:
            rows = connection.execute("SELECT * FROM chat_battery_runs WHERE run_key = ?", (run_key,)).fetchall()
        else:
            rows = connection.execute(
                "SELECT * FROM chat_battery_runs WHERE agent = ? AND set_name = ? AND status = 'done' ORDER BY id DESC LIMIT 1",
                (agent, cohort),
            ).fetchall()
    if len(rows) != 1:
        raise ValueError(f"Expected one run for {run_key or agent}, found {len(rows)}")
    row = dict(rows[0])
    if row['status'] != 'done':
        raise ValueError(f"Run {row['run_key']} is not complete")
    results = json.loads(row['results'])
    selected = [item for item in results if item['id'] in IDS]
    if len(selected) != 4 or {item['id'] for item in selected} != IDS:
        raise ValueError(f"Run {row['run_key']} lacks the four unique tuning questions")
    row['selected'] = {item['id']: item for item in selected}
    return row


def valid_grade(value):
    return type(value) in (int, float) and 1 <= value <= 5


def metrics(run):
    rows = list(run['selected'].values())
    grades = [r['grade'] for r in rows if valid_grade(r.get('grade'))]
    seconds = [r['seconds'] for r in rows if type(r.get('seconds')) in (int, float) and r['seconds'] >= 0]
    return {'run_key': run['run_key'], 'questions': len(rows), 'graded': len(grades),
            'mean_grade': mean(grades) if grades else None, 'failed': sum(r.get('status') != 'done' for r in rows),
            'timed': len(seconds), 'mean_seconds': mean(seconds) if seconds else None}


def paired(base, candidate):
    pairs = []
    for question in sorted(IDS):
        a, b = base['selected'][question], candidate['selected'][question]
        if valid_grade(a.get('grade')) and valid_grade(b.get('grade')):
            if not a.get('grader') or a.get('grader') != b.get('grader'):
                raise ValueError(f"Grader missing or changed for {question}")
            pairs.append(b['grade'] - a['grade'])
    return {'paired_graded': len(pairs), 'unpaired': len(IDS) - len(pairs),
            'wins': sum(x > 0 for x in pairs), 'ties': sum(x == 0 for x in pairs),
            'losses': sum(x < 0 for x in pairs), 'mean_grade_difference': mean(pairs) if pairs else None}


def analyze(baseline_db, arm_dbs, report_dir):
    trials = {}
    for arm, db in arm_dbs.items():
        trials[arm] = []
        for repeat in range(1, 4):
            report = (Path(report_dir) / f'{arm}-{repeat}.md').read_text()
            matches = re.findall(r'^### Run (\S+) \(finance\):', report, re.MULTILINE)
            if len(matches) != 1:
                raise ValueError(f'Expected one run header in {arm}-{repeat}.md')
            run = read_run(db, run_key=matches[0])
            if run['agent'] != 'lfm3-text' or not run['set_name'].endswith(' (part)') or run['questions'] != 4:
                raise ValueError(f"Unexpected experimental run {run['run_key']}")
            trials[arm].append(run)
    all_runs = [r for runs in trials.values() for r in runs]
    if len({r['run_key'] for r in all_runs}) != 6:
        raise ValueError('Repeated run keys in reports')
    cohort = all_runs[0]['set_name'].removesuffix(' (part)')
    if not re.fullmatch(r'finance-cohort-[0-9a-f]{16}', cohort):
        raise ValueError('Unexpected cohort')
    baselines = {agent: read_run(baseline_db, agent=agent, cohort=cohort) for agent in ('qwen', 'lfm3-text')}
    if any(r['set_name'].removesuffix(' (part)') != cohort or r['tenant_id'] != all_runs[0]['tenant_id'] for r in all_runs + list(baselines.values())):
        raise ValueError('Cohort or tenant differs between runs')
    return {'caveat': 'Four tuning questions; one Qwen baseline; DeepSeek grades both models. Not a held-out or independent quality comparison.',
            'cohort': cohort, 'baselines': {k: metrics(v) for k, v in baselines.items()},
            'arms': {arm: [{'metrics': metrics(run), 'vs_qwen': paired(baselines['qwen'], run),
                            'vs_original_liquid': paired(baselines['lfm3-text'], run)} for run in runs]
                     for arm, runs in trials.items()}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ('baseline', 'only-db', 'budget-db', 'report-dir', 'output'):
        parser.add_argument('--' + arg, required=True)
    args = parser.parse_args()
    result = analyze(args.baseline, {'only': args.only_db, 'budget': args.budget_db}, args.report_dir)
    Path(args.output).write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
