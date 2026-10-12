#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const claudeDir = path.resolve(__dirname, '..');

const sortKeys = (obj) =>
  Object.fromEntries(Object.entries(obj).sort(([a], [b]) => a.localeCompare(b)));

const readJson = (file) => JSON.parse(fs.readFileSync(path.join(claudeDir, file), 'utf8'));

const marketplaceSource = ({ source, repo, url }) => {
  if (source === 'github') return `github:${repo}`;
  if (source === 'git') return `git:${url}`;
  return `${source}:${url || repo || 'unknown'}`;
};

const buildManifest = () => {
  const installed = readJson('plugins/installed_plugins.json');
  const known = readJson('plugins/known_marketplaces.json');

  const marketplaces = sortKeys(
    Object.fromEntries(
      Object.entries(known).map(([name, m]) => [name, { source: marketplaceSource(m.source) }])
    )
  );

  const plugins = sortKeys(
    Object.fromEntries(
      Object.entries(installed.plugins || {}).flatMap(([name, entries]) => {
        const entry = entries.find((e) => e.scope === 'user') || entries[0];
        if (!entry) return [];
        const record = { version: entry.version };
        if (entry.gitCommitSha) record.gitCommitSha = entry.gitCommitSha;
        return [[name, record]];
      })
    )
  );

  return { marketplaces, plugins };
};

const out = path.join(claudeDir, 'plugins-manifest.json');
fs.writeFileSync(out, `${JSON.stringify(buildManifest(), null, 2)}\n`);
console.log(`wrote ${path.relative(claudeDir, out)}`);
