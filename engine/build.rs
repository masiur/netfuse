fn main() {
    println!("cargo:rerun-if-changed=src/owner.c");
    cc::Build::new().file("src/owner.c").compile("owner");
}
