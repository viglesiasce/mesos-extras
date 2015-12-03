#
# Cookbook Name:: mesos-extras
# Recipe:: default
#
# Copyright (c) 2015 The Authors, All Rights Reserved.
# include_recipe 'collectd'
# directory '/opt/collectd/etc/conf.d'
# include_recipe 'collectd::attribute_driven'

docker_service 'default' do
   host ['unix:///var/run/docker.sock']
   graph '/mnt/docker'
   storage_driver 'overlay'
   insecure_registry 'registry.marathon.mesos:5000'
   action [:create, :start]
end

if node.has_key? 'gce'
  hostname = node['gce']['instance']['hostname']
elsif node.has_key? 'ec2'
  hostname = node['ec2']['public_hostname']
else
  raise 'Unable to find hostname in node attributes'
end

mesos_zk_url = node['mesos']['master']['flags']['zk']
node.override[:mesos][:master][:flags][:hostname] = hostname
node.override[:mesos][:slave][:flags][:hostname] = hostname
node.save

include_recipe 'mesos::install'
include_recipe 'mesos::master'
include_recipe 'mesos::slave'

package 'marathon'
service 'marathon' do
  action [:start, :enable]
end
directory '/etc/marathon'
directory '/etc/marathon/conf'
file '/etc/marathon/conf/hostname' do
  content hostname
  notifies :restart, 'service[marathon]', :immediately
end
file '/etc/marathon/conf/master' do
  content mesos_zk_url
  notifies :restart, 'service[marathon]', :immediately
end
file '/etc/marathon/conf/zk' do
  content mesos_zk_url.gsub('mesos', 'marathon')
  notifies :restart, 'service[marathon]', :immediately
end


package 'chronos'

remote_file '/root/mesos-dns' do
  source 'http://mesos-extras.s3.amazonaws.com/mesos-dns'
  mode '0755'
end


dns_server = `cat /etc/resolv.conf | grep -i nameserver | tail -n1 | cut -d ' ' -f2`.strip
template "/root/config.json" do
  source 'mesos-dns.json.erb'
  variables(
    :mesos_hosts  => node["mesos"]["mesos-hosts"],
    :resolver => dns_server
  )
  mode 00644
end

# Use mesos-dns as the first resolver
execute "sed -i '1inameserver 127.0.0.1' /etc/resolv.conf" do
  not_if 'cat /etc/resolv.conf | grep 127.0.0.1'
end

directory '/root/apps'
node['mesos-extras']['marathon-app-list'].each do |app_name|
  filename = "marathon-#{app_name}.json"
  cookbook_file "/root/apps/#{filename}" do
    source filename
    mode 00644
  end
  execute "curl -X POST http://localhost:8080/v2/apps -H \"Content-type: application/json\" -d@/root/apps/#{filename}" do
    retries 12
    retry_delay 10
    not_if "curl http://localhost:8080/v2/apps | egrep '\"id\":\"/#{app_name}\"'"
  end
end

service 'rsyslog' do
  action :nothing
end

# influx_deb = '/root/influxdb.deb'
# remote_file influx_deb do
#   source 'https://s3.amazonaws.com/influxdb/influxdb_0.8.8_amd64.deb'
# end
#
# execute "dpkg -i #{influx_deb}"
#
# template '/opt/influxdb/current/influxdb' do
#   source 'influxdb.conf.erb'
# end

file '/etc/rsyslog.d/99-mesos-remote.conf' do
  content '*.*   @logstash.marathon.mesos:5001'
  notifies :restart, 'service[rsyslog]', :immediately
end
