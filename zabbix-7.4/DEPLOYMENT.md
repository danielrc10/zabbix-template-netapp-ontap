# Implantação / Deployment

[Português](#português) · [English](#english)

## Português

1. Importe `template/template_netapp_ontap_complete_http.yaml` em **Coleta de dados → Templates → Importar**.
2. Crie um host lógico sem interface ou use um host dedicado ao cluster.
3. Vincule `NetApp ONTAP Complete by HTTP`.
4. Defina no host:

   ```text
   {$NETAPP.URL}=https://cluster.example.com
   {$NETAPP.USERNAME}=zabbix-readonly
   {$NETAPP.PASSWORD}=<texto secreto>
   ```

5. Conceda ao usuário somente leitura aos endpoints REST necessários. Teste inicialmente em homologação.
6. Confirme que `Get cluster`, `Get nodes`, `Get disks`, `Get Ethernet ports` e `Get shelves and environmental sensors` retornam JSON sem erro.
7. Execute as descobertas e revise os protótipos criados antes de habilitar notificações externas.

### FSA

FSA não seleciona volumes por padrão. Ative File System Analytics e atime nos volumes desejados e configure, por exemplo:

```text
{$NETAPP.FSA.VOLUME.MATCHES}=^(user-data|project-data)$
```

Comece com `{$NETAPP.FSA.MAX.DEPTH}=1`. Verifique duração, quantidade de pastas e carga da API antes de aumentar profundidade ou limites.

### Quotas

Quotas não selecionam volumes por padrão. Depois que quotas estiverem configuradas e ativas no ONTAP, defina:

```text
{$NETAPP.QUOTA.VOLUME.MATCHES}=^(user-data|project-data)$
```

### Portas esperadamente inativas

A descoberta inclui apenas portas administrativamente habilitadas. Se uma porta habilitada puder permanecer sem link por projeto, desative somente os alarmes dela com macro contextual:

```text
{$NETAPP.ETH.PORT.ALARM:"node-01/e0c"}=0
```

### Atualização

Faça backup do template atual, importe a nova versão com atualização de objetos existentes e revise a opção de remover entidades ausentes. Eventos já abertos conservam o nome capturado no momento do disparo até recuperarem; novos eventos usam a definição atualizada.

## English

Import `template/template_netapp_ontap_complete_http.yaml`, create an interface-less logical host, link `NetApp ONTAP Complete by HTTP`, and set the URL, read-only username, and secret password macros at host level.

Verify the master HTTP items before enabling external notifications. FSA and quota volume filters select nothing by default; explicitly configure the intended volume regexes. Start FSA at depth 1 and measure execution time and API load before increasing its limits.

Administratively disabled Ethernet ports are excluded. If an enabled port is intentionally allowed to remain without link, disable only its alarms with the contextual `{$NETAPP.ETH.PORT.ALARM:"node-01/e0c"}=0` macro.

Before an update, export a backup, import with existing-object updates enabled, and review deletion of missing entities. Already-open events retain the name captured when they fired until recovery; new events use the updated definition.
