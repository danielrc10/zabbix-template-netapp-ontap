# NetApp ONTAP Complete by HTTP — Zabbix 7.4+

[Português](#português) · [English](#english)

> ONTAP REST API · HTTP Agent · JavaScript LLD · hardware, storage, SAN, rede, quotas e FSA

## Português

### Cobertura

O template reúne 20 regras de descoberta e monitora:

- cluster, versão, estado, IOPS, latência e throughput;
- nós, CPU, memória instalada, temperatura, HA, interconnect, NVRAM, spares, fans e fontes;
- chassis, shelves, FRUs/PSUs, ventoinhas e sensores de temperatura, tensão e corrente;
- discos, vida útil, estado persistente de falha, agregados, volumes, LUNs e SVMs;
- portas Ethernet e FC, link, velocidade, utilização, erros, descartes e topologia L2;
- SnapMirror, AutoSupport e eventos EMS críticos recentes;
- quotas efetivas de espaço e arquivos;
- volumes FSA, maiores diretórios e árvore recursiva de diretórios.

### Arquivos

- [Template YAML importável](template/template_netapp_ontap_complete_http.yaml)
- [Gerador determinístico](tools/generate_template.rb)
- [Validador estrutural e de JavaScript](tools/validate_template.rb)
- [Fonte oficial usada como base](tools/source/official_netapp_aff_a700_http.yaml)
- [Guia de implantação](DEPLOYMENT.md)

### Requisitos

- Zabbix 7.4 ou superior dentro da série compatível;
- NetApp ONTAP 9.10 ou superior recomendado;
- conectividade HTTPS do Zabbix Server ou Proxy até a API REST do cluster;
- usuário ONTAP somente leitura com acesso aos endpoints monitorados;
- Node.js disponível apenas para executar o validador do repositório, não para usar o template.

O núcleo REST existe em versões anteriores do ONTAP, mas algumas métricas e estruturas de hardware variam. CPU/rede requerem recursos presentes a partir de versões mais novas, e determinados sensores dependem do modelo e da versão do ONTAP.

### Instalação rápida

1. Importe [o template YAML](template/template_netapp_ontap_complete_http.yaml) no Zabbix.
2. Crie um host sem interface e vincule `NetApp ONTAP Complete by HTTP`.
3. Defina no host `{$NETAPP.URL}`, `{$NETAPP.USERNAME}` e `{$NETAPP.PASSWORD}`.
4. Execute os itens mestres e as descobertas; confirme permissões e campos retornados por sua versão do ONTAP.
5. Configure os filtros de FSA e quotas somente se quiser essas coletas.

Exemplo sem dados reais:

```text
{$NETAPP.URL}=https://cluster.example.com
{$NETAPP.USERNAME}=zabbix-readonly
{$NETAPP.PASSWORD}=<texto secreto no host>
{$NETAPP.FSA.VOLUME.MATCHES}=^(user-data|project-data)$
{$NETAPP.QUOTA.VOLUME.MATCHES}=^(user-data|project-data)$
```

Por segurança, os dois filtros de volume vêm como `^$`, que não seleciona volume algum. Não coloque credenciais no YAML.

### Macros principais

| Macro | Padrão | Finalidade |
|---|---:|---|
| `{$NETAPP.URL}` | vazio | URL HTTPS do cluster, sem `/` final |
| `{$NETAPP.USERNAME}` | vazio | Usuário REST somente leitura |
| `{$NETAPP.PASSWORD}` | vazio/secret | Senha do usuário REST |
| `{$NETAPP.HTTP.AGENT.TIMEOUT}` | `15s` | Timeout das coletas HTTP comuns |
| `{$NETAPP.API.MAX.RECORDS}` | `1000` | Limite geral de registros por chamada |
| `{$NETAPP.CPU.UTIL.CRIT}` | `90` | CPU alta por nó |
| `{$NETAPP.CPU.UTIL.RECOVERY}` | `80` | Recuperação do alarme de CPU |
| `{$NETAPP.DISK.LIFE.USED.CRIT}` | `90` | Vida útil consumida do disco |
| `{$NETAPP.DISK.LIFE.USED.RECOVERY}` | `85` | Recuperação da vida útil do disco |
| `{$NETAPP.VOLUME.USED.WARN}` | `80` | Uso Warning do volume |
| `{$NETAPP.VOLUME.USED.CRIT}` | `90` | Uso High do volume |
| `{$NETAPP.VOLUME.USED.RECOVERY}` | `75` | Recuperação dos alarmes do volume |
| `{$NETAPP.AGGREGATE.USED.WARN}` | `80` | Uso físico Warning do agregado |
| `{$NETAPP.AGGREGATE.USED.CRIT}` | `90` | Uso físico High do agregado |
| `{$NETAPP.AGGREGATE.USED.RECOVERY}` | `75` | Recuperação do uso físico do agregado |
| `{$NETAPP.SNAPMIRROR.LAG.CRIT}` | `86400` | Atraso crítico em segundos |
| `{$NETAPP.SNAPMIRROR.LAG.RECOVERY}` | `43200` | Recuperação do atraso em segundos |
| `{$NETAPP.EMS.MAX.RECORDS}` | `100` | Quantidade consultada de eventos EMS |
| `{$NETAPP.EMS.WINDOW}` | `900` | Janela de atualidade EMS em segundos |
| `{$NETAPP.SHELF.TIMEOUT}` | `30s` | Timeout da coleta pesada de shelves |
| `{$NETAPP.AUTOSUPPORT.TIMEOUT}` | `30s` | Timeout da verificação AutoSupport |

### Ethernet

| Macro | Padrão | Finalidade |
|---|---:|---|
| `{$NETAPP.ETH.PORT.ENABLED.MATCHES}` | `^1$` | Descobre somente portas administrativamente habilitadas |
| `{$NETAPP.ETH.PORT.MATCHES}` | `.*` | Inclui identificadores `nó/porta` |
| `{$NETAPP.ETH.PORT.NOT_MATCHES}` | `^$` | Exclui identificadores `nó/porta` |
| `{$NETAPP.ETH.PORT.ALARM}` | `1` | Controle global/contextual dos alarmes Ethernet |
| `{$NETAPP.PORT.UTIL.CRIT}` | `85` | Utilização sustentada que dispara alarme |
| `{$NETAPP.PORT.UTIL.RECOVERY}` | `75` | Recuperação do alarme de utilização |

Para silenciar apenas uma porta esperadamente fora de uso, crie no host uma macro contextual:

```text
{$NETAPP.ETH.PORT.ALARM:"node-01/e0c"}=0
```

Portas desabilitadas deixam a descoberta imediatamente e são removidas após um dia. Em LAG/ifgrp, a capacidade soma as portas físicas ativas; uma VLAN herda a capacidade da porta base. Quando a capacidade não pode ser determinada, o alarme de utilização é suprimido. O percentual é limitado a 100%.

`Inconsistência de topologia L2` significa que os domínios de broadcast alcançáveis diferem do domínio esperado pelo ONTAP. É um diagnóstico de VLAN/broadcast domain, separado do alarme de link perdido.

### Capacidade de agregados e volumes

Os alarmes de volume usam o consumo dentro do volume. Os alarmes de agregado usam `physical_used_percent`, isto é, blocos físicos realmente ocupados, e não o espaço apenas reservado por volumes thick provisioned. Os valores reservado, disponível e físico continuam coletados separadamente para diagnóstico.

### File System Analytics

| Macro | Padrão | Finalidade |
|---|---:|---|
| `{$NETAPP.FSA.VOLUME.MATCHES}` | `^$` | Volumes RW/online incluídos; obrigatório configurar para coletar FSA |
| `{$NETAPP.FSA.VOLUME.NOT_MATCHES}` | `^$` | Volumes excluídos |
| `{$NETAPP.FSA.MAX.DEPTH}` | `1` | Somente pastas de primeiro nível abaixo da raiz |
| `{$NETAPP.FSA.MAX.DIRECTORIES}` | `5000` | Limite de segurança por execução |
| `{$NETAPP.FSA.PAGE.SIZE}` | `1000` | Registros por página da API de arquivos |
| `{$NETAPP.FSA.DIRECTORY.DELAY}` | `6h` | Frequência da árvore recursiva |
| `{$NETAPP.FSA.DIRECTORY.TIMEOUT}` | `300s` | Timeout do item Script |
| `{$NETAPP.FSA.TOP.N}` | `20` | Quantidade de maiores diretórios no resumo |
| `{$NETAPP.FSA.MAX.RECORDS}` | `200` | Registros do resumo por volume |
| `{$NETAPP.FSA.DELAY}` | `1h` | Frequência do resumo por volume |
| `{$NETAPP.FSA.TIMEOUT}` | `60s` | Timeout do resumo por volume |
| `{$NETAPP.FSA.INACTIVE.WARN.DAYS}` | `365` | Warning se acesso e modificação estiverem antigos |
| `{$NETAPP.FSA.INACTIVE.CRIT.DAYS}` | `1095` | High se acesso e modificação estiverem antigos |

O alerta de pasta só abre quando **os dados mais novos de acesso e de modificação** estão antigos. Uma pasta modificada há anos, mas acessada recentemente, não alarma. A API FSA fornece faixas de tempo agregadas; por isso o template registra o rótulo da faixa e calcula a inatividade pelo fim do período conhecido, evitando apresentar uma precisão que o ONTAP não forneceu.

O FSA deve estar ativo nos volumes e a atualização de atime deve estar habilitada para que acesso seja significativo. A consulta pode gerar muitas chamadas; comece com profundidade `1`, mantenha o limite de segurança e aumente somente após medir o tempo de execução.

### Quotas efetivas

| Macro | Padrão | Finalidade |
|---|---:|---|
| `{$NETAPP.QUOTA.VOLUME.MATCHES}` | `^$` | Volumes incluídos; obrigatório configurar para descobrir quotas |
| `{$NETAPP.QUOTA.VOLUME.NOT_MATCHES}` | `^$` | Volumes excluídos |
| `{$NETAPP.QUOTA.TYPE.MATCHES}` | `^(user|group|tree)$` | Tipos de cota incluídos |
| `{$NETAPP.QUOTA.USED.WARN}` | `80` | Warning do hard limit |
| `{$NETAPP.QUOTA.USED.CRIT}` | `90` | High do hard limit; 100% gera Disaster |
| `{$NETAPP.QUOTA.MAX.RECORDS}` | `5000` | Limite de relatórios efetivos |
| `{$NETAPP.QUOTA.DELAY}` | `15m` | Frequência da coleta |
| `{$NETAPP.QUOTA.TIMEOUT}` | `30s` | Timeout da coleta |

Quotas sem limite não geram falso alarme. O template também alerta soft limits quando presentes e diferencia espaço de quantidade de arquivos.

### Hardware e alarmes

Estados de fontes/FRUs, ventoinhas, shelves, discos e sensores são descobertos com a identidade do componente no evento. Uma fonte instalada com estado diferente de `ok` gera alarme; falhas resumidas no controlador também são verificadas. A disponibilidade exata dos campos depende do modelo e da versão do ONTAP.

### Validação

```bash
ruby zabbix-7.4/tools/generate_template.rb
git diff --exit-code -- zabbix-7.4/template/template_netapp_ontap_complete_http.yaml
ruby zabbix-7.4/tools/validate_template.rb
```

O validador confere YAML, UUIDv4, ausência de colisão com a base oficial, macros secretas, referências de itens/gráficos/triggers, sintaxe JavaScript e cenários de execução para Ethernet, LAG/VLAN, FSA, quotas, shelves/PSUs e EMS. A validação final deve incluir importação e coleta em uma homologação com o mesmo patch do Zabbix e a mesma família de ONTAP usada em produção.

---

## English

This Zabbix 7.4+ template monitors NetApp ONTAP through the REST API. It includes 20 discovery rules covering cluster and node health/performance, storage, SAN, Ethernet, shelves and environmental hardware, AutoSupport, EMS, SnapMirror, effective quotas, and File System Analytics.

Import [the YAML template](template/template_netapp_ontap_complete_http.yaml), link it to an interface-less host, and define `{$NETAPP.URL}`, `{$NETAPP.USERNAME}`, and the secret `{$NETAPP.PASSWORD}` at host level. Use a read-only ONTAP account.

FSA and quota volume discovery are intentionally disabled by the default `^$` filters. Set `{$NETAPP.FSA.VOLUME.MATCHES}` and `{$NETAPP.QUOTA.VOLUME.MATCHES}` to regexes matching the intended volumes. FSA defaults to first-level directories, warns after one year, and raises High severity after three years only when both accessed and modified data are old.

Ethernet discovery selects administratively enabled ports by default. LAG capacity is the sum of active member speeds, VLAN capacity follows the base port, unknown capacity suppresses utilization alerts, and calculated utilization is capped at 100%. Layer-2 reachability inconsistency is reported separately from link loss.

Aggregate capacity alerts use physically occupied blocks rather than thick-provisioned reservations. Volume space remains monitored independently. Hardware events include the affected disk, PSU/FRU, fan, shelf, or sensor identity whenever ONTAP exposes it.

Run the generator and validator commands shown above before contributing. Always validate the import and live collection against a staging Zabbix/ONTAP environment before production deployment.
