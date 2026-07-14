// Zaro — RAG-powered personality injection plugin for opencode
//
// Three-tier retrieval:
//   1. Semantic (RAG): embed user message → cosine sim vs 96 section vectors
//      → inject top-3 if max score ≥ domain threshold
//   2. Fallback: keyword domain matching (original logic)
//      → inject matching sections
//   3. Last resort: 2 most recent sections
//
// Embedding: @xenova/transformers (Xenova/all-MiniLM-L6-v2) — local ONNX, no network
// Default threshold: 0.2. Per-domain overrides in domain-map.json.

import { readFileSync, existsSync, statSync, writeFileSync, appendFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pipeline } from '@xenova/transformers';

const __dirname = dirname(fileURLToPath(import.meta.url));
const CONFIG = join(__dirname, '..');
const PERSONALITY_FILE = join(CONFIG, 'ZARO_PERSONALITY.md');
const DOMAIN_MAP_FILE = join(CONFIG, 'zaro-domain-map.json');
const CORE_INTENT_FILE = join(CONFIG, 'zaro-core-intent.md');
const EMBEDDINGS_FILE = join(CONFIG, 'zaro-embeddings.json');
const LOG_FILE = join(CONFIG, 'zaro-injections.log');

const DEFAULT_THRESHOLD = 0.2;
const MAX_SECTIONS = 3;

// ─── Per-domain threshold overrides ─────────────────────────────
//
// Domain map supports two formats:
//   Old: { "engineering": ["debug", "code"] }
//   New: { "engineering": { keywords: ["debug", "code"], threshold: 0.18 } }
//
// Values below tuned from empirical testing. Domains not listed use DEFAULT_THRESHOLD.
//
// If you want per-domain thresholds, add them to the DOMAIN_MAP_FILE:
//   { "engineering": { "keywords": [...], "threshold": 0.18 } }

// ─── State ──────────────────────────────────────────────────────

let cache = { personality: '', domainMap: {}, coreIntent: '', mtime: 0 };
let embedder = null;
let stored = []; // [{heading, body, domain, vector}]

// ─── Logging ────────────────────────────────────────────────────

function logInjection(query, tier, sections, domain) {
  try {
    const ts = new Date().toISOString();
    const q = query.length > 80 ? query.slice(0, 80) + '…' : query;
    const names = sections.map(s => {
      const h = (s.heading || '').replace('### ', '').split(' —')[0].trim();
      return s.score !== undefined ? `${h}(${(s.score * 100).toFixed(0)}%)` : h;
    }).join(', ');
    const scores = sections.filter(s => s.score !== undefined).map(s => s.score);
    const maxScore = scores.length > 0 ? Math.max(...scores) : 0;
    const avgScore = scores.length > 0 ? scores.reduce((a, b) => a + b, 0) / scores.length : 0;
    const domainStr = domain ? ` domain=${domain}` : '';
    const scoreStr = scores.length > 0 ? ` max_score=${(maxScore * 100).toFixed(0)} avg_score=${(avgScore * 100).toFixed(0)}` : '';
    const line = `[${ts}] tier=${tier}${domainStr}${scoreStr} query="${q}" sections=[${names}]\n`;
    appendFileSync(LOG_FILE, line, 'utf-8');
  } catch {
    // silent — logging should never break injection
  }
}

function getThresholdForDomain(domain) {
  if (!domain || !cache.domainMap || !cache.domainMap[domain]) return DEFAULT_THRESHOLD;
  const entry = cache.domainMap[domain];
  // New format: { keywords: [...], threshold: 0.18 }
  if (typeof entry === 'object' && !Array.isArray(entry) && entry.threshold !== undefined) {
    return entry.threshold;
  }
  // Old format: ["keyword1", "keyword2", ...]
  return DEFAULT_THRESHOLD;
}

// ─── File loading ───────────────────────────────────────────────

function loadFiles() {
  try {
    if (!existsSync(PERSONALITY_FILE)) return false;
    const stat = statSync(PERSONALITY_FILE);
    if (cache.mtime === stat.mtimeMs) return true;

    cache.personality = readFileSync(PERSONALITY_FILE, 'utf-8');
    cache.domainMap = existsSync(DOMAIN_MAP_FILE)
      ? JSON.parse(readFileSync(DOMAIN_MAP_FILE, 'utf-8'))
      : {};
    cache.coreIntent = existsSync(CORE_INTENT_FILE)
      ? readFileSync(CORE_INTENT_FILE, 'utf-8')
      : '';
    cache.mtime = stat.mtimeMs;
    return true;
  } catch {
    return false;
  }
}

// ─── Section parsing ────────────────────────────────────────────

function parseSections(content) {
  const lines = content.split('\n');
  const sections = [];
  let current = null;
  let body = [];
  let domain = '';
  let summary = '';

  for (const line of lines) {
    if (line.startsWith('### ')) {
      if (current) {
        sections.push({ heading: current, body: body.join('\n').trim(), domain, summary: summary.trim() });
      }
      current = line;
      body = [];
      domain = '';
      summary = '';
    }
    const dm = line.match(/<!-- domain:\s*(.*?)\s*-->/i);
    if (dm) domain = dm[1].toLowerCase();
    if (current && !line.startsWith('### ') && !line.startsWith('<!-- domain:')) {
      body.push(line);
      // First bullet point after heading = summary
      if (line.startsWith('- **[') && !summary) {
        summary = line;
      }
    }
  }
  if (current) {
    sections.push({ heading: current, body: body.join('\n').trim(), domain, summary: summary.trim() });
  }
  return sections;
}

// ─── Embedding ───────────────────────────────────────────────────

async function getEmbedder() {
  if (!embedder) {
    embedder = await pipeline('feature-extraction', 'Xenova/all-MiniLM-L6-v2', {
      quantized: true,  // smaller/faster
    });
  }
  return embedder;
}

async function embedText(text) {
  const ext = await getEmbedder();
  const result = await ext(text, { pooling: 'mean', normalize: true });
  return Array.from(result.data);
}

function cosineSimilarity(a, b) {
  let dot = 0;
  for (let i = 0; i < a.length; i++) dot += a[i] * b[i];
  return dot;
}

function topKBySimilarity(queryVec, items, k) {
  const scored = items.map(item => ({
    ...item,
    score: cosineSimilarity(queryVec, item.vector),
  }));
  scored.sort((a, b) => b.score - a.score);
  return scored.slice(0, k);
}

// ─── Embeddings cache ───────────────────────────────────────────

async function ensureEmbeddings() {
  loadFiles();
  const personalityStat = statSync(PERSONALITY_FILE);

  // Try loading cached embeddings
  if (existsSync(EMBEDDINGS_FILE)) {
    try {
      const cached = JSON.parse(readFileSync(EMBEDDINGS_FILE, 'utf-8'));
      if (cached.personalityMtime === personalityStat.mtimeMs && Array.isArray(cached.sections)) {
        stored = cached.sections;
        return;
      }
    } catch {
      // corrupted cache, rebuild
    }
  }

  // Build embeddings — one-time per personality.md change
  const sections = parseSections(cache.personality);
  console.log(`[zaro] Embedding ${sections.length} personality sections...`);

  const embedded = [];
  for (let i = 0; i < sections.length; i++) {
    const s = sections[i];
    // Embed full body for richer semantic signal
    const textToEmbed = `${s.heading}\n${s.body}`;
    try {
      const vector = await embedText(textToEmbed);
      embedded.push({
        heading: s.heading,
        body: s.body,
        domain: s.domain,
        vector,
      });
    } catch (err) {
      console.error(`[zaro] Failed to embed section ${i}: ${err.message}`);
      // Skip failed section — system still works with partial index
    }
    if ((i + 1) % 20 === 0) console.log(`[zaro]  ${i + 1}/${sections.length} embedded`);
  }

  stored = embedded;
  writeFileSync(EMBEDDINGS_FILE, JSON.stringify({
    personalityMtime: personalityStat.mtimeMs,
    sectionCount: sections.length,
    dimensions: 384,
    sections: embedded.map(s => ({
      ...s,
      vector: s.vector, // included in JSON
    })),
  }, null, 2));
  console.log(`[zaro] Embeddings saved to ${EMBEDDINGS_FILE} (${stored.length} sections)`);
}

// ─── Pattern matching fallback ──────────────────────────────────

function matchDomain(word) {
  const lower = word.toLowerCase().trim();
  if (!lower || lower.length < 3) return null;
  for (const [domain, entry] of Object.entries(cache.domainMap)) {
    const keywords = Array.isArray(entry) ? entry : (entry.keywords || []);
    for (const kw of keywords) {
      if (lower.includes(kw)) return domain;
    }
  }
  return null;
}

function getDomainsForPrompt(text) {
  const words = text.split(/\s+/);
  const domains = new Set();
  const lowerFull = text.toLowerCase();

  // Match single-word keywords (per-word check)
  for (const word of words) {
    const d = matchDomain(word);
    if (d) domains.add(d);
  }

  // Match multi-word keywords against full text
  // (e.g. "deliberate practice", "feedback loop", "beginner's mind")
  for (const [domain, entry] of Object.entries(cache.domainMap)) {
    const keywords = Array.isArray(entry) ? entry : (entry.keywords || []);
    for (const kw of keywords) {
      if (kw.includes(' ') && lowerFull.includes(kw)) {
        domains.add(domain);
      }
    }
  }

  return domains;
}

function collectSectionsByDomain(content, targetDomains) {
  const lines = content.split('\n');
  const results = [];
  let current = null;
  let domains = new Set();
  let body = [];

  for (const line of lines) {
    if (line.startsWith('### ')) {
      if (current && body.length > 0) {
        const match = [...domains].some(d => targetDomains.has(d));
        if (match) results.push({ heading: current, body: body.join('\n').trim() });
      }
      current = line;
      domains = new Set();
      body = [];
    }
    const dm = line.match(/<!-- domain:\s*(.*?)\s*-->/i);
    if (dm) domains.add(dm[1].toLowerCase());
    if (current && !line.startsWith('### ')) body.push(line);
  }
  if (current && body.length > 0) {
    const match = [...domains].some(d => targetDomains.has(d));
    if (match) results.push({ heading: current, body: body.join('\n').trim() });
  }
  return results;
}

function getRecentSections(content, n = 2) {
  const lines = content.split('\n');
  const sections = [];
  let current = null;
  let body = [];
  for (const line of lines) {
    if (line.startsWith('### ')) {
      if (current && body.length > 0) {
        sections.push({ heading: current, body: body.join('\n').trim() });
      }
      current = line;
      body = [];
    } else if (current && !line.startsWith('<!-- domain:')) {
      body.push(line);
    }
  }
  if (current && body.length > 0) {
    sections.push({ heading: current, body: body.join('\n').trim() });
  }
  return sections.slice(-n);
}

// ─── Injection ──────────────────────────────────────────────────

function trimBody(body, max = 400) {
  if (!body || body.length <= max) return body || '';
  const truncated = body.slice(0, max);
  const lastPeriod = truncated.lastIndexOf('.');
  if (lastPeriod > max * 0.7) return truncated.slice(0, lastPeriod + 1);
  return truncated + '…';
}

function formatInjection(sections, coreIntent) {
  const parts = [];
  // Always prepend core intent as grounding context
  if (coreIntent) {
    parts.push(`### Core Intent — Zaro's Identity\n${coreIntent.trim()}`);
  }
  // Add retrieved sections
  if (sections && sections.length > 0) {
    const sectionParts = sections.slice(0, MAX_SECTIONS).map(s => {
      const h = s.heading || '';
      const b = trimBody(s.body, 400);
      const score = s.score !== undefined
        ? `<!-- relevance: ${(s.score * 100).toFixed(0)}% -->`
        : '';
      return `${h}\n${score}\n${b}`;
    });
    parts.push(...sectionParts);
  }
  if (parts.length === 0) return '';
  return `<personality-context>\n${parts.join('\n\n')}\n</personality-context>`;
}

// ─── RAG query ──────────────────────────────────────────────────

async function retrieveRelevant(text) {
  if (stored.length === 0) return null;

  try {
    const queryVec = await embedText(text);
    const top = topKBySimilarity(queryVec, stored, MAX_SECTIONS);

    // Score injects section domain info for debugging
    const results = top.map(s => ({
      heading: s.heading,
      body: s.body,
      domain: s.domain,
      score: s.score,
    }));

    return results;
  } catch {
    return null; // embed failed → fallback
  }
}

// ─── Main injection builder ─────────────────────────────────────

async function buildInjection(text) {
  loadFiles();
  if (!cache.personality) return '';

  const coreIntent = cache.coreIntent || '';

  // Tier 1: RAG — keep only sections that clear their OWN domain threshold.
  // retrieveRelevant returns up to MAX_SECTIONS sorted by score desc, so a
  // passing top section no longer drags sub-threshold siblings in with it.
  const ragResults = await retrieveRelevant(text);
  if (ragResults && ragResults[0]) {
    const passing = ragResults.filter(s => s.score >= getThresholdForDomain(s.domain || ''));
    if (passing.length > 0) {
      logInjection(text, 'rag', passing, passing[0].domain || '');
      return formatInjection(passing, coreIntent);
    }
  }

  // Tier 2: Pattern matching
  const domains = getDomainsForPrompt(text);
  if (domains.size > 0) {
    const sections = collectSectionsByDomain(cache.personality, domains);
    if (sections.length > 0) {
      const tagged = sections.map(s => ({ ...s, score: 0 }));
      logInjection(text, 'pattern', tagged, [...domains][0]);
      return formatInjection(tagged, coreIntent);
    }
  }

  // Tier 3: Recent sections
  const recent = getRecentSections(cache.personality, 2);
  if (recent.length > 0) {
    const tagged = recent.map(s => ({ ...s, score: 0 }));
    logInjection(text, 'fallback', tagged);
    return formatInjection(tagged, coreIntent);
  }

  // Fallback: core intent only (no domain sections matched)
  if (coreIntent) {
    logInjection(text, 'fallback', [], '');
  }
  return formatInjection([], coreIntent);
}

// ─── Plugin export ──────────────────────────────────────────────

export const ZaroPlugin = async () => {
  loadFiles();
  console.log('[zaro] Initializing personality injection plugin');

  // Pre-warm embedder and load/build embeddings
  // This runs once at boot — first load may take ~5s to download model
  try {
    const start = Date.now();
    await ensureEmbeddings();
    console.log(`[zaro] Ready (${stored.length} sections, ${Date.now() - start}ms)`);
  } catch (err) {
    console.error(`[zaro] Embedding init failed: ${err.message}`);
    console.error('[zaro] RAG disabled, falling back to pattern matching only');
  }

  return {
    "chat.message": async (input, output) => {
      const text = (input?.parts || [])
        .filter(p => p.type === 'text')
        .map(p => p.text)
        .join(' ');
      if (!text.trim()) return;

      const injection = await buildInjection(text);
      if (injection) {
        output.parts = output.parts || [];
        output.parts.push({ type: "text", text: injection });
      }
    }
  };
};
