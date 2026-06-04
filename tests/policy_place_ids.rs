use studio_stud::policy::Policy;

#[test]
fn allowed_place_ids_accepts_string_and_int() {
    let s: Policy = serde_json::from_str(r#"{"allowedPlaceIds":["109595751023912"]}"#).unwrap();
    assert_eq!(s.allowed_place_ids, vec![109_595_751_023_912]);
    let i: Policy = serde_json::from_str(r#"{"allowedPlaceIds":[109595751023912]}"#).unwrap();
    assert_eq!(i.allowed_place_ids, vec![109_595_751_023_912]);
}
