# Changelog

All notable changes to this project are documented here.

## [1.1.1] - 2026-09-18

### Fixed

- Clarified that FSA inactivity days are a conservative minimum derived from the end of an ONTAP time bucket.
- Added a per-directory `Possible inactivity range` item for coarse yearly FSA buckets.
- Marked inactivity as minimum in FSA item and event names.

## [1.1.0] - 2026-09-18

### Added

- Directory size in one-year and three-year FSA inactivity event names.
- Informational `FSA: Espaço total de pastas inativas` item, summing directories at or above the Warning inactivity threshold without nested-directory double counting.

## [1.0.0] - 2026-09-12

### Added

- Initial public release for Zabbix 7.4.
- ONTAP REST monitoring for cluster, nodes, storage, SAN, network, hardware, AutoSupport, EMS, SnapMirror, effective quotas, and FSA.
- Hardware alerts with component identity for disks, power supplies, fans, shelves, and environmental sensors.
- Ethernet discovery limited to administratively enabled ports by default, with per-port contextual alarm control.
- Link aggregation and VLAN-aware interface capacity calculation with utilization capped at 100%.
- Separate Ethernet link-state and Layer-2 reachability diagnostics.
- Recursive first-level FSA directory discovery and alerts only when both access and modification data are old.
- One-year Warning and three-year High FSA inactivity thresholds.
- Effective quota discovery for space and file hard/soft limits.
- Deterministic UUIDv4 generation and structural/runtime validation.

### Security

- URL, username, and password are empty in the export; the password macro is secret text.
- FSA and quota volume filters select nothing until explicitly configured on the host.
