pub mod v1 {
    include!(concat!(env!("OUT_DIR"), "/nudge.v1.rs"));
}

pub fn free_entitlement() -> v1::Entitlement {
    v1::Entitlement {
        plan: "free".to_string(),
        max_bound_computers: 1,
        max_tabs_per_computer: 1,
    }
}
