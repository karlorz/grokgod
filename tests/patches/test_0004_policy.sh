#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
temp=$(mktemp -d /tmp/grokgod-0004-policy.XXXXXX)
trap 'rm -rf "$temp"' EXIT HUP INT TERM

# Standalone regression using the actual added function bodies from the patch.
# Full crate integration is tested separately; no crate dependencies are needed.
python3 - "$repo/patches/0004-disable-builtin-deep-research.patch" "$temp/policy.rs" <<'PY'
import pathlib
import re
import sys

patch = pathlib.Path(sys.argv[1]).read_text()
added = '\n'.join(line[1:] for line in patch.splitlines()
                  if (line.startswith('+') and not line.startswith('+++'))
                  or line.startswith(' '))

def extract(pattern, label):
    matches = re.findall(pattern, added, flags=re.S)
    if len(matches) != 1:
        raise SystemExit(f'Expected exactly one added {label} body, found {len(matches)}')
    return matches[0]

pager_body = extract(
    r'pub\(crate\) fn workflow_is_togglable\(wf: &WorkflowInfo\) -> bool \{(.*?)\n\}',
    'workflow_is_togglable',
)
assert pager_body.count('matches!') == 1
assert 'entry_data_indices' not in pager_body
registry_body = extract(
    r'pub\(crate\) fn without_compiled_in\(mut self, names: &\[&str\]\) -> Self \{(.*?)\n    \}',
    'without_compiled_in',
)

rust = '''// Actual patch function bodies, hosted in minimal standalone types.
// Full crate integration is tested separately.
#[derive(Debug)]
struct WorkflowInfo {
    source: String,
    name: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WorkflowSource {
    Builtin,
    File,
}

#[derive(Debug)]
struct Meta {
    name: String,
}

#[derive(Debug)]
struct Entry {
    meta: Meta,
    source_label: &'static str,
    source: WorkflowSource,
}

#[derive(Debug)]
struct Registry {
    entries: Vec<Entry>,
}

pub(crate) fn workflow_is_togglable(wf: &WorkflowInfo) -> bool {
''' + pager_body + '''
}

impl Registry {
    pub(crate) fn without_compiled_in(mut self, names: &[&str]) -> Self {
''' + registry_body + '''
    }
}

fn entry(scope: &'static str, name: &str, source: WorkflowSource) -> Entry {
    Entry {
        meta: Meta { name: name.to_owned() },
        source_label: scope,
        source,
    }
}

#[test]
fn scope_name_and_source_matrix() {
    for scope in ["builtin", "bundled", "user", "project"] {
        for name in ["deep-research", "learn-traces"] {
            let targeted = name == "deep-research";
            let compiled_scope = matches!(scope, "builtin" | "bundled");
            let wf = WorkflowInfo {
                source: scope.to_owned(),
                name: name.to_owned(),
            };
            assert_eq!(
                workflow_is_togglable(&wf),
                targeted && compiled_scope,
                "pager: scope={scope}, name={name}",
            );

            for source in [WorkflowSource::File, WorkflowSource::Builtin] {
                let registry = Registry {
                    entries: vec![entry(scope, name, source)],
                }.without_compiled_in(&["deep-research"]);
                // Preserve the preexisting Builtin-source rule as well as
                // recognizing builtin/bundled source labels.
                let removed = targeted
                    && (compiled_scope || source == WorkflowSource::Builtin);
                assert_eq!(
                    registry.entries.len(),
                    if removed { 0 } else { 1 },
                    "registry: scope={scope}, name={name}, source={source:?}",
                );
            }
        }
    }
}

#[test]
fn multiple_bundled_entries_remove_only_deep_research() {
    let registry = Registry {
        entries: vec![
            entry("bundled", "learn-traces", WorkflowSource::File),
            entry("bundled", "deep-research", WorkflowSource::File),
            entry("bundled", "another-workflow", WorkflowSource::File),
            entry("bundled", "deep-research", WorkflowSource::Builtin),
            entry("bundled", "learn-traces", WorkflowSource::Builtin),
        ],
    }.without_compiled_in(&["deep-research"]);
    let names: Vec<&str> = registry.entries.iter()
        .map(|entry| entry.meta.name.as_str())
        .collect();
    assert_eq!(names, ["learn-traces", "another-workflow", "learn-traces"]);
}
'''
pathlib.Path(sys.argv[2]).write_text(rust)
PY

rustc --edition=2024 --test "$temp/policy.rs" -o "$temp/policy"
"$temp/policy"
