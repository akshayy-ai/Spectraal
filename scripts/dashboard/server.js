const express = require('express');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const app = express();
const PORT = process.env.DASHBOARD_PORT || 9000;
const SPECTRAAL_ROOT = process.env.SPECTRAAL_ROOT || path.resolve(__dirname, '../..');
const BUILDS_DIR = path.join(SPECTRAAL_ROOT, 'builds');

app.use(express.json());

function readJSON(filePath) {
  try { return JSON.parse(fs.readFileSync(filePath, 'utf8')); }
  catch { return null; }
}

function getContainerStatus(projectName) {
  try {
    const out = execSync(
      `docker ps -a --filter "name=${projectName}" --format "{{.Names}}|{{.Status}}|{{.Ports}}"`,
      { encoding: 'utf8', timeout: 5000 }
    ).trim();
    if (!out) return [];
    return out.split('\n').map(line => {
      const [name, status, ports] = line.split('|');
      return { name, status, ports, running: status?.startsWith('Up') || false };
    });
  } catch { return []; }
}

function getBuildInfo(buildDir) {
  const spec = readJSON(path.join(buildDir, 'spec.json'));
  if (!spec || !spec.project_name) return null;

  const summary = readJSON(path.join(buildDir, 'build-summary.json'));
  const costData = readJSON(path.join(buildDir, 'cost-tracking.json'));

  const projectDir = path.join(buildDir, spec.project_name);
  const meta = fs.existsSync(projectDir)
    ? readJSON(path.join(projectDir, 'build-meta.json'))
    : null;

  const containers = getContainerStatus(spec.project_name);
  const isRunning = containers.some(c => c.running);

  const fePort = meta?.ports?.frontend;
  const url = isRunning && fePort ? `http://localhost:${fePort}` : null;

  return {
    build_id: path.basename(buildDir),
    project_name: spec.project_name,
    display_name: spec.display_name || spec.project_name,
    domain: spec.domain || '',
    stack_profile: meta?.stack_profile || spec.stack_profile || 'full-stack',
    blueprint: meta?.blueprint || '',
    status: isRunning ? 'running' : 'stopped',
    url,
    ports: meta?.ports || {},
    created_at: meta?.created_at || summary?.created_at || '',
    cost: costData?.totals ? {
      total_usd: costData.totals.total_cost_usd || 0,
      claude_calls: costData.totals.call_count || 0,
      output_tokens: costData.totals.output_tokens || 0
    } : (meta?.cost || {}),
    test_results: meta?.test_results || summary?.test_results || null,
    lint_results: meta?.lint_results || null,
    scan_results: meta?.scan_results || null,
    refinements: meta?.refinements || [],
    containers,
    elapsed: summary?.elapsed || ''
  };
}

// GET /api/builds
app.get('/api/builds', (_req, res) => {
  try {
    if (!fs.existsSync(BUILDS_DIR)) return res.json([]);
    const dirs = fs.readdirSync(BUILDS_DIR)
      .filter(d => fs.statSync(path.join(BUILDS_DIR, d)).isDirectory())
      .sort()
      .reverse();

    const builds = dirs.map(d => getBuildInfo(path.join(BUILDS_DIR, d))).filter(Boolean);
    res.json(builds);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// GET /api/builds/:id
app.get('/api/builds/:id', (req, res) => {
  const buildDir = path.join(BUILDS_DIR, req.params.id);
  if (!fs.existsSync(buildDir)) return res.status(404).json({ error: 'Build not found' });
  const info = getBuildInfo(buildDir);
  if (!info) return res.status(404).json({ error: 'Invalid build directory' });

  const spec = readJSON(path.join(buildDir, 'spec.json'));
  info.features = spec?.features || [];
  info.entities = spec?.entities || [];
  info.pages = spec?.pages || [];
  res.json(info);
});

// GET /api/containers
app.get('/api/containers', (_req, res) => {
  try {
    const out = execSync(
      'docker ps -a --format "{{.Names}}|{{.Status}}|{{.Ports}}|{{.Image}}"',
      { encoding: 'utf8', timeout: 5000 }
    ).trim();
    if (!out) return res.json([]);
    const containers = out.split('\n').map(line => {
      const [name, status, ports, image] = line.split('|');
      return { name, status, ports, image, running: status?.startsWith('Up') || false };
    });
    res.json(containers);
  } catch { res.json([]); }
});

// POST /api/builds/:id/stop
app.post('/api/builds/:id/stop', (req, res) => {
  const buildDir = path.join(BUILDS_DIR, req.params.id);
  const info = getBuildInfo(buildDir);
  if (!info) return res.status(404).json({ error: 'Build not found' });
  try {
    execSync(`docker compose -p "${info.project_name}" down`, { timeout: 30000 });
    res.json({ success: true, message: `Stopped ${info.project_name}` });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// POST /api/builds/:id/restart
app.post('/api/builds/:id/restart', (req, res) => {
  const buildDir = path.join(BUILDS_DIR, req.params.id);
  const info = getBuildInfo(buildDir);
  if (!info) return res.status(404).json({ error: 'Build not found' });
  try {
    const projectDir = path.join(buildDir, info.project_name);
    execSync(`cd "${projectDir}" && docker compose -p "${info.project_name}" up -d`, { timeout: 60000 });
    res.json({ success: true, message: `Restarted ${info.project_name}` });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// POST /api/builds/:id/rollback
app.post('/api/builds/:id/rollback', (req, res) => {
  const buildDir = path.join(BUILDS_DIR, req.params.id);
  const info = getBuildInfo(buildDir);
  if (!info) return res.status(404).json({ error: 'Build not found' });
  try {
    execSync(`cd "${SPECTRAAL_ROOT}" && bash jarvis rollback "${info.project_name}"`, { timeout: 60000 });
    res.json({ success: true, message: `Rolled back ${info.project_name}` });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Serve dashboard HTML
app.get('/', (_req, res) => {
  res.sendFile(path.join(__dirname, 'index.html'));
});

app.listen(PORT, () => {
  console.log(`Spectraal Dashboard running at http://localhost:${PORT}`);
});
