mod adapters;
mod owner;
mod sched;

fn main() {
    println!("{:?}", adapters::discover());
}
