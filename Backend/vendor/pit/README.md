# samloader-pit

A robust, pure-Rust parser and manipulator for Samsung device Partition Information Table (PIT) files.

## Features

- Parses and serializes binary PIT headers and structured partition entries.
- Exposes metadata such as block offsets, write permissions, secure flags, and partition names.
- Computes logical partition sizes based on underlying sector sizes (MMC or UFS).
- Reconstructs binary PIT tables from structured records for flashing.

## Usage

### Parsing a PIT file

```rust
use samloader_pit::PitData;
use std::fs;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let pit_bytes = fs::read("device.pit")?;
    
    // Parse the binary PIT table
    let pit_data = PitData::new(&pit_bytes)?;
    println!("Total partitions found: {}", pit_data.entries.len());

    // Print human-readable PIT layout
    println!("{}", pit_data);

    // Look up a specific partition entry by name
    if let Some(entry) = pit_data.find_entry_by_name("RECOVERY") {
        println!("Recovery partition offset: {}", entry.start_block);
        println!("Recovery partition size in bytes: {}", entry.partition_size());
    }

    Ok(())
}
```

## License

This project is licensed under the Apache License, Version 2.0.
