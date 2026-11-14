use std::env;
use std::fs;
use std::process;

fn usage(prog: &str) {
    eprintln!("Usage: {} --file <path> [--format jsonl]", prog);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut file: Option<String> = None;
    let mut format = String::from("jsonl");
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--help" => { usage(&args[0]); return; }
            "--file" if i + 1 < args.len() => { file = Some(args[i + 1].clone()); i += 1; }
            "--format" if i + 1 < args.len() => { format = args[i + 1].clone(); i += 1; }
            other => {
                eprintln!("unknown argument: {}", other);
                usage(&args[0]);
                process::exit(2);
            }
        }
        i += 1;
    }
    let file = match file {
        Some(f) => f,
        None => { usage(&args[0]); process::exit(2); }
    };
    if format != "jsonl" {
        eprintln!("only --format jsonl is supported");
        process::exit(2);
    }
    let data = match fs::read(&file) {
        Ok(d) => d,
        Err(e) => { eprintln!("cannot open file: {}: {}", file, e); process::exit(2); }
    };
    match mysqlbinlog::parse_buffer(&data) {
        Ok(s) => print!("{}", s),
        Err(e) => { eprintln!("parse failed: {:?}", e); process::exit(1); }
    }
}
