use std::path::{Component, Path, PathBuf};

fn normalize(p: &Path) -> PathBuf {
    p.components()
        .filter(|c| !matches!(c, Component::CurDir))
        .collect()
}

#[test]
fn test_normalize_curdir_joined_skills() {
    let raw = Path::new("/tmp/plugin").join("./skills/");
    let normalized = normalize(&raw);
    assert_eq!(normalized, PathBuf::from("/tmp/plugin/skills"));
}

#[test]
fn test_join_forms_collapse_to_same_normalized_path() {
    let base = Path::new("/tmp/plugin");
    let forms = ["./skills", "skills/", "skills"];
    let expected = PathBuf::from("/tmp/plugin/skills");

    for form in &forms {
        let joined = base.join(form);
        let normalized = normalize(&joined);
        assert_eq!(
            normalized, expected,
            "failed normalization for join form: {}",
            form
        );
    }
}

#[test]
fn test_parent_dir_components_preserved() {
    let raw = Path::new("/tmp/plugin").join("../skills");
    let normalized = normalize(&raw);
    let has_parent_dir = normalized
        .components()
        .any(|c| matches!(c, Component::ParentDir));
    assert!(
        has_parent_dir,
        ".. components must not be removed by normalize (containment rejection is separate)"
    );
    assert_eq!(normalized, PathBuf::from("/tmp/plugin/../skills"));
}

#[test]
fn test_repeated_curdir_collapses() {
    let raw = Path::new("/tmp/plugin").join("././skills/");
    let normalized = normalize(&raw);
    assert_eq!(normalized, PathBuf::from("/tmp/plugin/skills"));
}

#[test]
fn test_windows_style_path_no_panic_and_no_curdir() {
    let p = Path::new("C:/plugin/skills");
    let normalized = normalize(p);
    assert!(
        !normalized
            .components()
            .any(|c| matches!(c, Component::CurDir)),
        "normalized path must not contain CurDir components"
    );
}
