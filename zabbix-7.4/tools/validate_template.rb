#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'
require 'open3'
require 'json'
require 'time'

root = File.expand_path('..', __dir__)
output_path = File.join(root, 'template', 'template_netapp_ontap_complete_http.yaml')
source_path = File.join(__dir__, 'source', 'official_netapp_aff_a700_http.yaml')

data = YAML.safe_load(File.read(output_path), aliases: true)
source = YAML.safe_load(File.read(source_path), aliases: true)
template = data.fetch('zabbix_export').fetch('templates').first
source_template = source.fetch('zabbix_export').fetch('templates').first
global_graphs = data.fetch('zabbix_export').fetch('graphs', [])
source_global_graphs = source.fetch('zabbix_export').fetch('graphs', [])

raise 'Unexpected export version' unless data.dig('zabbix_export', 'version') == '7.4'
raise 'Unexpected template name' unless template['template'] == 'NetApp ONTAP Complete by HTTP'

def collect_values(node, key, values = [])
  case node
  when Hash
    values << node[key] if node.key?(key)
    node.each_value { |value| collect_values(value, key, values) }
  when Array
    node.each { |value| collect_values(value, key, values) }
  end
  values
end

uuids = collect_values([template, global_graphs], 'uuid')
raise 'Duplicate UUIDs in output' unless uuids.uniq.length == uuids.length

invalid_v4_uuids = uuids.reject { |uuid| uuid.match?(/\A[0-9a-f]{12}4[0-9a-f]{3}[89ab][0-9a-f]{15}\z/) }
raise "Invalid UUIDv4 values: #{invalid_v4_uuids.join(', ')}" unless invalid_v4_uuids.empty?

source_uuids = collect_values([source_template, source_global_graphs], 'uuid')
overlap = uuids & source_uuids
raise "UUID collision with official template: #{overlap.join(', ')}" unless overlap.empty?

password_macro = template.fetch('macros').find { |macro| macro['macro'] == '{$NETAPP.PASSWORD}' }
raise 'Password macro missing' unless password_macro
raise 'Password macro is not secret' unless password_macro['type'] == 'SECRET_TEXT'
raise 'Password macro contains a value' if password_macro.key?('value')

fsa_volume_macro = template.fetch('macros').find { |macro| macro['macro'] == '{$NETAPP.FSA.VOLUME.MATCHES}' }
raise 'FSA volume discovery must be opt-in by default' unless fsa_volume_macro && fsa_volume_macro['value'] == '^$'

macro_values = template.fetch('macros').to_h { |macro| [macro['macro'], macro['value']] }
%w[{$NETAPP.URL} {$NETAPP.USERNAME} {$NETAPP.PASSWORD}].each do |macro_name|
  raise "Required host macro missing: #{macro_name}" unless template.fetch('macros').any? { |macro| macro['macro'] == macro_name }
end
raise 'Default Ethernet alarm control must be enabled' unless macro_values['{$NETAPP.ETH.PORT.ALARM}'] == '1'
raise 'Ethernet discovery must select only administratively enabled ports by default' unless macro_values['{$NETAPP.ETH.PORT.ENABLED.MATCHES}'] == '^1$'
raise 'Ethernet discovery include filter must select all by default' unless macro_values['{$NETAPP.ETH.PORT.MATCHES}'] == '.*'
raise 'Ethernet discovery exclude filter must exclude nothing by default' unless macro_values['{$NETAPP.ETH.PORT.NOT_MATCHES}'] == '^$'
raise 'FSA must stop at first-level directories by default' unless macro_values['{$NETAPP.FSA.MAX.DEPTH}'] == '1'
raise 'FSA directory safety limit mismatch' unless macro_values['{$NETAPP.FSA.MAX.DIRECTORIES}'] == '5000'
raise 'FSA one-year warning threshold mismatch' unless macro_values['{$NETAPP.FSA.INACTIVE.WARN.DAYS}'] == '365'
raise 'FSA three-year high threshold mismatch' unless macro_values['{$NETAPP.FSA.INACTIVE.CRIT.DAYS}'] == '1095'
raise 'Quota volume discovery must be opt-in by default' unless macro_values['{$NETAPP.QUOTA.VOLUME.MATCHES}'] == '^$'
raise 'Quota type filter mismatch' unless macro_values['{$NETAPP.QUOTA.TYPE.MATCHES}'] == '^(user|group|tree)$'
raise 'Quota warning threshold mismatch' unless macro_values['{$NETAPP.QUOTA.USED.WARN}'] == '80'
raise 'Quota high threshold mismatch' unless macro_values['{$NETAPP.QUOTA.USED.CRIT}'] == '90'

all_objects = []
walker = lambda do |node|
  case node
  when Hash
    all_objects << node
    node.each_value { |value| walker.call(value) }
  when Array
    node.each { |value| walker.call(value) }
  end
end
walker.call([template, global_graphs])

ethernet_discovery = all_objects.find { |object| object['key'] == 'netapp.ports.ether.discovery' && object.key?('uuid') }
raise 'Ethernet discovery missing' unless ethernet_discovery
ethernet_conditions = ethernet_discovery.dig('filter', 'conditions') || []
raise 'Ethernet discovery include filter missing' unless ethernet_conditions.any? do |condition|
  condition['macro'] == '{#ETHPORTID}' && condition['value'] == '{$NETAPP.ETH.PORT.MATCHES}'
end
raise 'Ethernet discovery exclude filter missing' unless ethernet_conditions.any? do |condition|
  condition['macro'] == '{#ETHPORTID}' && condition['value'] == '{$NETAPP.ETH.PORT.NOT_MATCHES}' && condition['operator'] == 'NOT_MATCHES_REGEX'
end
raise 'Ethernet administrative-state discovery filter missing' unless ethernet_conditions.any? do |condition|
  condition['macro'] == '{#ETHPORTENABLED}' && condition['value'] == '{$NETAPP.ETH.PORT.ENABLED.MATCHES}'
end
raise 'Lost Ethernet ports must be disabled immediately' unless ethernet_discovery['enabled_lifetime_type'] == 'DISABLE_IMMEDIATELY'
raise 'Lost Ethernet ports must be deleted after one day' unless ethernet_discovery['lifetime_type'] == 'DELETE_AFTER' && ethernet_discovery['lifetime'] == '1d'

ethernet_alarm_context = '{$NETAPP.ETH.PORT.ALARM:"{#NODENAME}/{#ETHPORTNAME}"}'
ethernet_alarms = all_objects.select { |object| object['expression'].to_s.include?("/#{template['template']}/netapp.port.eth.") }
raise 'Expected Ethernet alarms are missing' unless ethernet_alarms.length >= 4
ethernet_alarms.each do |alarm|
  raise "Ethernet alarm lacks contextual control: #{alarm['name']}" unless alarm['expression'].include?(ethernet_alarm_context)
  raise "Ethernet alarm ignores administrative state: #{alarm['name']}" unless alarm['expression'].include?('netapp.port.eth.enabled[')
end

javascript_steps = all_objects.flat_map do |object|
  Array(object['preprocessing']).select { |step| step['type'] == 'JAVASCRIPT' }
end
script_items = all_objects.select { |object| object['type'] == 'SCRIPT' && object['params'].is_a?(String) }
javascript_sources = javascript_steps.map { |step| ['preprocessing', step.fetch('parameters').first] } +
                     script_items.map { |item| ["script item #{item['key']}", item.fetch('params')] }

forbidden = {
  'optional chaining' => /\?\./,
  'nullish coalescing' => /\?\?/,
  'arrow function' => /=>/,
  'let declaration' => /(^|[;{}\s])let\s+/,
  'const declaration' => /(^|[;{}\s])const\s+/
}

javascript_sources.each_with_index do |(kind, script), index|
  forbidden.each do |name, pattern|
    raise "JavaScript #{index + 1} (#{kind}) uses #{name}" if script.match?(pattern)
  end
  _stdout, stderr, status = Open3.capture3('node', '--check', '-', stdin_data: "function zabbixPreprocessing(value) {\n#{script}\n}\n")
  raise "JavaScript #{index + 1} (#{kind}) does not parse: #{stderr}" unless status.success?
end

def execute_preprocessing(script, value)
  source = <<~JS
    var value = #{JSON.generate(value)};
    var result = (function (value) {
    #{script}
    }(value));
    process.stdout.write(JSON.stringify(result));
  JS
  stdout, stderr, status = Open3.capture3('node', '-e', source)
  raise "JavaScript runtime error: #{stderr}" unless status.success?
  JSON.parse(stdout)
end

ethernet_lld_script = ethernet_discovery.fetch('preprocessing').first.fetch('parameters').first
ethernet_lld_value = JSON.generate('records' => [
  { 'node' => { 'name' => 'node-01' }, 'name' => 'e0a', 'uuid' => 'enabled-fixture', 'type' => 'physical', 'enabled' => true,
    'broadcast_domain' => { 'name' => 'data' },
    'reachable_broadcast_domains' => [{ 'name' => 'data' }, { 'name' => 'management' }] },
  { 'node' => { 'name' => 'node-01' }, 'name' => 'e0c', 'uuid' => 'disabled-fixture', 'type' => 'physical', 'enabled' => false }
])
ethernet_lld_rows = JSON.parse(execute_preprocessing(ethernet_lld_script, ethernet_lld_value))
raise 'Ethernet node/port LLD identifier failed' unless ethernet_lld_rows.dig(0, '{#ETHPORTID}') == 'node-01/e0a'
raise 'Ethernet enabled-state normalization failed' unless ethernet_lld_rows.dig(0, '{#ETHPORTENABLED}') == '1' && ethernet_lld_rows.dig(1, '{#ETHPORTENABLED}') == '0'
raise 'Ethernet expected broadcast-domain LLD failed' unless ethernet_lld_rows.dig(0, '{#ETHBROADCASTDOMAIN}') == 'data'
raise 'Ethernet reachable broadcast-domains LLD failed' unless ethernet_lld_rows.dig(0, '{#ETHREACHABLEDOMAINS}') == 'data, management'

ethernet_speed_item = all_objects.find { |object| object['key'] == 'netapp.port.eth.speed[{#NODENAME},{#ETHPORTNAME}]' && object.key?('uuid') }
raise 'Ethernet effective speed item missing' unless ethernet_speed_item
ethernet_speed_script = ethernet_speed_item.fetch('preprocessing').first.fetch('parameters').first
ethernet_speed_fixture = JSON.generate('records' => [
  { 'node' => { 'name' => 'node-01' }, 'name' => 'a0a', 'type' => 'lag', 'speed' => 0,
    'metric' => { 'throughput' => { 'read' => 1_250_000_000, 'write' => 5_000_000_000 } },
    'lag' => { 'active_ports' => [
      { 'node' => { 'name' => 'node-01' }, 'name' => 'e0a' },
      { 'node' => { 'name' => 'node-01' }, 'name' => 'e0b' }
    ] } },
  { 'node' => { 'name' => 'node-01' }, 'name' => 'e0a', 'type' => 'physical', 'speed' => 10_000 },
  { 'node' => { 'name' => 'node-01' }, 'name' => 'e0b', 'type' => 'physical', 'speed' => 10_000 },
  { 'node' => { 'name' => 'node-01' }, 'name' => 'a0a-100', 'type' => 'vlan', 'speed' => 0,
    'vlan' => { 'base_port' => { 'node' => { 'name' => 'node-01' }, 'name' => 'a0a' } } },
  { 'node' => { 'name' => 'node-01' }, 'name' => 'e0z', 'type' => 'physical', 'speed' => 0,
    'metric' => { 'throughput' => { 'read' => 1000, 'write' => 1000 } } }
])
lag_speed_script = ethernet_speed_script.gsub('{#NODENAME}', 'node-01').gsub('{#ETHPORTNAME}', 'a0a')
raise 'Ethernet LAG effective speed calculation failed' unless execute_preprocessing(lag_speed_script, ethernet_speed_fixture) == 20_000
vlan_speed_script = ethernet_speed_script.gsub('{#NODENAME}', 'node-01').gsub('{#ETHPORTNAME}', 'a0a-100')
raise 'Ethernet VLAN effective speed calculation failed' unless execute_preprocessing(vlan_speed_script, ethernet_speed_fixture) == 20_000

ethernet_utilization_items = all_objects.select { |object| object['key'].to_s.start_with?('netapp.port.eth.utilization.') && object['type'] == 'DEPENDENT' }
raise 'Ethernet utilization dependent items missing' unless ethernet_utilization_items.length == 2
ethernet_utilization_items.each do |item|
  utilization_script = item.fetch('preprocessing').first.fetch('parameters').first
  lag_utilization_script = utilization_script.gsub('{#NODENAME}', 'node-01').gsub('{#ETHPORTNAME}', 'a0a')
  expected = item['key'].include?('.read[') ? 50 : 100
  raise "Ethernet utilization calculation/cap failed: #{item['key']}" unless execute_preprocessing(lag_utilization_script, ethernet_speed_fixture) == expected
  unknown_utilization_script = utilization_script.gsub('{#NODENAME}', 'node-01').gsub('{#ETHPORTNAME}', 'e0z')
  raise "Ethernet utilization does not suppress unknown capacity: #{item['key']}" unless execute_preprocessing(unknown_utilization_script, ethernet_speed_fixture).zero?
end

ethernet_utilization_alarm = ethernet_alarms.find { |alarm| alarm['name'].to_s.include?('alta utilização') }
raise 'Ethernet utilization alarm lacks capacity guard' unless ethernet_utilization_alarm && ethernet_utilization_alarm['expression'].include?('netapp.port.eth.speed[')
raise 'Ethernet utilization alarm must require sustained utilization' unless ethernet_utilization_alarm['expression'].include?('min(')
raise 'Ethernet utilization recovery must use current values' unless ethernet_utilization_alarm['recovery_expression'].include?('last(')

ethernet_reachability_alarm = ethernet_alarms.find { |alarm| alarm['expression'].to_s.include?('netapp.port.eth.reachability[') }
raise 'Ethernet Layer-2 topology alarm missing' unless ethernet_reachability_alarm
raise 'Ethernet topology alarm must cover every non-ok diagnostic' unless ethernet_reachability_alarm['expression'].include?('<>"ok"')
raise 'Ethernet topology alarm must not classify a down link as a topology-only event' unless ethernet_reachability_alarm['expression'].include?('netapp.port.eth.state[') && ethernet_reachability_alarm['expression'].include?('="up"')
raise 'Ethernet topology alarm has a misleading availability name' if ethernet_reachability_alarm['name'].include?('sem alcance')
raise 'Ethernet topology event lacks expected broadcast domain' unless ethernet_reachability_alarm['event_name'].include?('{#ETHBROADCASTDOMAIN}')
raise 'Ethernet topology event lacks reachable broadcast domains' unless ethernet_reachability_alarm['event_name'].include?('{#ETHREACHABLEDOMAINS}')

fsa_object = all_objects.find { |object| object['key'].to_s.start_with?('netapp.fsa.level1.top[') }
fsa_script = fsa_object.fetch('preprocessing').first.fetch('parameters').first.gsub('{$NETAPP.FSA.TOP.N}', '2')
fsa_value = JSON.generate('records' => [
  { 'name' => '.', 'analytics' => { 'bytes_used' => 10, 'file_count' => 1, 'subdir_count' => 1 } },
  { 'name' => './small', 'analytics' => { 'bytes_used' => 100, 'file_count' => 5, 'subdir_count' => 0 } },
  { 'name' => './large', 'analytics' => { 'bytes_used' => 1000, 'file_count' => 8, 'subdir_count' => 2 } }
])
fsa_result = execute_preprocessing(fsa_script, fsa_value)
raise 'FSA top-N runtime test failed' unless fsa_result.start_with?('1 - ./large') && !fsa_result.include?("1 - . |")

fsa_recursive_object = all_objects.find { |object| object['key'] == 'netapp.fsa.directories.get' && object['type'] == 'SCRIPT' }
fsa_recursive_script = fsa_recursive_object.fetch('params')
fsa_recursive_params = JSON.generate(
  'url' => 'https://cluster.example',
  'username' => 'monitor',
  'password' => 'fixture-only',
  'volume_matches' => '^(data|skip)$',
  'volume_not_matches' => '^skip$',
  'max_depth' => '2',
  'max_directories' => '10',
  'page_size' => '1000'
)
recent_fsa_label = Time.now.utc.strftime('%Y-%m')
recent_fsa_access_time = Time.now.utc.strftime('%Y-%m-10T12:00:00Z')
fsa_mock = <<~JS
  var HTTPAUTH_BASIC = 0;
  function HttpRequest() { this.status = 200; }
  HttpRequest.prototype.addHeader = function () {};
  HttpRequest.prototype.setHttpAuth = function () {};
  HttpRequest.prototype.getStatus = function () { return this.status; };
  HttpRequest.prototype.get = function (url) {
    this.status = 200;
    if (url.indexOf('/api/storage/volumes?') !== -1) {
      return JSON.stringify({records:[
        {name:'data',uuid:'11111111-2222-3333-4444-555555555555',type:'rw',state:'online',svm:{name:'svm1'}},
        {name:'skip',uuid:'99999999-2222-3333-4444-555555555555',type:'rw',state:'online',svm:{name:'svm1'}}
      ]});
    }
    if (url.indexOf('/files/%2E?') !== -1) {
      return JSON.stringify({records:[{
        name:'projects',path:'./projects',type:'directory',bytes_used:4096,accessed_time:'#{recent_fsa_access_time}',modified_time:'2021-06-09T08:00:00Z',
        analytics:{bytes_used:5096,file_count:10,subdir_count:1,
          by_accessed_time:{bytes_used:{newest_label:'#{recent_fsa_label}',values:[4096,1000,1000,0]}},
          by_modified_time:{bytes_used:{newest_label:'#{recent_fsa_label}',values:[0,1000,1000,0]}}}
      }],analytics:{
        by_accessed_time:{bytes_used:{newest_label:'#{recent_fsa_label}',labels:['#{recent_fsa_label}','2022-Q4','2022','unknown']}},
        by_modified_time:{bytes_used:{newest_label:'#{recent_fsa_label}',labels:['#{recent_fsa_label}','2020-05--2021-Q2','2021','unknown']}}
      },_links:{next:{href:'/api/fsa-root-page-2'}}});
    }
    if (url.indexOf('/api/fsa-root-page-2') !== -1) {
      return JSON.stringify({records:[
        {name:'logs',path:'./logs',type:'directory',analytics:{bytes_used:200,file_count:2,subdir_count:0}},
        {name:'recent-access',path:'./recent-access',type:'directory',bytes_used:4096,accessed_time:'#{recent_fsa_access_time}',analytics:{bytes_used:8192,file_count:3,subdir_count:0,
          by_accessed_time:{bytes_used:{newest_label:'#{recent_fsa_label}',values:[8192,0,0,0]}},
          by_modified_time:{bytes_used:{newest_label:'#{recent_fsa_label}',values:[0,0,300,0]}}}},
        {name:'.snapshot',path:'./.snapshot',type:'directory',analytics:{bytes_used:0,file_count:0,subdir_count:0}}
      ],analytics:{
        by_accessed_time:{bytes_used:{newest_label:'#{recent_fsa_label}',labels:['#{recent_fsa_label}','2022-Q4','2022','unknown']}},
        by_modified_time:{bytes_used:{newest_label:'#{recent_fsa_label}',labels:['#{recent_fsa_label}','2020-05--2021-Q2','2010','unknown']}}
      }});
    }
    if (url.indexOf('/files/projects?') !== -1) {
      return JSON.stringify({records:[{name:'archive',path:'./projects/archive',type:'directory',analytics:{bytes_used:600,file_count:6,subdir_count:0}}]});
    }
    if (url.indexOf('/files/logs?') !== -1) return JSON.stringify({records:[]});
    if (url.indexOf('/files/recent-access?') !== -1) return JSON.stringify({records:[]});
    this.status = 404;
    return JSON.stringify({error:{message:'fixture route not found'}});
  };
JS
fsa_recursive_source = <<~JS
  #{fsa_mock}
  var value = #{JSON.generate(fsa_recursive_params)};
  var output = (function (value) {
  #{fsa_recursive_script}
  }(value));
  process.stdout.write(output);
JS
fsa_recursive_stdout, fsa_recursive_stderr, fsa_recursive_status = Open3.capture3('node', '-e', fsa_recursive_source)
raise "FSA recursive runtime error: #{fsa_recursive_stderr}" unless fsa_recursive_status.success?
fsa_recursive_result = JSON.parse(fsa_recursive_stdout)
raise "FSA recursive fixture returned error: #{fsa_recursive_result['error']}" unless fsa_recursive_result['error'].empty?
raise 'FSA recursive volume filtering failed' unless fsa_recursive_result.dig('stats', 'selected_volumes') == 1
raise 'FSA recursive pagination/depth failed' unless fsa_recursive_result['records'].map { |record| record['path'] }.sort == %w[/logs /projects /projects/archive /recent-access]
raise 'FSA special snapshot directory must be excluded' if fsa_recursive_result['records'].any? { |record| record['path'] == '/.snapshot' }
archive = fsa_recursive_result['records'].find { |record| record['path'] == '/projects/archive' }
raise 'FSA recursive hierarchy failed' unless archive['parent_path'] == '/projects' && archive['depth'] == 2
projects = fsa_recursive_result['records'].find { |record| record['path'] == '/projects' }
raise 'FSA exact timestamp conversion failed' unless projects['accessed_epoch'] == Time.parse(recent_fsa_access_time).to_i
raise 'FSA analytics runtime fixture failed' unless projects['bytes_used'] == 5096 && projects['accessed_newest_label'] == '2022-Q4'
raise 'FSA collector still mistakes newest_label for populated data' if projects['accessed_newest_label'] == recent_fsa_label
raise 'FSA directory inode bytes were not removed from the access bucket' unless projects['accessed_bucket_inode_bytes_removed'] == 4096
raise 'FSA quarter-label conversion failed' unless projects['accessed_data_period_end_epoch'] == Time.utc(2022, 12, 31, 23, 59, 59).to_i
raise 'FSA interval-label conversion failed' unless projects['modified_data_period_end_epoch'] == Time.utc(2021, 6, 30, 23, 59, 59).to_i
raise 'FSA inactivity must use the newest of access and modification' unless projects['inactivity_reference_epoch'] == projects['accessed_data_period_end_epoch']
raise 'FSA inactivity age calculation failed' unless projects['inactivity_days'] >= 1095
logs = fsa_recursive_result['records'].find { |record| record['path'] == '/logs' }
raise 'FSA unknown analytics must not create inactivity' unless logs['inactivity_days'] == 0 && logs['inactivity_reference_epoch'] == 0
recent_access = fsa_recursive_result['records'].find { |record| record['path'] == '/recent-access' }
raise 'FSA recent access must suppress old-modification inactivity' unless recent_access['inactivity_days'] == 0 && recent_access['modified_data_period_end_epoch'] < recent_access['accessed_data_period_end_epoch']

fsa_inactive_bytes_item = all_objects.find do |object|
  object['key'] == 'netapp.fsa.inactive.bytes.total' && object.key?('uuid')
end
raise 'FSA inactive-directory total-space item missing' unless fsa_inactive_bytes_item
raise 'FSA inactive-directory total-space item must have no trigger' unless Array(fsa_inactive_bytes_item['triggers']).empty?
raise 'FSA inactive-directory total-space item must use byte units' unless fsa_inactive_bytes_item['units'] == 'B'
fsa_inactive_bytes_script = fsa_inactive_bytes_item.fetch('preprocessing').first.fetch('parameters').first
fsa_inactive_bytes_script = fsa_inactive_bytes_script.gsub('{$NETAPP.FSA.INACTIVE.WARN.DAYS}', '365')
fsa_inactive_bytes_fixture = JSON.generate('records' => [
  { 'volume_uuid' => 'vol-a', 'path' => '/people', 'depth' => 1, 'bytes_used' => 5000, 'inactivity_days' => 400 },
  { 'volume_uuid' => 'vol-a', 'path' => '/people/archive', 'depth' => 2, 'bytes_used' => 1000, 'inactivity_days' => 500 },
  { 'volume_uuid' => 'vol-a', 'path' => '/active', 'depth' => 1, 'bytes_used' => 2000, 'inactivity_days' => 100 },
  { 'volume_uuid' => 'vol-a', 'path' => '/unknown', 'depth' => 1, 'bytes_used' => 9000, 'inactivity_days' => 0 },
  { 'volume_uuid' => 'vol-b', 'path' => '/projects', 'depth' => 1, 'bytes_used' => 3000, 'inactivity_days' => 365 }
])
raise 'FSA inactive-directory total-space calculation or overlap removal failed' unless execute_preprocessing(fsa_inactive_bytes_script, fsa_inactive_bytes_fixture) == 8000

quota_master = all_objects.find { |object| object['key'] == 'netapp.quotas.get' && object['type'] == 'HTTP_AGENT' }
raise 'Effective quota report master item missing' unless quota_master
raise 'Quota report must exclude generic default records' unless quota_master['url'].include?('show_default_records=false')
raise 'Quota report must request effective percentage fields' unless quota_master['url'].include?('space.used.hard_limit_percent') && quota_master['url'].include?('files.used.hard_limit_percent')

quota_discovery = all_objects.find { |object| object['key'] == 'netapp.quotas.discovery' && object.key?('uuid') }
raise 'Effective quota discovery missing' unless quota_discovery
quota_discovery_script = quota_discovery.fetch('preprocessing').first.fetch('parameters').first
quota_fixture = JSON.generate('records' => [
  {
    'index' => 7, 'type' => 'user', 'svm' => { 'name' => 'svm1' },
    'volume' => { 'name' => 'user-data', 'uuid' => 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' },
    'users' => [{ 'id' => '1001', 'name' => 'alice' }],
    'space' => { 'hard_limit' => 1_000_000, 'soft_limit' => 900_000,
                 'used' => { 'total' => 920_000, 'hard_limit_percent' => 92, 'soft_limit_percent' => 102 } },
    'files' => { 'hard_limit' => nil, 'soft_limit' => nil,
                 'used' => { 'total' => 10_000, 'hard_limit_percent' => nil, 'soft_limit_percent' => nil } }
  },
  {
    'index' => 8, 'type' => 'tree', 'svm' => { 'name' => 'svm1' },
    'volume' => { 'name' => 'project-data', 'uuid' => 'ffffffff-eeee-4ddd-8ccc-bbbbbbbbbbbb' },
    'qtree' => { 'id' => 3, 'name' => 'project-x' }
  }
])
quota_lld = JSON.parse(execute_preprocessing(quota_discovery_script, quota_fixture))
quota_user = quota_lld.find { |row| row['{#QUOTATYPE}'] == 'user' }
raise 'Quota user target discovery failed' unless quota_user && quota_user['{#QUOTATARGET}'] == 'alice' && quota_user['{#QUOTASCOPE}'] == 'volume'
raise 'Quota discovery ID is not item-key safe' unless quota_user['{#QUOTAID}'].match?(/\A[0-9a-f]+_\d+\z/)
quota_tree = quota_lld.find { |row| row['{#QUOTATYPE}'] == 'tree' }
raise 'Quota qtree target discovery failed' unless quota_tree && quota_tree['{#QUOTATARGET}'] == 'project-x' && quota_tree['{#QUOTASCOPE}'] == 'project-x'

quota_space_percent = all_objects.find { |object| object['key'] == 'netapp.quota.space.hard_limit.percent[{#QUOTAID}]' && object.key?('uuid') }
raise 'Quota space hard-limit percentage item missing' unless quota_space_percent
quota_space_percent_script = quota_space_percent.fetch('preprocessing').first.fetch('parameters').first
quota_space_percent_script = quota_space_percent_script.gsub('{#QUOTAINDEX}', '7').gsub('{#VOLUMEUUID}', 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee')
raise 'Quota effective percentage preprocessing failed' unless execute_preprocessing(quota_space_percent_script, quota_fixture) == 92
quota_null_fixture = JSON.generate('records' => [{
  'index' => 7, 'volume' => { 'uuid' => 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' },
  'space' => { 'used' => { 'hard_limit_percent' => nil } }
}])
raise 'Unlimited quota must preprocess to zero' unless execute_preprocessing(quota_space_percent_script, quota_null_fixture) == 0

shelf_object = all_objects.find { |object| object['key'] == 'netapp.shelf.frus.json' && object.key?('uuid') }
shelf_script = shelf_object.fetch('preprocessing').first.fetch('parameters').first
shelf_value = JSON.generate('records' => [
  { 'uid' => '42', 'name' => '1.1', 'frus' => [{ 'id' => 2, 'type' => 'psu', 'state' => 'error', 'installed' => true }] }
])
shelf_result = JSON.parse(execute_preprocessing(shelf_script, shelf_value))
raise 'Shelf PSU flattening runtime test failed' unless shelf_result.dig('records', 0, 'type') == 'psu' && shelf_result.dig('records', 0, 'state') == 'error'

ems_object = all_objects.find { |object| object['key'] == 'netapp.ems.latest.critical' && object.key?('uuid') }
ems_script = ems_object.fetch('preprocessing').first.fetch('parameters').first.gsub('{$NETAPP.EMS.WINDOW}', '900')
ems_value = JSON.generate('records' => [
  { 'time' => Time.now.utc.iso8601, 'node' => { 'name' => 'node-01' }, 'message' => { 'name' => 'callhome.psu.fault', 'severity' => 'error' }, 'log_message' => 'PSU fault' }
])
ems_result = execute_preprocessing(ems_script, ems_value)
raise 'EMS runtime test failed' unless ems_result.include?('callhome.psu.fault')

required_keys = %w[
  netapp.nodes.get
  netapp.aggregates.get
  netapp.aggregate.space.physical.used[{#AGGRUUID}]
  netapp.aggregate.space.physical.used.percent[{#AGGRUUID}]
  netapp.aggregate.space.reserved[{#AGGRUUID}]
  netapp.ports.eth.get
  netapp.shelves.get
  netapp.autosupport.get
  netapp.ems.events.get
  netapp.snapmirror.get
  netapp.fsa.directories.get
  netapp.fsa.inactive.bytes.total
  netapp.fsa.directories.discovery
  netapp.fsa.directory.bytes_used[{#DIRID}]
  netapp.fsa.directory.modified_time[{#DIRID}]
  netapp.fsa.directory.inactivity.reference[{#DIRID}]
  netapp.fsa.directory.inactivity.days[{#DIRID}]
  netapp.volume.quota.state[{#VOLUMEUUID}]
  netapp.quotas.get
  netapp.quotas.count
  netapp.quotas.truncated
  netapp.quotas.discovery
  netapp.quota.space.used[{#QUOTAID}]
  netapp.quota.space.hard_limit[{#QUOTAID}]
  netapp.quota.space.hard_limit.percent[{#QUOTAID}]
  netapp.quota.files.used[{#QUOTAID}]
  netapp.quota.files.hard_limit[{#QUOTAID}]
  netapp.quota.files.hard_limit.percent[{#QUOTAID}]
]
keys = collect_values(template, 'key')
missing = required_keys - keys
raise "Missing required keys: #{missing.join(', ')}" unless missing.empty?

defined_keys = all_objects.select { |object| object.key?('uuid') && object.key?('key') }.map { |object| object['key'] }
duplicate_keys = defined_keys.group_by { |key| key }.select { |_key, matches| matches.length > 1 }.keys
raise "Duplicate object keys: #{duplicate_keys.join(', ')}" unless duplicate_keys.empty?

graph_item_references = all_objects.select { |object| object['graph_items'].is_a?(Array) }.flat_map do |graph|
  graph['graph_items'].map { |graph_item| [graph['name'], graph_item.fetch('item')] }
end
graph_item_references.each do |graph_name, item|
  raise "Graph #{graph_name} references unexpected host: #{item['host']}" unless item['host'] == template['template']
  raise "Graph #{graph_name} references missing key: #{item['key']}" unless defined_keys.include?(item['key'])
end

required_alarm_keys = %w[
  netapp.chassis.fru.state[{#CHASSISID},{#FRUID}]
  netapp.node.power_supply.failed.count[{#NODENAME}]
  netapp.node.fan.failed.count[{#NODENAME}]
  netapp.shelf.fru.state[{#SHELFUID},{#FRUID}]
  netapp.shelf.fan.state[{#SHELFUID},{#SENSORID}]
  netapp.disk.state[{#NODENAME},{#DISKNAME}]
  netapp.disk.rated_life_used[{#NODENAME},{#DISKNAME}]
  netapp.disk.outage.persistently_failed[{#NODENAME},{#DISKNAME}]
  netapp.node.cpu.utilization[{#NODENAME}]
  netapp.aggregate.space.physical.used.percent[{#AGGRUUID}]
  netapp.fsa.directory.inactivity.days[{#DIRID}]
  netapp.quota.space.hard_limit.percent[{#QUOTAID}]
  netapp.quota.files.hard_limit.percent[{#QUOTAID}]
]
required_alarm_keys.each do |key|
  item = all_objects.find { |object| object['key'] == key && object.key?('uuid') }
  raise "Required alarm item missing: #{key}" unless item
  alarms = Array(item['triggers']) + Array(item['trigger_prototypes'])
  raise "Required item has no alarm: #{key}" if alarms.empty?
  alarms.each do |alarm|
    raise "Alarm has no value in event name for #{key}" unless alarm['event_name'].to_s.include?('{ITEM.')
    raise "Alarm has no operational data for #{key}" if alarm['opdata'].to_s.empty?
  end
end

aggregate_committed_item = all_objects.find do |object|
  object['key'] == 'netapp.aggregate.space.used.percent[{#AGGRUUID}]' && object.key?('uuid')
end
raise 'Aggregate committed percentage item missing' unless aggregate_committed_item
raise 'Aggregate committed percentage must be collection-only' unless Array(aggregate_committed_item['trigger_prototypes']).empty?

aggregate_physical_alarm_item = all_objects.find do |object|
  object['key'] == 'netapp.aggregate.space.physical.used.percent[{#AGGRUUID}]' && object.key?('uuid')
end
raise 'Aggregate physical-used alarm item missing' unless aggregate_physical_alarm_item
aggregate_physical_alarms = Array(aggregate_physical_alarm_item['trigger_prototypes'])
raise 'Aggregate physical-used warning/critical alarms missing' unless aggregate_physical_alarms.length == 2
aggregate_physical_alarms.each do |alarm|
  raise 'Aggregate capacity alarm does not use physical-used percentage' unless alarm['expression'].include?('netapp.aggregate.space.physical.used.percent[')
  raise 'Aggregate capacity alarm name does not identify physical usage' unless alarm['name'].include?('uso físico')
end

fsa_inactivity_item = all_objects.find do |object|
  object['key'] == 'netapp.fsa.directory.inactivity.days[{#DIRID}]' && object.key?('uuid')
end
raise 'FSA directory inactivity item missing' unless fsa_inactivity_item
fsa_inactivity_alarms = Array(fsa_inactivity_item['trigger_prototypes'])
raise 'FSA one-year and three-year inactivity alarms missing' unless fsa_inactivity_alarms.length == 2
fsa_warning = fsa_inactivity_alarms.find { |alarm| alarm['priority'] == 'WARNING' }
fsa_high = fsa_inactivity_alarms.find { |alarm| alarm['priority'] == 'HIGH' }
raise 'FSA one-year warning missing' unless fsa_warning && fsa_warning['expression'].include?('{$NETAPP.FSA.INACTIVE.WARN.DAYS}')
raise 'FSA warning must hand over to the three-year alarm' unless fsa_warning['expression'].include?('<{$NETAPP.FSA.INACTIVE.CRIT.DAYS}')
raise 'FSA three-year high-severity alarm missing' unless fsa_high && fsa_high['expression'].include?('{$NETAPP.FSA.INACTIVE.CRIT.DAYS}')
legacy_fsa_accessed_time = all_objects.find do |object|
  object['key'] == 'netapp.fsa.directory.accessed_time[{#DIRID}]' && object.key?('uuid')
end
raise 'Obsolete FSA inode-atime prototype is still exported' if legacy_fsa_accessed_time
fsa_inactivity_alarms.each do |alarm|
  raise 'FSA inactivity alarm does not identify the directory' unless alarm['name'].include?('{#VOLUMENAME}:{#DIRDISPLAY}')
  raise 'FSA inactivity alarm does not include directory size in its expression' unless alarm['expression'].include?('netapp.fsa.directory.bytes_used[{#DIRID}]')
  raise 'FSA inactivity event does not show directory size' unless alarm['event_name'].include?('tamanho: {ITEM.VALUE1}')
  raise 'FSA inactivity event does not show event-time inactivity' unless alarm['event_name'].include?('inatividade: {ITEM.VALUE2}')
  raise 'FSA inactivity event must read the live access-bucket item' unless alarm['event_name'].include?('{?last(//netapp.fsa.directory.accessed_newest_label[{#DIRID}])}')
  raise 'FSA inactivity event must read the live modification-bucket item' unless alarm['event_name'].include?('{?last(//netapp.fsa.directory.modified_newest_label[{#DIRID}])}')
  raise 'FSA inactivity event still uses stale discovery labels' if alarm['event_name'].include?('{#FSAACCESSEDLABEL}') || alarm['event_name'].include?('{#FSAMODIFIEDLABEL}')
end

quota_space_hard_item = all_objects.find do |object|
  object['key'] == 'netapp.quota.space.hard_limit.percent[{#QUOTAID}]' && object.key?('uuid')
end
quota_files_hard_item = all_objects.find do |object|
  object['key'] == 'netapp.quota.files.hard_limit.percent[{#QUOTAID}]' && object.key?('uuid')
end
raise 'Quota hard-limit alarm items missing' unless quota_space_hard_item && quota_files_hard_item
[quota_space_hard_item, quota_files_hard_item].each do |item|
  alarms = Array(item['trigger_prototypes'])
  raise "Quota hard-limit warning/high/full alarms missing for #{item['key']}" unless alarms.length == 3
  raise "Quota hard-limit severities incorrect for #{item['key']}" unless alarms.map { |alarm| alarm['priority'] }.sort == %w[DISASTER HIGH WARNING].sort
  alarms.each do |alarm|
    raise "Quota alarm lacks target context for #{item['key']}" unless alarm['name'].include?('{#QUOTATYPE}') && alarm['name'].include?('{#QUOTATARGET}') && alarm['name'].include?('{#VOLUMENAME}')
    raise "Unlimited quota is not guarded for #{item['key']}" unless alarm['expression'].include?('hard_limit[{#QUOTAID}])>0')
  end
end

quota_space_soft_item = all_objects.find do |object|
  object['key'] == 'netapp.quota.space.soft_limit.percent[{#QUOTAID}]' && object.key?('uuid')
end
quota_files_soft_item = all_objects.find do |object|
  object['key'] == 'netapp.quota.files.soft_limit.percent[{#QUOTAID}]' && object.key?('uuid')
end
[quota_space_soft_item, quota_files_soft_item].each do |item|
  raise 'Quota soft-limit item missing' unless item
  alarms = Array(item['trigger_prototypes'])
  raise "Quota soft-limit alarm missing for #{item['key']}" unless alarms.length == 1
  raise "Quota soft-limit alarm must fire at 100% for #{item['key']}" unless alarms.first['expression'].include?('>=100')
  raise "Unlimited soft quota is not guarded for #{item['key']}" unless alarms.first['expression'].include?('soft_limit[{#QUOTAID}])>0')
end

volume_quota_state = all_objects.find do |object|
  object['key'] == 'netapp.volume.quota.state[{#VOLUMEUUID}]' && object.key?('uuid')
end
raise 'Volume quota-state collection item missing' unless volume_quota_state
raise 'Inactive quotas must not alarm before deployment' unless Array(volume_quota_state['trigger_prototypes']).empty?

chassis_psu_alarm = all_objects.find do |object|
  object['key'] == 'netapp.chassis.fru.state[{#CHASSISID},{#FRUID}]' && object.key?('uuid')
end.fetch('trigger_prototypes').first
raise 'Chassis PSU/FRU alarm must fire for every non-ok state' unless chassis_psu_alarm['expression'].include?('<>"ok"')

shelf_psu_alarm = all_objects.find do |object|
  object['key'] == 'netapp.shelf.fru.state[{#SHELFUID},{#FRUID}]' && object.key?('uuid')
end.fetch('trigger_prototypes').first
raise 'Shelf PSU/FRU alarm must fire for every non-ok state' unless shelf_psu_alarm['expression'].include?('<>"ok"')

alarms_without_context = all_objects.select do |object|
  object['expression'] && object['name'] && !object['expression'].include?('nodata(') &&
    (object['event_name'].to_s.empty? || object['opdata'].to_s.empty?)
end
raise "Alarms without visible value context: #{alarms_without_context.map { |alarm| alarm['name'] }.join(', ')}" unless alarms_without_context.empty?

event_names_with_lastvalue = all_objects.select do |object|
  object['event_name'].to_s.include?('{ITEM.LASTVALUE')
end
raise 'Event names must use ITEM.VALUE; reserve ITEM.LASTVALUE for operational data' unless event_names_with_lastvalue.empty?

expressions = all_objects.flat_map { |object| [object['expression'], object['recovery_expression']] }.compact
expressions.each do |expression|
  references = expression.scan(%r{/NetApp ONTAP Complete by HTTP/([A-Za-z0-9_.-]+(?:\[[^\]]*\])?)}).flatten
  unresolved = references - defined_keys
  raise "Unresolved item key in expression: #{unresolved.join(', ')}" unless unresolved.empty?
end

trigger_prototypes = all_objects.sum { |object| Array(object['trigger_prototypes']).length }
triggers = all_objects.sum { |object| Array(object['triggers']).length }

puts "Template: #{template['template']}"
puts "Items: #{template.fetch('items').length}"
puts "Discovery rules: #{template.fetch('discovery_rules').length}"
puts "Item prototypes: #{template.fetch('discovery_rules').sum { |rule| Array(rule['item_prototypes']).length }}"
puts "Triggers: #{triggers}"
puts "Trigger prototypes: #{trigger_prototypes}"
puts "Graph item references: #{graph_item_references.length} resolved"
puts "Required hardware/resource alarm items: #{required_alarm_keys.length} covered"
puts "Macros: #{template.fetch('macros').length}"
puts "JavaScript sources parsed: #{javascript_sources.length} (#{javascript_steps.length} preprocessing, #{script_items.length} script items)"
puts 'JavaScript runtime fixtures: recursive FSA, inactive FSA total, quota reports, FSA top-N, shelf PSU and EMS passed'
puts "UUIDs: #{uuids.length} unique; zero overlap with official template"
puts 'Validation: OK'
