pub fn format_ingest(instance_count: usize, bytes: usize, ms: u128) -> String {
    let us_per = if instance_count > 0 {
        (ms * 1000) / instance_count as u128
    } else {
        0
    };
    format!("ingest n={instance_count} bytes={bytes} ms={ms} ({us_per}µs/inst)")
}

pub fn format_delta(upserted: usize, removed: usize, ms: u128) -> String {
    let ops = upserted + removed;
    let us_per = if ops > 0 {
        (ms * 1000) / ops as u128
    } else {
        0
    };
    format!("delta upserted={upserted} removed={removed} ms={ms} ({us_per}µs/op)")
}

pub fn format_bulk(bytes: usize, ms: u128) -> String {
    format!("bulk bytes={bytes} ms={ms}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_ingest_is_deterministic() {
        assert_eq!(
            format_ingest(1234, 98765, 420),
            "ingest n=1234 bytes=98765 ms=420 (340µs/inst)"
        );
    }

    #[test]
    fn format_delta_includes_op_counts() {
        assert_eq!(
            format_delta(3, 2, 50),
            "delta upserted=3 removed=2 ms=50 (10000µs/op)"
        );
    }

    #[test]
    fn format_bulk_reports_bytes_and_ms() {
        assert_eq!(format_bulk(1_048_576, 900), "bulk bytes=1048576 ms=900");
    }
}
