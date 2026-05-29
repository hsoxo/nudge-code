fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-changed=../../proto/nudge.proto");
    prost_build::compile_protos(&["../../proto/nudge.proto"], &["../../proto"])?;
    Ok(())
}
