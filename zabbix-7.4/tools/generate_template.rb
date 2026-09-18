#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'
require 'digest'
require 'fileutils'

SOURCE = File.expand_path('source/official_netapp_aff_a700_http.yaml', __dir__)
OUTPUT = File.expand_path('../template/template_netapp_ontap_complete_http.yaml', __dir__)

TEMPLATE = 'NetApp ONTAP Complete by HTTP'
PREFIX = 'NetApp ONTAP'

def uuid(name)
  # Zabbix exports UUIDs without dashes, but validates the RFC 4122 version
  # and variant bits. Keep the identifiers deterministic while making every
  # generated value a valid UUIDv4.
  value = Digest::MD5.hexdigest("netapp-ontap-complete-v1:#{name}")
  value[12] = '4'
  value[16] = ((value[16].to_i(16) & 0x3) | 0x8).to_s(16)
  value
end

# The source is an official Zabbix template. Every object in this customized
# copy gets a fresh deterministic UUID so an import cannot overwrite or collide
# with the official template already installed on the server.
def remap_template_uuids!(node, path = 'template')
  case node
  when Hash
    node['uuid'] = uuid("object:#{path}") if node.key?('uuid')
    node.each do |key, value|
      remap_template_uuids!(value, "#{path}/#{key}") unless key == 'uuid'
    end
  when Array
    # Revision 7.4-18 removed the obsolete directory accessed-time prototype
    # from the middle of this array. Reserve its former index only while
    # deriving UUIDs so every following prototype keeps the identity already
    # imported by previous releases, without shipping a disabled placeholder.
    fsa_directory_uuid_gap = node.any? do |value|
      value.is_a?(Hash) && value['key'] == 'netapp.fsa.directory.bytes_used[{#DIRID}]'
    end && node.any? do |value|
      value.is_a?(Hash) && value['key'] == 'netapp.fsa.directory.accessed_newest_label[{#DIRID}]'
    end && node.none? do |value|
      value.is_a?(Hash) && value['key'] == 'netapp.fsa.directory.accessed_time[{#DIRID}]'
    end
    node.each_with_index do |value, index|
      stable_index = fsa_directory_uuid_gap && index >= 3 ? index + 1 : index
      remap_template_uuids!(value, "#{path}/#{stable_index}")
    end
  end
end

def tags(component, extra = {})
  result = [{ 'tag' => 'component', 'value' => component }]
  extra.each { |key, value| result << { 'tag' => key, 'value' => value } }
  result
end

def jsonpath(path)
  [{ 'type' => 'JSONPATH', 'parameters' => [path] }]
end

def javascript(code)
  [{ 'type' => 'JAVASCRIPT', 'parameters' => [code] }]
end

def http_item(name:, key:, url:, delay: nil, timeout: '{$NETAPP.HTTP.AGENT.TIMEOUT}', component: 'raw')
  item = {
    'uuid' => uuid("item:#{key}"),
    'name' => name,
    'type' => 'HTTP_AGENT',
    'key' => key,
    'history' => '0',
    'value_type' => 'TEXT',
    'authtype' => 'BASIC',
    'username' => '{$NETAPP.USERNAME}',
    'password' => '{$NETAPP.PASSWORD}',
    'timeout' => timeout,
    'url' => url,
    'tags' => tags(component)
  }
  item['delay'] = delay if delay
  item
end

def dependent_item(name:, key:, master:, preprocessing:, component:, value_type: nil,
                   units: nil, description: nil, triggers: nil, extra_tags: {})
  item = {
    'uuid' => uuid("item:#{key}"),
    'name' => name,
    'type' => 'DEPENDENT',
    'key' => key,
    'preprocessing' => preprocessing,
    'master_item' => { 'key' => master },
    'tags' => tags(component, extra_tags)
  }
  item['value_type'] = value_type if value_type
  item['units'] = units if units
  item['description'] = description if description
  item['triggers'] = triggers if triggers
  item
end

def trigger(id:, expression:, name:, priority: 'AVERAGE', description: nil,
            recovery_expression: nil, manual_close: nil, scope: 'availability',
            event_name: nil, opdata: nil)
  value = {
    'uuid' => uuid("trigger:#{id}"),
    'expression' => expression,
    'name' => name,
    'priority' => priority,
    'tags' => [{ 'tag' => 'scope', 'value' => scope }]
  }
  if recovery_expression
    value['recovery_mode'] = 'RECOVERY_EXPRESSION'
    value['recovery_expression'] = recovery_expression
  end
  value['description'] = description if description
  value['manual_close'] = manual_close if manual_close
  value['event_name'] = event_name if event_name
  value['opdata'] = opdata if opdata
  value
end

def proto_trigger(id:, expression:, name:, priority: 'AVERAGE', description: nil,
                  recovery_expression: nil, scope: 'availability', event_name: nil,
                  opdata: nil)
  trigger(
    id: "prototype:#{id}",
    expression: expression,
    name: name,
    priority: priority,
    description: description,
    recovery_expression: recovery_expression,
    scope: scope,
    event_name: event_name,
    opdata: opdata
  )
end

def dependent_proto(name:, key:, master:, preprocessing:, component:, value_type: nil,
                    units: nil, description: nil, triggers: nil, extra_tags: {})
  item = {
    'uuid' => uuid("prototype:#{key}"),
    'name' => name,
    'type' => 'DEPENDENT',
    'key' => key,
    'preprocessing' => preprocessing,
    'master_item' => { 'key' => master },
    'tags' => tags(component, extra_tags)
  }
  item['value_type'] = value_type if value_type
  item['units'] = units if units
  item['description'] = description if description
  item['trigger_prototypes'] = triggers if triggers
  item
end

def calculated_proto(name:, key:, formula:, component:, units: nil, description: nil, triggers: nil, extra_tags: {})
  item = {
    'uuid' => uuid("prototype:#{key}"),
    'name' => name,
    'type' => 'CALCULATED',
    'key' => key,
    'value_type' => 'FLOAT',
    'params' => formula,
    'tags' => tags(component, extra_tags)
  }
  item['units'] = units if units
  item['description'] = description if description
  item['trigger_prototypes'] = triggers if triggers
  item
end

def dependent_discovery(name:, key:, master:, preprocessing:, prototypes:, delay: nil, graph_prototypes: nil)
  rule = {
    'uuid' => uuid("discovery:#{key}"),
    'name' => name,
    'type' => 'DEPENDENT',
    'key' => key,
    'item_prototypes' => prototypes,
    'master_item' => { 'key' => master },
    'preprocessing' => preprocessing
  }
  rule['delay'] = delay if delay
  rule['graph_prototypes'] = graph_prototypes if graph_prototypes
  rule
end

def find_record_js(match_expression, value_expression, missing = 'null')
  <<~JS
    var data = JSON.parse(value);
    var records = data.records || [];
    for (var i = 0; i < records.length; i++) {
      var r = records[i];
      if (#{match_expression}) {
        var result = #{value_expression};
        return (result === undefined || result === null) ? #{missing} : result;
      }
    }
    return #{missing};
  JS
end

def lld_from_records_js(mapping)
  assignments = mapping.map { |macro, expr| "row[\"#{macro}\"] = #{expr};" }.join("\n    ")
  <<~JS
    var data = JSON.parse(value);
    var records = data.records || [];
    var result = [];
    for (var i = 0; i < records.length; i++) {
      var r = records[i];
      var row = {};
      #{assignments}
      result.push(row);
    }
    return JSON.stringify(result);
  JS
end

def deep_replace(value)
  case value
  when Hash
    value.each { |key, child| value[key] = deep_replace(child) }
  when Array
    value.map! { |child| deep_replace(child) }
  when String
    value.gsub('NetApp AFF A700 by HTTP', TEMPLATE).gsub('NetApp AFF A700', PREFIX).gsub('AFF700', 'ONTAP')
  else
    value
  end
end

def add_value_context_to_alarms!(node)
  case node
  when Hash
    if node['expression'] && node['name'] && !node['expression'].include?('nodata(')
      node['event_name'] ||= "#{node['name']} | valor no disparo: {ITEM.VALUE1}"
      node['event_name'] = node['event_name'].gsub('{ITEM.LASTVALUE', '{ITEM.VALUE')
      node['opdata'] ||= 'Valor atual: {ITEM.LASTVALUE1}'
    end
    node.each_value { |value| add_value_context_to_alarms!(value) }
  when Array
    node.each { |value| add_value_context_to_alarms!(value) }
  end
end

data = YAML.load_file(SOURCE)
template = data.fetch('zabbix_export').fetch('templates').first
deep_replace(template)

template['template'] = TEMPLATE
template['name'] = TEMPLATE
template['description'] = <<~DESC
  Template consolidado para monitoramento de clusters NetApp ONTAP por REST API no Zabbix 7.4.

  Baseado no template oficial "NetApp AFF A700 by HTTP" 7.4-1, ampliado para:
  - cluster, nós, CPU, capacidade de memória, HA, NVRAM, fans e fontes;
  - chassis, shelves, FRUs/PSUs, ventoinhas e sensores elétricos/térmicos;
  - discos, agregados, volumes, quotas efetivas, LUNs, SVMs e SnapMirror;
  - Ethernet/FC, vazão, utilização, erros, descartes e quedas de link;
  - AutoSupport, eventos EMS críticos recentes e File System Analytics (FSA).

  Compatibilidade alvo: ONTAP 9.10 ou superior. O núcleo funciona desde 9.6; métricas de CPU/rede
  requerem 9.8 e alguns sensores/estado de hardware requerem 9.9/9.10.

  Configure no host: {$NETAPP.URL}, {$NETAPP.USERNAME} e {$NETAPP.PASSWORD}.
  Use uma conta REST somente leitura. A senha não está embutida neste arquivo.

  FSA fica em descobertas separadas: um resumo top-N e uma árvore recursiva de diretórios.
  Por segurança, FSA e quotas não selecionam nenhum volume por padrão. Configure
  {$NETAPP.FSA.VOLUME.MATCHES} e {$NETAPP.QUOTA.VOLUME.MATCHES} no host. Controle a árvore com
  {$NETAPP.FSA.MAX.DEPTH} e {$NETAPP.FSA.MAX.DIRECTORIES}; o ONTAP não devolve toda a hierarquia
  em uma única chamada. Pastas sem acesso nem modificação geram Warning após um ano e High após
  três anos, conforme as macros de inatividade.
DESC
template['vendor'] = { 'name' => 'Daniel Carvalho', 'version' => '1.1.1' }
template['tags'] = [
  { 'tag' => 'class', 'value' => 'storage' },
  { 'tag' => 'target', 'value' => 'netapp' },
  { 'tag' => 'target', 'value' => 'ontap' }
]

items = template.fetch('items')
discoveries = template.fetch('discovery_rules')

by_key = items.to_h { |item| [item['key'], item] }
by_discovery_key = discoveries.to_h { |rule| [rule['key'], rule] }

# Harden official collection calls and request fields omitted from the upstream template.
by_key['netapp.chassis.get']['url'] = '{$NETAPP.URL}/api/cluster/chassis?fields=id,state&max_records={$NETAPP.API.MAX.RECORDS}'
by_key['netapp.disks.get']['url'] = '{$NETAPP.URL}/api/storage/disks?fields=name,uid,node.name,state,container_type,model,serial_number,firmware_version,usable_size,physical_size,rated_life_used_percent,outage.persistently_failed,outage.reason.message,error.reason.message,bay,location&max_records={$NETAPP.API.MAX.RECORDS}'
by_key['netapp.frus.get']['url'] = '{$NETAPP.URL}/api/cluster/chassis?fields=id,frus.id,frus.state,frus.type&max_records={$NETAPP.API.MAX.RECORDS}'
by_key['netapp.frus.get']['preprocessing'] = javascript(<<~JS)
  var data = JSON.parse(value);
  var records = data.records || [];
  var result = [];
  for (var i = 0; i < records.length; i++) {
    var chassis = records[i];
    var frus = chassis.frus || [];
    for (var j = 0; j < frus.length; j++) {
      var fru = frus[j];
      fru.chassisId = chassis.id;
      result.push(fru);
    }
  }
  return JSON.stringify(result);
JS
by_key['netapp.luns.get']['url'] = '{$NETAPP.URL}/api/storage/luns?fields=name,uuid,svm.name,space.size,space.used,status.state,status.container_state&max_records={$NETAPP.API.MAX.RECORDS}'
by_key['netapp.nodes.get']['url'] = '{$NETAPP.URL}/api/cluster/nodes?fields=name,uuid,state,uptime,location,membership,version.full,controller.over_temperature,controller.memory_size,controller.cpu.count,controller.failed_fan.count,controller.failed_fan.message.message,controller.failed_power_supply.count,controller.failed_power_supply.message.message,metric.processor_utilization,metric.status,ha.enabled,ha.interconnect.state,nvram.battery_state,is_spares_low&max_records={$NETAPP.API.MAX.RECORDS}'
by_key['netapp.ports.eth.get']['url'] = '{$NETAPP.URL}/api/network/ethernet/ports?fields=uuid,name,type,node.name,broadcast_domain.name,reachable_broadcast_domains.name,enabled,state,reachability,mtu,speed,lag.*,vlan.*,metric.*,statistics.device.*&max_records={$NETAPP.API.MAX.RECORDS}'
by_key['netapp.ports.fc.get']['url'] = '{$NETAPP.URL}/api/network/fc/ports?fields=uuid,name,node.name,description,enabled,fabric.switch_port,state,metric.*&max_records={$NETAPP.API.MAX.RECORDS}'
by_key['netapp.svms.get']['url'] = '{$NETAPP.URL}/api/svm/svms?fields=name,state,comment&max_records={$NETAPP.API.MAX.RECORDS}'
by_key['netapp.volumes.get']['url'] = '{$NETAPP.URL}/api/storage/volumes?fields=name,uuid,comment,state,type,svm.name,quota.state,space.size,space.available,space.used,statistics&max_records={$NETAPP.API.MAX.RECORDS}'

# Availability alarm for the REST polling path itself.
by_key['netapp.cluster.get']['triggers'] ||= []
by_key['netapp.cluster.get']['triggers'] << trigger(
  id: 'rest-api-no-data',
  expression: "nodata(/#{TEMPLATE}/netapp.cluster.get,10m)=1",
  recovery_expression: "nodata(/#{TEMPLATE}/netapp.cluster.get,10m)=0",
  name: "#{PREFIX}: REST API sem dados por 10 minutos",
  priority: 'HIGH',
  description: 'Verifique URL, credenciais, certificado, conectividade e permissões da conta REST.'
)

# Update official LLD URLs for pagination and richer records.
by_discovery_key['netapp.chassis.discovery']['url'] = '{$NETAPP.URL}/api/cluster/chassis?fields=id&max_records={$NETAPP.API.MAX.RECORDS}'
by_discovery_key['netapp.disks.discovery']['url'] = '{$NETAPP.URL}/api/storage/disks?fields=name,node.name&max_records={$NETAPP.API.MAX.RECORDS}'
by_discovery_key['netapp.luns.discovery']['url'] = '{$NETAPP.URL}/api/storage/luns?fields=name,uuid,svm.name&max_records={$NETAPP.API.MAX.RECORDS}'
by_discovery_key['netapp.nodes.discovery']['url'] = '{$NETAPP.URL}/api/cluster/nodes?fields=name,uuid&max_records={$NETAPP.API.MAX.RECORDS}'
by_discovery_key['netapp.ports.ether.discovery']['url'] = '{$NETAPP.URL}/api/network/ethernet/ports?fields=uuid,name,state,type,enabled,node.name,broadcast_domain.name,reachable_broadcast_domains.name&max_records={$NETAPP.API.MAX.RECORDS}'
by_discovery_key['netapp.ports.fc.discovery']['url'] = '{$NETAPP.URL}/api/network/fc/ports?fields=uuid,node.name,name,state,enabled&max_records={$NETAPP.API.MAX.RECORDS}'
by_discovery_key['netapp.svms.discovery']['url'] = '{$NETAPP.URL}/api/svm/svms?fields=name&max_records={$NETAPP.API.MAX.RECORDS}'
by_discovery_key['netapp.volumes.discovery']['url'] = '{$NETAPP.URL}/api/storage/volumes?fields=name,uuid,svm.name,type&max_records={$NETAPP.API.MAX.RECORDS}'

by_discovery_key['netapp.nodes.discovery']['preprocessing'] = javascript(lld_from_records_js(
  '{#NODENAME}' => 'r.name',
  '{#NODEUUID}' => 'r.uuid'
))
by_discovery_key['netapp.ports.ether.discovery']['preprocessing'] = javascript(lld_from_records_js(
  '{#NODENAME}' => 'r.node.name',
  '{#ETHPORTNAME}' => 'r.name',
  '{#ETHPORTID}' => 'r.node.name + "/" + r.name',
  '{#ETHPORTUUID}' => 'r.uuid',
  '{#ETHPORTTYPE}' => 'r.type',
  '{#ETHPORTENABLED}' => '(r.enabled === true || r.enabled === 1 || String(r.enabled).toLowerCase() === "true" ? "1" : "0")',
  '{#ETHBROADCASTDOMAIN}' => '(r.broadcast_domain && r.broadcast_domain.name ? r.broadcast_domain.name : "unknown")',
  '{#ETHREACHABLEDOMAINS}' => '(r.reachable_broadcast_domains || []).map(function (domain) { return domain && domain.name ? domain.name : ""; }).join(", ")'
))
by_discovery_key['netapp.ports.ether.discovery']['filter'] = {
  'evaltype' => 'AND',
  'conditions' => [
    { 'macro' => '{#ETHPORTID}', 'value' => '{$NETAPP.ETH.PORT.MATCHES}', 'formulaid' => 'A' },
    { 'macro' => '{#ETHPORTID}', 'value' => '{$NETAPP.ETH.PORT.NOT_MATCHES}', 'operator' => 'NOT_MATCHES_REGEX', 'formulaid' => 'B' },
    { 'macro' => '{#ETHPORTENABLED}', 'value' => '{$NETAPP.ETH.PORT.ENABLED.MATCHES}', 'formulaid' => 'C' }
  ]
}
by_discovery_key['netapp.ports.ether.discovery']['delay'] = '10m'
by_discovery_key['netapp.ports.ether.discovery']['enabled_lifetime_type'] = 'DISABLE_IMMEDIATELY'
by_discovery_key['netapp.ports.ether.discovery']['lifetime_type'] = 'DELETE_AFTER'
by_discovery_key['netapp.ports.ether.discovery']['lifetime'] = '1d'
by_discovery_key['netapp.ports.fc.discovery']['preprocessing'] = javascript(lld_from_records_js(
  '{#NODENAME}' => 'r.node.name',
  '{#FCPORTNAME}' => 'r.name',
  '{#FCPORTUUID}' => 'r.uuid',
  '{#FCPORTENABLED}' => 'r.enabled'
))
by_discovery_key['netapp.volumes.discovery']['preprocessing'] = javascript(lld_from_records_js(
  '{#VOLUMENAME}' => 'r.name',
  '{#VOLUMEUUID}' => 'r.uuid',
  '{#SVMNAME}' => '(r.svm ? r.svm.name : "")',
  '{#VOLUMETYPE}' => 'r.type'
))

# Correct ambiguous JSONPath selectors on ports with the same name on different nodes.
by_discovery_key['netapp.ports.ether.discovery']['item_prototypes'].each do |prototype|
  (prototype['preprocessing'] || []).each do |step|
    next unless step['type'] == 'JSONPATH'
    step['parameters'][0] = step['parameters'][0].sub(
      "@.name=='{#ETHPORTNAME}'",
      "@.name=='{#ETHPORTNAME}'&&@.node.name=='{#NODENAME}'"
    )
  end
end
by_discovery_key['netapp.ports.fc.discovery']['item_prototypes'].each do |prototype|
  (prototype['preprocessing'] || []).each do |step|
    next unless step['type'] == 'JSONPATH'
    step['parameters'][0] = step['parameters'][0].sub(
      "@.name=='{#FCPORTNAME}'",
      "@.name=='{#FCPORTNAME}'&&@.node.name=='{#NODENAME}'"
    )
  end
end

# Replace the upstream disk trigger: spare/zeroing/reconstructing are valid operational states.
disk_state = by_discovery_key['netapp.disks.discovery']['item_prototypes'].find { |p| p['key'].start_with?('netapp.disk.state[') }
disk_state['trigger_prototypes'] = [proto_trigger(
  id: 'disk-failed',
  expression: "find(/#{TEMPLATE}/netapp.disk.state[{#NODENAME},{#DISKNAME}],,\"regexp\",\"^(broken|removed|unfail)$\")=1",
  recovery_expression: "find(/#{TEMPLATE}/netapp.disk.state[{#NODENAME},{#DISKNAME}],,\"regexp\",\"^(broken|removed|unfail)$\")=0",
  name: "#{PREFIX}: {#DISKNAME} no nó {#NODENAME} está com falha",
  event_name: "#{PREFIX}: Disco {#DISKNAME} no nó {#NODENAME} com falha | estado: {ITEM.LASTVALUE1}",
  opdata: 'Estado atual: {ITEM.LASTVALUE1}',
  priority: 'HIGH',
  description: 'Estados spare, copy, zeroing e reconstructing não são tratados como falha.'
)]

# Make the inherited chassis alarms immediately readable in the Problems view.
chassis_state = by_discovery_key['netapp.chassis.discovery']['item_prototypes'].find do |prototype|
  prototype['key'].start_with?('netapp.chassis.state[')
end
Array(chassis_state['trigger_prototypes']).each do |alarm|
  alarm['name'] = "#{PREFIX}: Chassis {#ID} em estado anormal"
  alarm['event_name'] = "#{PREFIX}: Chassis {#ID} em estado anormal | estado: {ITEM.LASTVALUE1}"
  alarm['opdata'] = 'Estado atual: {ITEM.LASTVALUE1}'
end
chassis_fru_state = by_discovery_key['netapp.frus.discovery']['item_prototypes'].find do |prototype|
  prototype['key'].start_with?('netapp.chassis.fru.state[')
end
by_discovery_key['netapp.frus.discovery']['preprocessing'] = javascript(<<~JS)
  var records = JSON.parse(value) || [];
  var result = [];
  for (var i = 0; i < records.length; i++) {
    var fru = records[i] || {};
    result.push({
      "{#CHASSISID}": fru.chassisId,
      "{#FRUID}": fru.id,
      "{#FRUTYPE}": fru.type || 'fru'
    });
  }
  return JSON.stringify(result);
JS
chassis_fru_state['name'] = '{#FRUTYPE} {#FRUID}: State'
chassis_fru_state['description'] = 'Estado da FRU: qualquer valor diferente de ok gera alarme.'
chassis_fru_state['tags'] ||= []
chassis_fru_state['tags'] << { 'tag' => 'type', 'value' => '{#FRUTYPE}' }
Array(chassis_fru_state['trigger_prototypes']).each do |alarm|
  alarm['expression'] = "last(/#{TEMPLATE}/netapp.chassis.fru.state[{#CHASSISID},{#FRUID}])<>\"ok\""
  alarm['recovery_mode'] = 'RECOVERY_EXPRESSION'
  alarm['recovery_expression'] = "last(/#{TEMPLATE}/netapp.chassis.fru.state[{#CHASSISID},{#FRUID}])=\"ok\""
  alarm.delete('manual_close')
  alarm['priority'] = 'DISASTER'
  alarm['name'] = "#{PREFIX}: FRU/FONTE {#FRUTYPE} {#FRUID} do chassis {#CHASSISID} com falha"
  alarm['event_name'] = "#{PREFIX}: FRU/FONTE {#FRUTYPE} {#FRUID} do chassis {#CHASSISID} com falha | estado: {ITEM.LASTVALUE1}"
  alarm['opdata'] = 'Estado atual: {ITEM.LASTVALUE1}'
end

# Node health and resource prototypes.
node_prototypes = by_discovery_key['netapp.nodes.discovery']['item_prototypes']
node_match = "r.name === \"{#NODENAME}\""

node_prototypes << dependent_proto(
  name: '{#NODENAME}: CPU utilization',
  key: 'netapp.node.cpu.utilization[{#NODENAME}]',
  master: 'netapp.nodes.get',
  preprocessing: javascript(find_record_js(node_match, 'r.metric && r.metric.processor_utilization', 'null')),
  component: 'cpu', value_type: 'FLOAT', units: '%', extra_tags: { 'node' => '{#NODENAME}' },
  description: 'Utilização média do processador reportada pela métrica REST do nó (ONTAP 9.8+).',
  triggers: [proto_trigger(
    id: 'node-cpu-high',
    expression: "avg(/#{TEMPLATE}/netapp.node.cpu.utilization[{#NODENAME}],5m)>{$NETAPP.CPU.UTIL.CRIT}",
    recovery_expression: "avg(/#{TEMPLATE}/netapp.node.cpu.utilization[{#NODENAME}],5m)<{$NETAPP.CPU.UTIL.RECOVERY}",
    name: "#{PREFIX}: CPU alta no nó {#NODENAME}",
    event_name: "#{PREFIX}: CPU alta no nó {#NODENAME} | atual: {ITEM.LASTVALUE1}; limite: >{$NETAPP.CPU.UTIL.CRIT}%",
    opdata: 'CPU atual: {ITEM.LASTVALUE1}; limite crítico: {$NETAPP.CPU.UTIL.CRIT}%',
    priority: 'HIGH', scope: 'performance'
  )]
)
node_prototypes << dependent_proto(
  name: '{#NODENAME}: Installed memory',
  key: 'netapp.node.memory.size[{#NODENAME}]',
  master: 'netapp.nodes.get',
  preprocessing: javascript(find_record_js(node_match, 'r.controller && r.controller.memory_size', 'null')),
  component: 'memory', units: 'B', extra_tags: { 'node' => '{#NODENAME}' },
  description: 'Memória física disponível no nó. ONTAP não expõe utilização de memória por REST nem por SNMP.'
)
node_prototypes << dependent_proto(
  name: '{#NODENAME}: CPU count',
  key: 'netapp.node.cpu.count[{#NODENAME}]',
  master: 'netapp.nodes.get',
  preprocessing: javascript(find_record_js(node_match, 'r.controller && r.controller.cpu && r.controller.cpu.count', 'null')),
  component: 'cpu', extra_tags: { 'node' => '{#NODENAME}' }
)
node_prototypes << dependent_proto(
  name: '{#NODENAME}: Failed power supplies',
  key: 'netapp.node.power_supply.failed.count[{#NODENAME}]',
  master: 'netapp.nodes.get',
  preprocessing: javascript(find_record_js(node_match, 'r.controller && r.controller.failed_power_supply && r.controller.failed_power_supply.count', '0')),
  component: 'power', extra_tags: { 'node' => '{#NODENAME}' },
  description: 'Contagem direta de fontes com falha no controller (ONTAP 9.9+).',
  triggers: [proto_trigger(
    id: 'node-psu-failed',
    expression: "last(/#{TEMPLATE}/netapp.node.power_supply.failed.count[{#NODENAME}])>0",
    recovery_expression: "last(/#{TEMPLATE}/netapp.node.power_supply.failed.count[{#NODENAME}])=0",
    name: "#{PREFIX}: FONTE COM FALHA no nó {#NODENAME}",
    event_name: "#{PREFIX}: FONTE COM FALHA no nó {#NODENAME} | quantidade: {ITEM.LASTVALUE1}",
    opdata: 'Fontes com falha: {ITEM.LASTVALUE1}', priority: 'DISASTER',
    description: 'O ONTAP reportou uma ou mais fontes degradadas ou com falha.'
  )]
)
node_prototypes << dependent_proto(
  name: '{#NODENAME}: Failed power supplies message',
  key: 'netapp.node.power_supply.failed.message[{#NODENAME}]',
  master: 'netapp.nodes.get',
  preprocessing: javascript(find_record_js(node_match, 'r.controller && r.controller.failed_power_supply && r.controller.failed_power_supply.message && r.controller.failed_power_supply.message.message', '""')),
  component: 'power', value_type: 'TEXT', extra_tags: { 'node' => '{#NODENAME}' }
)
node_prototypes << dependent_proto(
  name: '{#NODENAME}: Failed fans',
  key: 'netapp.node.fan.failed.count[{#NODENAME}]',
  master: 'netapp.nodes.get',
  preprocessing: javascript(find_record_js(node_match, 'r.controller && r.controller.failed_fan && r.controller.failed_fan.count', '0')),
  component: 'fan', extra_tags: { 'node' => '{#NODENAME}' },
  triggers: [proto_trigger(
    id: 'node-fan-failed',
    expression: "last(/#{TEMPLATE}/netapp.node.fan.failed.count[{#NODENAME}])>0",
    recovery_expression: "last(/#{TEMPLATE}/netapp.node.fan.failed.count[{#NODENAME}])=0",
    name: "#{PREFIX}: Ventoinha com falha no nó {#NODENAME}",
    event_name: "#{PREFIX}: Ventoinha com falha no nó {#NODENAME} | quantidade: {ITEM.LASTVALUE1}",
    opdata: 'Ventoinhas com falha: {ITEM.LASTVALUE1}', priority: 'HIGH'
  )]
)
node_prototypes << dependent_proto(
  name: '{#NODENAME}: HA interconnect state',
  key: 'netapp.node.ha.interconnect.state[{#NODENAME}]',
  master: 'netapp.nodes.get',
  preprocessing: javascript(find_record_js(node_match, 'r.ha && r.ha.interconnect && r.ha.interconnect.state', '"unknown"')),
  component: 'ha', value_type: 'CHAR', extra_tags: { 'node' => '{#NODENAME}' }
)
node_prototypes << dependent_proto(
  name: '{#NODENAME}: NVRAM battery state',
  key: 'netapp.node.nvram.battery.state[{#NODENAME}]',
  master: 'netapp.nodes.get',
  preprocessing: javascript(find_record_js(node_match, 'r.nvram && r.nvram.battery_state', '"unknown"')),
  component: 'battery', value_type: 'CHAR', extra_tags: { 'node' => '{#NODENAME}' },
  triggers: [proto_trigger(
    id: 'node-nvram-battery',
    expression: "find(/#{TEMPLATE}/netapp.node.nvram.battery.state[{#NODENAME}],,\"regexp\",\"^(battery_fully_discharged|battery_not_present|battery_near_end_of_life|battery_at_end_of_life|battery_over_charged)$\")=1",
    recovery_expression: "find(/#{TEMPLATE}/netapp.node.nvram.battery.state[{#NODENAME}],,\"regexp\",\"^(battery_fully_discharged|battery_not_present|battery_near_end_of_life|battery_at_end_of_life|battery_over_charged)$\")=0",
    name: "#{PREFIX}: Bateria NVRAM anormal no nó {#NODENAME}", priority: 'HIGH'
  )]
)
node_prototypes << dependent_proto(
  name: '{#NODENAME}: Spares low',
  key: 'netapp.node.spares.low[{#NODENAME}]',
  master: 'netapp.nodes.get',
  preprocessing: javascript(find_record_js(node_match, 'r.is_spares_low === true ? 1 : 0', '0')),
  component: 'disk', extra_tags: { 'node' => '{#NODENAME}' },
  triggers: [proto_trigger(
    id: 'node-spares-low',
    expression: "last(/#{TEMPLATE}/netapp.node.spares.low[{#NODENAME}])=1",
    recovery_expression: "last(/#{TEMPLATE}/netapp.node.spares.low[{#NODENAME}])=0",
    name: "#{PREFIX}: Poucos discos spare no nó {#NODENAME}",
    event_name: "#{PREFIX}: Poucos discos spare no nó {#NODENAME} | indicador: {ITEM.LASTVALUE1}",
    opdata: 'Indicador is_spares_low: {ITEM.LASTVALUE1}', priority: 'HIGH'
  )]
)

# Disk inventory, endurance and explicit outage registry.
disk_prototypes = by_discovery_key['netapp.disks.discovery']['item_prototypes']
disk_match = "r.name === \"{#DISKNAME}\" && r.node && r.node.name === \"{#NODENAME}\""
[
  ['Model', 'model', 'r.model', 'CHAR', nil],
  ['Serial number', 'serial', 'r.serial_number', 'CHAR', nil],
  ['Firmware', 'firmware', 'r.firmware_version', 'CHAR', nil],
  ['Container type', 'container', 'r.container_type', 'CHAR', nil],
  ['Usable size', 'usable_size', 'r.usable_size', nil, 'B'],
  ['Physical size', 'physical_size', 'r.physical_size', nil, 'B'],
  ['Rated life used', 'rated_life_used', 'r.rated_life_used_percent', nil, '%']
].each do |label, suffix, expression, value_type, units|
  disk_prototypes << dependent_proto(
    name: "{#DISKNAME}: #{label}", key: "netapp.disk.#{suffix}[{#NODENAME},{#DISKNAME}]",
    master: 'netapp.disks.get', preprocessing: javascript(find_record_js(disk_match, expression, 'null')),
    component: 'disk', value_type: value_type, units: units,
    extra_tags: { 'disk' => '{#DISKNAME}', 'node' => '{#NODENAME}' },
    triggers: suffix == 'rated_life_used' ? [proto_trigger(
      id: 'disk-endurance',
      expression: "last(/#{TEMPLATE}/netapp.disk.rated_life_used[{#NODENAME},{#DISKNAME}])>{$NETAPP.DISK.LIFE.USED.CRIT}",
      recovery_expression: "last(/#{TEMPLATE}/netapp.disk.rated_life_used[{#NODENAME},{#DISKNAME}])<{$NETAPP.DISK.LIFE.USED.RECOVERY}",
      name: "#{PREFIX}: Vida útil alta no disco {#DISKNAME} ({#NODENAME})",
      event_name: "#{PREFIX}: Disco {#DISKNAME} ({#NODENAME}) com vida útil alta | usado: {ITEM.LASTVALUE1}; limite: >{$NETAPP.DISK.LIFE.USED.CRIT}%",
      opdata: 'Vida útil usada: {ITEM.LASTVALUE1}; limite: {$NETAPP.DISK.LIFE.USED.CRIT}%', priority: 'HIGH'
    )] : nil
  )
end
disk_prototypes << dependent_proto(
  name: '{#DISKNAME}: Persistently failed',
  key: 'netapp.disk.outage.persistently_failed[{#NODENAME},{#DISKNAME}]',
  master: 'netapp.disks.get',
  preprocessing: javascript(find_record_js(disk_match, 'r.outage && r.outage.persistently_failed === true ? 1 : 0', '0')),
  component: 'disk', extra_tags: { 'disk' => '{#DISKNAME}', 'node' => '{#NODENAME}' },
  triggers: [proto_trigger(
    id: 'disk-persistent-failure',
    expression: "last(/#{TEMPLATE}/netapp.disk.outage.persistently_failed[{#NODENAME},{#DISKNAME}])=1",
    recovery_expression: "last(/#{TEMPLATE}/netapp.disk.outage.persistently_failed[{#NODENAME},{#DISKNAME}])=0",
    name: "#{PREFIX}: Disco {#DISKNAME} registrado como persistentemente falho",
    event_name: "#{PREFIX}: Disco {#DISKNAME} ({#NODENAME}) com falha persistente | indicador: {ITEM.LASTVALUE1}",
    opdata: 'Falha persistente: {ITEM.LASTVALUE1}', priority: 'DISASTER'
  )]
)

# Ethernet performance and errors.
eth_rule = by_discovery_key['netapp.ports.ether.discovery']
eth_prototypes = eth_rule['item_prototypes']
eth_filter = "@.name=='{#ETHPORTNAME}'&&@.node.name=='{#NODENAME}'"
eth_path = ->(tail) { "$.records[?(#{eth_filter})].#{tail}.first()" }
eth_alarm_control = '{$NETAPP.ETH.PORT.ALARM:"{#NODENAME}/{#ETHPORTNAME}"}'
eth_capacity_helpers_js = <<~JS
  var data = JSON.parse(value);
  var records = data.records || [];
  var targetNode = '{#NODENAME}';
  var targetName = '{#ETHPORTNAME}';

  function recordNodeName(record) {
    return record && record.node && record.node.name ? String(record.node.name) : '';
  }

  function findPort(reference, defaultNode) {
    if (!reference || !reference.name) return null;
    var name = String(reference.name);
    var node = reference.node && reference.node.name ? String(reference.node.name) : defaultNode;
    for (var i = 0; i < records.length; i++) {
      if (String(records[i].name || '') === name && recordNodeName(records[i]) === node) return records[i];
    }
    return null;
  }

  function capacity(port, visited) {
    if (!port) return 0;
    var identifier = recordNodeName(port) + '/' + String(port.name || '');
    if (visited[identifier]) return 0;
    visited[identifier] = true;

    var directSpeed = Number(port.speed || 0);
    if (directSpeed > 0) return directSpeed;

    if (port.type === 'lag' && port.lag) {
      var activePorts = port.lag.active_ports || [];
      var total = 0;
      for (var activeIndex = 0; activeIndex < activePorts.length; activeIndex++) {
        total += capacity(findPort(activePorts[activeIndex], recordNodeName(port)), visited);
      }
      return total;
    }

    if (port.type === 'vlan' && port.vlan && port.vlan.base_port) {
      return capacity(findPort(port.vlan.base_port, recordNodeName(port)), visited);
    }

    return 0;
  }

JS
eth_effective_speed_js = eth_capacity_helpers_js + <<~JS
  var target = findPort({name: targetName, node: {name: targetNode}}, targetNode);
  return capacity(target, {});
JS
eth_utilization_js = lambda do |direction|
  eth_capacity_helpers_js + <<~JS
    var target = findPort({name: targetName, node: {name: targetNode}}, targetNode);
    var effectiveCapacity = capacity(target, {});
    if (!target || effectiveCapacity <= 0) return 0;
    var throughput = Number(target.metric && target.metric.throughput ? target.metric.throughput.#{direction} || 0 : 0);
    var percent = 100 * throughput / (effectiveCapacity * 125000);
    if (!isFinite(percent) || percent <= 0) return 0;
    return percent > 100 ? 100 : percent;
  JS
end

eth_prototypes << dependent_proto(
  name: '{#NODENAME} {#ETHPORTNAME}: Enabled',
  key: 'netapp.port.eth.enabled[{#NODENAME},{#ETHPORTNAME}]', master: 'netapp.ports.eth.get',
  preprocessing: jsonpath(eth_path.call('enabled')) + javascript("return (value === 'true' || value === '1') ? 1 : 0;"),
  component: 'interfaces', extra_tags: { 'interface' => '{#ETHPORTNAME}', 'node' => '{#NODENAME}' }
)
eth_prototypes << dependent_proto(
  name: '{#NODENAME} {#ETHPORTNAME}: Effective speed',
  key: 'netapp.port.eth.speed[{#NODENAME},{#ETHPORTNAME}]', master: 'netapp.ports.eth.get',
  preprocessing: javascript(eth_effective_speed_js), component: 'interfaces', units: 'Mbps',
  description: 'Effective capacity in Mbps. Physical ports use speed; LAGs sum active member speeds; VLANs inherit their base-port capacity. Zero means that ONTAP did not provide enough capacity data.',
  extra_tags: { 'interface' => '{#ETHPORTNAME}', 'node' => '{#NODENAME}' }
)
eth_prototypes << dependent_proto(
  name: '{#NODENAME} {#ETHPORTNAME}: Reachability',
  key: 'netapp.port.eth.reachability[{#NODENAME},{#ETHPORTNAME}]', master: 'netapp.ports.eth.get',
  preprocessing: jsonpath(eth_path.call('reachability')), component: 'interfaces', value_type: 'CHAR',
  description: 'Diagnóstico de correspondência entre a topologia Layer 2 detectada e o broadcast domain configurado. Não representa diretamente o estado do link.',
  extra_tags: { 'interface' => '{#ETHPORTNAME}', 'node' => '{#NODENAME}' },
  triggers: [proto_trigger(
    id: 'ethernet-layer2-topology',
    expression: "last(/#{TEMPLATE}/netapp.port.eth.reachability[{#NODENAME},{#ETHPORTNAME}])<>\"ok\" and last(/#{TEMPLATE}/netapp.port.eth.state[{#NODENAME},{#ETHPORTNAME}])=\"up\" and last(/#{TEMPLATE}/netapp.port.eth.enabled[{#NODENAME},{#ETHPORTNAME}])=1 and #{eth_alarm_control}=1",
    recovery_expression: "last(/#{TEMPLATE}/netapp.port.eth.reachability[{#NODENAME},{#ETHPORTNAME}])=\"ok\" or last(/#{TEMPLATE}/netapp.port.eth.state[{#NODENAME},{#ETHPORTNAME}])<>\"up\" or last(/#{TEMPLATE}/netapp.port.eth.enabled[{#NODENAME},{#ETHPORTNAME}])=0 or #{eth_alarm_control}=0",
    name: "#{PREFIX}: Inconsistência de topologia L2 na porta {#NODENAME}/{#ETHPORTNAME}",
    event_name: "#{PREFIX}: Inconsistência de topologia L2 na porta {#NODENAME}/{#ETHPORTNAME} | esperado: {#ETHBROADCASTDOMAIN}; alcançável: {#ETHREACHABLEDOMAINS}; diagnóstico: {ITEM.VALUE1}",
    opdata: 'Diagnóstico REST: {ITEM.LASTVALUE1}; esperado: {#ETHBROADCASTDOMAIN}; alcançável: {#ETHREACHABLEDOMAINS}',
    description: 'A porta está operacional, mas a topologia Layer 2 detectada não corresponde ao broadcast domain configurado. Verifique VLAN nativa/PVID, trunk e broadcast domains; não execute reachability repair sem validar o desenho.',
    priority: 'WARNING', scope: 'configuration'
  )]
)
%w[read write total].each do |direction|
  eth_prototypes << dependent_proto(
    name: "{#NODENAME} {#ETHPORTNAME}: Throughput #{direction}",
    key: "netapp.port.eth.throughput.#{direction}[{#NODENAME},{#ETHPORTNAME}]",
    master: 'netapp.ports.eth.get', preprocessing: jsonpath(eth_path.call("metric.throughput.#{direction}")),
    component: 'network', value_type: 'FLOAT', units: 'Bps',
    extra_tags: { 'interface' => '{#ETHPORTNAME}', 'node' => '{#NODENAME}' }
  )
end
%w[read write].each do |direction|
  rate_key = "netapp.port.eth.utilization.#{direction}[{#NODENAME},{#ETHPORTNAME}]"
  eth_prototypes << dependent_proto(
    name: "{#NODENAME} {#ETHPORTNAME}: Utilization #{direction}", key: rate_key,
    master: 'netapp.ports.eth.get', preprocessing: javascript(eth_utilization_js.call(direction)),
    component: 'network', value_type: 'FLOAT', units: '%',
    description: 'Current directional utilization calculated from ONTAP throughput and effective port/LAG/VLAN capacity. Values are constrained to 0..100%.',
    extra_tags: { 'interface' => '{#ETHPORTNAME}', 'node' => '{#NODENAME}' },
    triggers: direction == 'read' ? [proto_trigger(
      id: 'ethernet-utilization-high',
      expression: "(min(/#{TEMPLATE}/netapp.port.eth.utilization.read[{#NODENAME},{#ETHPORTNAME}],5m)>{$NETAPP.PORT.UTIL.CRIT} or min(/#{TEMPLATE}/netapp.port.eth.utilization.write[{#NODENAME},{#ETHPORTNAME}],5m)>{$NETAPP.PORT.UTIL.CRIT}) and last(/#{TEMPLATE}/netapp.port.eth.speed[{#NODENAME},{#ETHPORTNAME}])>0 and last(/#{TEMPLATE}/netapp.port.eth.enabled[{#NODENAME},{#ETHPORTNAME}])=1 and #{eth_alarm_control}=1",
      recovery_expression: "(last(/#{TEMPLATE}/netapp.port.eth.utilization.read[{#NODENAME},{#ETHPORTNAME}])<{$NETAPP.PORT.UTIL.RECOVERY} and last(/#{TEMPLATE}/netapp.port.eth.utilization.write[{#NODENAME},{#ETHPORTNAME}])<{$NETAPP.PORT.UTIL.RECOVERY}) or last(/#{TEMPLATE}/netapp.port.eth.speed[{#NODENAME},{#ETHPORTNAME}])=0 or last(/#{TEMPLATE}/netapp.port.eth.enabled[{#NODENAME},{#ETHPORTNAME}])=0 or #{eth_alarm_control}=0",
      name: "#{PREFIX}: Porta {#NODENAME}/{#ETHPORTNAME} com alta utilização",
      event_name: "#{PREFIX}: Porta {#NODENAME}/{#ETHPORTNAME} com alta utilização | RX: {ITEM.LASTVALUE1}; TX: {ITEM.LASTVALUE2}; capacidade: {ITEM.LASTVALUE3}; limite: >{$NETAPP.PORT.UTIL.CRIT}%",
      opdata: 'RX: {ITEM.LASTVALUE1}; TX: {ITEM.LASTVALUE2}; capacidade: {ITEM.LASTVALUE3}; limite: {$NETAPP.PORT.UTIL.CRIT}%',
      priority: 'AVERAGE', scope: 'performance'
    )] : nil
  )
end
{
  'rx.errors' => 'statistics.device.receive_raw.errors',
  'tx.errors' => 'statistics.device.transmit_raw.errors',
  'rx.discards' => 'statistics.device.receive_raw.discards',
  'tx.discards' => 'statistics.device.transmit_raw.discards'
}.each do |suffix, path|
  eth_prototypes << dependent_proto(
    name: "{#NODENAME} {#ETHPORTNAME}: #{suffix} rate",
    key: "netapp.port.eth.#{suffix}.rate[{#NODENAME},{#ETHPORTNAME}]", master: 'netapp.ports.eth.get',
    preprocessing: jsonpath(eth_path.call(path)) + [{ 'type' => 'CHANGE_PER_SECOND' }],
    component: 'network', value_type: 'FLOAT', units: 'pps',
    extra_tags: { 'interface' => '{#ETHPORTNAME}', 'node' => '{#NODENAME}' }
  )
end
eth_prototypes << dependent_proto(
  name: '{#NODENAME} {#ETHPORTNAME}: Link down events',
  key: 'netapp.port.eth.link_down.delta[{#NODENAME},{#ETHPORTNAME}]', master: 'netapp.ports.eth.get',
  preprocessing: jsonpath(eth_path.call('statistics.device.link_down_count_raw')) + [{ 'type' => 'SIMPLE_CHANGE' }],
  component: 'network', extra_tags: { 'interface' => '{#ETHPORTNAME}', 'node' => '{#NODENAME}' },
  triggers: [proto_trigger(
    id: 'ethernet-link-flap',
    expression: "last(/#{TEMPLATE}/netapp.port.eth.link_down.delta[{#NODENAME},{#ETHPORTNAME}])>0 and last(/#{TEMPLATE}/netapp.port.eth.enabled[{#NODENAME},{#ETHPORTNAME}])=1 and #{eth_alarm_control}=1",
    name: "#{PREFIX}: Porta {#NODENAME}/{#ETHPORTNAME} perdeu link", priority: 'WARNING'
  )]
)

# Make the upstream Ethernet state alarm depend on administrative enablement.
eth_state = eth_prototypes.find { |p| p['key'].start_with?('netapp.port.eth.state[') }
eth_state['trigger_prototypes'] = [proto_trigger(
  id: 'ethernet-down',
  expression: "last(/#{TEMPLATE}/netapp.port.eth.state[{#NODENAME},{#ETHPORTNAME}])<>\"up\" and last(/#{TEMPLATE}/netapp.port.eth.enabled[{#NODENAME},{#ETHPORTNAME}])=1 and #{eth_alarm_control}=1",
  recovery_expression: "last(/#{TEMPLATE}/netapp.port.eth.state[{#NODENAME},{#ETHPORTNAME}])=\"up\" or last(/#{TEMPLATE}/netapp.port.eth.enabled[{#NODENAME},{#ETHPORTNAME}])=0 or #{eth_alarm_control}=0",
  name: "#{PREFIX}: Porta Ethernet {#NODENAME}/{#ETHPORTNAME} está inativa", priority: 'HIGH'
)]

# FC enabled state and direct REST metrics.
fc_rule = by_discovery_key['netapp.ports.fc.discovery']
fc_prototypes = fc_rule['item_prototypes']
fc_filter = "@.name=='{#FCPORTNAME}'&&@.node.name=='{#NODENAME}'"
fc_path = ->(tail) { "$.records[?(#{fc_filter})].#{tail}.first()" }
fc_prototypes << dependent_proto(
  name: '{#NODENAME} {#FCPORTNAME}: Enabled',
  key: 'netapp.port.fc.enabled[{#NODENAME},{#FCPORTNAME}]', master: 'netapp.ports.fc.get',
  preprocessing: jsonpath(fc_path.call('enabled')) + javascript("return (value === 'true' || value === '1') ? 1 : 0;"),
  component: 'interfaces', extra_tags: { 'interface' => '{#FCPORTNAME}', 'node' => '{#NODENAME}' }
)
%w[read write total].each do |direction|
  fc_prototypes << dependent_proto(
    name: "{#NODENAME} {#FCPORTNAME}: Throughput #{direction}",
    key: "netapp.port.fc.throughput.#{direction}[{#NODENAME},{#FCPORTNAME}]", master: 'netapp.ports.fc.get',
    preprocessing: jsonpath(fc_path.call("metric.throughput.#{direction}")), component: 'network',
    value_type: 'FLOAT', units: 'Bps', extra_tags: { 'interface' => '{#FCPORTNAME}', 'node' => '{#NODENAME}' }
  )
end
fc_state = fc_prototypes.find { |p| p['key'].start_with?('netapp.port.fc.state[') }
fc_state['trigger_prototypes'] = [proto_trigger(
  id: 'fc-down',
  expression: "last(/#{TEMPLATE}/netapp.port.fc.state[{#NODENAME},{#FCPORTNAME}])<>\"online\" and last(/#{TEMPLATE}/netapp.port.fc.enabled[{#NODENAME},{#FCPORTNAME}])=1",
  recovery_expression: "last(/#{TEMPLATE}/netapp.port.fc.state[{#NODENAME},{#FCPORTNAME}])=\"online\" or last(/#{TEMPLATE}/netapp.port.fc.enabled[{#NODENAME},{#FCPORTNAME}])=0",
  name: "#{PREFIX}: Porta FC {#NODENAME}/{#FCPORTNAME} não está online", priority: 'HIGH'
)]

# Volume and LUN utilization calculated from their existing dependent items.
volume_rule = by_discovery_key['netapp.volumes.discovery']
volume_formula = '100 * last(//netapp.volume.space_used[{#VOLUMENAME}]) / (last(//netapp.volume.space_size[{#VOLUMENAME}]) + (last(//netapp.volume.space_size[{#VOLUMENAME}])=0))'
volume_rule['item_prototypes'] << calculated_proto(
  name: '{#VOLUMENAME}: Used percentage', key: 'netapp.volume.space_used.percent[{#VOLUMENAME}]',
  formula: volume_formula, component: 'volume', units: '%', extra_tags: { 'volume' => '{#VOLUMENAME}' },
  triggers: [
    proto_trigger(
      id: 'volume-capacity-critical',
      expression: "last(/#{TEMPLATE}/netapp.volume.space_used.percent[{#VOLUMENAME}])>={$NETAPP.VOLUME.USED.CRIT}",
      recovery_expression: "last(/#{TEMPLATE}/netapp.volume.space_used.percent[{#VOLUMENAME}])<{$NETAPP.VOLUME.USED.RECOVERY}",
      name: "#{PREFIX}: Volume {#VOLUMENAME} crítico de espaço",
      event_name: "#{PREFIX}: Volume {#VOLUMENAME} crítico de espaço | usado: {ITEM.LASTVALUE1}; limite: >={$NETAPP.VOLUME.USED.CRIT}%",
      opdata: 'Espaço usado: {ITEM.LASTVALUE1}; limite crítico: {$NETAPP.VOLUME.USED.CRIT}%',
      priority: 'HIGH', scope: 'capacity'
    ),
    proto_trigger(
      id: 'volume-capacity-warning',
      expression: "last(/#{TEMPLATE}/netapp.volume.space_used.percent[{#VOLUMENAME}])>={$NETAPP.VOLUME.USED.WARN} and last(/#{TEMPLATE}/netapp.volume.space_used.percent[{#VOLUMENAME}])<{$NETAPP.VOLUME.USED.CRIT}",
      recovery_expression: "last(/#{TEMPLATE}/netapp.volume.space_used.percent[{#VOLUMENAME}])<{$NETAPP.VOLUME.USED.RECOVERY}",
      name: "#{PREFIX}: Volume {#VOLUMENAME} com pouco espaço",
      event_name: "#{PREFIX}: Volume {#VOLUMENAME} com pouco espaço | usado: {ITEM.LASTVALUE1}; alerta: >={$NETAPP.VOLUME.USED.WARN}%",
      opdata: 'Espaço usado: {ITEM.LASTVALUE1}; limite de alerta: {$NETAPP.VOLUME.USED.WARN}%',
      priority: 'AVERAGE', scope: 'capacity'
    )
  ]
)
volume_rule['item_prototypes'] << dependent_proto(
  name: '{#VOLUMENAME}: Quota state', key: 'netapp.volume.quota.state[{#VOLUMEUUID}]',
  master: 'netapp.volumes.get',
  preprocessing: jsonpath("$.records[?(@.uuid=='{#VOLUMEUUID}')].quota.state.first()"),
  component: 'quota', value_type: 'CHAR',
  description: 'Estado da aplicação de quotas no volume. Coleta informativa, sem alarme quando quotas ainda não estiverem habilitadas.',
  extra_tags: { 'volume' => '{#VOLUMENAME}', 'svm' => '{#SVMNAME}' }
)
lun_rule = by_discovery_key['netapp.luns.discovery']
lun_formula = '100 * last(//netapp.lun.space.used[{#SVMNAME},{#LUNNAME}]) / (last(//netapp.lun.space.size[{#SVMNAME},{#LUNNAME}]) + (last(//netapp.lun.space.size[{#SVMNAME},{#LUNNAME}])=0))'
lun_rule['item_prototypes'] << calculated_proto(
  name: '{#LUNNAME}: Used percentage', key: 'netapp.lun.space.used.percent[{#SVMNAME},{#LUNNAME}]',
  formula: lun_formula, component: 'lun', units: '%', extra_tags: { 'lun' => '{#LUNNAME}', 'svm' => '{#SVMNAME}' }
)

# Aggregate collection and LLD.
aggregates_raw = http_item(
  name: 'Get aggregates', key: 'netapp.aggregates.get', delay: '1m',
  url: '{$NETAPP.URL}/api/storage/aggregates?fields=name,uuid,node.name,state,block_storage.primary.disk_count,space.block_storage.size,space.block_storage.used,space.block_storage.available,space.block_storage.physical_used,space.block_storage.physical_used_percent,metric.*&max_records={$NETAPP.API.MAX.RECORDS}'
)
items << aggregates_raw

aggregate_prototypes = []
aggr_filter = "@.uuid=='{#AGGRUUID}'"
aggr_path = ->(tail) { "$.records[?(#{aggr_filter})].#{tail}.first()" }
aggregate_prototypes << dependent_proto(
  name: '{#AGGRNAME}: State', key: 'netapp.aggregate.state[{#AGGRUUID}]', master: 'netapp.aggregates.get',
  preprocessing: jsonpath(aggr_path.call('state')), component: 'aggregate', value_type: 'CHAR',
  extra_tags: { 'aggregate' => '{#AGGRNAME}', 'node' => '{#NODENAME}' },
  triggers: [proto_trigger(
    id: 'aggregate-state', expression: "last(/#{TEMPLATE}/netapp.aggregate.state[{#AGGRUUID}])<>\"online\"",
    recovery_expression: "last(/#{TEMPLATE}/netapp.aggregate.state[{#AGGRUUID}])=\"online\"",
    name: "#{PREFIX}: Agregado {#AGGRNAME} não está online",
    event_name: "#{PREFIX}: Agregado {#AGGRNAME} não está online | estado: {ITEM.LASTVALUE1}",
    opdata: 'Estado atual: {ITEM.LASTVALUE1}', priority: 'HIGH'
  )]
)
{
  'size' => ['Total size', 'space.block_storage.size', 'Capacidade física utilizável do agregado.'],
  'used' => ['Used or reserved size', 'space.block_storage.used', 'Espaço usado ou reservado. Inclui garantias de volumes e metadados; não representa sozinho o consumo físico.'],
  'available' => ['Uncommitted available size', 'space.block_storage.available', 'Espaço físico ainda não utilizado nem reservado para volumes existentes.']
}.each do |suffix, (label, path, description)|
  aggregate_prototypes << dependent_proto(
    name: "{#AGGRNAME}: #{label}", key: "netapp.aggregate.space.#{suffix}[{#AGGRUUID}]",
    master: 'netapp.aggregates.get', preprocessing: jsonpath(aggr_path.call(path)), component: 'aggregate', units: 'B',
    description: description,
    extra_tags: { 'aggregate' => '{#AGGRNAME}', 'node' => '{#NODENAME}' }
  )
end
aggregate_prototypes << calculated_proto(
  name: '{#AGGRNAME}: Committed percentage (used or reserved)', key: 'netapp.aggregate.space.used.percent[{#AGGRUUID}]',
  formula: '100 * last(//netapp.aggregate.space.used[{#AGGRUUID}]) / (last(//netapp.aggregate.space.size[{#AGGRUUID}]) + (last(//netapp.aggregate.space.size[{#AGGRUUID}])=0))',
  component: 'aggregate', units: '%',
  description: 'Percentual comprometido por uso físico ou reservas. Mantido para histórico e planejamento, sem trigger, pois volumes thick podem elevá-lo mesmo com muitos blocos físicos livres.',
  extra_tags: { 'aggregate' => '{#AGGRNAME}', 'node' => '{#NODENAME}' }
)
aggregate_prototypes << dependent_proto(
  name: '{#AGGRNAME}: Disk count', key: 'netapp.aggregate.disk.count[{#AGGRUUID}]', master: 'netapp.aggregates.get',
  preprocessing: jsonpath(aggr_path.call('block_storage.primary.disk_count')), component: 'disk',
  extra_tags: { 'aggregate' => '{#AGGRNAME}', 'node' => '{#NODENAME}' }
)
%w[read write total].each do |direction|
  aggregate_prototypes << dependent_proto(
    name: "{#AGGRNAME}: IOPS #{direction}", key: "netapp.aggregate.iops.#{direction}[{#AGGRUUID}]",
    master: 'netapp.aggregates.get', preprocessing: jsonpath(aggr_path.call("metric.iops.#{direction}")),
    component: 'iops', value_type: 'FLOAT', units: '!iops', extra_tags: { 'aggregate' => '{#AGGRNAME}' }
  )
  aggregate_prototypes << dependent_proto(
    name: "{#AGGRNAME}: Throughput #{direction}", key: "netapp.aggregate.throughput.#{direction}[{#AGGRUUID}]",
    master: 'netapp.aggregates.get', preprocessing: jsonpath(aggr_path.call("metric.throughput.#{direction}")),
    component: 'throughput', value_type: 'FLOAT', units: 'Bps', extra_tags: { 'aggregate' => '{#AGGRNAME}' }
  )
  aggregate_prototypes << dependent_proto(
    name: "{#AGGRNAME}: Latency #{direction}", key: "netapp.aggregate.latency.#{direction}[{#AGGRUUID}]",
    master: 'netapp.aggregates.get', preprocessing: jsonpath(aggr_path.call("metric.latency.#{direction}")) + [{ 'type' => 'MULTIPLIER', 'parameters' => ['0.001'] }],
    component: 'latency', value_type: 'FLOAT', units: '!ms', extra_tags: { 'aggregate' => '{#AGGRNAME}' }
  )
end

# Append the new capacity items after the original prototype sequence so UUIDs
# of existing prototypes remain stable when an earlier template is reimported.
aggregate_prototypes << dependent_proto(
  name: '{#AGGRNAME}: Physical used size', key: 'netapp.aggregate.space.physical.used[{#AGGRUUID}]',
  master: 'netapp.aggregates.get', preprocessing: jsonpath(aggr_path.call('space.block_storage.physical_used')),
  component: 'aggregate', units: 'B',
  description: 'Blocos físicos realmente ocupados no agregado.',
  extra_tags: { 'aggregate' => '{#AGGRNAME}', 'node' => '{#NODENAME}' }
)
aggregate_prototypes << calculated_proto(
  name: '{#AGGRNAME}: Reserved size', key: 'netapp.aggregate.space.reserved[{#AGGRUUID}]',
  formula: 'last(//netapp.aggregate.space.used[{#AGGRUUID}])-last(//netapp.aggregate.space.physical.used[{#AGGRUUID}])',
  component: 'aggregate', units: 'B',
  description: 'Estimativa da parcela reservada para volumes já provisionados: usado-ou-reservado menos uso físico.',
  extra_tags: { 'aggregate' => '{#AGGRNAME}', 'node' => '{#NODENAME}' }
)
aggregate_prototypes << dependent_proto(
  name: '{#AGGRNAME}: Physical used percentage', key: 'netapp.aggregate.space.physical.used.percent[{#AGGRUUID}]',
  master: 'netapp.aggregates.get', preprocessing: jsonpath(aggr_path.call('space.block_storage.physical_used_percent')),
  component: 'aggregate', value_type: 'FLOAT', units: '%',
  description: 'Percentual dos blocos físicos realmente ocupados. Esta é a métrica usada pelos alarmes de capacidade do agregado.',
  extra_tags: { 'aggregate' => '{#AGGRNAME}', 'node' => '{#NODENAME}' },
  triggers: [
    proto_trigger(
      id: 'aggregate-physical-capacity-critical',
      expression: "last(/#{TEMPLATE}/netapp.aggregate.space.physical.used.percent[{#AGGRUUID}])>={$NETAPP.AGGREGATE.USED.CRIT}",
      recovery_expression: "last(/#{TEMPLATE}/netapp.aggregate.space.physical.used.percent[{#AGGRUUID}])<{$NETAPP.AGGREGATE.USED.RECOVERY}",
      name: "#{PREFIX}: Agregado {#AGGRNAME} com uso físico crítico",
      event_name: "#{PREFIX}: Agregado {#AGGRNAME} com uso físico crítico | ocupado: {ITEM.VALUE1}; limite: >={$NETAPP.AGGREGATE.USED.CRIT}%",
      opdata: 'Uso físico atual: {ITEM.LASTVALUE1}; limite crítico: {$NETAPP.AGGREGATE.USED.CRIT}%',
      priority: 'HIGH', scope: 'capacity'
    ),
    proto_trigger(
      id: 'aggregate-physical-capacity-warning',
      expression: "last(/#{TEMPLATE}/netapp.aggregate.space.physical.used.percent[{#AGGRUUID}])>={$NETAPP.AGGREGATE.USED.WARN} and last(/#{TEMPLATE}/netapp.aggregate.space.physical.used.percent[{#AGGRUUID}])<{$NETAPP.AGGREGATE.USED.CRIT}",
      recovery_expression: "last(/#{TEMPLATE}/netapp.aggregate.space.physical.used.percent[{#AGGRUUID}])<{$NETAPP.AGGREGATE.USED.RECOVERY}",
      name: "#{PREFIX}: Agregado {#AGGRNAME} com uso físico elevado",
      event_name: "#{PREFIX}: Agregado {#AGGRNAME} com uso físico elevado | ocupado: {ITEM.VALUE1}; alerta: >={$NETAPP.AGGREGATE.USED.WARN}%",
      opdata: 'Uso físico atual: {ITEM.LASTVALUE1}; limite de alerta: {$NETAPP.AGGREGATE.USED.WARN}%',
      priority: 'AVERAGE', scope: 'capacity'
    )
  ]
)
discoveries << dependent_discovery(
  name: 'Aggregates discovery', key: 'netapp.aggregates.discovery', master: 'netapp.aggregates.get',
  preprocessing: javascript(lld_from_records_js(
    '{#AGGRNAME}' => 'r.name', '{#AGGRUUID}' => 'r.uuid', '{#NODENAME}' => '(r.node ? r.node.name : "")'
  )), prototypes: aggregate_prototypes
)

# Shelves and flattened hardware components.
shelves_raw = http_item(
  name: 'Get shelves and environmental sensors', key: 'netapp.shelves.get', delay: '5m',
  url: '{$NETAPP.URL}/api/storage/shelves?fields=uid,name,id,state,model,serial_number,disk_count,errors,frus,fans,current_sensors,temperature_sensors,voltage_sensors&max_records={$NETAPP.API.MAX.RECORDS}',
  timeout: '{$NETAPP.SHELF.TIMEOUT}'
)
items << shelves_raw

flatteners = {
  'netapp.shelf.frus.json' => <<~JS,
    var data = JSON.parse(value), out = [];
    var shelves = data.records || [];
    for (var i = 0; i < shelves.length; i++) {
      var s = shelves[i], list = s.frus || [];
      for (var j = 0; j < list.length; j++) {
        var f = list[j];
        out.push({shelf_uid:String(s.uid),shelf_name:s.name || s.id || String(s.uid),id:String(f.id !== undefined ? f.id : ((f.type || 'fru') + '-' + j)),type:f.type || 'unknown',state:f.state || 'unknown',installed:(f.installed === false || f.installed === 0) ? 0 : 1,serial_number:f.serial_number || ''});
      }
    }
    return JSON.stringify({records:out});
  JS
  'netapp.shelf.fans.json' => <<~JS,
    var data = JSON.parse(value), out = [];
    var shelves = data.records || [];
    for (var i = 0; i < shelves.length; i++) {
      var s = shelves[i], list = s.fans || [];
      for (var j = 0; j < list.length; j++) {
        var f = list[j];
        out.push({shelf_uid:String(s.uid),shelf_name:s.name || s.id || String(s.uid),id:String(f.id),location:f.location || '',state:f.state || 'unknown',rpm:f.rpm || 0});
      }
    }
    return JSON.stringify({records:out});
  JS
  'netapp.shelf.temperature.json' => <<~JS,
    var data = JSON.parse(value), out = [];
    var shelves = data.records || [];
    for (var i = 0; i < shelves.length; i++) {
      var s = shelves[i], list = s.temperature_sensors || [];
      for (var j = 0; j < list.length; j++) {
        var x = list[j], th = x.threshold || {}, high = th.high || {}, low = th.low || {};
        out.push({shelf_uid:String(s.uid),shelf_name:s.name || s.id || String(s.uid),id:String(x.id),location:x.location || '',state:x.state || 'unknown',temperature:x.temperature,high_warning:high.warning || 0,high_critical:high.critical || 0,low_warning:low.warning || 0,low_critical:low.critical || 0});
      }
    }
    return JSON.stringify({records:out});
  JS
  'netapp.shelf.voltage.json' => <<~JS,
    var data = JSON.parse(value), out = [];
    var shelves = data.records || [];
    for (var i = 0; i < shelves.length; i++) {
      var s = shelves[i], list = s.voltage_sensors || [];
      for (var j = 0; j < list.length; j++) {
        var x = list[j];
        out.push({shelf_uid:String(s.uid),shelf_name:s.name || s.id || String(s.uid),id:String(x.id),location:x.location || '',state:x.state || 'unknown',voltage:x.voltage});
      }
    }
    return JSON.stringify({records:out});
  JS
  'netapp.shelf.current.json' => <<~JS
    var data = JSON.parse(value), out = [];
    var shelves = data.records || [];
    for (var i = 0; i < shelves.length; i++) {
      var s = shelves[i], list = s.current_sensors || [];
      for (var j = 0; j < list.length; j++) {
        var x = list[j];
        out.push({shelf_uid:String(s.uid),shelf_name:s.name || s.id || String(s.uid),id:String(x.id),location:x.location || '',state:x.state || 'unknown',current:x.current});
      }
    }
    return JSON.stringify({records:out});
  JS
}
flatteners.each do |key, script|
  items << dependent_item(
    name: "Flattened #{key}", key: key, master: 'netapp.shelves.get', preprocessing: javascript(script),
    component: 'raw', value_type: 'TEXT'
  )
end

shelf_prototypes = []
shelf_path = ->(tail) { "$.records[?(@.uid=='{#SHELFUID}')].#{tail}.first()" }
shelf_prototypes << dependent_proto(
  name: 'Shelf {#SHELFNAME}: State', key: 'netapp.shelf.state[{#SHELFUID}]', master: 'netapp.shelves.get',
  preprocessing: jsonpath(shelf_path.call('state')), component: 'shelf', value_type: 'CHAR',
  extra_tags: { 'shelf' => '{#SHELFNAME}' },
  triggers: [proto_trigger(
    id: 'shelf-state', expression: "last(/#{TEMPLATE}/netapp.shelf.state[{#SHELFUID}])<>\"ok\"",
    recovery_expression: "last(/#{TEMPLATE}/netapp.shelf.state[{#SHELFUID}])=\"ok\"",
    name: "#{PREFIX}: Shelf {#SHELFNAME} em estado anormal",
    event_name: "#{PREFIX}: Shelf {#SHELFNAME} em estado anormal | estado: {ITEM.LASTVALUE1}",
    opdata: 'Estado atual: {ITEM.LASTVALUE1}', priority: 'HIGH'
  )]
)
shelf_prototypes << dependent_proto(
  name: 'Shelf {#SHELFNAME}: Disk count', key: 'netapp.shelf.disk.count[{#SHELFUID}]', master: 'netapp.shelves.get',
  preprocessing: jsonpath(shelf_path.call('disk_count')), component: 'disk', extra_tags: { 'shelf' => '{#SHELFNAME}' }
)
shelf_prototypes << dependent_proto(
  name: 'Shelf {#SHELFNAME}: Error count', key: 'netapp.shelf.error.count[{#SHELFUID}]', master: 'netapp.shelves.get',
  preprocessing: javascript(find_record_js("String(r.uid) === \"{#SHELFUID}\"", '(r.errors || []).length', '0')),
  component: 'shelf', extra_tags: { 'shelf' => '{#SHELFNAME}' },
  triggers: [proto_trigger(
    id: 'shelf-errors', expression: "last(/#{TEMPLATE}/netapp.shelf.error.count[{#SHELFUID}])>0",
    recovery_expression: "last(/#{TEMPLATE}/netapp.shelf.error.count[{#SHELFUID}])=0",
    name: "#{PREFIX}: Shelf {#SHELFNAME} reporta erros",
    event_name: "#{PREFIX}: Shelf {#SHELFNAME} reporta erros | quantidade: {ITEM.LASTVALUE1}",
    opdata: 'Erros atuais: {ITEM.LASTVALUE1}', priority: 'HIGH'
  )]
)
discoveries << dependent_discovery(
  name: 'Shelves discovery', key: 'netapp.shelves.discovery', master: 'netapp.shelves.get',
  preprocessing: javascript(lld_from_records_js(
    '{#SHELFUID}' => 'String(r.uid)', '{#SHELFNAME}' => '(r.name || r.id || String(r.uid))', '{#SHELFMODEL}' => '(r.model || "")'
  )), prototypes: shelf_prototypes
)

def flat_path(tail)
  "$.records[?(@.shelf_uid=='{#SHELFUID}'&&@.id=='{#SENSORID}')].#{tail}.first()"
end

fru_prototypes = []
fru_path = ->(tail) { "$.records[?(@.shelf_uid=='{#SHELFUID}'&&@.id=='{#FRUID}')].#{tail}.first()" }
fru_prototypes << dependent_proto(
  name: 'Shelf {#SHELFNAME} {#FRUTYPE} {#FRUID}: State', key: 'netapp.shelf.fru.state[{#SHELFUID},{#FRUID}]',
  master: 'netapp.shelf.frus.json', preprocessing: jsonpath(fru_path.call('state')), component: 'hardware', value_type: 'CHAR',
  extra_tags: { 'shelf' => '{#SHELFNAME}', 'fru' => '{#FRUID}', 'type' => '{#FRUTYPE}' },
  triggers: [proto_trigger(
    id: 'shelf-fru-state',
    expression: "last(/#{TEMPLATE}/netapp.shelf.fru.state[{#SHELFUID},{#FRUID}])<>\"ok\" and last(/#{TEMPLATE}/netapp.shelf.fru.installed[{#SHELFUID},{#FRUID}])=1",
    recovery_expression: "last(/#{TEMPLATE}/netapp.shelf.fru.state[{#SHELFUID},{#FRUID}])=\"ok\" or last(/#{TEMPLATE}/netapp.shelf.fru.installed[{#SHELFUID},{#FRUID}])=0",
    name: "#{PREFIX}: FRU/FONTE {#FRUTYPE} {#FRUID} com falha na shelf {#SHELFNAME}",
    event_name: "#{PREFIX}: FRU/FONTE {#FRUTYPE} {#FRUID} da shelf {#SHELFNAME} com falha | estado: {ITEM.LASTVALUE1}",
    opdata: 'Estado atual: {ITEM.LASTVALUE1}', priority: 'DISASTER'
  )]
)
fru_prototypes << dependent_proto(
  name: 'Shelf {#SHELFNAME} {#FRUTYPE} {#FRUID}: Installed', key: 'netapp.shelf.fru.installed[{#SHELFUID},{#FRUID}]',
  master: 'netapp.shelf.frus.json', preprocessing: jsonpath(fru_path.call('installed')), component: 'hardware',
  extra_tags: { 'shelf' => '{#SHELFNAME}', 'fru' => '{#FRUID}', 'type' => '{#FRUTYPE}' }
)
discoveries << dependent_discovery(
  name: 'Shelf FRUs and PSUs discovery', key: 'netapp.shelf.frus.discovery', master: 'netapp.shelf.frus.json',
  preprocessing: javascript(lld_from_records_js(
    '{#SHELFUID}' => 'r.shelf_uid', '{#SHELFNAME}' => 'r.shelf_name', '{#FRUID}' => 'r.id', '{#FRUTYPE}' => 'r.type'
  )), prototypes: fru_prototypes
)

fan_prototypes = [
  dependent_proto(
    name: 'Shelf {#SHELFNAME} fan {#SENSORID}: State', key: 'netapp.shelf.fan.state[{#SHELFUID},{#SENSORID}]',
    master: 'netapp.shelf.fans.json', preprocessing: jsonpath(flat_path('state')), component: 'fan', value_type: 'CHAR',
    extra_tags: { 'shelf' => '{#SHELFNAME}', 'sensor' => '{#SENSORID}' },
    triggers: [proto_trigger(
      id: 'shelf-fan-state', expression: "last(/#{TEMPLATE}/netapp.shelf.fan.state[{#SHELFUID},{#SENSORID}])<>\"ok\"",
      recovery_expression: "last(/#{TEMPLATE}/netapp.shelf.fan.state[{#SHELFUID},{#SENSORID}])=\"ok\"",
      name: "#{PREFIX}: Ventoinha {#SENSORID} com falha na shelf {#SHELFNAME}",
      event_name: "#{PREFIX}: Ventoinha {#SENSORID} ({#SENSORLOCATION}) da shelf {#SHELFNAME} com falha | estado: {ITEM.LASTVALUE1}",
      opdata: 'Estado atual: {ITEM.LASTVALUE1}', priority: 'HIGH'
    )]
  ),
  dependent_proto(
    name: 'Shelf {#SHELFNAME} fan {#SENSORID}: RPM', key: 'netapp.shelf.fan.rpm[{#SHELFUID},{#SENSORID}]',
    master: 'netapp.shelf.fans.json', preprocessing: jsonpath(flat_path('rpm')), component: 'fan', units: 'rpm',
    extra_tags: { 'shelf' => '{#SHELFNAME}', 'sensor' => '{#SENSORID}' }
  )
]
discoveries << dependent_discovery(
  name: 'Shelf fans discovery', key: 'netapp.shelf.fans.discovery', master: 'netapp.shelf.fans.json',
  preprocessing: javascript(lld_from_records_js(
    '{#SHELFUID}' => 'r.shelf_uid', '{#SHELFNAME}' => 'r.shelf_name', '{#SENSORID}' => 'r.id', '{#SENSORLOCATION}' => 'r.location'
  )), prototypes: fan_prototypes
)

temp_prototypes = [
  dependent_proto(
    name: 'Shelf {#SHELFNAME} temperature {#SENSORID}: State', key: 'netapp.shelf.temperature.state[{#SHELFUID},{#SENSORID}]',
    master: 'netapp.shelf.temperature.json', preprocessing: jsonpath(flat_path('state')), component: 'temperature', value_type: 'CHAR',
    extra_tags: { 'shelf' => '{#SHELFNAME}', 'sensor' => '{#SENSORID}' },
    triggers: [proto_trigger(
      id: 'shelf-temperature-state', expression: "last(/#{TEMPLATE}/netapp.shelf.temperature.state[{#SHELFUID},{#SENSORID}])<>\"ok\"",
      recovery_expression: "last(/#{TEMPLATE}/netapp.shelf.temperature.state[{#SHELFUID},{#SENSORID}])=\"ok\"",
      name: "#{PREFIX}: Sensor de temperatura {#SENSORID} anormal na shelf {#SHELFNAME}", priority: 'HIGH'
    )]
  ),
  dependent_proto(
    name: 'Shelf {#SHELFNAME} temperature {#SENSORID}', key: 'netapp.shelf.temperature.value[{#SHELFUID},{#SENSORID}]',
    master: 'netapp.shelf.temperature.json', preprocessing: jsonpath(flat_path('temperature')), component: 'temperature', units: '°C',
    extra_tags: { 'shelf' => '{#SHELFNAME}', 'sensor' => '{#SENSORID}' }
  ),
  dependent_proto(
    name: 'Shelf {#SHELFNAME} temperature {#SENSORID}: High warning threshold', key: 'netapp.shelf.temperature.high.warning[{#SHELFUID},{#SENSORID}]',
    master: 'netapp.shelf.temperature.json', preprocessing: jsonpath(flat_path('high_warning')), component: 'temperature', units: '°C',
    extra_tags: { 'shelf' => '{#SHELFNAME}', 'sensor' => '{#SENSORID}' }
  ),
  dependent_proto(
    name: 'Shelf {#SHELFNAME} temperature {#SENSORID}: High critical threshold', key: 'netapp.shelf.temperature.high.critical[{#SHELFUID},{#SENSORID}]',
    master: 'netapp.shelf.temperature.json', preprocessing: jsonpath(flat_path('high_critical')), component: 'temperature', units: '°C',
    extra_tags: { 'shelf' => '{#SHELFNAME}', 'sensor' => '{#SENSORID}' }
  )
]
discoveries << dependent_discovery(
  name: 'Shelf temperature sensors discovery', key: 'netapp.shelf.temperature.discovery', master: 'netapp.shelf.temperature.json',
  preprocessing: javascript(lld_from_records_js(
    '{#SHELFUID}' => 'r.shelf_uid', '{#SHELFNAME}' => 'r.shelf_name', '{#SENSORID}' => 'r.id', '{#SENSORLOCATION}' => 'r.location'
  )), prototypes: temp_prototypes
)

[
  ['voltage', 'Voltage', 'V'],
  ['current', 'Current', 'mA']
].each do |kind, label, units|
  master = "netapp.shelf.#{kind}.json"
  protos = [
    dependent_proto(
      name: "Shelf {#SHELFNAME} #{kind} {#SENSORID}: State", key: "netapp.shelf.#{kind}.state[{#SHELFUID},{#SENSORID}]",
      master: master, preprocessing: jsonpath(flat_path('state')), component: kind, value_type: 'CHAR',
      extra_tags: { 'shelf' => '{#SHELFNAME}', 'sensor' => '{#SENSORID}' },
      triggers: [proto_trigger(
        id: "shelf-#{kind}-state", expression: "last(/#{TEMPLATE}/netapp.shelf.#{kind}.state[{#SHELFUID},{#SENSORID}])<>\"ok\"",
        recovery_expression: "last(/#{TEMPLATE}/netapp.shelf.#{kind}.state[{#SHELFUID},{#SENSORID}])=\"ok\"",
        name: "#{PREFIX}: Sensor de #{kind} {#SENSORID} anormal na shelf {#SHELFNAME}", priority: 'HIGH'
      )]
    ),
    dependent_proto(
      name: "Shelf {#SHELFNAME} #{label} {#SENSORID}", key: "netapp.shelf.#{kind}.value[{#SHELFUID},{#SENSORID}]",
      master: master, preprocessing: jsonpath(flat_path(kind)), component: kind, value_type: 'FLOAT', units: units,
      extra_tags: { 'shelf' => '{#SHELFNAME}', 'sensor' => '{#SENSORID}' }
    )
  ]
  discoveries << dependent_discovery(
    name: "Shelf #{kind} sensors discovery", key: "netapp.shelf.#{kind}.discovery", master: master,
    preprocessing: javascript(lld_from_records_js(
      '{#SHELFUID}' => 'r.shelf_uid', '{#SHELFNAME}' => 'r.shelf_name', '{#SENSORID}' => 'r.id', '{#SENSORLOCATION}' => 'r.location'
    )), prototypes: protos
  )
end

# AutoSupport configuration and connectivity.
autosupport_raw = http_item(
  name: 'Get AutoSupport configuration and issues', key: 'netapp.autosupport.get', delay: '15m',
  url: '{$NETAPP.URL}/api/support/autosupport?fields=*,issues', timeout: '{$NETAPP.AUTOSUPPORT.TIMEOUT}'
)
items << autosupport_raw
items << dependent_item(
  name: 'AutoSupport enabled', key: 'netapp.autosupport.enabled', master: 'netapp.autosupport.get',
  preprocessing: jsonpath('$.enabled') + javascript("return (value === 'true' || value === '1') ? 1 : 0;"), component: 'autosupport',
  triggers: [trigger(
    id: 'autosupport-disabled', expression: "last(/#{TEMPLATE}/netapp.autosupport.enabled)=0",
    recovery_expression: "last(/#{TEMPLATE}/netapp.autosupport.enabled)=1",
    name: "#{PREFIX}: AutoSupport está desabilitado", priority: 'AVERAGE'
  )]
)
items << dependent_item(
  name: 'AutoSupport connectivity issue count', key: 'netapp.autosupport.issues.count', master: 'netapp.autosupport.get',
  preprocessing: javascript("var x=JSON.parse(value); return (x.issues || []).length;"), component: 'autosupport',
  triggers: [trigger(
    id: 'autosupport-issues', expression: "last(/#{TEMPLATE}/netapp.autosupport.issues.count)>0",
    recovery_expression: "last(/#{TEMPLATE}/netapp.autosupport.issues.count)=0",
    name: "#{PREFIX}: AutoSupport possui problema de conectividade", priority: 'AVERAGE'
  )]
)

# EMS latest critical/recent event. The freshness check prevents old log entries from holding a problem open.
ems_raw = http_item(
  name: 'Get latest EMS events', key: 'netapp.ems.events.get', delay: '5m',
  url: '{$NETAPP.URL}/api/support/ems/events?fields=index,time,node.name,message.name,message.severity,log_message&order_by=time%20desc&max_records={$NETAPP.EMS.MAX.RECORDS}'
)
items << ems_raw
ems_script = <<~JS
  var data = JSON.parse(value);
  var records = data.records || [];
  var windowSeconds = parseInt('{$NETAPP.EMS.WINDOW}', 10);
  if (!windowSeconds || windowSeconds < 60) windowSeconds = 900;
  var now = (new Date()).getTime();
  var severities = {emergency:1,alert:1,error:1};
  for (var i = 0; i < records.length; i++) {
    var r = records[i], severity = r.message && r.message.severity;
    var timestamp = (new Date(r.time)).getTime();
    if (severities[severity] && !isNaN(timestamp) && (now - timestamp) <= windowSeconds * 1000) {
      return severity + ' | ' + (r.node ? r.node.name : '-') + ' | ' + (r.message ? r.message.name : '-') + ' | ' + (r.log_message || '');
    }
  }
  return 'none';
JS
items << dependent_item(
  name: 'Latest recent critical EMS event', key: 'netapp.ems.latest.critical', master: 'netapp.ems.events.get',
  preprocessing: javascript(ems_script), component: 'ems', value_type: 'TEXT',
  triggers: [trigger(
    id: 'ems-critical', expression: "last(/#{TEMPLATE}/netapp.ems.latest.critical)<>\"none\"",
    recovery_expression: "last(/#{TEMPLATE}/netapp.ems.latest.critical)=\"none\"",
    name: "#{PREFIX}: Evento EMS crítico recente: {ITEM.VALUE}", priority: 'HIGH'
  )]
)

# SnapMirror relationships.
snapmirror_raw = http_item(
  name: 'Get SnapMirror relationships', key: 'netapp.snapmirror.get', delay: '5m',
  url: '{$NETAPP.URL}/api/snapmirror/relationships?fields=uuid,healthy,state,lag_time,source.path,source.svm.name,destination.path,destination.svm.name,unhealthy_reason&max_records={$NETAPP.API.MAX.RECORDS}'
)
items << snapmirror_raw
sm_filter = "@.uuid=='{#SMUUID}'"
sm_path = ->(tail) { "$.records[?(#{sm_filter})].#{tail}.first()" }
sm_prototypes = []
sm_prototypes << dependent_proto(
  name: 'SnapMirror {#SMSOURCE} -> {#SMDESTINATION}: Healthy', key: 'netapp.snapmirror.healthy[{#SMUUID}]',
  master: 'netapp.snapmirror.get', preprocessing: jsonpath(sm_path.call('healthy')) + javascript("return (value === 'true' || value === '1') ? 1 : 0;"),
  component: 'snapmirror', extra_tags: { 'source' => '{#SMSOURCE}', 'destination' => '{#SMDESTINATION}' },
  triggers: [proto_trigger(
    id: 'snapmirror-unhealthy', expression: "last(/#{TEMPLATE}/netapp.snapmirror.healthy[{#SMUUID}])=0",
    recovery_expression: "last(/#{TEMPLATE}/netapp.snapmirror.healthy[{#SMUUID}])=1",
    name: "#{PREFIX}: SnapMirror {#SMSOURCE} -> {#SMDESTINATION} não saudável", priority: 'HIGH'
  )]
)
sm_prototypes << dependent_proto(
  name: 'SnapMirror {#SMSOURCE} -> {#SMDESTINATION}: State', key: 'netapp.snapmirror.state[{#SMUUID}]',
  master: 'netapp.snapmirror.get', preprocessing: jsonpath(sm_path.call('state')), component: 'snapmirror', value_type: 'CHAR',
  extra_tags: { 'source' => '{#SMSOURCE}', 'destination' => '{#SMDESTINATION}' }
)
iso_duration_script = find_record_js(
  "r.uuid === \"{#SMUUID}\"",
  <<~'JS_EXPR'.strip,
    (function () {
      var text = r.lag_time || 'PT0S';
      var m = /^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$/.exec(text);
      if (!m) return null;
      return (parseInt(m[1] || 0,10) * 86400) + (parseInt(m[2] || 0,10) * 3600) + (parseInt(m[3] || 0,10) * 60) + parseFloat(m[4] || 0);
    }())
  JS_EXPR
  'null'
)
sm_prototypes << dependent_proto(
  name: 'SnapMirror {#SMSOURCE} -> {#SMDESTINATION}: Lag', key: 'netapp.snapmirror.lag.seconds[{#SMUUID}]',
  master: 'netapp.snapmirror.get', preprocessing: javascript(iso_duration_script), component: 'snapmirror', units: 's',
  extra_tags: { 'source' => '{#SMSOURCE}', 'destination' => '{#SMDESTINATION}' },
  triggers: [proto_trigger(
    id: 'snapmirror-lag', expression: "last(/#{TEMPLATE}/netapp.snapmirror.lag.seconds[{#SMUUID}])>{$NETAPP.SNAPMIRROR.LAG.CRIT}",
    recovery_expression: "last(/#{TEMPLATE}/netapp.snapmirror.lag.seconds[{#SMUUID}])<{$NETAPP.SNAPMIRROR.LAG.RECOVERY}",
    name: "#{PREFIX}: SnapMirror {#SMSOURCE} -> {#SMDESTINATION} com atraso alto", priority: 'AVERAGE', scope: 'performance'
  )]
)
discoveries << dependent_discovery(
  name: 'SnapMirror relationships discovery', key: 'netapp.snapmirror.discovery', master: 'netapp.snapmirror.get',
  preprocessing: javascript(lld_from_records_js(
    '{#SMUUID}' => 'r.uuid',
    '{#SMSOURCE}' => '((r.source && r.source.svm ? r.source.svm.name + ":" : "") + (r.source ? r.source.path : ""))',
    '{#SMDESTINATION}' => '((r.destination && r.destination.svm ? r.destination.svm.name + ":" : "") + (r.destination ? r.destination.path : ""))'
  )), prototypes: sm_prototypes
)

# FSA: recursively discover directories using the ONTAP files endpoint. That endpoint
# returns only the immediate children of one path, so a Zabbix Script item performs
# the bounded breadth-first traversal and follows ONTAP pagination links.
fsa_recursive_script = <<~'JS'
  var params = JSON.parse(value);
  var started = new Date().getTime();
  var result = {
    records: [],
    stats: {selected_volumes: 0, directory_count: 0, api_requests: 0, duration_ms: 0, truncated: 0},
    error: ''
  };

  function asInteger(text, fallback, minimum, maximum) {
    var number = parseInt(text, 10);
    if (isNaN(number)) number = fallback;
    if (number < minimum) number = minimum;
    if (number > maximum) number = maximum;
    return number;
  }

  function cleanBaseUrl(url) {
    var cleaned = String(url || '');
    while (cleaned.length && cleaned.charAt(cleaned.length - 1) === '/') {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    if (!/^https?:\/\//i.test(cleaned)) throw 'NETAPP URL must start with http:// or https://';
    return cleaned;
  }

  function absoluteUrl(baseUrl, href) {
    href = String(href || '');
    if (/^https?:\/\//i.test(href)) return href;
    if (href.charAt(0) === '/') return baseUrl + href;
    return baseUrl + '/' + href;
  }

  function encodeOntapPath(path) {
    var encoded = encodeURIComponent(path || '.');
    return encoded.replace(/\./g, '%2E');
  }

  function cleanPath(path) {
    var cleaned = String(path || '');
    while (cleaned.indexOf('./') === 0) cleaned = cleaned.substring(2);
    while (cleaned.charAt(0) === '/') cleaned = cleaned.substring(1);
    while (cleaned.length && cleaned.charAt(cleaned.length - 1) === '/') {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    return cleaned === '.' ? '' : cleaned;
  }

  function joinPath(parent, name) {
    parent = cleanPath(parent);
    name = cleanPath(name);
    return parent ? parent + '/' + name : name;
  }

  function displayPath(path) {
    var full = '/' + cleanPath(path);
    if (full.length <= 180) return full;
    return '/...' + full.substring(full.length - 176);
  }

  function stableId(volumeUuid, path) {
    var text = String(path || '');
    var hash = 2166136261;
    for (var i = 0; i < text.length; i++) {
      hash ^= text.charCodeAt(i);
      hash += (hash << 1) + (hash << 4) + (hash << 7) + (hash << 8) + (hash << 24);
    }
    return String(volumeUuid || '').replace(/-/g, '').substring(0, 16) + '_' +
      ('00000000' + (hash >>> 0).toString(16)).slice(-8);
  }

  function numberOrZero(number) {
    return (number === undefined || number === null || isNaN(Number(number))) ? 0 : Number(number);
  }

  function stringOrUnknown(text) {
    return (text === undefined || text === null || text === '') ? 'unknown' : String(text);
  }

  function epochOrZero(text) {
    if (!text) return 0;
    var normalized = String(text);
    var ontapDate = /^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+([+-]\d{2})(\d{2})$/.exec(normalized);
    if (ontapDate) normalized = ontapDate[1] + 'T' + ontapDate[2] + ontapDate[3] + ':' + ontapDate[4];
    var milliseconds = Date.parse(normalized);
    return isNaN(milliseconds) ? 0 : Math.floor(milliseconds / 1000);
  }

  // FSA histogram labels are partial ISO 8601 periods, not exact timestamps.
  // Use the final second of a populated period so inactivity alarms remain
  // conservative.
  function fsaPeriodEndEpoch(label) {
    var text = String(label || '').replace(/^\s+|\s+$/g, '');
    if (!text || text === 'unknown') return 0;

    var separator = text.indexOf('--');
    if (separator !== -1) {
      var intervalEnd = text.substring(separator + 2);
      if (!intervalEnd) return Math.floor(started / 1000);
      text = intervalEnd;
    }

    var match = /^(\d{4})-Q([1-4])$/.exec(text);
    if (match) {
      return Math.floor((Date.UTC(parseInt(match[1], 10), parseInt(match[2], 10) * 3, 1) - 1) / 1000);
    }

    match = /^(\d{4})-W(\d{2})$/.exec(text);
    if (match) {
      var weekYear = parseInt(match[1], 10);
      var week = parseInt(match[2], 10);
      if (week < 1 || week > 53) return 0;
      var januaryFourth = new Date(Date.UTC(weekYear, 0, 4));
      var januaryFourthDay = januaryFourth.getUTCDay() || 7;
      var firstMonday = Date.UTC(weekYear, 0, 4 - januaryFourthDay + 1);
      return Math.floor((firstMonday + week * 7 * 86400000 - 1) / 1000);
    }

    match = /^(\d{4})$/.exec(text);
    if (match) {
      return Math.floor((Date.UTC(parseInt(match[1], 10) + 1, 0, 1) - 1) / 1000);
    }

    match = /^(\d{4})-(\d{2})$/.exec(text);
    if (match) {
      var month = parseInt(match[2], 10);
      if (month < 1 || month > 12) return 0;
      return Math.floor((Date.UTC(parseInt(match[1], 10), month, 1) - 1) / 1000);
    }

    match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text);
    if (match) {
      var dateEnd = Date.UTC(parseInt(match[1], 10), parseInt(match[2], 10) - 1, parseInt(match[3], 10) + 1) - 1;
      return Math.floor(dateEnd / 1000);
    }

    var milliseconds = Date.parse(text);
    return isNaN(milliseconds) ? 0 : Math.floor(milliseconds / 1000);
  }

  function fsaPeriodStartEpoch(label) {
    var text = String(label || '').replace(/^\s+|\s+$/g, '');
    if (!text || text === 'unknown') return 0;

    var separator = text.indexOf('--');
    if (separator !== -1) {
      text = text.substring(0, separator);
      if (!text) return 0;
    }

    var match = /^(\d{4})-Q([1-4])$/.exec(text);
    if (match) return Math.floor(Date.UTC(parseInt(match[1], 10), (parseInt(match[2], 10) - 1) * 3, 1) / 1000);

    match = /^(\d{4})-W(\d{2})$/.exec(text);
    if (match) {
      var weekYear = parseInt(match[1], 10);
      var week = parseInt(match[2], 10);
      if (week < 1 || week > 53) return 0;
      var januaryFourth = new Date(Date.UTC(weekYear, 0, 4));
      var januaryFourthDay = januaryFourth.getUTCDay() || 7;
      var firstMonday = Date.UTC(weekYear, 0, 4 - januaryFourthDay + 1);
      return Math.floor((firstMonday + (week - 1) * 7 * 86400000) / 1000);
    }

    match = /^(\d{4})$/.exec(text);
    if (match) return Math.floor(Date.UTC(parseInt(match[1], 10), 0, 1) / 1000);

    match = /^(\d{4})-(\d{2})$/.exec(text);
    if (match) {
      var month = parseInt(match[2], 10);
      if (month < 1 || month > 12) return 0;
      return Math.floor(Date.UTC(parseInt(match[1], 10), month - 1, 1) / 1000);
    }

    match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text);
    if (match) return Math.floor(Date.UTC(parseInt(match[1], 10), parseInt(match[2], 10) - 1, parseInt(match[3], 10)) / 1000);

    var milliseconds = Date.parse(text);
    return isNaN(milliseconds) ? 0 : Math.floor(milliseconds / 1000);
  }

  function fsaPeriodContainsEpoch(label, epoch) {
    if (!epoch) return false;
    var startEpoch = fsaPeriodStartEpoch(label);
    var endEpoch = fsaPeriodEndEpoch(label);
    return endEpoch > 0 && epoch >= startEpoch && epoch <= endEpoch;
  }

  function histogram(container, axis) {
    if (!container || !container[axis] || !container[axis].bytes_used) return {};
    return container[axis].bytes_used;
  }

  // Labels describe the buckets; newest_label only describes the newest
  // available bucket and does not prove that the bucket contains data. ONTAP
  // returns the histogram in newest-to-oldest priority order and includes
  // overlapping rollups (week, month, quarter and year). Therefore the first
  // populated bucket is the most precise recent period; choosing the greatest
  // calculated end date would incorrectly prefer the overlapping year rollup.
  function newestPopulatedBucket(localHistogram, sharedHistogram, excludedEpoch, excludedBytes) {
    localHistogram = localHistogram || {};
    sharedHistogram = sharedHistogram || {};
    var labels = localHistogram.labels || sharedHistogram.labels || [];
    var values = localHistogram.values || [];
    var percentages = localHistogram.percentages || [];
    var useValues = values.length > 0;
    var usePercentages = !useValues && percentages.length > 0;
    var selected = {label: 'unknown', epoch: 0, start_epoch: 0, raw_amount: 0, adjusted_amount: 0, excluded_bytes: 0};
    var totalExcludedBytes = 0;

    if (!labels.length || (!useValues && !usePercentages)) return selected;
    for (var index = 0; index < labels.length; index++) {
      var amount = useValues ? Number(values[index]) : Number(percentages[index]);
      if (isNaN(amount) || amount <= 0) continue;
      var rawAmount = amount;
      var removed = 0;
      if (useValues && excludedBytes > 0 && fsaPeriodContainsEpoch(labels[index], excludedEpoch)) {
        removed = Math.min(amount, excludedBytes);
        amount -= removed;
        totalExcludedBytes += removed;
      }
      if (amount <= 0) continue;
      var epoch = fsaPeriodEndEpoch(labels[index]);
      epoch = Math.min(epoch, Math.floor(started / 1000));
      if (epoch <= 0) continue;
      selected.label = String(labels[index]);
      selected.epoch = epoch;
      selected.start_epoch = fsaPeriodStartEpoch(labels[index]);
      selected.raw_amount = rawAmount;
      selected.adjusted_amount = amount;
      break;
    }
    selected.excluded_bytes = totalExcludedBytes;
    return selected;
  }

  try {
    var baseUrl = cleanBaseUrl(params.url);
    var includePattern = new RegExp(params.volume_matches || '^$');
    var excludePattern = new RegExp(params.volume_not_matches || '^$');
    var maxDepth = asInteger(params.max_depth, 1, 1, 20);
    var maxDirectories = asInteger(params.max_directories, 5000, 1, 10000);
    var pageSize = asInteger(params.page_size, 1000, 1, 1000);
    var request = new HttpRequest();
    request.addHeader('Accept: application/json');
    request.setHttpAuth(HTTPAUTH_BASIC, params.username, params.password);

    function getJson(url) {
      result.stats.api_requests++;
      var body = request.get(url);
      var status = request.getStatus();
      if (status !== 200) {
        throw 'ONTAP HTTP ' + status + ' for ' + url + ': ' + String(body).substring(0, 500);
      }
      try {
        return JSON.parse(body);
      }
      catch (error) {
        throw 'Invalid ONTAP JSON for ' + url + ': ' + error;
      }
    }

    function getAll(firstUrl) {
      var records = [];
      var nextUrl = firstUrl;
      var visited = {};
      while (nextUrl) {
        nextUrl = absoluteUrl(baseUrl, nextUrl);
        if (visited[nextUrl]) throw 'ONTAP pagination loop at ' + nextUrl;
        visited[nextUrl] = true;
        var page = getJson(nextUrl);
        var pageRecords = page.records || [];
        for (var i = 0; i < pageRecords.length; i++) {
          // ONTAP can place invariant histogram labels at response level while
          // each directory record contains only its values/percentages.
          if (page.analytics) pageRecords[i].__fsa_response_analytics = page.analytics;
          records.push(pageRecords[i]);
        }
        nextUrl = page._links && page._links.next ? page._links.next.href : '';
      }
      return records;
    }

    var volumeUrl = baseUrl + '/api/storage/volumes?fields=name,uuid,svm.name,type,state' +
      '&max_records=' + pageSize;
    var allVolumes = getAll(volumeUrl);
    var volumes = [];
    for (var volumeIndex = 0; volumeIndex < allVolumes.length; volumeIndex++) {
      var candidate = allVolumes[volumeIndex] || {};
      var candidateName = String(candidate.name || '');
      includePattern.lastIndex = 0;
      excludePattern.lastIndex = 0;
      if (!includePattern.test(candidateName) || excludePattern.test(candidateName)) continue;
      if (candidate.type && candidate.type !== 'rw') continue;
      if (candidate.state && candidate.state !== 'online') continue;
      volumes.push(candidate);
    }
    result.stats.selected_volumes = volumes.length;

    var seen = {};
    for (var selectedIndex = 0; selectedIndex < volumes.length; selectedIndex++) {
      var volume = volumes[selectedIndex];
      var queue = [{path: '', depth: 0}];
      var queueIndex = 0;
      while (queueIndex < queue.length && !result.stats.truncated) {
        var parent = queue[queueIndex++];
        if (parent.depth >= maxDepth) continue;
        var apiPath = parent.path ? parent.path : '.';
        var fields = 'name,path,type,bytes_used,accessed_time,modified_time,changed_time,' +
          'analytics.bytes_used,analytics.file_count,analytics.subdir_count,' +
          'analytics.incomplete_data,analytics.report_time,' +
          'analytics.by_accessed_time.bytes_used.labels,' +
          'analytics.by_accessed_time.bytes_used.values,' +
          'analytics.by_accessed_time.bytes_used.percentages,' +
          'analytics.by_modified_time.bytes_used.labels,' +
          'analytics.by_modified_time.bytes_used.values,' +
          'analytics.by_modified_time.bytes_used.percentages';
        var directoryUrl = baseUrl + '/api/storage/volumes/' + encodeURIComponent(volume.uuid) +
          '/files/' + encodeOntapPath(apiPath) + '?return_metadata=false&type=directory&fields=' +
          fields + '&max_records=' + pageSize;
        var children = getAll(directoryUrl);

        for (var childIndex = 0; childIndex < children.length; childIndex++) {
          var child = children[childIndex] || {};
          if (!child.name || child.name === '.' || child.name === '..' || child.name === '.snapshot') continue;
          if (child.type && child.type !== 'directory') continue;
          var childPath = cleanPath(child.path);
          if (!childPath || childPath === parent.path) childPath = joinPath(parent.path, child.name);
          var uniqueKey = volume.uuid + '|' + childPath;
          if (seen[uniqueKey]) continue;
          seen[uniqueKey] = true;

          var analytics = child.analytics || {};
          var sharedAnalytics = child.__fsa_response_analytics || {};
          var accessedHistogram = histogram(analytics, 'by_accessed_time');
          var sharedAccessedHistogram = histogram(sharedAnalytics, 'by_accessed_time');
          var modifiedHistogram = histogram(analytics, 'by_modified_time');
          var sharedModifiedHistogram = histogram(sharedAnalytics, 'by_modified_time');
          var directoryInodeBytes = numberOrZero(child.bytes_used);
          var accessedBucket = newestPopulatedBucket(
            accessedHistogram, sharedAccessedHistogram, epochOrZero(child.accessed_time), directoryInodeBytes);
          var modifiedBucket = newestPopulatedBucket(
            modifiedHistogram, sharedModifiedHistogram, 0, 0);
          var accessedDataEpoch = accessedBucket.epoch;
          var modifiedDataEpoch = modifiedBucket.epoch;
          var inactivityReferenceEpoch = 0;
          var inactivityReferenceStartEpoch = 0;
          if (!analytics.incomplete_data && accessedDataEpoch > 0 && modifiedDataEpoch > 0) {
            inactivityReferenceEpoch = Math.max(accessedDataEpoch, modifiedDataEpoch);
            inactivityReferenceStartEpoch = Math.max(accessedBucket.start_epoch, modifiedBucket.start_epoch);
          }
          var inactivityDays = inactivityReferenceEpoch > 0 ?
            Math.max(0, Math.floor((Math.floor(started / 1000) - inactivityReferenceEpoch) / 86400)) : 0;
          var inactivityMaximumDays = inactivityReferenceStartEpoch > 0 ?
            Math.max(inactivityDays, Math.floor((Math.floor(started / 1000) - inactivityReferenceStartEpoch) / 86400)) : 0;
          var inactivityRange = inactivityReferenceEpoch <= 0 ? 'unknown' :
            (inactivityMaximumDays > 0 ? inactivityDays + '-' + inactivityMaximumDays + ' dias' :
              'pelo menos ' + inactivityDays + ' dias');
          var depth = parent.depth + 1;
          result.records.push({
            id: stableId(volume.uuid, childPath),
            volume_uuid: volume.uuid,
            volume_name: volume.name,
            svm_name: volume.svm ? volume.svm.name : '',
            name: child.name,
            path: '/' + childPath,
            display_path: displayPath(childPath),
            parent_path: parent.path ? '/' + parent.path : '/',
            parent_display_path: displayPath(parent.path),
            depth: depth,
            directory_inode_bytes: directoryInodeBytes,
            bytes_used: numberOrZero(analytics.bytes_used),
            file_count: numberOrZero(analytics.file_count),
            subdir_count: numberOrZero(analytics.subdir_count),
            accessed_epoch: epochOrZero(child.accessed_time),
            modified_epoch: epochOrZero(child.modified_time),
            changed_epoch: epochOrZero(child.changed_time),
            accessed_time: stringOrUnknown(child.accessed_time),
            modified_time: stringOrUnknown(child.modified_time),
            accessed_histogram_labels: (accessedHistogram.labels || sharedAccessedHistogram.labels || []).join(','),
            accessed_histogram_values: (accessedHistogram.values || []).join(','),
            accessed_bucket_raw_bytes: accessedBucket.raw_amount,
            accessed_bucket_inode_bytes_removed: accessedBucket.excluded_bytes,
            accessed_newest_label: accessedBucket.label,
            modified_histogram_labels: (modifiedHistogram.labels || sharedModifiedHistogram.labels || []).join(','),
            modified_histogram_values: (modifiedHistogram.values || []).join(','),
            modified_bucket_raw_bytes: modifiedBucket.raw_amount,
            modified_newest_label: modifiedBucket.label,
            accessed_data_period_end_epoch: accessedDataEpoch,
            modified_data_period_end_epoch: modifiedDataEpoch,
            inactivity_reference_epoch: inactivityReferenceEpoch,
            inactivity_days: inactivityDays,
            inactivity_maximum_days: inactivityMaximumDays,
            inactivity_range: inactivityRange
          });

          if (depth < maxDepth) queue.push({path: childPath, depth: depth});
          if (result.records.length >= maxDirectories) {
            result.stats.truncated = 1;
            break;
          }
        }
      }
      if (result.stats.truncated) break;
    }
  }
  catch (error) {
    result.error = String(error);
  }

  result.stats.directory_count = result.records.length;
  result.stats.duration_ms = new Date().getTime() - started;
  return JSON.stringify(result);
JS

fsa_master_key = 'netapp.fsa.directories.get'
items << {
  'uuid' => uuid("item:#{fsa_master_key}"),
  'name' => 'FSA recursive directory tree: raw',
  'type' => 'SCRIPT',
  'key' => fsa_master_key,
  'delay' => '{$NETAPP.FSA.DIRECTORY.DELAY}',
  'history' => '0',
  'value_type' => 'TEXT',
  'params' => fsa_recursive_script,
  'timeout' => '{$NETAPP.FSA.DIRECTORY.TIMEOUT}',
  'parameters' => [
    { 'name' => 'url', 'value' => '{$NETAPP.URL}' },
    { 'name' => 'username', 'value' => '{$NETAPP.USERNAME}' },
    { 'name' => 'password', 'value' => '{$NETAPP.PASSWORD}' },
    { 'name' => 'volume_matches', 'value' => '{$NETAPP.FSA.VOLUME.MATCHES}' },
    { 'name' => 'volume_not_matches', 'value' => '{$NETAPP.FSA.VOLUME.NOT_MATCHES}' },
    { 'name' => 'max_depth', 'value' => '{$NETAPP.FSA.MAX.DEPTH}' },
    { 'name' => 'max_directories', 'value' => '{$NETAPP.FSA.MAX.DIRECTORIES}' },
    { 'name' => 'page_size', 'value' => '{$NETAPP.FSA.PAGE.SIZE}' }
  ],
  'description' => 'Descoberta recursiva e limitada de diretórios. A raiz tem profundidade 0 e as primeiras pastas têm profundidade 1.',
  'tags' => tags('fsa')
}

fsa_error_key = 'netapp.fsa.directories.error'
items << dependent_item(
  name: 'FSA recursive directory tree: collection error', key: fsa_error_key, master: fsa_master_key,
  preprocessing: jsonpath('$.error'), component: 'fsa', value_type: 'CHAR',
  description: 'Vazio quando a coleta terminou sem erro.',
  triggers: [trigger(
    id: 'fsa-recursive-error', expression: "length(last(/#{TEMPLATE}/#{fsa_error_key}))>0",
    recovery_expression: "length(last(/#{TEMPLATE}/#{fsa_error_key}))=0",
    name: "#{PREFIX}: falha na descoberta recursiva FSA", priority: 'AVERAGE'
  )]
)
items << dependent_item(
  name: 'FSA recursive directory tree: discovered directories', key: 'netapp.fsa.directories.count', master: fsa_master_key,
  preprocessing: jsonpath('$.stats.directory_count'), component: 'fsa'
)
items << dependent_item(
  name: 'FSA recursive directory tree: API requests', key: 'netapp.fsa.directories.requests', master: fsa_master_key,
  preprocessing: jsonpath('$.stats.api_requests'), component: 'fsa'
)
items << dependent_item(
  name: 'FSA recursive directory tree: duration', key: 'netapp.fsa.directories.duration', master: fsa_master_key,
  preprocessing: jsonpath('$.stats.duration_ms'), component: 'fsa', units: 'ms'
)
items << dependent_item(
  name: 'FSA recursive directory tree: truncated', key: 'netapp.fsa.directories.truncated', master: fsa_master_key,
  preprocessing: jsonpath('$.stats.truncated'), component: 'fsa',
  triggers: [trigger(
    id: 'fsa-recursive-truncated', expression: "last(/#{TEMPLATE}/netapp.fsa.directories.truncated)=1",
    recovery_expression: "last(/#{TEMPLATE}/netapp.fsa.directories.truncated)=0",
    name: "#{PREFIX}: árvore FSA atingiu o limite de diretórios", priority: 'WARNING', scope: 'performance',
    description: 'Aumente {$NETAPP.FSA.MAX.DIRECTORIES}, reduza os volumes selecionados ou diminua a profundidade.'
  )]
)

quota_master_key = 'netapp.quotas.get'
items << http_item(
  name: 'Get effective quota reports', key: quota_master_key,
  delay: '{$NETAPP.QUOTA.DELAY}', timeout: '{$NETAPP.QUOTA.TIMEOUT}', component: 'raw',
  url: '{$NETAPP.URL}/api/storage/quota/reports?show_default_records=false&fields=index,type,svm.name,svm.uuid,volume.name,volume.uuid,qtree.name,qtree.id,users.name,users.id,group.name,group.id,space.used.total,space.used.hard_limit_percent,space.used.soft_limit_percent,space.hard_limit,space.soft_limit,files.used.total,files.used.hard_limit_percent,files.used.soft_limit_percent,files.hard_limit,files.soft_limit&max_records={$NETAPP.QUOTA.MAX.RECORDS}'
)
items << dependent_item(
  name: 'Effective quota report records', key: 'netapp.quotas.count', master: quota_master_key,
  preprocessing: jsonpath('$.num_records'), component: 'quota',
  description: 'Quantidade de registros efetivos de quota devolvidos pelo ONTAP. Zero é normal enquanto não houver quotas ativas.'
)
items << dependent_item(
  name: 'Effective quota report collection truncated', key: 'netapp.quotas.truncated', master: quota_master_key,
  preprocessing: javascript("var data=JSON.parse(value); return data._links && data._links.next ? 1 : 0;"), component: 'quota',
  triggers: [trigger(
    id: 'quota-report-truncated',
    expression: "last(/#{TEMPLATE}/netapp.quotas.truncated)=1",
    recovery_expression: "last(/#{TEMPLATE}/netapp.quotas.truncated)=0",
    name: "#{PREFIX}: relatório de quotas excedeu o limite de registros", priority: 'WARNING', scope: 'performance',
    description: 'Aumente {$NETAPP.QUOTA.MAX.RECORDS}; enquanto houver paginação, algumas quotas podem não ser descobertas.'
  )]
)

fsa_inactive_bytes_script = <<~JS
  var data = JSON.parse(value);
  if (data.error) throw data.error;
  var records = data.records || [];
  var threshold = parseInt('{$NETAPP.FSA.INACTIVE.WARN.DAYS}', 10);
  if (isNaN(threshold) || threshold < 1) threshold = 365;
  var candidates = [];

  function cleanPath(path) {
    var cleaned = String(path || '');
    while (cleaned.indexOf('./') === 0) cleaned = cleaned.substring(2);
    while (cleaned.charAt(0) === '/') cleaned = cleaned.substring(1);
    while (cleaned.length && cleaned.charAt(cleaned.length - 1) === '/') {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    return cleaned;
  }

  for (var i = 0; i < records.length; i++) {
    var r = records[i] || {};
    var days = Number(r.inactivity_days);
    var bytes = Number(r.bytes_used);
    var path = cleanPath(r.path || r.display_path);
    if (isNaN(days) || days < threshold || isNaN(bytes) || bytes <= 0 || !path) continue;
    candidates.push({
      volume: String(r.volume_uuid || r.volume_name || 'unknown'),
      path: path,
      depth: Number(r.depth) || path.split('/').length,
      bytes: Math.round(bytes)
    });
  }

  candidates.sort(function (a, b) {
    if (a.depth !== b.depth) return a.depth - b.depth;
    if (a.volume !== b.volume) return a.volume < b.volume ? -1 : 1;
    return a.path < b.path ? -1 : (a.path > b.path ? 1 : 0);
  });

  var selected = {};
  var total = 0;
  for (var j = 0; j < candidates.length; j++) {
    var candidate = candidates[j];
    var prefix = candidate.volume + ':';
    var parts = candidate.path.split('/');
    var ancestor = '';
    var covered = selected[prefix + candidate.path] === 1;
    for (var p = 0; p < parts.length - 1 && !covered; p++) {
      ancestor = ancestor ? ancestor + '/' + parts[p] : parts[p];
      if (selected[prefix + ancestor] === 1) covered = true;
    }
    if (covered) continue;
    selected[prefix + candidate.path] = 1;
    total += candidate.bytes;
  }
  return total;
JS
items << dependent_item(
  name: 'FSA: Espaço total de pastas inativas', key: 'netapp.fsa.inactive.bytes.total', master: fsa_master_key,
  preprocessing: javascript(fsa_inactive_bytes_script), component: 'fsa', units: 'B',
  description: 'Soma informativa, sem trigger, dos diretórios com inatividade igual ou superior a {$NETAPP.FSA.INACTIVE.WARN.DAYS} dias. Diretórios descendentes já cobertos por um pai inativo não são somados novamente.'
)

fsa_directory_path = lambda do |field|
  "$.records[?(@.id=='{#DIRID}')].#{field}.first()"
end
fsa_directory_tags = {
  'volume' => '{#VOLUMENAME}', 'svm' => '{#SVMNAME}', 'path' => '{#DIRDISPLAY}',
  'parent' => '{#PARENTDISPLAY}', 'depth' => '{#DIRDEPTH}'
}
fsa_directory_prototypes = []
fsa_bytes_key = 'netapp.fsa.directory.bytes_used[{#DIRID}]'
fsa_directory_prototypes << dependent_proto(
  name: 'FSA [{#VOLUMENAME}] {#DIRDISPLAY}: Size used', key: fsa_bytes_key,
  master: fsa_master_key, preprocessing: jsonpath(fsa_directory_path.call('bytes_used')),
  component: 'fsa-directory', units: 'B', extra_tags: fsa_directory_tags
)
fsa_directory_prototypes << dependent_proto(
  name: 'FSA [{#VOLUMENAME}] {#DIRDISPLAY}: Files', key: 'netapp.fsa.directory.file_count[{#DIRID}]',
  master: fsa_master_key, preprocessing: jsonpath(fsa_directory_path.call('file_count')),
  component: 'fsa-directory', extra_tags: fsa_directory_tags
)
fsa_directory_prototypes << dependent_proto(
  name: 'FSA [{#VOLUMENAME}] {#DIRDISPLAY}: Subdirectories', key: 'netapp.fsa.directory.subdir_count[{#DIRID}]',
  master: fsa_master_key, preprocessing: jsonpath(fsa_directory_path.call('subdir_count')),
  component: 'fsa-directory', extra_tags: fsa_directory_tags
)
fsa_directory_prototypes << dependent_proto(
  name: 'FSA [{#VOLUMENAME}] {#DIRDISPLAY}: Directory last modification', key: 'netapp.fsa.directory.modified_time[{#DIRID}]',
  master: fsa_master_key, preprocessing: jsonpath(fsa_directory_path.call('modified_epoch')),
  component: 'fsa-directory', units: 'unixtime',
  description: 'modified_time exato do inode do diretório. Zero significa que o ONTAP não devolveu o campo.',
  extra_tags: fsa_directory_tags
)
fsa_directory_prototypes << dependent_proto(
  name: 'FSA [{#VOLUMENAME}] {#DIRDISPLAY}: Newest accessed-data bucket', key: 'netapp.fsa.directory.accessed_newest_label[{#DIRID}]',
  master: fsa_master_key, preprocessing: jsonpath(fsa_directory_path.call('accessed_newest_label')),
  component: 'fsa-directory', value_type: 'CHAR',
  description: 'Faixa temporal mais recente do histograma FSA de acesso cujo valor de bytes é maior que zero; não é o timestamp exato do diretório.',
  extra_tags: fsa_directory_tags
)
fsa_directory_prototypes << dependent_proto(
  name: 'FSA [{#VOLUMENAME}] {#DIRDISPLAY}: Newest modified-data bucket', key: 'netapp.fsa.directory.modified_newest_label[{#DIRID}]',
  master: fsa_master_key, preprocessing: jsonpath(fsa_directory_path.call('modified_newest_label')),
  component: 'fsa-directory', value_type: 'CHAR',
  description: 'Faixa temporal mais recente do histograma FSA de modificação cujo valor de bytes é maior que zero; não é o timestamp exato do diretório.',
  extra_tags: fsa_directory_tags
)
fsa_directory_prototypes << dependent_proto(
  name: 'FSA [{#VOLUMENAME}] {#DIRDISPLAY}: Inactivity reference', key: 'netapp.fsa.directory.inactivity.reference[{#DIRID}]',
  master: fsa_master_key, preprocessing: jsonpath(fsa_directory_path.call('inactivity_reference_epoch')),
  component: 'fsa-directory', units: 'unixtime',
  description: 'Fim conservador da faixa de atividade mais recente entre acesso e modificação dos dados descendentes. Zero significa que uma das duas datas FSA é desconhecida.',
  extra_tags: fsa_directory_tags
)

fsa_inactivity_key = 'netapp.fsa.directory.inactivity.days[{#DIRID}]'
fsa_inactivity_range_key = 'netapp.fsa.directory.inactivity.range[{#DIRID}]'
fsa_directory_prototypes << dependent_proto(
  name: 'FSA [{#VOLUMENAME}] {#DIRDISPLAY}: Minimum days without access or modification', key: fsa_inactivity_key,
  master: fsa_master_key, preprocessing: jsonpath(fsa_directory_path.call('inactivity_days')),
  component: 'fsa-directory', units: '!dias',
  description: 'Limite mínimo conservador calculado pelo fim da faixa FSA mais recente. Rótulos anuais não informam o dia exato, portanto várias pastas do mesmo ano podem ter o mesmo valor. Só aumenta quando acesso e modificação estão antigos; zero também é usado quando alguma faixa FSA é desconhecida.',
  extra_tags: fsa_directory_tags,
  triggers: [
    proto_trigger(
      id: 'fsa-directory-inactive-high',
      expression: "last(/#{TEMPLATE}/#{fsa_bytes_key})>=0 and last(/#{TEMPLATE}/#{fsa_inactivity_key})>={$NETAPP.FSA.INACTIVE.CRIT.DAYS}",
      recovery_expression: "last(/#{TEMPLATE}/#{fsa_inactivity_key})<{$NETAPP.FSA.INACTIVE.CRIT.DAYS}",
      name: 'NetApp ONTAP: Pasta {#VOLUMENAME}:{#DIRDISPLAY} sem acesso nem modificação há pelo menos 3 anos',
      priority: 'HIGH', scope: 'capacity',
      description: 'A faixa FSA mais recente tanto de acesso quanto de modificação terminou há pelo menos {$NETAPP.FSA.INACTIVE.CRIT.DAYS} dias. Uma pasta apenas sem modificação não dispara se houve acesso recente.',
      event_name: 'NetApp ONTAP: Pasta {#VOLUMENAME}:{#DIRDISPLAY} sem acesso nem modificação há pelo menos 3 anos | tamanho: {ITEM.VALUE1}; inatividade mínima: {ITEM.VALUE2}; acesso FSA: {?last(//netapp.fsa.directory.accessed_newest_label[{#DIRID}])}; modificação FSA: {?last(//netapp.fsa.directory.modified_newest_label[{#DIRID}])}',
      opdata: 'Tamanho atual: {ITEM.LASTVALUE1}; inatividade mínima atual: {ITEM.LASTVALUE2}; limite: {$NETAPP.FSA.INACTIVE.CRIT.DAYS} dias'
    ),
    proto_trigger(
      id: 'fsa-directory-inactive-warning',
      expression: "last(/#{TEMPLATE}/#{fsa_bytes_key})>=0 and last(/#{TEMPLATE}/#{fsa_inactivity_key})>={$NETAPP.FSA.INACTIVE.WARN.DAYS} and last(/#{TEMPLATE}/#{fsa_inactivity_key})<{$NETAPP.FSA.INACTIVE.CRIT.DAYS}",
      recovery_expression: "last(/#{TEMPLATE}/#{fsa_inactivity_key})<{$NETAPP.FSA.INACTIVE.WARN.DAYS} or last(/#{TEMPLATE}/#{fsa_inactivity_key})>={$NETAPP.FSA.INACTIVE.CRIT.DAYS}",
      name: 'NetApp ONTAP: Pasta {#VOLUMENAME}:{#DIRDISPLAY} sem acesso nem modificação há pelo menos 1 ano',
      priority: 'WARNING', scope: 'capacity',
      description: 'A faixa FSA mais recente tanto de acesso quanto de modificação terminou há pelo menos {$NETAPP.FSA.INACTIVE.WARN.DAYS} dias. Uma pasta apenas sem modificação não dispara se houve acesso recente.',
      event_name: 'NetApp ONTAP: Pasta {#VOLUMENAME}:{#DIRDISPLAY} sem acesso nem modificação há pelo menos 1 ano | tamanho: {ITEM.VALUE1}; inatividade mínima: {ITEM.VALUE2}; acesso FSA: {?last(//netapp.fsa.directory.accessed_newest_label[{#DIRID}])}; modificação FSA: {?last(//netapp.fsa.directory.modified_newest_label[{#DIRID}])}',
      opdata: 'Tamanho atual: {ITEM.LASTVALUE1}; inatividade mínima atual: {ITEM.LASTVALUE2}; limite: {$NETAPP.FSA.INACTIVE.WARN.DAYS} dias'
    )
  ]
)
fsa_directory_prototypes << dependent_proto(
  name: 'FSA [{#VOLUMENAME}] {#DIRDISPLAY}: Possible inactivity range', key: fsa_inactivity_range_key,
  master: fsa_master_key, preprocessing: jsonpath(fsa_directory_path.call('inactivity_range')),
  component: 'fsa-directory', value_type: 'CHAR',
  description: 'Faixa possível de inatividade derivada do início e do fim dos buckets FSA. Exemplo: 625-990 dias significa que o ONTAP só identificou o ano, não o dia exato.',
  extra_tags: fsa_directory_tags
)

fsa_directory_discovery_script = <<~JS
  var data = JSON.parse(value);
  if (data.error) throw data.error;
  var records = data.records || [];
  var result = [];
  for (var i = 0; i < records.length; i++) {
    var r = records[i];
    result.push({
      "{#DIRID}": r.id,
      "{#DIRNAME}": r.name,
      "{#DIRPATH}": r.path,
      "{#DIRDISPLAY}": r.display_path,
      "{#PARENTPATH}": r.parent_path,
      "{#PARENTDISPLAY}": r.parent_display_path,
      "{#DIRDEPTH}": r.depth,
      "{#VOLUMEUUID}": r.volume_uuid,
      "{#VOLUMENAME}": r.volume_name,
      "{#SVMNAME}": r.svm_name,
      "{#FSAACCESSEDLABEL}": r.accessed_newest_label,
      "{#FSAMODIFIEDLABEL}": r.modified_newest_label
    });
  }
  return JSON.stringify(result);
JS
discoveries << dependent_discovery(
  name: 'FSA recursive directories discovery', key: 'netapp.fsa.directories.discovery', master: fsa_master_key,
  preprocessing: javascript(fsa_directory_discovery_script), prototypes: fsa_directory_prototypes
)

# Keep a lightweight top-N summary per selected volume as a complementary view.
# The preprocessing uses ES5 syntax for Zabbix/Duktape.
fsa_top_script = <<~JS
  var data;
  try { data = JSON.parse(value); } catch (error) { throw 'Invalid JSON: ' + error; }
  var records = data.records || [];
  var topN = parseInt('{$NETAPP.FSA.TOP.N}', 10);
  if (!topN || topN < 1) topN = 20;
  var dirs = [];
  for (var i = 0; i < records.length; i++) {
    var r = records[i];
    if (!r || !r.name || r.name === '.' || r.name === '..') continue;
    var analytics = r.analytics || {};
    dirs.push({name:r.name,size:analytics.bytes_used || 0,files:analytics.file_count || 0,subdirs:analytics.subdir_count || 0});
  }
  dirs.sort(function (a, b) { return b.size - a.size; });
  if (dirs.length > topN) dirs.length = topN;
  var out = [];
  for (var j = 0; j < dirs.length; j++) {
    out.push((j + 1) + ' - ' + dirs[j].name + ' | bytes=' + dirs[j].size + ' | files=' + dirs[j].files + ' | subdirs=' + dirs[j].subdirs);
  }
  return out.length ? out.join('\\n') : 'No directory analytics returned';
JS
fsa_rule = {
  'uuid' => uuid('discovery:netapp.fsa.volumes.discovery'),
  'name' => 'FSA volumes discovery',
  'type' => 'HTTP_AGENT',
  'key' => 'netapp.fsa.volumes.discovery',
  'delay' => '1h',
  'authtype' => 'BASIC',
  'username' => '{$NETAPP.USERNAME}',
  'password' => '{$NETAPP.PASSWORD}',
  'filter' => {
    'evaltype' => 'AND',
    'conditions' => [
      { 'macro' => '{#VOLUMENAME}', 'value' => '{$NETAPP.FSA.VOLUME.MATCHES}', 'formulaid' => 'A' },
      { 'macro' => '{#VOLUMETYPE}', 'value' => '^rw$', 'formulaid' => 'B' }
    ]
  },
  'item_prototypes' => [
    {
      'uuid' => uuid('prototype:netapp.fsa.level1.raw[{#VOLUMEUUID}]'),
      'name' => 'FSA level-1 directories raw: {#SVMNAME}/{#VOLUMENAME}',
      'type' => 'HTTP_AGENT',
      'key' => 'netapp.fsa.level1.raw[{#VOLUMEUUID}]',
      'delay' => '{$NETAPP.FSA.DELAY}',
      'history' => '1h',
      'value_type' => 'TEXT',
      'authtype' => 'BASIC',
      'username' => '{$NETAPP.USERNAME}',
      'password' => '{$NETAPP.PASSWORD}',
      'timeout' => '{$NETAPP.FSA.TIMEOUT}',
      'url' => '{$NETAPP.URL}/api/storage/volumes/{#VOLUMEUUID}/files/%2E?fields=name,analytics&order_by=analytics.bytes_used%20desc&max_records={$NETAPP.FSA.MAX.RECORDS}',
      'tags' => tags('fsa', 'volume' => '{#VOLUMENAME}', 'svm' => '{#SVMNAME}')
    },
    dependent_proto(
      name: 'FSA top {$NETAPP.FSA.TOP.N} directories: {#SVMNAME}/{#VOLUMENAME}',
      key: 'netapp.fsa.level1.top[{#VOLUMEUUID}]', master: 'netapp.fsa.level1.raw[{#VOLUMEUUID}]',
      preprocessing: javascript(fsa_top_script), component: 'fsa', value_type: 'TEXT',
      extra_tags: { 'volume' => '{#VOLUMENAME}', 'svm' => '{#SVMNAME}' }
    )
  ],
  'timeout' => '{$NETAPP.HTTP.AGENT.TIMEOUT}',
  'url' => '{$NETAPP.URL}/api/storage/volumes?fields=name,uuid,svm.name,type&max_records={$NETAPP.API.MAX.RECORDS}',
  'preprocessing' => javascript(lld_from_records_js(
    '{#VOLUMENAME}' => 'r.name', '{#VOLUMEUUID}' => 'r.uuid', '{#SVMNAME}' => '(r.svm ? r.svm.name : "")', '{#VOLUMETYPE}' => 'r.type'
  ))
}
discoveries << fsa_rule

# Effective user/group/qtree quota discovery. Reports expose what is actually
# enforced in the filesystem; policy rules alone may not yet be active.
quota_match = "String(r.index)==='{#QUOTAINDEX}' && r.volume && String(r.volume.uuid)==='{#VOLUMEUUID}'"
quota_value = lambda do |expression, missing = '0'|
  javascript(find_record_js(quota_match, expression, missing))
end
quota_tags = {
  'quota-type' => '{#QUOTATYPE}', 'quota-target' => '{#QUOTATARGET}',
  'quota-scope' => '{#QUOTASCOPE}', 'volume' => '{#VOLUMENAME}', 'svm' => '{#SVMNAME}'
}

quota_space_used_key = 'netapp.quota.space.used[{#QUOTAID}]'
quota_space_hard_key = 'netapp.quota.space.hard_limit[{#QUOTAID}]'
quota_space_soft_key = 'netapp.quota.space.soft_limit[{#QUOTAID}]'
quota_space_hard_percent_key = 'netapp.quota.space.hard_limit.percent[{#QUOTAID}]'
quota_space_soft_percent_key = 'netapp.quota.space.soft_limit.percent[{#QUOTAID}]'
quota_files_used_key = 'netapp.quota.files.used[{#QUOTAID}]'
quota_files_hard_key = 'netapp.quota.files.hard_limit[{#QUOTAID}]'
quota_files_soft_key = 'netapp.quota.files.soft_limit[{#QUOTAID}]'
quota_files_hard_percent_key = 'netapp.quota.files.hard_limit.percent[{#QUOTAID}]'
quota_files_soft_percent_key = 'netapp.quota.files.soft_limit.percent[{#QUOTAID}]'

quota_context = '{#QUOTATYPE} {#QUOTATARGET} no volume {#VOLUMENAME} (escopo {#QUOTASCOPE})'
quota_space_hard_triggers = [
  proto_trigger(
    id: 'quota-space-hard-full',
    expression: "last(/#{TEMPLATE}/#{quota_space_hard_percent_key})>=100 and last(/#{TEMPLATE}/#{quota_space_hard_key})>0",
    recovery_expression: "last(/#{TEMPLATE}/#{quota_space_hard_percent_key})<100 or last(/#{TEMPLATE}/#{quota_space_hard_key})=0",
    name: "#{PREFIX}: Cota de espaço #{quota_context} esgotada", priority: 'DISASTER', scope: 'capacity',
    event_name: "#{PREFIX}: Cota de espaço #{quota_context} esgotada | usado: {ITEM.VALUE1}; limite hard: {ITEM.VALUE2}",
    opdata: 'Percentual atual: {ITEM.LASTVALUE1}; limite hard: {ITEM.LASTVALUE2}'
  ),
  proto_trigger(
    id: 'quota-space-hard-high',
    expression: "last(/#{TEMPLATE}/#{quota_space_hard_percent_key})>={$NETAPP.QUOTA.USED.CRIT} and last(/#{TEMPLATE}/#{quota_space_hard_key})>0 and last(/#{TEMPLATE}/#{quota_space_hard_percent_key})<100",
    recovery_expression: "last(/#{TEMPLATE}/#{quota_space_hard_percent_key})<{$NETAPP.QUOTA.USED.CRIT} or last(/#{TEMPLATE}/#{quota_space_hard_percent_key})>=100 or last(/#{TEMPLATE}/#{quota_space_hard_key})=0",
    name: "#{PREFIX}: Cota de espaço #{quota_context} crítica", priority: 'HIGH', scope: 'capacity',
    event_name: "#{PREFIX}: Cota de espaço #{quota_context} crítica | usado: {ITEM.VALUE1}; limite hard: {ITEM.VALUE2}; alerta: >={$NETAPP.QUOTA.USED.CRIT}%",
    opdata: 'Percentual atual: {ITEM.LASTVALUE1}; limite hard: {ITEM.LASTVALUE2}; limite de alerta: {$NETAPP.QUOTA.USED.CRIT}%'
  ),
  proto_trigger(
    id: 'quota-space-hard-warning',
    expression: "last(/#{TEMPLATE}/#{quota_space_hard_percent_key})>={$NETAPP.QUOTA.USED.WARN} and last(/#{TEMPLATE}/#{quota_space_hard_key})>0 and last(/#{TEMPLATE}/#{quota_space_hard_percent_key})<{$NETAPP.QUOTA.USED.CRIT}",
    recovery_expression: "last(/#{TEMPLATE}/#{quota_space_hard_percent_key})<{$NETAPP.QUOTA.USED.WARN} or last(/#{TEMPLATE}/#{quota_space_hard_percent_key})>={$NETAPP.QUOTA.USED.CRIT} or last(/#{TEMPLATE}/#{quota_space_hard_key})=0",
    name: "#{PREFIX}: Cota de espaço #{quota_context} elevada", priority: 'WARNING', scope: 'capacity',
    event_name: "#{PREFIX}: Cota de espaço #{quota_context} elevada | usado: {ITEM.VALUE1}; limite hard: {ITEM.VALUE2}; alerta: >={$NETAPP.QUOTA.USED.WARN}%",
    opdata: 'Percentual atual: {ITEM.LASTVALUE1}; limite hard: {ITEM.LASTVALUE2}; limite de alerta: {$NETAPP.QUOTA.USED.WARN}%'
  )
]
quota_space_soft_trigger = proto_trigger(
  id: 'quota-space-soft-exceeded',
  expression: "last(/#{TEMPLATE}/#{quota_space_soft_percent_key})>=100 and last(/#{TEMPLATE}/#{quota_space_soft_key})>0 and (last(/#{TEMPLATE}/#{quota_space_hard_key})=0 or last(/#{TEMPLATE}/#{quota_space_hard_percent_key})<{$NETAPP.QUOTA.USED.WARN})",
  recovery_expression: "last(/#{TEMPLATE}/#{quota_space_soft_percent_key})<100 or last(/#{TEMPLATE}/#{quota_space_soft_key})=0 or (last(/#{TEMPLATE}/#{quota_space_hard_key})>0 and last(/#{TEMPLATE}/#{quota_space_hard_percent_key})>={$NETAPP.QUOTA.USED.WARN})",
  name: "#{PREFIX}: Cota soft de espaço #{quota_context} ultrapassada", priority: 'WARNING', scope: 'capacity',
  event_name: "#{PREFIX}: Cota soft de espaço #{quota_context} ultrapassada | usado: {ITEM.VALUE1}; limite soft: {ITEM.VALUE2}",
  opdata: 'Percentual atual do soft limit: {ITEM.LASTVALUE1}; limite soft: {ITEM.LASTVALUE2}'
)

quota_files_hard_triggers = [
  proto_trigger(
    id: 'quota-files-hard-full',
    expression: "last(/#{TEMPLATE}/#{quota_files_hard_percent_key})>=100 and last(/#{TEMPLATE}/#{quota_files_hard_key})>0",
    recovery_expression: "last(/#{TEMPLATE}/#{quota_files_hard_percent_key})<100 or last(/#{TEMPLATE}/#{quota_files_hard_key})=0",
    name: "#{PREFIX}: Cota de arquivos #{quota_context} esgotada", priority: 'DISASTER', scope: 'capacity',
    event_name: "#{PREFIX}: Cota de arquivos #{quota_context} esgotada | usado: {ITEM.VALUE1}; limite hard: {ITEM.VALUE2}",
    opdata: 'Percentual atual: {ITEM.LASTVALUE1}; limite hard de arquivos: {ITEM.LASTVALUE2}'
  ),
  proto_trigger(
    id: 'quota-files-hard-high',
    expression: "last(/#{TEMPLATE}/#{quota_files_hard_percent_key})>={$NETAPP.QUOTA.USED.CRIT} and last(/#{TEMPLATE}/#{quota_files_hard_key})>0 and last(/#{TEMPLATE}/#{quota_files_hard_percent_key})<100",
    recovery_expression: "last(/#{TEMPLATE}/#{quota_files_hard_percent_key})<{$NETAPP.QUOTA.USED.CRIT} or last(/#{TEMPLATE}/#{quota_files_hard_percent_key})>=100 or last(/#{TEMPLATE}/#{quota_files_hard_key})=0",
    name: "#{PREFIX}: Cota de arquivos #{quota_context} crítica", priority: 'HIGH', scope: 'capacity',
    event_name: "#{PREFIX}: Cota de arquivos #{quota_context} crítica | usado: {ITEM.VALUE1}; limite hard: {ITEM.VALUE2}; alerta: >={$NETAPP.QUOTA.USED.CRIT}%",
    opdata: 'Percentual atual: {ITEM.LASTVALUE1}; limite hard de arquivos: {ITEM.LASTVALUE2}; limite de alerta: {$NETAPP.QUOTA.USED.CRIT}%'
  ),
  proto_trigger(
    id: 'quota-files-hard-warning',
    expression: "last(/#{TEMPLATE}/#{quota_files_hard_percent_key})>={$NETAPP.QUOTA.USED.WARN} and last(/#{TEMPLATE}/#{quota_files_hard_key})>0 and last(/#{TEMPLATE}/#{quota_files_hard_percent_key})<{$NETAPP.QUOTA.USED.CRIT}",
    recovery_expression: "last(/#{TEMPLATE}/#{quota_files_hard_percent_key})<{$NETAPP.QUOTA.USED.WARN} or last(/#{TEMPLATE}/#{quota_files_hard_percent_key})>={$NETAPP.QUOTA.USED.CRIT} or last(/#{TEMPLATE}/#{quota_files_hard_key})=0",
    name: "#{PREFIX}: Cota de arquivos #{quota_context} elevada", priority: 'WARNING', scope: 'capacity',
    event_name: "#{PREFIX}: Cota de arquivos #{quota_context} elevada | usado: {ITEM.VALUE1}; limite hard: {ITEM.VALUE2}; alerta: >={$NETAPP.QUOTA.USED.WARN}%",
    opdata: 'Percentual atual: {ITEM.LASTVALUE1}; limite hard de arquivos: {ITEM.LASTVALUE2}; limite de alerta: {$NETAPP.QUOTA.USED.WARN}%'
  )
]
quota_files_soft_trigger = proto_trigger(
  id: 'quota-files-soft-exceeded',
  expression: "last(/#{TEMPLATE}/#{quota_files_soft_percent_key})>=100 and last(/#{TEMPLATE}/#{quota_files_soft_key})>0 and (last(/#{TEMPLATE}/#{quota_files_hard_key})=0 or last(/#{TEMPLATE}/#{quota_files_hard_percent_key})<{$NETAPP.QUOTA.USED.WARN})",
  recovery_expression: "last(/#{TEMPLATE}/#{quota_files_soft_percent_key})<100 or last(/#{TEMPLATE}/#{quota_files_soft_key})=0 or (last(/#{TEMPLATE}/#{quota_files_hard_key})>0 and last(/#{TEMPLATE}/#{quota_files_hard_percent_key})>={$NETAPP.QUOTA.USED.WARN})",
  name: "#{PREFIX}: Cota soft de arquivos #{quota_context} ultrapassada", priority: 'WARNING', scope: 'capacity',
  event_name: "#{PREFIX}: Cota soft de arquivos #{quota_context} ultrapassada | usado: {ITEM.VALUE1}; limite soft: {ITEM.VALUE2}",
  opdata: 'Percentual atual do soft limit: {ITEM.LASTVALUE1}; limite soft de arquivos: {ITEM.LASTVALUE2}'
)

quota_prototypes = [
  dependent_proto(name: 'Quota {#QUOTATYPE} {#QUOTATARGET}: Space used', key: quota_space_used_key, master: quota_master_key,
                  preprocessing: quota_value.call('r.space && r.space.used ? r.space.used.total : 0'), component: 'quota', units: 'B', extra_tags: quota_tags),
  dependent_proto(name: 'Quota {#QUOTATYPE} {#QUOTATARGET}: Space hard limit', key: quota_space_hard_key, master: quota_master_key,
                  preprocessing: quota_value.call('r.space ? r.space.hard_limit : 0'), component: 'quota', units: 'B', extra_tags: quota_tags),
  dependent_proto(name: 'Quota {#QUOTATYPE} {#QUOTATARGET}: Space soft limit', key: quota_space_soft_key, master: quota_master_key,
                  preprocessing: quota_value.call('r.space ? r.space.soft_limit : 0'), component: 'quota', units: 'B', extra_tags: quota_tags),
  dependent_proto(name: 'Quota {#QUOTATYPE} {#QUOTATARGET}: Space hard-limit used', key: quota_space_hard_percent_key, master: quota_master_key,
                  preprocessing: quota_value.call('r.space && r.space.used ? r.space.used.hard_limit_percent : 0'), component: 'quota', value_type: 'FLOAT', units: '%', triggers: quota_space_hard_triggers, extra_tags: quota_tags),
  dependent_proto(name: 'Quota {#QUOTATYPE} {#QUOTATARGET}: Space soft-limit used', key: quota_space_soft_percent_key, master: quota_master_key,
                  preprocessing: quota_value.call('r.space && r.space.used ? r.space.used.soft_limit_percent : 0'), component: 'quota', value_type: 'FLOAT', units: '%', triggers: [quota_space_soft_trigger], extra_tags: quota_tags),
  dependent_proto(name: 'Quota {#QUOTATYPE} {#QUOTATARGET}: Files used', key: quota_files_used_key, master: quota_master_key,
                  preprocessing: quota_value.call('r.files && r.files.used ? r.files.used.total : 0'), component: 'quota', extra_tags: quota_tags),
  dependent_proto(name: 'Quota {#QUOTATYPE} {#QUOTATARGET}: Files hard limit', key: quota_files_hard_key, master: quota_master_key,
                  preprocessing: quota_value.call('r.files ? r.files.hard_limit : 0'), component: 'quota', extra_tags: quota_tags),
  dependent_proto(name: 'Quota {#QUOTATYPE} {#QUOTATARGET}: Files soft limit', key: quota_files_soft_key, master: quota_master_key,
                  preprocessing: quota_value.call('r.files ? r.files.soft_limit : 0'), component: 'quota', extra_tags: quota_tags),
  dependent_proto(name: 'Quota {#QUOTATYPE} {#QUOTATARGET}: Files hard-limit used', key: quota_files_hard_percent_key, master: quota_master_key,
                  preprocessing: quota_value.call('r.files && r.files.used ? r.files.used.hard_limit_percent : 0'), component: 'quota', value_type: 'FLOAT', units: '%', triggers: quota_files_hard_triggers, extra_tags: quota_tags),
  dependent_proto(name: 'Quota {#QUOTATYPE} {#QUOTATARGET}: Files soft-limit used', key: quota_files_soft_percent_key, master: quota_master_key,
                  preprocessing: quota_value.call('r.files && r.files.used ? r.files.used.soft_limit_percent : 0'), component: 'quota', value_type: 'FLOAT', units: '%', triggers: [quota_files_soft_trigger], extra_tags: quota_tags)
]

quota_discovery_script = <<~JS
  var data = JSON.parse(value);
  var records = data.records || [];
  var result = [];

  function joinedNames(entries) {
    var names = [];
    entries = entries || [];
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i] || {};
      names.push(String(entry.name || entry.id || 'unknown'));
    }
    return names.join(', ');
  }

  for (var index = 0; index < records.length; index++) {
    var r = records[index] || {};
    if (!r.volume || !r.volume.uuid || r.index === undefined || r.index === null) continue;
    var type = String(r.type || 'unknown');
    var target = 'unknown';
    if (type === 'user') target = joinedNames(r.users);
    else if (type === 'group') target = r.group ? String(r.group.name || r.group.id || 'unknown') : 'unknown';
    else if (type === 'tree') target = r.qtree ? String(r.qtree.name || r.qtree.id || 'unknown') : 'unknown';
    if (!target) target = 'unknown';
    var qtree = r.qtree && r.qtree.name ? String(r.qtree.name) : 'volume';
    result.push({
      "{#QUOTAID}": String(r.volume.uuid).replace(/-/g, '') + '_' + String(r.index),
      "{#QUOTAINDEX}": String(r.index),
      "{#QUOTATYPE}": type,
      "{#QUOTATARGET}": target,
      "{#QUOTASCOPE}": qtree,
      "{#QTREENAME}": qtree,
      "{#VOLUMEUUID}": String(r.volume.uuid),
      "{#VOLUMENAME}": String(r.volume.name || 'unknown'),
      "{#SVMNAME}": r.svm ? String(r.svm.name || 'unknown') : 'unknown'
    });
  }
  return JSON.stringify(result);
JS

quota_rule = dependent_discovery(
  name: 'Effective quotas discovery', key: 'netapp.quotas.discovery', master: quota_master_key,
  preprocessing: javascript(quota_discovery_script), prototypes: quota_prototypes
)
quota_rule['filter'] = {
  'evaltype' => 'AND',
  'conditions' => [
    { 'macro' => '{#VOLUMENAME}', 'value' => '{$NETAPP.QUOTA.VOLUME.MATCHES}', 'formulaid' => 'A' },
    { 'macro' => '{#VOLUMENAME}', 'value' => '{$NETAPP.QUOTA.VOLUME.NOT_MATCHES}', 'operator' => 'NOT_MATCHES_REGEX', 'formulaid' => 'B' },
    { 'macro' => '{#QUOTATYPE}', 'value' => '{$NETAPP.QUOTA.TYPE.MATCHES}', 'formulaid' => 'C' }
  ]
}
quota_rule['enabled_lifetime_type'] = 'DISABLE_IMMEDIATELY'
quota_rule['lifetime_type'] = 'DELETE_AFTER'
quota_rule['lifetime'] = '1d'
discoveries << quota_rule

# User macros. Existing password macro is kept secret and has no value.
macros = template.fetch('macros')
password_macro = macros.find { |entry| entry['macro'] == '{$NETAPP.PASSWORD}' }
password_macro.delete('value')
password_macro['type'] = 'SECRET_TEXT'
macros.find { |entry| entry['macro'] == '{$NETAPP.HTTP.AGENT.TIMEOUT}' }['value'] = '15s'
macros.concat([
  { 'macro' => '{$NETAPP.API.MAX.RECORDS}', 'value' => '1000', 'description' => 'Maximum records per ONTAP collection request.' },
  { 'macro' => '{$NETAPP.SHELF.TIMEOUT}', 'value' => '30s', 'description' => 'Timeout for the heavier shelf/sensor collection.' },
  { 'macro' => '{$NETAPP.AUTOSUPPORT.TIMEOUT}', 'value' => '30s', 'description' => 'AutoSupport connectivity check can take about 10 seconds.' },
  { 'macro' => '{$NETAPP.CPU.UTIL.CRIT}', 'value' => '90' },
  { 'macro' => '{$NETAPP.CPU.UTIL.RECOVERY}', 'value' => '80' },
  { 'macro' => '{$NETAPP.PORT.UTIL.CRIT}', 'value' => '85' },
  { 'macro' => '{$NETAPP.PORT.UTIL.RECOVERY}', 'value' => '75' },
  { 'macro' => '{$NETAPP.ETH.PORT.ALARM}', 'value' => '1', 'description' => 'Default Ethernet alarm control. Set a contextual host macro such as {$NETAPP.ETH.PORT.ALARM:"node-01/e0c"}=0 to silence only that port.' },
  { 'macro' => '{$NETAPP.ETH.PORT.ENABLED.MATCHES}', 'value' => '^1$', 'description' => 'Regex for administrative state in Ethernet discovery. Default discovers only ports with enabled=true.' },
  { 'macro' => '{$NETAPP.ETH.PORT.MATCHES}', 'value' => '.*', 'description' => 'Regex of node/port identifiers included in Ethernet discovery.' },
  { 'macro' => '{$NETAPP.ETH.PORT.NOT_MATCHES}', 'value' => '^$', 'description' => 'Regex of node/port identifiers excluded from Ethernet discovery; example: ^(node-01/e0c|node-02/e0d)$.' },
  { 'macro' => '{$NETAPP.DISK.LIFE.USED.CRIT}', 'value' => '90' },
  { 'macro' => '{$NETAPP.DISK.LIFE.USED.RECOVERY}', 'value' => '85' },
  { 'macro' => '{$NETAPP.VOLUME.USED.WARN}', 'value' => '80' },
  { 'macro' => '{$NETAPP.VOLUME.USED.CRIT}', 'value' => '90' },
  { 'macro' => '{$NETAPP.VOLUME.USED.RECOVERY}', 'value' => '75' },
  { 'macro' => '{$NETAPP.AGGREGATE.USED.WARN}', 'value' => '80' },
  { 'macro' => '{$NETAPP.AGGREGATE.USED.CRIT}', 'value' => '90' },
  { 'macro' => '{$NETAPP.AGGREGATE.USED.RECOVERY}', 'value' => '75' },
  { 'macro' => '{$NETAPP.SNAPMIRROR.LAG.CRIT}', 'value' => '86400', 'description' => 'Critical lag in seconds.' },
  { 'macro' => '{$NETAPP.SNAPMIRROR.LAG.RECOVERY}', 'value' => '43200', 'description' => 'Recovery lag in seconds.' },
  { 'macro' => '{$NETAPP.EMS.MAX.RECORDS}', 'value' => '100' },
  { 'macro' => '{$NETAPP.EMS.WINDOW}', 'value' => '900', 'description' => 'Freshness window for emergency/alert/error EMS events, in seconds.' },
  { 'macro' => '{$NETAPP.FSA.VOLUME.MATCHES}', 'value' => '^$', 'description' => 'Regex of RW online volumes queried by FSA. Empty selection by default; configure it at host level before enabling FSA collection.' },
  { 'macro' => '{$NETAPP.FSA.VOLUME.NOT_MATCHES}', 'value' => '^$', 'description' => 'Regex of volumes excluded from recursive FSA discovery.' },
  { 'macro' => '{$NETAPP.FSA.MAX.DEPTH}', 'value' => '1', 'description' => 'Maximum recursive directory depth. Root is 0; value 1 collects only the first-level person/project folders.' },
  { 'macro' => '{$NETAPP.FSA.MAX.DIRECTORIES}', 'value' => '5000', 'description' => 'Safety cap for directories returned by one recursive collection.' },
  { 'macro' => '{$NETAPP.FSA.INACTIVE.WARN.DAYS}', 'value' => '365', 'description' => 'Warning threshold in days with neither data access nor data modification.' },
  { 'macro' => '{$NETAPP.FSA.INACTIVE.CRIT.DAYS}', 'value' => '1095', 'description' => 'High-severity threshold in days with neither data access nor data modification.' },
  { 'macro' => '{$NETAPP.FSA.PAGE.SIZE}', 'value' => '1000', 'description' => 'Maximum records requested per ONTAP files API page.' },
  { 'macro' => '{$NETAPP.FSA.DIRECTORY.DELAY}', 'value' => '6h', 'description' => 'Interval for the recursive directory tree, which may require many API calls.' },
  { 'macro' => '{$NETAPP.FSA.DIRECTORY.TIMEOUT}', 'value' => '300s', 'description' => 'Zabbix Script timeout for recursive FSA collection (maximum supported: 600s).' },
  { 'macro' => '{$NETAPP.FSA.TOP.N}', 'value' => '20' },
  { 'macro' => '{$NETAPP.FSA.MAX.RECORDS}', 'value' => '200' },
  { 'macro' => '{$NETAPP.FSA.DELAY}', 'value' => '1h' },
  { 'macro' => '{$NETAPP.FSA.TIMEOUT}', 'value' => '60s' },
  { 'macro' => '{$NETAPP.QUOTA.DELAY}', 'value' => '15m', 'description' => 'Interval for effective quota report collection.' },
  { 'macro' => '{$NETAPP.QUOTA.TIMEOUT}', 'value' => '30s', 'description' => 'Timeout for quota report collection.' },
  { 'macro' => '{$NETAPP.QUOTA.MAX.RECORDS}', 'value' => '5000', 'description' => 'Maximum effective quota records requested in one REST response.' },
  { 'macro' => '{$NETAPP.QUOTA.VOLUME.MATCHES}', 'value' => '^$', 'description' => 'Regex of volume names whose effective quotas are discovered. Empty selection by default; configure it at host level.' },
  { 'macro' => '{$NETAPP.QUOTA.VOLUME.NOT_MATCHES}', 'value' => '^$', 'description' => 'Regex of volume names excluded from effective quota discovery.' },
  { 'macro' => '{$NETAPP.QUOTA.TYPE.MATCHES}', 'value' => '^(user|group|tree)$', 'description' => 'Effective quota types included in discovery.' },
  { 'macro' => '{$NETAPP.QUOTA.USED.WARN}', 'value' => '80', 'description' => 'Warning percentage of a hard space or file quota.' },
  { 'macro' => '{$NETAPP.QUOTA.USED.CRIT}', 'value' => '90', 'description' => 'High-severity percentage of a hard space or file quota.' }
])

# Sort only the appended macros; keep all object order intact for a readable Zabbix export.
template['macros'] = macros.sort_by { |entry| entry['macro'] }

# Global graphs live beside `templates` in a Zabbix export, not inside the
# template object. Rename their host references too and give them fresh UUIDs.
global_graphs = data.fetch('zabbix_export').fetch('graphs', [])
deep_replace(global_graphs)
add_value_context_to_alarms!(template)
remap_template_uuids!(template)
remap_template_uuids!(global_graphs, 'global-graphs')

FileUtils.mkdir_p(File.dirname(OUTPUT))
File.write(OUTPUT, YAML.dump(data).sub(/\A---\s*\n/, ''))
puts OUTPUT
