// app.js — LiveView client + chart hooks
import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

// ── Chart.js (loaded via CDN in layout) ─────────────────────────────────────
// We use a lightweight inline chart renderer to avoid bundling Chart.js
// when it's already available globally. Falls back to a canvas sparkline.

// ── Hooks ────────────────────────────────────────────────────────────────────

const RpsChart = {
  mounted() {
    this.points = parsePoints(this.el.dataset.points);
    this.chart = buildChart(this.el, {
      label: "req/s",
      color: "#00e676",
      shadowColor: "rgba(0,230,118,0.3)",
      dataKey: "rps",
    });
    this.drawChart();
  },

  updated() {
    const raw = this.el.dataset.points;
    if (raw) {
      this.points = parsePoints(raw);
      this.drawChart();
    }
  },

  drawChart() {
    if (this.chart) {
      updateChart(this.chart, this.points, "rps");
    } else {
      fallbackSparkline(this.el, this.points, "rps", "#00e676");
    }
  },
};

const LatencyChart = {
  mounted() {
    this.points = parsePoints(this.el.dataset.points);
    this.chart = buildChart(this.el, {
      label: "avg latency ms",
      color: "#40c4ff",
      shadowColor: "rgba(64,196,255,0.3)",
      dataKey: "latency",
    });
    this.drawChart();
  },

  updated() {
    const raw = this.el.dataset.points;
    if (raw) {
      this.points = parsePoints(raw);
      this.drawChart();
    }
  },

  drawChart() {
    if (this.chart) {
      updateChart(this.chart, this.points, "latency");
    } else {
      fallbackSparkline(this.el, this.points, "latency", "#40c4ff");
    }
  },
};

// ── Chart.js integration ─────────────────────────────────────────────────────

function buildChart(canvas, { label, color, shadowColor, dataKey }) {
  if (typeof Chart === "undefined") return null;

  const ctx = canvas.getContext("2d");

  const gradient = ctx.createLinearGradient(0, 0, 0, canvas.parentElement.offsetHeight || 180);
  gradient.addColorStop(0, shadowColor);
  gradient.addColorStop(1, "rgba(0,0,0,0)");

  return new Chart(ctx, {
    type: "line",
    data: {
      labels: [],
      datasets: [
        {
          label,
          data: [],
          borderColor: color,
          borderWidth: 1.5,
          backgroundColor: gradient,
          fill: true,
          tension: 0.3,
          pointRadius: 0,
          pointHoverRadius: 3,
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: { duration: 200 },
      interaction: { intersect: false, mode: "index" },
      plugins: {
        legend: { display: false },
        tooltip: {
          backgroundColor: "#161b20",
          borderColor: "#1e2530",
          borderWidth: 1,
          titleColor: "#4a5a6a",
          bodyColor: color,
          titleFont: { family: "'IBM Plex Mono', monospace", size: 10 },
          bodyFont: { family: "'IBM Plex Mono', monospace", size: 12, weight: "600" },
        },
      },
      scales: {
        x: {
          display: false,
        },
        y: {
          border: { color: "#1e2530" },
          grid: { color: "rgba(255,255,255,0.03)" },
          ticks: {
            color: "#4a5a6a",
            font: { family: "'IBM Plex Mono', monospace", size: 10 },
            maxTicksLimit: 5,
          },
        },
      },
    },
  });
}

function updateChart(chart, points, key) {
  if (!chart || !points.length) return;
  chart.data.labels = points.map((_, i) => i);
  chart.data.datasets[0].data = points.map((p) => p[key] || 0);
  chart.update("none"); // skip animation for real-time feel
}

// ── Fallback canvas sparkline (no Chart.js) ──────────────────────────────────

function fallbackSparkline(canvas, points, key, color) {
  if (!points.length) return;
  const ctx = canvas.getContext("2d");
  const w = canvas.width = canvas.offsetWidth;
  const h = canvas.height = canvas.offsetHeight;
  const values = points.map((p) => p[key] || 0);
  const max = Math.max(...values, 1);

  ctx.clearRect(0, 0, w, h);

  // Grid lines
  ctx.strokeStyle = "rgba(255,255,255,0.04)";
  ctx.lineWidth = 1;
  for (let i = 0; i <= 4; i++) {
    const y = (h / 4) * i;
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(w, y);
    ctx.stroke();
  }

  if (values.length < 2) return;

  const step = w / (values.length - 1);

  // Fill
  ctx.beginPath();
  ctx.moveTo(0, h - (values[0] / max) * h * 0.9);
  values.forEach((v, i) => {
    ctx.lineTo(i * step, h - (v / max) * h * 0.9);
  });
  ctx.lineTo(w, h);
  ctx.lineTo(0, h);
  ctx.closePath();
  ctx.fillStyle = color.replace(")", ", 0.1)").replace("rgb", "rgba");
  ctx.fill();

  // Line
  ctx.beginPath();
  ctx.strokeStyle = color;
  ctx.lineWidth = 1.5;
  ctx.moveTo(0, h - (values[0] / max) * h * 0.9);
  values.forEach((v, i) => {
    ctx.lineTo(i * step, h - (v / max) * h * 0.9);
  });
  ctx.stroke();
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function parsePoints(raw) {
  try {
    return JSON.parse(raw || "[]");
  } catch {
    return [];
  }
}

// ── LiveSocket ────────────────────────────────────────────────────────────────

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: { RpsChart, LatencyChart },
});

liveSocket.connect();
window.liveSocket = liveSocket;
