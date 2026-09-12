# NetApp ONTAP Complete by HTTP

[![Validar / Validate](https://github.com/danielrc10/zabbix-template-netapp-ontap/actions/workflows/validate.yml/badge.svg)](https://github.com/danielrc10/zabbix-template-netapp-ontap/actions/workflows/validate.yml)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)

[Catálogo Projetos Zabbix](https://github.com/danielrc10/projetos-zabbix) · [Português](#português) · [English](#english)

## Português

Template Zabbix 7.4+ para monitoramento completo do NetApp ONTAP por REST API: cluster, nós, CPU, memória, discos, agregados, volumes, rede, FC, shelves, fontes, fans, sensores, SnapMirror, AutoSupport, EMS, quotas e FSA.

**[Baixar template YAML](zabbix-7.4/template/template_netapp_ontap_complete_http.yaml)**

### Macros obrigatórias

| Macro | Exemplo |
|---|---|
| `{$NETAPP.URL}` | `https://cluster.example.com` |
| `{$NETAPP.USERNAME}` | `zabbix-readonly` |
| `{$NETAPP.PASSWORD}` | senha secreta no host |

### Opcional

FSA e quotas não selecionam volumes até você configurar:

```text
# Um volume
{$NETAPP.FSA.VOLUME.MATCHES}=^volume_users$

# Vários volumes
{$NETAPP.FSA.VOLUME.MATCHES}=^(volume_users|volume_projects)$

# Quotas
{$NETAPP.QUOTA.VOLUME.MATCHES}=^(volume_users|volume_projects)$
```

As demais macros já possuem valores padrão. Veja a [referência rápida e instalação](zabbix-7.4/README.md).

## English

Zabbix 7.4+ template for comprehensive NetApp ONTAP REST API monitoring: cluster, nodes, CPU, memory, disks, aggregates, volumes, network, FC, shelves, PSUs, fans, sensors, SnapMirror, AutoSupport, EMS, quotas, and FSA.

**[Download the YAML template](zabbix-7.4/template/template_netapp_ontap_complete_http.yaml)**

Required host macros: `{$NETAPP.URL}`, `{$NETAPP.USERNAME}`, and secret `{$NETAPP.PASSWORD}`. FSA and quotas are optional; select their volumes with `{$NETAPP.FSA.VOLUME.MATCHES}` and `{$NETAPP.QUOTA.VOLUME.MATCHES}`. See the [quick reference](zabbix-7.4/README.md#english).

Derived from Zabbix's official `NetApp AFF A700 by HTTP` template. See [NOTICE.md](NOTICE.md) and [LICENSE](LICENSE).
