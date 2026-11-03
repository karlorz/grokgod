#!/usr/bin/env node
/**
 * launcher_fixture_driver.js — deterministic full-launcher fixture driver.
 *
 * Launches a generated grokgod .cmd launcher exactly the way T3 launches a
 * Windows provider process: Node child_process with piped stdin/stdout/stderr
 * (stdio: 'pipe'), through cmd.exe /d /s /c. Captures BOTH the process 'exit'
 * event and the 'close' event (which fires only when every inherited pipe
 * handle is released, i.e. true EOF for the caller), plus wall times for each.
 *
 * The driver never asserts; it reports one JSON document on stdout and always
 * exits 0, so the calling PowerShell suite owns every assertion.
 *
 * Usage:
 *   node launcher_fixture_driver.js --cmd <path\to\grok.cmd>
 *     [--args-file <path>]               (UTF-8 JSON array of tokens, joined with spaces)
 *     [--env-file <path>]                (UTF-8 JSON object merged over the parent env)
 *     [--stdin-b64 <base64>]             (bytes written to child stdin, then EOF)
 *     [--keep-stdin-open]                (write nothing and keep stdin open)
 *     [--timeout-ms 15000]               (watchdog; taskkill /T /F on overrun)
 *     [--cwd <dir>]
 *
 * File-based JSON is used instead of inline --args-json/--env-json so no
 * nested quoting ever crosses a command line.
 *
 * Reported JSON:
 *   { ok, pid, exitCode, exitMs, closeMs, stdoutB64, stderrB64, stdoutLen,
 *     stderrLen, timedOut, killError, error }
 * exitMs/closeMs are milliseconds from spawn to the 'exit'/'close' events.
 */
'use strict';

const { spawn } = require('node:child_process');
const { readFileSync } = require('node:fs');

function argValue(argv, name) {
  const i = argv.indexOf(name);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : null;
}

function parseJson(text, label) {
  if (text === null || text === undefined) return null;
  try {
    return JSON.parse(text);
  } catch (e) {
    throw new Error(label + ' is not valid JSON: ' + e.message);
  }
}

function readJsonFile(path, label) {
  if (!path) return null;
  let raw;
  try {
    raw = readFileSync(path, 'utf8');
  } catch (e) {
    throw new Error(label + ' could not be read: ' + e.message);
  }
  if (raw.charCodeAt(0) === 0xfeff) raw = raw.slice(1);
  return parseJson(raw, label);
}

function main() {
  const argv = process.argv.slice(2);
  const cmd = argValue(argv, '--cmd');
  if (!cmd) throw new Error('missing --cmd <launcher.cmd>');
  const args = readJsonFile(argValue(argv, '--args-file'), '--args-file') || [];
  const envExtra = readJsonFile(argValue(argv, '--env-file'), '--env-file') || {};
  if (!Array.isArray(args)) throw new Error('--args-file must contain a JSON array');
  const stdinB64 = argValue(argv, '--stdin-b64');
  const keepStdinOpen = argv.includes('--keep-stdin-open');
  const timeoutMs = parseInt(argValue(argv, '--timeout-ms') || '15000', 10);
  const cwd = argValue(argv, '--cwd') || process.cwd();

  const result = {
    ok: true,
    pid: -1,
    exitCode: null,
    exitMs: null,
    closeMs: null,
    stdoutB64: '',
    stderrB64: '',
    stdoutLen: 0,
    stderrLen: 0,
    timedOut: false,
    killError: null,
    error: null,
  };

  const t0 = Date.now();
  // Proven native argv transport (root /tmp/grokgod-argv-audit 4/4 exact):
  // CRT quote/backslash encoding, wrap in quotes, then twice CMD-metachar
  // escaping. Spawned with windowsVerbatimArguments through cmd.exe /d /s /c.
  // Launchers forward %* directly under setlocal DisableDelayedExpansion.
  const meta = /([()\][%!^"`<>&|;, *?])/g;
  function escapeArg(value) {
    let arg = String(value).replace(/(\\*)"/g, '$1$1\\"').replace(/(\\*)$/, '$1$1');
    arg = '"' + arg + '"';
    arg = arg.replace(meta, '^$1');
    return arg.replace(meta, '^$1');
  }
  const commandLine = [cmd].concat(args).map(escapeArg).join(' ');
  const child = spawn('cmd.exe', ['/d', '/s', '/c', '"' + commandLine + '"'], {
    cwd,
    stdio: ['pipe', 'pipe', 'pipe'],
    env: Object.assign({}, process.env, envExtra),
    windowsHide: true,
    // The command line is pre-quoted above; without this flag Node re-quotes
    // the fourth argument (it contains spaces), producing a triple-quoted
    // blob that cmd /s cannot parse and failing with 'not recognized'.
    windowsVerbatimArguments: true,
  });
  result.pid = child.pid;

  const outChunks = [];
  const errChunks = [];
  child.stdout.on('data', (d) => outChunks.push(d));
  child.stderr.on('data', (d) => errChunks.push(d));

  child.on('exit', (code) => {
    result.exitCode = code;
    result.exitMs = Date.now() - t0;
  });
  child.on('close', () => {
    result.closeMs = Date.now() - t0;
    finish();
  });
  child.on('error', (e) => {
    result.ok = false;
    result.error = String(e && e.message ? e.message : e);
    finish();
  });

  // A child that ignores stdin must never see a driver-side EPIPE exception.
  child.stdin.on('error', () => {});
  if (stdinB64) {
    child.stdin.write(Buffer.from(stdinB64, 'base64'));
  }
  if (!keepStdinOpen) {
    child.stdin.end();
  }

  let finished = false;
  function finish() {
    if (finished) return;
    finished = true;
    clearTimeout(watchdog);
    clearTimeout(hardCap);
    const outBuf = Buffer.concat(outChunks);
    const errBuf = Buffer.concat(errChunks);
    result.stdoutLen = outBuf.length;
    result.stderrLen = errBuf.length;
    result.stdoutB64 = outBuf.toString('base64');
    result.stderrB64 = errBuf.toString('base64');
    process.stdout.write(JSON.stringify(result) + '\n');
    process.exit(0);
  }

  function killTree(pid) {
    if (process.platform === 'win32') {
      const tk = spawn('taskkill.exe', ['/pid', String(pid), '/T', '/F'], {
        stdio: 'ignore',
        windowsHide: true,
      });
      tk.on('error', (e) => {
        result.killError = String(e && e.message ? e.message : e);
      });
    } else {
      try {
        child.kill('SIGKILL');
      } catch (e) {
        result.killError = String(e && e.message ? e.message : e);
      }
    }
  }

  const watchdog = setTimeout(() => {
    result.timedOut = true;
    killTree(child.pid);
  }, timeoutMs);
  // Hard cap: never let a stuck tree hang the suite past the watchdog grace.
  const hardCap = setTimeout(() => {
    result.timedOut = true;
    finish();
  }, timeoutMs + 20000);
}

try {
  main();
} catch (e) {
  process.stdout.write(
    JSON.stringify({ ok: false, error: String(e && e.message ? e.message : e) }) + '\n'
  );
  process.exit(0);
}
