/**
 * cut.mjs - derive src/installer/templates/ from the committed installers.
 *
 * This is the extraction step the refactor used, kept as a script rather than a
 * pile of hand edits so it stays reviewable and repeatable. It reads the
 * installers as they exist on disk, replaces the blocks that are duplicated
 * across files (and the literals that must agree everywhere) with include
 * markers, and writes the templates.
 *
 * It is idempotent: run against the pre-refactor artifacts it performs the
 * extraction, and run against already-generated artifacts it is a no-op. Every
 * cut is verified by re-rendering the template it just produced and comparing
 * the result to the artifact it came from, so a cut that is not exactly
 * reversible fails instead of silently changing shipped bytes.
 *
 * `--check` compares the templates on disk against freshly cut ones. It only
 * has something to say when the inputs still contain the hand-maintained
 * copies; after the refactor the standing drift check is `build.mjs --check`.
 *
 *   node src/installer/cut.mjs [--check]
 */

import { existsSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { renderTemplate } from './build.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', '..');

const constants = JSON.parse(readFileSync(join(HERE, 'constants.json'), 'utf8'));

const PS_PROBE_MARKER = '{{GROKGOD:ps-engine-probe.cmd}}';

// The duplicated copies carried a "keep this in sync" comment. The build makes
// the copies one text, so the warning would be false; the cut drops it. Running
// the cut again finds it already gone.
const INSTALL_SH_SYNC_COMMENT =
  '# Behavior must match the other copy in src/shim/grok-shim.sh (fast_forward_or_reset_repo)';
const SHIM_SYNC_COMMENT =
  '# Behavior must match the other copy in install.sh (sync_installed_grokgod_src)';
const INSTALL_SH_SIG_SYNC_COMMENTS = [
  '# Behavior must match the other copy in src/shim/grok-shim.sh',
  "# (classify_signature): both must answer 'unsupported' off Darwin, or the",
  '# recorded value can never agree with the observed one.',
];
const SHIM_SIG_SYNC_COMMENT =
  '# Behavior must match the other copy in install.sh (classify_signature).';

/** Offset of the closing brace of the shell/PowerShell function at `start`. */
function functionSpan(text, signature) {
  const start = text.indexOf(signature);
  if (start === -1) throw new Error(`signature not found: ${signature}`);
  let depth = 0;
  for (let index = start; index < text.length; index++) {
    if (text[index] === '{') depth++;
    else if (text[index] === '}') {
      depth--;
      if (depth === 0) return [start, index + 1];
    }
  }
  throw new Error(`unterminated function: ${signature}`);
}

/** Replace one literal, refusing to touch anything but an unambiguous match. */
function replaceOnce(text, anchor, marker, label) {
  const occurrences = text.split(anchor).length - 1;
  if (occurrences !== 1) {
    throw new Error(`${label}: expected exactly one ${JSON.stringify(anchor)}, found ${occurrences}`);
  }
  return text.replace(anchor, () => marker);
}

/** Delete a whole line, if present. Idempotent by design. */
function dropLine(text, line) {
  const occurrences = text.split(`${line}\n`).length - 1;
  if (occurrences === 0) return text;
  if (occurrences > 1) throw new Error(`expected at most one ${JSON.stringify(line)}`);
  return text.replace(`${line}\n`, '');
}

/** Delete each of a run of whole lines, idempotently. */
function dropLines(text, lines) {
  return lines.reduce((current, line) => dropLine(current, line), text);
}

/**
 * Replace a whole function with an include marker.
 *
 * The marker expands to a body that ends in `}` with no trailing newline, so
 * the template supplies the blank lines around it.
 */
function cutFunction(text, signature, functionName, sharedFile) {
  const [start, end] = functionSpan(text, signature);
  const commentStart = text.lastIndexOf('\n', start) + 1;
  return `${text.slice(0, commentStart)}` +
    `{{GROKGOD:shared/${sharedFile}#${functionName}}}` +
    text.slice(end);
}

/**
 * Each cut returns the template plus the artifact it is expected to render
 * back to. They differ only where a cut deliberately deletes a line, so the
 * round-trip check stays exact instead of being loosened.
 */
const CUTS = [
  {
    output: 'templates/install.sh.in',
    input: 'install.sh',
    cut(original, label) {
      let expected = dropLine(original, INSTALL_SH_SYNC_COMMENT);
      expected = dropLines(expected, INSTALL_SH_SIG_SYNC_COMMENTS);
      let text = cutFunction(expected, 'fast_forward_or_reset_grokgod_src() {',
        'fast_forward_or_reset_grokgod_src', 'fast-forward-repo.sh');
      text = cutFunction(text, 'manifest_classify_signature() {',
        'manifest_classify_signature', 'classify-signature.sh');
      text = replaceOnce(text, `COMPAT_ISSUE_TITLE="${constants.compatIssueTitle}"`,
        'COMPAT_ISSUE_TITLE="{{GROKGOD:compatIssueTitle}}"', label);
      text = replaceOnce(text, `https://github.com/${constants.githubRepoSlug}/issues`,
        'https://github.com/{{GROKGOD:githubRepoSlug}}/issues', label);
      text = replaceOnce(text, `PINNED_BASE_SHA=${constants.grokBuildBaseSha}`,
        'PINNED_BASE_SHA={{GROKGOD:grokBuildBaseSha}}', label);
      text = replaceOnce(text, `https://github.com/${constants.githubRepoSlug}`,
        'https://github.com/{{GROKGOD:githubRepoSlug}}', label);
      return { template: text, expected };
    },
  },
  {
    output: 'templates/install.ps1.in',
    input: 'install.ps1',
    cut(original, label) {
      let text = original;
      text = replaceOnce(text, `single matching line for ${constants.windowsTargetAsset})`,
        'single matching line for {{GROKGOD:windowsTargetAsset}})', label);
      text = replaceOnce(text, `$PINNED_BASE_SHA = "${constants.grokBuildBaseSha}"`,
        '$PINNED_BASE_SHA = "{{GROKGOD:grokBuildBaseSha}}"', label);
      text = replaceOnce(text, `$REPO_DEFAULT    = "${constants.githubRepoSlug}"`,
        '$REPO_DEFAULT    = "{{GROKGOD:githubRepoSlug}}"', label);
      text = replaceOnce(text, `$TARGET_ASSET    = "${constants.windowsTargetAsset}"`,
        '$TARGET_ASSET    = "{{GROKGOD:windowsTargetAsset}}"', label);
      return { template: text, expected: original };
    },
  },
  {
    output: 'templates/grok-shim.sh.in',
    input: 'src/shim/grok-shim.sh',
    cut(original, label) {
      let expected = dropLine(original, SHIM_SYNC_COMMENT);
      expected = dropLine(expected, SHIM_SIG_SYNC_COMMENT);
      let text = cutFunction(expected, 'fast_forward_or_reset_repo() {', 'fast_forward_or_reset_repo',
        'fast-forward-repo.sh');
      text = cutFunction(text, 'classify_signature() {', 'classify_signature',
        'classify-signature.sh');
      text = replaceOnce(text,
        `https://api.github.com/repos/${constants.githubRepoSlug}/releases/latest`,
        'https://api.github.com/repos/{{GROKGOD:apiRepoSlug}}/releases/latest', label);
      return { template: text, expected };
    },
  },
  {
    output: 'templates/grok.cmd.template.in',
    input: 'src/shim/templates/grok.cmd.template',
    cut: cutEngineProbe,
  },
  {
    output: 'templates/grokgod.cmd.template.in',
    input: 'src/shim/templates/grokgod.cmd.template',
    cut: cutEngineProbe,
  },
  {
    output: 'templates/LauncherHelpers.ps1.in',
    input: 'src/shim/LauncherHelpers.ps1',
    cut: cutEngineProbe,
  },
];

function cutEngineProbe(original, label) {
  const start = original.indexOf('set "POWERSHELL_EXE="');
  const end = original.indexOf('\n\n:powershell_ready', start);
  if (start === -1 || end === -1) throw new Error(`${label}: engine probe region not found`);
  return {
    template: `${original.slice(0, start)}${PS_PROBE_MARKER}${original.slice(end)}`,
    expected: original,
  };
}

function main() {
  const check = process.argv.includes('--check');
  const unknown = process.argv.slice(2).filter((arg) => arg !== '--check');
  if (unknown.length > 0) {
    console.error(`Unknown argument(s): ${unknown.join(' ')}`);
    process.exit(2);
  }

  let failed = false;
  for (const entry of CUTS) {
    const inputPath = join(ROOT, entry.input);
    if (!existsSync(inputPath)) {
      console.error(`skipped (missing input): ${entry.input}`);
      continue;
    }
    const original = readFileSync(inputPath, 'utf8');

    let template;
    let expected;
    let rebuilt;
    try {
      ({ template, expected } = entry.cut(original, entry.input));
      rebuilt = renderTemplate(template, entry.output);
    } catch (error) {
      console.error(`FAIL ${entry.output}: ${error.message}`);
      failed = true;
      continue;
    }
    if (rebuilt !== expected) {
      console.error(`FAIL ${entry.output}: not a byte-exact round-trip of ${entry.input}`);
      failed = true;
      continue;
    }

    const outputPath = join(HERE, entry.output);
    if (check) {
      const existing = existsSync(outputPath) ? readFileSync(outputPath, 'utf8') : null;
      if (existing !== template) {
        console.error(`out of date: ${entry.output}`);
        failed = true;
      } else {
        console.log(`ok: ${entry.output}`);
      }
      continue;
    }
    writeFileSync(outputPath, template);
    console.log(`cut: ${entry.output} (${Buffer.byteLength(template)} bytes, round-trip verified)`);
  }

  if (failed) process.exit(1);
}

// Compared through realpath: a symlinked or /var-prefixed checkout would
// otherwise skip main() and exit 0 without checking anything.
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
