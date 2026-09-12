# NetApp ONTAP Complete by HTTP

[![Validar / Validate](https://github.com/danielrc10/zabbix-template-netapp-ontap/actions/workflows/validate.yml/badge.svg)](https://github.com/danielrc10/zabbix-template-netapp-ontap/actions/workflows/validate.yml)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)

[Catálogo Projetos Zabbix](https://github.com/danielrc10/projetos-zabbix)

[Português](#português) · [English](#english)

## Português

Template API-first para monitorar clusters NetApp ONTAP no Zabbix. Uma única vinculação cobre cluster, nós, CPU, memória, HA, NVRAM, discos, agregados, volumes, LUNs, SVMs, SnapMirror, Ethernet, Fibre Channel, shelves, fontes, ventoinhas, sensores, AutoSupport, EMS, quotas e File System Analytics (FSA).

As descobertas de FSA e quotas são opt-in: nenhum volume é selecionado por padrão. Credenciais e endereços do storage não fazem parte do repositório e devem ser definidos como macros no host.

### Versões

| Zabbix | Template | Estado | Arquivos |
|---|---:|---|---|
| 7.4+ | `1.0.0` | Validado estruturalmente | [Abrir versão 7.4](zabbix-7.4/README.md) |

Este é um projeto independente, derivado e amplamente estendido a partir do template oficial `NetApp AFF A700 by HTTP` do Zabbix. Consulte [NOTICE.md](NOTICE.md) e [LICENSE](LICENSE).

## English

API-first template for monitoring NetApp ONTAP clusters with Zabbix. A single linked template covers the cluster, nodes, CPU, memory, HA, NVRAM, disks, aggregates, volumes, LUNs, SVMs, SnapMirror, Ethernet, Fibre Channel, shelves, power supplies, fans, sensors, AutoSupport, EMS, quotas, and File System Analytics (FSA).

FSA and quota discoveries are opt-in: no volume is selected by default. Storage credentials and addresses are not included in the repository and must be configured as host macros.

### Versions

| Zabbix | Template | Status | Files |
|---|---:|---|---|
| 7.4+ | `1.0.0` | Structurally validated | [Open version 7.4](zabbix-7.4/README.md#english) |

This independent project is derived and extensively extended from Zabbix's official `NetApp AFF A700 by HTTP` template. See [NOTICE.md](NOTICE.md) and [LICENSE](LICENSE).
