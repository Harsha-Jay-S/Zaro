// Zaro injection log analysis + recommendations
// Usage: node scripts/zaro-analyze.mjs
import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const CONFIG = join(__dirname, '..');
const LOG_FILE = join(CONFIG, 'zaro-injections.log');
const CURRICULUM_FILE = join(CONFIG, 'zaro-curriculum.json');
const PERSONALITY_FILE = join(CONFIG, 'ZARO_PERSONALITY.md');

// ─── Log parser ─────────────────────────────────────────────────

function parseLog(filepath) {
  if (!existsSync(filepath)) return [];
  const text = readFileSync(filepath, 'utf-8');
  const entries = [];
  for (const line of text.split('\n').filter(Boolean)) {
    const ts = line.match(/^\[(.*?)\]/)?.[1] || '';
    const tier = line.match(/tier=(\w+)/)?.[1] || '';
    const query = line.match(/query="(.*?)"/)?.[1] || '';
    const domain = line.match(/domain=([\w-]+)/)?.[1] || '';
    const maxScore = line.match(/max_score=(\d+)/)?.[1];
    const avgScore = line.match(/avg_score=(\d+)/)?.[1];
    const sectionsRaw = line.match(/sections=\[(.*?)\]/)?.[1] || '';
    const sections = [...sectionsRaw.matchAll(/([\w /-]+?)\((\d+)%\)/g)].map(m => ({
      name: m[1].trim(),
      score: parseInt(m[2]),
    }));
    entries.push({ ts, tier, query, domain, maxScore, avgScore, sections });
  }
  return entries;
}

// ─── Domain distribution from personality ────────────────────────

function parseDomains(filepath) {
  if (!existsSync(filepath)) return {};
  const text = readFileSync(filepath, 'utf-8');
  const domains = {};
  for (const m of text.matchAll(/<!-- domain:\s*(.*?)\s*-->/gi)) {
    const d = m[1].toLowerCase();
    domains[d] = (domains[d] || 0) + 1;
  }
  return domains;
}

// ─── Curriculum analysis ─────────────────────────────────────────

function getUnstudiedDomains(filepath) {
  if (!existsSync(filepath)) return [];
  const data = JSON.parse(readFileSync(filepath, 'utf-8'));
  const topics = data.topics || [];
  const unstudied = topics.filter(t => !t.studied);
  const domainCount = {};
  for (const t of unstudied) {
    domainCount[t.domain] = (domainCount[t.domain] || 0) + 1;
  }
  return Object.entries(domainCount).sort((a, b) => b[1] - a[1]);
}

// ─── Report ──────────────────────────────────────────────────────

function report(entries) {
  console.log('╔══════════════════════════════════════╗');
  console.log('║   Zaro Injection Analysis Report     ║');
  console.log('╚══════════════════════════════════════╝\n');

  // Summary
  console.log(`Total log entries: ${entries.length}`);
  const dateRange = entries.length > 0
    ? `${entries[0].ts.slice(0, 10)} → ${entries[entries.length - 1].ts.slice(0, 10)}`
    : 'N/A';
  console.log(`Date range: ${dateRange}\n`);

  // Tier distribution
  const tiers = {};
  for (const e of entries) tiers[e.tier] = (tiers[e.tier] || 0) + 1;
  console.log('── Tiers ──');
  for (const [t, c] of Object.entries(tiers).sort((a, b) => b[1] - a[1])) {
    const pct = (c / entries.length * 100).toFixed(0);
    const bar = '█'.repeat(Math.round(c / entries.length * 40));
    console.log(`  ${t.padEnd(10)} ${c.toString().padStart(3)} (${pct}%) ${bar}`);
  }

  // Domain distribution in log
  const logDomains = {};
  for (const e of entries) {
    if (e.domain) logDomains[e.domain] = (logDomains[e.domain] || 0) + 1;
  }
  if (Object.keys(logDomains).length > 0) {
    console.log('\n── Logged Domains ──');
    for (const [d, c] of Object.entries(logDomains).sort((a, b) => b[1] - a[1])) {
      console.log(`  ${d}: ${c}`);
    }
  }

  // Top injected sections
  const sectionCount = {};
  const sectionScores = {};
  for (const e of entries) {
    for (const s of e.sections) {
      sectionCount[s.name] = (sectionCount[s.name] || 0) + 1;
      if (!sectionScores[s.name]) sectionScores[s.name] = [];
      sectionScores[s.name].push(s.score);
    }
  }
  console.log('\n── Top Injected Sections ──');
  let rank = 1;
  for (const [name, count] of Object.entries(sectionCount).sort((a, b) => b[1] - a[1]).slice(0, 10)) {
    const scores = sectionScores[name];
    const avg = scores ? (scores.reduce((a, b) => a + b, 0) / scores.length).toFixed(0) : '—';
    console.log(`  ${rank}. ${name} — ${count}x hits, avg score ${avg}%`);
    rank++;
  }

  // RAG score trends
  const ragEntries = entries.filter(e => e.tier === 'rag' && e.avgScore);
  if (ragEntries.length >= 2) {
    console.log('\n── RAG Score Trend ──');
    const recent = ragEntries.slice(-5);
    for (const e of recent) {
      console.log(`  ${e.ts.slice(11, 19)} avg=${e.avgScore}%  "${e.query.slice(0, 50)}"`);
    }
  }

  // Domain distribution in personality file
  const personalityDomains = parseDomains(PERSONALITY_FILE);
  const totalSections = Object.values(personalityDomains).reduce((a, b) => a + b, 0);
  console.log('\n── Personality Domain Distribution ──');
  for (const [d, c] of Object.entries(personalityDomains).sort((a, b) => b[1] - a[1])) {
    const pct = (c / totalSections * 100).toFixed(0);
    const bar = '█'.repeat(Math.round(c / totalSections * 40));
    console.log(`  ${d.padEnd(16)} ${c.toString().padStart(3)} (${pct}%) ${bar}`);
  }

  // Recommendations
  console.log('\n── Recommendations ──');

  // Check if RAG hit rate is low
  const ragCount = tiers['rag'] || 0;
  if (ragCount < entries.length * 0.3) {
    console.log('  ⚠ Low RAG hit rate — consider lowering thresholds in domain-map.json');
  }

  // Check thin domains
  const thinDomains = Object.entries(personalityDomains)
    .filter(([_, c]) => c <= 5)
    .map(([d]) => d);
  if (thinDomains.length > 0) {
    console.log(`  ⚠ Thin domains (<5 sections): ${thinDomains.join(', ')}`);
    console.log(`    → Prioritize these in remaining curriculum`);
  }

  // Check unstudied curriculum domains
  const unstudied = getUnstudiedDomains(CURRICULUM_FILE);
  if (unstudied.length > 0) {
    console.log(`\n  Unstudied curriculum topics by domain:`);
    for (const [d, c] of unstudied) {
      const note = thinDomains.includes(d) ? ' ← THIN, prioritize' : '';
      console.log(`    ${d.padEnd(16)} ${c} remaining${note}`);
    }
  }

  const totalLogSize = existsSync(LOG_FILE)
    ? (readFileSync(LOG_FILE, 'utf-8').split('\n').filter(Boolean).length)
    : 0;
  console.log(`\n  Log size: ${totalLogSize} entries (${LOG_FILE})`);
  console.log(`  Rotate if > 5000: truncate -s 0 ${LOG_FILE}`);
}

// ─── Main ────────────────────────────────────────────────────────

const entries = parseLog(LOG_FILE);
report(entries);
