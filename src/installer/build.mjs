#!/usr/bin/env node
/**
 * build.mjs - compile the committed grokgod installers from canonical sources.
 *
 * The shipped installers used to be hand-maintained monoliths whose shared
 * blocks were copied between files with a "keep this in sync" comment. This
 * script makes that relationship mechanical, modelled on ClawGod's build.js:
 * templates under src/installer/templates/ hold the parts that differ per
 * platform, src/installer/shared/ holds the parts that do not, and
 * src/installer/constants.json holds the literals that must agree everywhere.
 *
 * Targets are the committed artifacts themselves, so `--check` is a drift
 * check: it fails when a generated file no longer matches its sources.
 *
 *   node src/installer/build.mjs           # regenerate the committed artifacts
 *   node src/installer/build.mjs --check   # fail if any artifact is out of date
 *
 * Exit codes: 0 ok, 1 out of date / build error, 2 bad usage.
 */

import {
  chmodSync,
  existsSync,
  readFileSync,
  realpathSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', '..');

const PLACEHOLDER_RE = /\{\{GROKGOD:[^}]+\}\}/g;
const STRIP_HEADER_BEGIN = '#@build:strip-header';
const STRIP_HEADER_END = '#@build:end-header';
const FUNCTION_NAME_MARKER = '{{GROKGOD:functionName}}';
const FAST_FORWARD_INCLUDE_RE =
  /\{\{GROKGOD:shared\/fast-forward-repo\.sh#([A-Za-z_][A-Za-z0-9_]*)\}\}/g;
const PS_PROBE_MARKER = '{{GROKGOD:ps-engine-probe.cmd}}';

/**
 * Read a shared part, drop its provenance header and its single trailing
 * newline, so the including template controls the blank lines around the
 * spliced block.
 */
export function readPart(relative) {
  const path = join(HERE, 'shared', relative);
  if (!existsSync(path)) throw new Error(`Missing shared part: shared/${relative}`);
  const raw = readFileSync(path, 'utf8');
  if (raw.includes('\r')) throw new Error(`shared/${relative} must use LF line endings`);
  const lines = raw.split('\n');
  if (lines[0] !== STRIP_HEADER_BEGIN) {
    throw new Error(`shared/${relative}: expected ${STRIP_HEADER_BEGIN} on line 1`);
  }
  const end = lines.indexOf(STRIP_HEADER_END);
  if (end === -1) throw new Error(`shared/${relative}: missing ${STRIP_HEADER_END}`);
  if (lines[lines.length - 1] !== '') {
    throw new Error(`shared/${relative} must end with exactly one newline`);
  }
  return lines.slice(end + 1, -1).join('\n');
}

function readConstants() {
  const path = join(HERE, 'constants.json');
  const parsed = JSON.parse(readFileSync(path, 'utf8'));
  for (const [key, value] of Object.entries(parsed)) {
    if (typeof value !== 'string' || value.length === 0) {
      throw new Error(`constants.json: ${key} must be a non-empty string`);
    }
  }
  return parsed;
}

const constants = readConstants();

// The update-check endpoint is the repo slug in API form, so it is derived
// rather than stored twice.
const CONSTANT_VALUES = {
  ...constants,
  apiRepoSlug: constants.githubRepoSlug,
};

function renderFastForward(functionName) {
  const body = readPart('fast-forward-repo.sh');
  const occurrences = body.split(FUNCTION_NAME_MARKER).length - 1;
  if (occurrences !== 1) {
    throw new Error(
      `shared/fast-forward-repo.sh: expected one ${FUNCTION_NAME_MARKER}, found ${occurrences}`,
    );
  }
  // The part is `{{GROKGOD:functionName}}() { ... }`; only the name is injected.
  return body.replace(FUNCTION_NAME_MARKER, () => functionName);
}

export function renderTemplate(template, label) {
  let output = template.replace(
    FAST_FORWARD_INCLUDE_RE,
    (_match, name) => renderFastForward(name),
  );
  output = output.split(PS_PROBE_MARKER).join(readPart('ps-engine-probe.cmd.part'));

  for (const [key, value] of Object.entries(CONSTANT_VALUES)) {
    output = output.split(`{{GROKGOD:${key}}}`).join(value);
  }

  const unresolved = output.match(PLACEHOLDER_RE);
  if (unresolved) {
    throw new Error(`${label}: unresolved placeholders: ${[...new Set(unresolved)].join(', ')}`);
  }
  return output;
}

const TARGETS = [
  { name: 'install.sh', template: 'install.sh.in', mode: 0o755 },
  { name: 'install.ps1', template: 'install.ps1.in', asciiOnly: true },
  { name: 'src/shim/grok-shim.sh', template: 'grok-shim.sh.in', mode: 0o755 },
  { name: 'src/shim/templates/grok.cmd.template', template: 'grok.cmd.template.in', asciiOnly: true },
  { name: 'src/shim/templates/grokgod.cmd.template', template: 'grokgod.cmd.template.in', asciiOnly: true },
  { name: 'src/shim/LauncherHelpers.ps1', template: 'LauncherHelpers.ps1.in', asciiOnly: true },
];

function readTemplate(relative) {
  const path = join(HERE, 'templates', relative);
  if (!existsSync(path)) throw new Error(`Missing template: templates/${relative}`);
  const raw = readFileSync(path, 'utf8');
  if (raw.includes('\r')) throw new Error(`templates/${relative} must use LF line endings`);
  return raw;
}

export function render(target) {
  const label = target.template;
  const output = renderTemplate(readTemplate(target.template), label);

  if (!output.endsWith('\n')) throw new Error(`${label}: generated output must end with a newline`);
  if (output.endsWith('\n\n')) {
    throw new Error(`${label}: generated output must end with exactly one newline`);
  }

  if (target.asciiOnly) {
    const index = output.search(/[^\x00-\x7F]/);
    if (index !== -1) {
      const codePoint = output.codePointAt(index).toString(16).toUpperCase();
      throw new Error(`${label}: non-ASCII U+${codePoint} at character ${index}`);
    }
  }
  return output;
}

function firstDifference(actual, expected) {
  const length = Math.min(actual.length, expected.length);
  for (let index = 0; index < length; index++) {
    if (actual[index] !== expected[index]) return index;
  }
  return actual.length === expected.length ? -1 : length;
}

function main() {
  const check = process.argv.includes('--check');
  const unknown = process.argv.slice(2).filter((arg) => arg !== '--check');
  if (unknown.length > 0) {
    console.error(`Unknown argument(s): ${unknown.join(' ')}`);
    process.exit(2);
  }

  let success = true;
  for (const target of TARGETS) {
    const expected = render(target);
    const outputPath = join(ROOT, target.name);

    if (check) {
      if (!existsSync(outputPath)) {
        console.error(`out of date: ${target.name} is missing`);
        success = false;
        continue;
      }
      const actual = readFileSync(outputPath, 'utf8');
      if (actual === expected) {
        console.log(`ok: ${target.name}`);
        continue;
      }
      console.error(
        `out of date: ${target.name} (first difference at character ${firstDifference(actual, expected)})`,
      );
      success = false;
      continue;
    }

    writeFileSync(outputPath, expected, 'utf8');
    if (target.mode) chmodSync(outputPath, target.mode);
    console.log(`built: ${target.name} (${Buffer.byteLength(expected)} bytes)`);
  }

  if (!success) {
    console.error('Generated installers are out of date. Run: node src/installer/build.mjs');
    process.exit(1);
  }
}

/**
 * True when this module is the process entry point.
 *
 * Compared through realpath: `/var` and `/private/var` (and any symlinked
 * checkout) would otherwise compare unequal and main() would be skipped
 * silently, turning the drift check into a no-op that exits 0.
 */
function isEntryPoint() {
  if (!process.argv[1]) return false;
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (isEntryPoint()) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  }
}
