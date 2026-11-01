//! Embed the native manifest, icon and Explorer version information.

use std::{env, path::PathBuf, process::Command};

fn main() {
    if std::env::var_os("CARGO_CFG_WINDOWS").is_some() {
        embed_manifest::embed_manifest(embed_manifest::new_manifest("TrayLuma")).expect("unable to embed manifest");
        let out = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR"));
        let msvc = env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc");
        let resource = out.join(if msvc { "trayluma.res" } else { "trayluma.o" });
        let mut compiler = if msvc {
            let rc = env::var_os("RC").map(PathBuf::from).or_else(|| {
                let kits = PathBuf::from(env::var_os("ProgramFiles(x86)")?).join("Windows Kits/10/bin");
                let mut versions: Vec<_> = std::fs::read_dir(kits).ok()?.filter_map(|e| e.ok().map(|e| e.path())).collect();
                versions.sort();
                versions.into_iter().rev().map(|p| p.join("x64/rc.exe")).find(|p| p.is_file())
            }).unwrap_or_else(|| PathBuf::from("rc.exe"));
            let mut command = Command::new(rc);
            command.arg("/nologo").arg("/fo").arg(&resource).arg("trayluma.rc");
            command
        } else {
            let mut command = Command::new(env::var_os("WINDRES").unwrap_or_else(|| "windres".into()));
            command.args(["-i", "trayluma.rc", "-O", "coff", "-o"]).arg(&resource);
            command
        };
        assert!(compiler.current_dir("assets").status().expect("Install the Windows SDK resource compiler (rc.exe) or MinGW windres").success(), "resource compilation failed");
        println!("cargo:rustc-link-arg={}", resource.display());
    }
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=assets/trayluma.rc");
    println!("cargo:rerun-if-changed=assets/trayluma.ico");
    println!("cargo:rerun-if-env-changed=RC");
    println!("cargo:rerun-if-env-changed=WINDRES");
}
