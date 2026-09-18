# NetApp ONTAP Complete by HTTP — Zabbix 7.4+

[Português](#português) · [English](#english)

## Português

### Instalação

1. Importe [template_netapp_ontap_complete_http.yaml](template/template_netapp_ontap_complete_http.yaml).
2. Vincule `NetApp ONTAP Complete by HTTP` a um host sem interface.
3. Configure as três macros obrigatórias no host:

| Macro | Exemplo |
|---|---|
| `{$NETAPP.URL}` | `https://cluster.example.com` |
| `{$NETAPP.USERNAME}` | `zabbix-readonly` |
| `{$NETAPP.PASSWORD}` | senha como texto secreto |

### Recursos opcionais

| Recurso | Macro | Padrão |
|---|---|---|
| Volumes do FSA | `{$NETAPP.FSA.VOLUME.MATCHES}` | `^$` — nenhum |
| Volumes com quotas | `{$NETAPP.QUOTA.VOLUME.MATCHES}` | `^$` — nenhum |
| Excluir portas Ethernet | `{$NETAPP.ETH.PORT.NOT_MATCHES}` | `^$` — nenhuma |
| Desativar alarmes de uma porta | `{$NETAPP.ETH.PORT.ALARM:"nó/porta"}` | `1` — ativo |

As outras macros já possuem padrões seguros e podem ser ajustadas no host.

### Filtros FSA

```text
# Somente um volume
{$NETAPP.FSA.VOLUME.MATCHES}=^volume_users$

# Dois volumes
{$NETAPP.FSA.VOLUME.MATCHES}=^(volume_users|volume_projects)$

# Todos os volumes
{$NETAPP.FSA.VOLUME.MATCHES}=.*

# Inclui todos, exceto backup e volumes root
{$NETAPP.FSA.VOLUME.MATCHES}=.*
{$NETAPP.FSA.VOLUME.NOT_MATCHES}=^(backup|.*_root.*)$
```

Padrões do FSA:

- somente pastas de primeiro nível: `{$NETAPP.FSA.MAX.DEPTH}=1`;
- Warning após 365 dias;
- High após 1095 dias;
- só alarma quando acesso **e** modificação estão antigos;
- dias de inatividade são o mínimo garantido pelo bucket FSA; o item `Possible inactivity range` mostra a faixa possível;
- o evento mostra o tamanho da pasta;
- `FSA: Espaço total de pastas inativas` soma todas as pastas acima do limite de Warning, sem gerar alarme.

O FSA e a atualização de atime precisam estar ativos nos volumes selecionados.

### Comportamentos importantes

- Descobre somente portas Ethernet administrativamente habilitadas.
- LAG soma a velocidade dos membros ativos; VLAN usa a velocidade da porta base.
- Utilização de porta fica limitada a 100%; capacidade desconhecida não alarma.
- Agregados alarmam pelo uso físico, não pelo espaço apenas reservado em volumes thick.
- Fontes, fans, discos, shelves e sensores incluem o componente com problema no evento.

Para silenciar uma porta habilitada que pode ficar sem link:

```text
{$NETAPP.ETH.PORT.ALARM:"node-01/e0c"}=0
```

Mais detalhes: [DEPLOYMENT.md](DEPLOYMENT.md).

### Validação

```bash
ruby zabbix-7.4/tools/generate_template.rb
ruby zabbix-7.4/tools/validate_template.rb
```

## English

1. Import [template_netapp_ontap_complete_http.yaml](template/template_netapp_ontap_complete_http.yaml).
2. Link `NetApp ONTAP Complete by HTTP` to an interface-less host.
3. Set `{$NETAPP.URL}`, `{$NETAPP.USERNAME}`, and secret `{$NETAPP.PASSWORD}` on the host.

FSA and quotas are optional and select no volumes by default. Configure `{$NETAPP.FSA.VOLUME.MATCHES}` and `{$NETAPP.QUOTA.VOLUME.MATCHES}` with a volume-name regex. For example, `^(volume_users|volume_projects)$` selects two volumes, while `^volume_users$` selects one.

FSA defaults to first-level directories. It warns after 365 days and raises High severity after 1095 days only when both access and modification data are old. Inactivity days are the minimum guaranteed by the FSA bucket; `Possible inactivity range` shows its possible range. Events show the directory size, and `FSA: Espaço total de pastas inativas` provides a non-alerting total. FSA and atime updates must be enabled on selected volumes.

Ethernet discovery includes only administratively enabled ports. LAG/VLAN capacity is resolved automatically, utilization is capped at 100%, and unknown capacity does not trigger utilization alarms. Aggregate alerts use physical usage instead of thick-provisioned reservations.
