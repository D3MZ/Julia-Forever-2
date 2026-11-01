#!/usr/bin/env python3
"""Render the Julia line-history image from Hercules' hourly burndown data."""

import argparse
from datetime import datetime, timedelta, timezone
from pathlib import Path
import subprocess

import matplotlib
matplotlib.use("Agg")
import matplotlib.dates as mdates
import matplotlib.pyplot as plt
from matplotlib import colors, ticker
import numpy as np
import yaml

# The first substantial Julia code arrived in the 06:00 UTC cohort.
START_HOUR = datetime(2026, 10, 31, 6, tzinfo=timezone.utc)
HOUR = timedelta(hours=1)


def parse_burndown(output):
    """Return the first UTC hour and rectangular hourly Hercules matrix."""
    report = yaml.safe_load(output)
    if not isinstance(report, dict):
        raise ValueError("Hercules returned an empty or invalid report")
    metadata = report.get("hercules", {})
    burndown = report.get("Burndown", {})
    if not isinstance(metadata, dict) or not isinstance(burndown, dict):
        raise ValueError("Hercules returned invalid report sections")
    if (burndown.get("tick_size"), burndown.get("granularity"), burndown.get("sampling")) != (3600, 1, 1):
        raise ValueError("Expected hourly Hercules cohorts and snapshots")
    project = burndown.get("project")
    if not isinstance(project, str) or not project.strip():
        raise ValueError("Hercules returned no project burndown data")
    try:
        rows = [[int(value) for value in line.split()] for line in project.splitlines() if line.strip()]
        if not rows or not rows[0] or any(len(row) != len(rows[0]) for row in rows):
            raise ValueError("Burndown matrix is empty or not rectangular")
        if any(value < 0 for row in rows for value in row):
            raise ValueError("Burndown matrix contains negative line counts")
        origin = datetime.fromtimestamp(metadata["begin_unix_time"], timezone.utc).replace(
            minute=0, second=0, microsecond=0
        )
    except (KeyError, OverflowError, TypeError) as exc:
        raise ValueError("Hercules returned invalid burndown metadata") from exc
    return origin, np.asarray(rows, dtype=np.int64)


def visible_history(origin, rows, start=START_HOUR):
    """Select hourly states at and after the first substantial code cohort."""
    offset = max(0, int((start - origin).total_seconds() // HOUR.total_seconds()))
    if offset >= len(rows):
        raise ValueError("No hourly burndown data at or after the requested start")
    visible = rows[offset:]
    if not np.any(visible[0]):
        raise ValueError("The selected start hour contains no Julia lines")
    times = [origin + i * HOUR for i in range(offset, len(rows))]
    # Each row is the final state in its hour. Extend the last state to its end.
    times.append(times[-1] + HOUR)
    return times, np.vstack((visible, visible[-1]))


def render_chart(origin, rows, output):
    """Generate the plot from hourly data; never crop a rendered image."""
    times, visible = visible_history(origin, rows)
    present = np.any(visible != 0, axis=0)
    born = [origin + i * HOUR for i in range(rows.shape[1]) if present[i]]
    data = visible[:, present].T
    final_lines = int(visible[-1].sum())
    cmap = matplotlib.colormaps["turbo"]
    norm = colors.Normalize(mdates.date2num(origin), mdates.date2num(times[-1]))

    plt.rcParams.update({
        "font.family": "DejaVu Sans",
        "figure.facecolor": "#f8fafc",
        "axes.facecolor": "#ffffff",
        "text.color": "#172033",
        "axes.labelcolor": "#34445a",
        "xtick.color": "#53647b",
        "ytick.color": "#53647b",
        "font.size": 11,
    })
    fig = plt.figure(figsize=(13, 7.2), constrained_layout=False)
    ax = fig.add_axes([0.085, 0.275, 0.875, 0.53])
    fig.text(0.085, 0.92, "Hercules · hourly cohorts", fontsize=22, fontweight="bold", color="#142235")
    fig.text(0.085, 0.865, "Julia Forever 2  ·  Julia files  ·  UTC", fontsize=11, color="#53647b")
    ax.stackplot(times, *data, colors=[cmap(norm(mdates.date2num(date))) for date in born],
                 step="post", linewidth=0)
    ax.set_xlim(times[0], times[-1])
    ax.set_ylim(0, max(1, final_lines * 1.16, float(visible.sum(axis=1).max()) * 1.16))
    ax.set_ylabel("Julia lines", fontsize=12, labelpad=8)
    ax.yaxis.set_major_formatter(ticker.StrMethodFormatter("{x:,.0f}"))
    ax.yaxis.set_major_locator(ticker.MaxNLocator(nbins=5))
    ax.xaxis.set_major_locator(mdates.AutoDateLocator(minticks=3, maxticks=7, tz=timezone.utc))
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%b %d\n%H:%M", tz=timezone.utc))
    ax.tick_params(axis="both", length=0, pad=8)
    ax.grid(axis="y", color="#dce4ed", linewidth=0.8, alpha=0.85)
    ax.set_axisbelow(True)
    for edge in ("top", "right", "left"):
        ax.spines[edge].set_visible(False)
    ax.spines["bottom"].set_color("#cbd5e1")
    ax.annotate(f"{final_lines:,} lines", xy=(times[-1], final_lines), xytext=(-7, 10),
                textcoords="offset points", ha="right", va="bottom", fontsize=12,
                fontweight="bold", color="#142235",
                bbox=dict(boxstyle="round,pad=0.32", fc="white", ec="#cbd5e1", alpha=0.96))

    cax = fig.add_axes([0.14, 0.138, 0.72, 0.025])
    cb = fig.colorbar(matplotlib.cm.ScalarMappable(norm=norm, cmap=cmap), cax=cax,
                      orientation="horizontal")
    ticks = np.linspace(mdates.date2num(origin), mdates.date2num(times[-1]), 4)
    cb.set_ticks(ticks)
    cb.set_ticklabels([mdates.num2date(value, tz=timezone.utc).strftime("%b %d %H:%M") for value in ticks])
    cb.ax.tick_params(labelsize=9, length=0, pad=5, colors="#53647b")
    cb.outline.set_visible(False)
    fig.text(0.14, 0.182, "COHORT: HOUR WHEN LINES WERE INTRODUCED  ·  UTC",
             fontsize=9, fontweight="bold", color="#53647b")
    fig.text(0.085, 0.035,
             "Julia files, including tests · values are the end-of-hour state · early seed period omitted",
             fontsize=9.5, color="#64748b")
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output, dpi=140, facecolor=fig.get_facecolor(), metadata={"Software": "Matplotlib"})
    plt.close(fig)
    return final_lines


def run_hercules(repo, binary):
    """Analyze first-parent Julia history with one-hour cohorts and snapshots."""
    command = [str(binary), "--burndown", "--first-parent", "--tick-size", "1",
               "--granularity", "1", "--sampling", "1", "--whitelist", r"\.jl$", str(repo)]
    result = subprocess.run(command, check=True, stdout=subprocess.PIPE, text=True)
    return parse_burndown(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="Full Git repository to analyze")
    parser.add_argument("--hercules", required=True, help="Path to the Hercules executable")
    parser.add_argument("--output", required=True, help="PNG to write")
    args = parser.parse_args()
    origin, matrix = run_hercules(args.repo, args.hercules)
    print(f"Rendered {render_chart(origin, matrix, args.output):,} Julia lines to {args.output}")


if __name__ == "__main__":
    main()
