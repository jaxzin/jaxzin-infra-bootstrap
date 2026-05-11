resource "unifi_dns_record" "this" {
  for_each = { for r in var.unifi_static_dns : r.name => r }

  name        = each.value.name
  value       = each.value.value
  record_type = each.value.type
}
