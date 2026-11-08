// `asfetch enforce-spoof` — apply the STRONG spoof flags to the engine's prop
// files in ONE native process.
//
// Why this exists: engine_enforce_spoof (engine.sh) rewrites every spoof flag
// (spoofBuild, spoofProps, spoofVendingFinger, …) in each prop file the zygisk
// reads — the hot step on every pif apply / boot / hourly pass. In shell that is
// a `sed -i` plus a `grep` spawned per target file (~8 processes for Fork's four
// files); here it is a single process that reads, rewrites and appends across
// all files. Pure local file I/O, so it can never stall — no watchdog needed.
//
// Semantics are byte-for-byte what the shell fallback does, so either path
// leaves identical files:
//   * for every KEY=VALUE, replace EVERY line that begins with `KEY=` with
//     `KEY=VALUE` (all occurrences, like `sed s|^KEY=.*|KEY=VALUE|`);
//   * if no line began with `KEY=`, append `KEY=VALUE`;
//   * a target file that is missing / unreadable is skipped (shell: `[ -f ]`).
// The write truncates the file in place (keeps its inode, so the SELinux label
// and mode the module set survive — a create+rename could relabel it).
//
// Usage:  asfetch enforce-spoof --kv "K1=V1 K2=V2 ..." FILE [FILE ...]
//   --kv   one argument: the whole space-separated key=value list (the shell's
//          $_kvs). Tokens without '=' are ignored.
//   exit 0 always unless --kv is missing (2); per-file I/O errors are swallowed,
//   exactly like the shell path's `2>/dev/null`, so a caller never has enforce
//   fail the apply.

// Does `line` begin with `key` followed by '='? (i.e. `sed`'s ^KEY= anchor)
fn line_has_key(line: &[u8], key: &[u8]) -> bool {
    line.len() > key.len() && &line[..key.len()] == key && line[key.len()] == b'='
}

fn enforce_file(path: &str, pairs: &[(Vec<u8>, Vec<u8>)]) -> std::io::Result<()> {
    // Missing or unreadable target: skip it (mirrors the shell's `[ -f "$_f" ]`
    // guard and its `2>/dev/null`), never fail the whole apply over one file.
    let data = match std::fs::read(path) {
        Ok(d) => d,
        Err(_) => return Ok(()),
    };

    let mut seen = vec![false; pairs.len()];
    let mut out: Vec<u8> = Vec::with_capacity(data.len() + 64);

    if !data.is_empty() {
        // A trailing '\n' produces an empty final segment when splitting on '\n'
        // that is not a real line — do not emit a blank line for it.
        let ends_nl = data.last() == Some(&b'\n');
        let mut start = 0usize;
        let len = data.len();
        loop {
            let nl = data[start..].iter().position(|&b| b == b'\n').map(|p| start + p);
            let (line, next, last) = match nl {
                Some(p) => (&data[start..p], p + 1, false),
                None => (&data[start..len], len, true),
            };
            let trailing_empty = last && line.is_empty() && ends_nl;
            if !trailing_empty {
                let mut replaced = false;
                for (ki, (k, v)) in pairs.iter().enumerate() {
                    if line_has_key(line, k) {
                        out.extend_from_slice(k);
                        out.push(b'=');
                        out.extend_from_slice(v);
                        seen[ki] = true;
                        replaced = true;
                        break; // a line can begin with at most one key
                    }
                }
                if !replaced {
                    out.extend_from_slice(line);
                }
                out.push(b'\n');
            }
            if last {
                break;
            }
            start = next;
        }
    }

    // Append any key no line carried (shell: the per-file append loop).
    for (ki, (k, v)) in pairs.iter().enumerate() {
        if !seen[ki] {
            out.extend_from_slice(k);
            out.push(b'=');
            out.extend_from_slice(v);
            out.push(b'\n');
        }
    }

    // Truncate-in-place write: keeps the inode, so the file's existing SELinux
    // label + mode are preserved (a tmp-file + rename would take the directory's
    // default label and could make it unreadable to the zygisk).
    std::fs::write(path, &out)
}

pub fn run(args: &[String]) -> i32 {
    let mut kv_str: Option<String> = None;
    let mut files: Vec<String> = Vec::new();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--kv" => {
                i += 1;
                kv_str = args.get(i).cloned();
            }
            s => files.push(s.to_string()),
        }
        i += 1;
    }

    let kv_str = match kv_str {
        Some(s) => s,
        None => {
            eprintln!("asfetch enforce-spoof: --kv \"K=V ...\" FILE... required");
            return 2;
        }
    };

    // "K1=V1 K2=V2 ..." -> pairs. Tokens without '=' are ignored (none occur in
    // the module's spoof list, but be safe). Keys/values held as bytes so a file
    // with stray non-UTF-8 bytes is never corrupted by a lossy round-trip.
    let pairs: Vec<(Vec<u8>, Vec<u8>)> = kv_str
        .split_whitespace()
        .filter_map(|tok| {
            tok.split_once('=')
                .map(|(k, v)| (k.as_bytes().to_vec(), v.as_bytes().to_vec()))
        })
        .collect();

    if pairs.is_empty() || files.is_empty() {
        return 0;
    }

    for f in &files {
        // Per-file errors are swallowed on purpose (see enforce_file): enforce is
        // best-effort, the caller falls back to the shell path on a non-zero exit
        // and either path is idempotent, so a double-apply is harmless.
        let _ = enforce_file(f, &pairs);
    }
    0
}
