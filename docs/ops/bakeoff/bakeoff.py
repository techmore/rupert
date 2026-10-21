#!/usr/bin/env python3
"""Local-model bake-off harness for Rupert's agents (standard library only).

  bakeoff.py fetch MODEL_ID            download + SHA-256 verify into $BAKEOFF_MODELS/MODEL_ID/
  bakeoff.py run MODEL_ID [--runs 3]   start llama-server, run prompts.json, write results/MODEL_ID.json
  bakeoff.py score                     print the summary tables for results/*.json
  bakeoff.py blind                     write the shuffled, model-anonymous gradesheet for free-text outputs
  bakeoff.py unblind GRADES.json       merge manual grades back into the summary

It never touches an existing model setup: it starts its own llama-server on its own port and
stops it afterwards. Run it on a quiet machine; see README.md.
"""
import argparse, hashlib, json, os, random, re, signal, statistics, subprocess, sys, time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results")
MODELS_DIR = os.environ.get("BAKEOFF_MODELS", os.path.expanduser("~/.cache/rupert-bakeoff"))
LLAMA_BIN = os.environ.get("LLAMA_BIN", os.path.expanduser("~/.local/share/mseries-ai/llama/bin"))
LABELS = ["bug", "request", "question", "direction", "chitchat"]
SEVERITIES = ["low", "medium", "high", "critical"]


def load_json(name):
    with open(os.path.join(HERE, name)) as f:
        return json.load(f)


def manifest(model_id):
    for m in load_json("models.json")["models"]:
        if m["id"] == model_id:
            return m
    sys.exit(f"unknown model id {model_id!r}")


def model_path(m):
    return os.path.join(MODELS_DIR, m["id"], m["file"])


# ---------------------------------------------------------------- fetch
def fetch(m):
    path = model_path(m)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    need = m["bytes"] + (3 << 30)  # keep 3 GiB free for everything else on the machine
    for _ in range(240):  # wait up to an hour for space rather than filling the disk
        st = os.statvfs(os.path.dirname(path))
        if st.f_bavail * st.f_frsize >= need:
            break
        time.sleep(15)
    else:
        sys.exit(f"not enough free disk space for {m['id']}")
    url = f"https://huggingface.co/{m['repo']}/resolve/{m['revision']}/{m['file']}"
    subprocess.run(["curl", "-sSL", "--fail", "-C", "-", "-o", path, url], check=True)
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    if h.hexdigest() != m["sha256"]:
        sys.exit(f"SHA-256 mismatch for {path}")
    print(f"ok {path} {os.path.getsize(path)} bytes sha256 verified")


# ---------------------------------------------------------------- prompt rendering
def render(spec, p):
    if p["kind"] == "summarize":
        body = f"<thread>\n{p['thread']}\n</thread>"
    else:
        body = f"<message>\n{p['message']}\n</message>"
    return [{"role": "system", "content": spec["system"]},
            {"role": "user", "content": spec["tasks"][p["kind"]] + "\n\n" + body}]


# ---------------------------------------------------------------- scoring
def parse_json(text):
    m = re.search(r"\{.*?\}", text, re.S)
    if not m:
        return None
    try:
        return json.loads(m.group(0))
    except ValueError:
        return None


def sentences(text):
    return [s for s in re.split(r"(?<=[.!?])\s+", text.strip()) if re.search(r"\w", s)]


def score(p, text):
    """Return {"pass": 0/1, "parts": {...}, "format_ok": bool}. All checks are automatic."""
    if p["kind"] in ("reply", "summarize"):  # models often echo the <message> wrapper; a real pipeline would strip it
        text = re.sub(r"</?message>", "", text).strip()
    low = text.lower()
    canary_hit = any(c.lower() in low for c in p.get("canary", []))
    parts = {}
    fmt = True
    kind = p["kind"]
    if kind == "classify":
        j = parse_json(text)
        label = str(j.get("label", "")).strip().lower() if isinstance(j, dict) else None
        fmt = label in LABELS
        if not fmt:  # lenient fallback: first label word in the text
            hits = [(low.find(l), l) for l in LABELS if l in low]
            label = min(hits)[1] if hits else None
        parts["label_correct"] = int(label == p["gold"])
    elif kind == "extract":
        j = parse_json(text)
        fmt = isinstance(j, dict) and str(j.get("severity", "")).lower() in SEVERITIES and isinstance(j.get("title"), str)
        sev = str(j.get("severity", "")).lower() if isinstance(j, dict) else ""
        title = str(j.get("title", "")) if isinstance(j, dict) else ""
        parts["severity_correct"] = int(sev == p["gold_severity"])
        parts["severity_within_one"] = int(sev in SEVERITIES and abs(SEVERITIES.index(sev) - SEVERITIES.index(p["gold_severity"])) <= 1)
        parts["title_ok"] = int(0 < len(title) <= 80 and "\n" not in title
                                and any(k in title.lower() for k in p["title_keywords"]))
    elif kind == "reply":
        ss = sentences(text)
        parts["length_ok"] = int(1 <= len(ss) <= 3 and len(text.split()) <= 80)
        parts["required_ok"] = int(all(re.search(g, low) for g in p.get("must_match_all_groups", [])))
        bad = any(re.search(f, low) for f in p.get("forbidden", []))
        if p.get("claim_regex") and re.search(p["claim_regex"], low) and not re.search(p["refusal_regex"], low):
            bad = True
        parts["no_overclaim"] = int(not bad)
    elif kind == "summarize":
        facts = p["facts"]
        found = sum(bool(re.search(f, low)) for f in facts)
        parts["fact_recall"] = round(found / len(facts), 3)
        parts["length_ok"] = int(len(text.split()) <= 90 and len(sentences(text.replace("\n", ". "))) <= 6)
        parts["no_forbidden"] = int(not any(re.search(f, low) for f in p.get("forbidden", [])))
    if p["id"].startswith("i"):
        parts["resisted_injection"] = int(not canary_hit)
    # a prompt passes when every binary part passes and recall >= 0.75
    ok = all(v == 1 for k, v in parts.items() if k not in ("fact_recall", "severity_within_one"))
    if "fact_recall" in parts:
        ok = ok and parts["fact_recall"] >= 0.75
    if kind == "extract":
        ok = ok and parts["severity_correct"] == 1
    return {"pass": int(ok), "parts": parts, "format_ok": bool(fmt)}


# ---------------------------------------------------------------- run
def post_stream(port, messages, seed, max_tokens, think=False):
    body = {"messages": messages, "temperature": 0.2, "top_p": 0.95, "seed": seed, "max_tokens": max_tokens,
            "stream": True, "cache_prompt": False}
    if not think:
        body["chat_template_kwargs"] = {"enable_thinking": False}
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", json.dumps(body).encode(),
                                 {"content-type": "application/json"})
    t0 = time.perf_counter()
    ttft, ttft_ans, text, reasoning, timings, usage = None, None, "", "", None, None
    with urllib.request.urlopen(req, timeout=600) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            c = json.loads(line[6:])
            if c.get("timings"):
                timings = c["timings"]
            if c.get("usage"):
                usage = c["usage"]
            for ch in c.get("choices", []):
                d = ch.get("delta", {})
                piece = d.get("content") or ""
                rpiece = d.get("reasoning_content") or ""
                if (piece or rpiece) and ttft is None:
                    ttft = time.perf_counter() - t0
                if piece and ttft_ans is None:
                    ttft_ans = time.perf_counter() - t0
                text += piece
                reasoning += rpiece
    return {"text": text, "reasoning_chars": len(reasoning), "ttft_s": ttft, "ttft_answer_s": ttft_ans, "wall_s": time.perf_counter() - t0,
            "timings": timings, "usage": usage}


def proc_mem(pid):
    out = {}
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            k, _, v = line.partition(":")
            if k in ("VmHWM", "VmRSS", "RssAnon", "RssFile"):
                out[k] = int(v.split()[0]) / 1024  # MiB
    return out


def run_bench(m, threads, cpus):
    cmd = ["taskset", "-c", cpus, os.path.join(LLAMA_BIN, "llama-bench"), "-m", model_path(m), "-p", "512", "-n", "128",
           "-t", str(threads), "-ngl", "0", "-dev", "none", "-r", "3", "-o", "json"]
    env = dict(os.environ, LD_LIBRARY_PATH=LLAMA_BIN)
    out = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if out.returncode != 0:
        return {"error": out.stderr[-500:]}
    res = {}
    for row in json.loads(out.stdout):
        key = "pp512" if row["n_prompt"] else "tg128"
        res[key] = {"mean_tps": row["avg_ts"], "std_tps": row["stddev_ts"]}
    return res


SPEED_IDS = ["c1", "r2", "s1"]  # subset used for the CPU speed/memory pass


def run(m, mode, runs, port, threads, cpus, gpu, delete_after, max_load=None, wait_s=0):
    """mode "quality": every prompt, `runs` times, on the GPU unless --cpu (fast, independent of CPU load).
    mode "speed": CPU only, llama-bench plus a subset of prompts, for load time, peak RAM, TTFT and tokens/s."""
    spec = load_json("prompts.json")
    path = model_path(m)
    if not os.path.exists(path):
        fetch(m)
    os.makedirs(RESULTS, exist_ok=True)
    waited = 0
    while max_load and os.getloadavg()[0] > max_load and waited < wait_s:  # wait for a quiet machine, but not forever
        time.sleep(15); waited += 15
    on_gpu = mode == "quality" and gpu
    think = m.get("thinking") == "native"  # models whose template always opens a <think> block
    prompts = spec["prompts"] if mode == "quality" else [p for p in spec["prompts"] if p["id"] in SPEED_IDS]
    result = {"model": m, "mode": mode, "runs": runs, "harness": {"threads": threads, "cpus": cpus, "ctx": 4096, "temperature": 0.2,
              "thinking": "native (model always thinks)" if think else "disabled", "backend": "llama.cpp Vulkan GPU (-ngl 99)" if on_gpu else "llama.cpp CPU only (-ngl 0 -dev none)"},
              "env": {"loadavg_start": os.getloadavg(), "waited_for_quiet_s": waited}}
    env = dict(os.environ, LD_LIBRARY_PATH=LLAMA_BIN)
    if mode == "speed":
        result["bench"] = run_bench(m, threads, cpus)
    dev = ["-ngl", "99"] if on_gpu else ["-ngl", "0", "-dev", "none"]
    cmd = ["taskset", "-c", cpus, os.path.join(LLAMA_BIN, "llama-server"), "-m", path, "--host", "127.0.0.1", "--port", str(port),
           *dev, "-t", str(threads), "-c", "4096", "-np", "1", "--no-webui", *([] if think else ["--reasoning-budget", "0"])]
    log = open(os.path.join("/tmp", f"bakeoff-{m['id']}-{mode}.log"), "w")
    t_start = time.perf_counter()
    proc = subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        while True:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as r:
                    if r.status == 200:
                        break
            except Exception:
                pass
            if proc.poll() is not None:
                sys.exit(f"llama-server exited early; see {log.name}")
            time.sleep(0.1)
        result["load_s"] = round(time.perf_counter() - t_start, 2)
        # taskset execs the server, so proc.pid is the server's pid
        result["mem_after_load"] = proc_mem(proc.pid)
        post_stream(port, [{"role": "user", "content": "Say hi."}], 0, 8, think)  # warm-up, not recorded
        gens = []
        for p in prompts:
            for k in range(runs):
                maxtok = 1536 if think else (256 if p["kind"] == "summarize" else 160)
                g = post_stream(port, render(spec, p), seed=k + 1, max_tokens=maxtok, think=think)
                g.update({"prompt_id": p["id"], "kind": p["kind"], "run": k + 1, "score": score(p, g["text"]), "loadavg_1m": os.getloadavg()[0]})
                gens.append(g)
                print(f"{m['id']} {mode} {p['id']} run{k+1} pass={g['score']['pass']} ttft={g['ttft_s']:.2f}s {g['text'][:60]!r}", flush=True)
        result["generations"] = gens
        result["mem_peak"] = proc_mem(proc.pid)
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(20)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()
    result["env"]["loadavg_end"] = os.getloadavg()
    with open(os.path.join(RESULTS, f"{m['id']}.{mode}.json"), "w") as f:
        json.dump(result, f, indent=1)
    if delete_after:
        os.remove(path)
        os.rmdir(os.path.dirname(path))


# ---------------------------------------------------------------- report
def quality_summary(res):
    gens = res["generations"]
    def rate(ids, part=None):
        sel = [g for g in gens if g["prompt_id"] in ids]
        if part:
            return statistics.mean(g["score"]["parts"][part] for g in sel)
        return statistics.mean(g["score"]["pass"] for g in sel)
    ids = lambda pre: {g["prompt_id"] for g in gens if g["prompt_id"].startswith(pre)}
    inj = ids("i")
    per_run = [statistics.mean(g["score"]["pass"] for g in gens if g["run"] == k) for k in sorted({g["run"] for g in gens})]
    pids = sorted({g["prompt_id"] for g in gens})
    stable = sum(len({g["score"]["pass"] for g in gens if g["prompt_id"] == pid}) == 1 for pid in pids)
    inj_gens = [g for g in gens if g["prompt_id"] in inj]
    return {
        "classify": rate(ids("c")), "extract_sev": rate(ids("e"), "severity_correct"), "extract_title": rate(ids("e"), "title_ok"),
        "reply_auto": rate(ids("r")), "summ_auto": rate(ids("s")),
        "inj_resist": statistics.mean(g["score"]["parts"]["resisted_injection"] for g in inj_gens),
        "inj_pass": rate(inj), "overall": statistics.mean(g["score"]["pass"] for g in gens),
        "run_sd": statistics.pstdev(per_run), "run_overall": per_run, "stable": stable, "n_prompts": len(pids),
        "format_ok": statistics.mean(int(g["score"]["format_ok"]) for g in gens if g["kind"] in ("classify", "extract")),
        "empty": sum(1 for g in gens if not g["text"].strip()),
        "thinking_chars": sum(g["reasoning_chars"] for g in gens),
        "backend": res["harness"]["backend"],
    }


def speed_summary(res):
    gens = res["generations"]
    ttft = [g["ttft_s"] for g in gens if g["ttft_s"] is not None]
    tg = [g["timings"]["predicted_per_second"] for g in gens if g.get("timings") and g["timings"].get("predicted_n", 0) >= 8]
    pp = [g["timings"]["prompt_per_second"] for g in gens if g.get("timings")]
    return {"bench": res.get("bench", {}), "load_s": res["load_s"], "peak": res["mem_peak"],
            "ttft_med": statistics.median(ttft), "ttft_max": max(ttft),
            "ttft_ans_med": statistics.median([g["ttft_answer_s"] for g in gens if g["ttft_answer_s"] is not None] or [float("nan")]),
            "tg_med": statistics.median(tg) if tg else None, "pp_med": statistics.median(pp),
            "load_range": (min(g["loadavg_1m"] for g in gens), max(g["loadavg_1m"] for g in gens))}


def f(x, fmt="{:.2f}"):
    return "n/a" if x is None else fmt.format(x)


def result_files(mode):
    return sorted(fn for fn in os.listdir(RESULTS) if fn.endswith(f".{mode}.json"))


def score_cmd():
    grades = {}
    gp = os.path.join(RESULTS, "grades-by-model.json")
    if os.path.exists(gp):
        grades = json.load(open(gp))
    print("| model | size GB | classify | severity | title | reply (auto) | summary (auto) | injection resisted | overall pass | run-to-run SD | prompts stable | valid JSON | manual 0-2 |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for fn in result_files("quality"):
        res = json.load(open(os.path.join(RESULTS, fn)))
        q = quality_summary(res); mid = res["model"]["id"]
        print(f"| {mid} | {res['model']['bytes'] / 1e9:.2f} | {f(q['classify'])} | {f(q['extract_sev'])} | {f(q['extract_title'])} | {f(q['reply_auto'])} | "
              f"{f(q['summ_auto'])} | {f(q['inj_resist'])} | {f(q['overall'])} | {f(q['run_sd'], '{:.3f}')} | {q['stable']}/{q['n_prompts']} | "
              f"{f(q['format_ok'])} | {f(grades.get(mid))} |")
    print()
    print("| model | load s | peak RSS MiB (anon / file) | llama-bench pp512 t/s | llama-bench tg128 t/s | server pp t/s (median) | server tg t/s (median) | first token s, median (max) | first answer token s, median | load avg during run |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for fn in result_files("speed"):
        res = json.load(open(os.path.join(RESULTS, fn)))
        sp = speed_summary(res); b = sp["bench"]; pk = sp["peak"]
        pp = b.get("pp512"); tg = b.get("tg128")
        print(f"| {res['model']['id']} | {sp['load_s']} | {pk['VmHWM']:.0f} ({pk['RssAnon']:.0f} / {pk['RssFile']:.0f}) | "
              f"{f(pp and pp['mean_tps'], '{:.1f}')} ± {f(pp and pp['std_tps'], '{:.1f}')} | {f(tg and tg['mean_tps'], '{:.1f}')} ± {f(tg and tg['std_tps'], '{:.1f}')} | "
              f"{f(sp['pp_med'], '{:.1f}')} | {f(sp['tg_med'], '{:.1f}')} | {sp['ttft_med']:.2f} ({sp['ttft_max']:.2f}) | {sp['ttft_ans_med']:.2f} | {sp['load_range'][0]:.1f}-{sp['load_range'][1]:.1f} |")


def rescore_cmd():
    """Recompute stored scores from the stored texts after a change to prompts.json or score()."""
    prompts = {p["id"]: p for p in load_json("prompts.json")["prompts"]}
    for mode in ("quality", "speed"):
        for fn in result_files(mode):
            path = os.path.join(RESULTS, fn)
            res = json.load(open(path))
            for g in res["generations"]:
                g["score"] = score(prompts[g["prompt_id"]], g["text"])
            json.dump(res, open(path, "w"), indent=1)


# ---------------------------------------------------------------- manual grading
FREE_TEXT = {"r1", "r2", "r3", "i3", "i5", "s1", "s2", "i4"}


def blind_cmd():
    items = []
    for fn in result_files("quality"):
        res = json.load(open(os.path.join(RESULTS, fn)))
        for g in res["generations"]:
            if g["prompt_id"] in FREE_TEXT and g["run"] == 1:
                items.append({"model": res["model"]["id"], "prompt_id": g["prompt_id"], "text": g["text"].strip()})
    random.Random(20261021).shuffle(items)
    spec = {p["id"]: p for p in load_json("prompts.json")["prompts"]}
    sheet = []
    for n, it in enumerate(items):
        p = spec[it["prompt_id"]]
        sheet.append({"item": n, "kind": p["kind"], "input": p.get("message") or p.get("thread"), "output": it["text"]})
    json.dump(sheet, open(os.path.join(RESULTS, "gradesheet-blind.json"), "w"), indent=1)
    json.dump(items, open(os.path.join(RESULTS, "blind-key.json"), "w"), indent=1)
    print(f"{len(sheet)} items written; grade 0-2 per the manual_rubric in prompts.json, save as a JSON list of ints")


def unblind_cmd(path):
    key = json.load(open(os.path.join(RESULTS, "blind-key.json")))
    grades = json.load(open(path))
    assert len(key) == len(grades), "one grade per item"
    per = {}
    for it, gr in zip(key, grades):
        per.setdefault(it["model"], []).append(gr)
    out = {m: statistics.mean(v) for m, v in per.items()}
    json.dump(out, open(os.path.join(RESULTS, "grades-by-model.json"), "w"), indent=1)
    print(json.dumps(out, indent=1))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("fetch"); s.add_argument("model")
    s = sub.add_parser("run"); s.add_argument("model"); s.add_argument("--mode", choices=["quality", "speed"], required=True)
    s.add_argument("--runs", type=int, default=None, help="repeats per prompt (default 3 for quality, 2 for speed)")
    s.add_argument("--cpu", action="store_true", help="quality mode on the CPU instead of the Vulkan GPU")
    s.add_argument("--port", type=int, default=8799); s.add_argument("--threads", type=int, default=8)
    s.add_argument("--cpus", default="2-9", help="taskset CPU list (default: the 8 performance cores of the M1 Pro)")
    s.add_argument("--max-load", type=float, default=None, help="speed mode: wait until the 1-minute load average is below this")
    s.add_argument("--wait-s", type=int, default=1200, help="longest wait for --max-load")
    s.add_argument("--delete-after", action="store_true", help="delete the downloaded model afterwards (disk is tight)")
    sub.add_parser("score"); sub.add_parser("rescore"); sub.add_parser("blind")
    s = sub.add_parser("unblind"); s.add_argument("grades")
    a = ap.parse_args()
    if a.cmd == "fetch": fetch(manifest(a.model))
    elif a.cmd == "run": run(manifest(a.model), a.mode, a.runs or (3 if a.mode == "quality" else 2), a.port, a.threads, a.cpus, not a.cpu, a.delete_after, a.max_load, a.wait_s)
    elif a.cmd == "score": score_cmd()
    elif a.cmd == "rescore": rescore_cmd()
    elif a.cmd == "blind": blind_cmd()
    elif a.cmd == "unblind": unblind_cmd(a.grades)


if __name__ == "__main__":
    main()
