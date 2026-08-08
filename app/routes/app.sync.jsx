import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { useLoaderData } from "react-router";
import { boundary } from "@shopify/shopify-app-react-router/server";
import { authenticate } from "../shopify.server";
import prisma from "../db.server";
import { dateTime } from "../lib/format";

export const loader = async ({ request }) => {
  await authenticate.admin(request);

  const runs = await prisma.syncRun.findMany({
    orderBy: { startedAt: "desc" },
    take: 25,
  });

  let logs = [];
  try {
    const root = path.dirname(fileURLToPath(import.meta.url));
    const logPath = path.join(root, "..", "..", "sync-log.jsonl");
    if (fs.existsSync(logPath)) {
      logs = fs
        .readFileSync(logPath, "utf8")
        .trim()
        .split(/\r?\n/)
        .filter(Boolean)
        .slice(-40)
        .map((line) => JSON.parse(line))
        .reverse();
    }
  } catch {
    logs = [];
  }

  return { runs, logs };
};

export default function Sync() {
  const { runs, logs } = useLoaderData();

  return (
    <div className="space-y-6">
      <section>
        <h1 className="font-display text-3xl text-ink">Sync</h1>
        <p className="mt-1 text-sm text-mocha">
          Every pull from Shopify and Square is recorded here. The ops console
          (<code className="font-mono text-xs">local-console.mjs</code>) runs the
          sync loop on a schedule.
        </p>
      </section>

      <section className="grid gap-4 lg:grid-cols-2">
        <div className="card overflow-hidden">
          <div className="card-pad pb-3">
            <h2 className="font-display text-xl text-ink">Sync runs</h2>
          </div>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="border-b border-fog bg-haze/60">
                <tr>
                  <th className="th">Started</th>
                  <th className="th">Mode</th>
                  <th className="th">Source</th>
                  <th className="th">Status</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-fog">
                {runs.length === 0 && (
                  <tr>
                    <td className="td py-8 text-center text-taupe">
                      No syncs recorded yet.
                    </td>
                  </tr>
                )}
                {runs.map((run) => (
                  <tr key={run.id} className="hover:bg-cream">
                    <td className="td whitespace-nowrap text-mocha">
                      {dateTime(run.startedAt)}
                    </td>
                    <td className="td text-mocha">{run.mode}</td>
                    <td className="td text-mocha">{run.source || "—"}</td>
                    <td className="td">
                      <span
                        className={`pill ${
                          run.status === "success"
                            ? "pill-fern"
                            : run.status === "failed"
                              ? "pill-rose"
                              : "pill-taupe"
                        }`}
                      >
                        {run.status}
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>

        <div className="card card-pad">
          <h2 className="font-display text-xl text-ink">Recent log entries</h2>
          <ul className="mt-4 space-y-2.5">
            {logs.length === 0 && (
              <li className="py-3 text-sm text-taupe">
                No log file yet — it appears after the console runs.
              </li>
            )}
            {logs.map((log, index) => (
              <li key={`${log.at}-${index}`} className="flex gap-3">
                <span
                  className={`pill shrink-0 ${
                    log.level === "success"
                      ? "pill-fern"
                      : log.level === "error"
                        ? "pill-rose"
                        : "pill-taupe"
                  }`}
                >
                  {log.level}
                </span>
                <div className="min-w-0">
                  <p className="text-sm text-ink">{log.message}</p>
                  <p className="text-xs text-taupe">{dateTime(log.at)}</p>
                </div>
              </li>
            ))}
          </ul>
        </div>
      </section>
    </div>
  );
}

export const headers = (headersArgs) => {
  return boundary.headers(headersArgs);
};
