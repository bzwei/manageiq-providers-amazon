class ManageIQ::Providers::Amazon::NetworkManager::RefreshParserDto < ::ManagerRefresh::RefreshParserDto
  include ManageIQ::Providers::Amazon::RefreshHelperMethods

  def initialize(ems, options = nil)
    super

    @aws_ec2 = ems.connect
    @aws_elb = ems.connect(:service => :ElasticLoadBalancing)

    initialize_dto_collections
  end

  def initialize_dto_collections
    add_cloud_manager_db_cached_dto(ManageIQ::Providers::Amazon::CloudManager::Vm,
                                    :vms)
    add_cloud_manager_db_cached_dto(ManageIQ::Providers::Amazon::CloudManager::OrchestrationStack,
                                    :orchestration_stacks)
    add_cloud_manager_db_cached_dto(ManageIQ::Providers::Amazon::CloudManager::AvailabilityZone,
                                    :availability_zones)

    add_dto_collection(CloudSubnetNetworkPort,
                       :cloud_subnet_network_ports,
                       [:address, :cloud_subnet, :network_port])
    add_dto_collection(self.class.network_port_type,
                       :network_ports)
    add_dto_collection(self.class.floating_ip_type,
                       :floating_ips)
    add_dto_collection(self.class.cloud_subnet_type,
                       :cloud_subnets)
    add_dto_collection(self.class.cloud_network_type,
                       :cloud_networks)
    add_dto_collection(self.class.security_group_type,
                       :security_groups)
    add_dto_collection(FirewallRule,
                       :firewall_rules,
                       [:resource, :source_security_group, :direction, :host_protocol, :port, :end_port, :source_ip_range])
    add_dto_collection(self.class.load_balancer_type,
                       :load_balancers)
    add_dto_collection(self.class.load_balancer_pool_type,
                       :load_balancer_pools)
    add_dto_collection(self.class.load_balancer_pool_member_type,
                       :load_balancer_pool_members)
    add_dto_collection(LoadBalancerPoolMemberPool,
                       :load_balancer_pool_member_pools,
                       [:load_balancer_pool, :load_balancer_pool_member])
    add_dto_collection(self.class.load_balancer_listener_type,
                       :load_balancer_listeners)
    add_dto_collection(LoadBalancerListenerPool,
                       :load_balancer_listener_pools,
                       [:load_balancer_listener, :load_balancer_pool])
    add_dto_collection(self.class.load_balancer_health_check_type,
                       :load_balancer_health_checks)
    add_dto_collection(LoadBalancerHealthCheckMember,
                       :load_balancer_health_check_members,
                       [:load_balancer_health_check, :load_balancer_pool_member])
  end

  def ems_inv_to_hashes
    log_header = "MIQ(#{self.class.name}.#{__method__}) Collecting data for EMS name: [#{@ems.name}] id: [#{@ems.id}]"

    $aws_log.info("#{log_header}...")
    # The order of the below methods does matter, because there are inner dependencies of the data!
    get_cloud_networks
    get_cloud_subnets
    get_security_groups
    get_network_ports
    get_load_balancers
    get_ec2_floating_ips_and_ports
    get_floating_ips
    get_public_ips
    $aws_log.info("#{log_header}...Complete")

    @data
  end

  private
  def security_groups
    @security_groups ||= @aws_ec2.security_groups
  end

  def network_ports
    @network_ports ||= @aws_ec2.client.describe_network_interfaces.network_interfaces
  end

  def get_cloud_networks
    vpcs = @aws_ec2.client.describe_vpcs[:vpcs]
    process_dto_collection(vpcs, :cloud_networks) { |vpc| parse_cloud_network(vpc) }
  end

  def get_cloud_subnets
    cloud_subnets = @aws_ec2.client.describe_subnets[:subnets]
    process_dto_collection(cloud_subnets, :cloud_subnets) { |s| parse_cloud_subnet(s) }
  end

  def get_security_groups
    process_dto_collection(security_groups, :security_groups) do |sg|
      get_outbound_firewall_rules(sg)
      get_inbound_firewall_rules(sg)

      parse_security_group(sg)
    end
  end

  def get_inbound_firewall_rules(sg)
    parsed_rules = sg.ip_permissions.collect { |perm| parse_firewall_rule(perm, "inbound", sg) }.flatten
    process_dto_collection(parsed_rules, :firewall_rules) { |firewall_rule| firewall_rule }
  end

  def get_outbound_firewall_rules(sg)
    parsed_rules = sg.ip_permissions_egress.collect { |perm| parse_firewall_rule(perm, "outbound", sg) }.flatten
    process_dto_collection(parsed_rules, :firewall_rules) { |firewall_rule| firewall_rule }
  end

  def get_load_balancers
    load_balancers = @aws_elb.client.describe_load_balancers.load_balancer_descriptions

    process_dto_collection(load_balancers, :load_balancers) do |lb|
      get_load_balancer_pools(lb)
      get_load_balancer_pool_members(lb)
      get_load_balancer_listeners(lb)
      get_load_balancer_health_checks(lb)

      parse_load_balancer(lb)
    end
  end

  def get_load_balancer_pools(load_balancer)
    process_dto_collection([load_balancer], :load_balancer_pools) { |lb| parse_load_balancer_pool(lb) }
  end

  def get_load_balancer_pool_members(lb)
    process_dto_collection(lb.instances, :load_balancer_pool_members) do |member|
      get_load_balancer_balancer_pool_member_pools(lb, member)

      parse_load_balancer_pool_member(member)
    end
  end

  def get_load_balancer_balancer_pool_member_pools(lb, member)
    process_dto_collection([member], :load_balancer_pool_member_pools) do |m|
      parse_load_balancer_pool_member_pools(lb, m)
    end
  end

  def listener_uid(lb, listener)
    "#{lb.load_balancer_name}__#{listener.protocol}__#{listener.load_balancer_port}__"\
    "#{listener.instance_protocol}__#{listener.instance_port}__#{listener.ssl_certificate_id}"
  end

  def get_load_balancer_listeners(lb)
    process_dto_collection(lb.listener_descriptions, :load_balancer_listeners) do |listener|
      listener = listener.listener

      get_load_balancer_listener_pool(listener, lb)

      parse_load_balancer_listener(lb, listener)
    end
  end

  def get_load_balancer_listener_pool(listener, lb)
    process_dto_collection([listener], :load_balancer_listener_pools) do |l|
      parse_load_balancer_listener_pool(l, lb)
    end
  end

  def get_load_balancer_health_checks(load_balancer)
    process_dto_collection([load_balancer], :load_balancer_health_checks) do |lb|
      get_load_balancer_health_check_members(lb)

      parse_load_balancer_health_check(lb)
    end
  end

  def get_load_balancer_health_check_members(lb)
    health_check_members = @aws_elb.client.describe_instance_health(:load_balancer_name => lb.load_balancer_name)
    process_dto_collection(health_check_members.instance_states, :load_balancer_health_check_members) do |m|
      parse_load_balancer_health_check_member(lb, m)
    end
  end

  def get_floating_ips
    ips = @aws_ec2.client.describe_addresses.addresses
    process_dto_collection(ips, :floating_ips) { |ip| parse_floating_ip(ip) }
  end

  def get_public_ips
    public_ips = []
    network_ports.each do |network_port|
      network_port.private_ip_addresses.each do |private_address|
        if private_address.association && !(public_ip = private_address.association.public_ip).blank? &&
          private_address.association.allocation_id.blank?

          public_ips << {
            :network_port_id    => network_port.network_interface_id,
            :private_ip_address => private_address.private_ip_address,
            :public_ip_address  => public_ip
          }
        end
      end
    end
    process_dto_collection(public_ips, :floating_ips) { |public_ip| parse_public_ip(public_ip) }
  end

  def get_network_ports
    process_dto_collection(network_ports, :network_ports) do |n|
      get_cloud_subnet_network_ports(n)

      parse_network_port(n)
    end
  end

  def get_cloud_subnet_network_ports(network_port)
    process_dto_collection(network_port.private_ip_addresses, :cloud_subnet_network_ports) do |address|
      parse_cloud_subnet_network_port(network_port, address)
    end
  end

  def get_ec2_floating_ips_and_ports
    instances = @aws_ec2.instances.select { |instance| instance.network_interfaces.blank? }
    process_dto_collection(instances, :network_ports) do |instance|
      get_ec2_cloud_subnet_network_port(instance)

      parse_network_port_inferred_from_instance(instance)
    end
    process_dto_collection(instances, :floating_ips) { |instance| parse_floating_ip_inferred_from_instance(instance) }
  end

  def get_ec2_cloud_subnet_network_port(instance)
    # Create network_port placeholder for old EC2 instances, those do not have interface nor subnet nor VPC
    process_dto_collection([instance], :cloud_subnet_network_ports) { |i| parse_ec2_cloud_subnet_network_port(i) }
  end

  def parse_cloud_network(vpc)
    uid = vpc.vpc_id

    name = get_from_tags(vpc, :name)
    name ||= uid

    status = (vpc.state == :available) ? "active" : "inactive"

    {
      :type                => self.class.cloud_network_type.name,
      :ems_ref             => uid,
      :name                => name,
      :cidr                => vpc.cidr_block,
      :status              => status,
      :enabled             => true,
      :orchestration_stack => @data[:orchestration_stacks].lazy_find(
        get_from_tags(vpc, "aws:cloudformation:stack-id")),
    }
  end

  def parse_cloud_subnet(subnet)
    uid = subnet.subnet_id

    name = get_from_tags(subnet, :name)
    name ||= uid

    {
      :type              => self.class.cloud_subnet_type.name,
      :ems_ref           => uid,
      :name              => name,
      :cidr              => subnet.cidr_block,
      :status            => subnet.state.try(:to_s),
      :availability_zone => @data[:availability_zones].lazy_find(subnet.availability_zone),
      :cloud_network     => @data[:cloud_networks].lazy_find(subnet.vpc_id),
    }
  end

  def parse_security_group(sg)
    uid = sg.group_id

    {
      :type                => self.class.security_group_type.name,
      :ems_ref             => uid,
      :name                => sg.group_name,
      :description         => sg.description.try(:truncate, 255),
      :cloud_network       => @data[:cloud_networks].lazy_find(sg.vpc_id),
      :orchestration_stack => @data[:orchestration_stacks].lazy_find(
        get_from_tags(sg, "aws:cloudformation:stack-id")),
    }
  end

  # TODO: Should ICMP protocol values have their own 2 columns, or
  #   should they override port and end_port like the Amazon API.
  def parse_firewall_rule(perm, direction, sg)
    ret = []

    common = {
      :direction     => direction,
      :host_protocol => perm.ip_protocol.to_s.upcase,
      :port          => perm.from_port,
      :end_port      => perm.to_port,
      :resource      => @data[:security_groups].lazy_find(sg.group_id)
    }

    perm.user_id_group_pairs.each do |g|
      new_result                         = common.dup
      # new_result[:source_security_group] = @data_index.fetch_path(:security_groups, g.group_id)
      new_result[:source_security_group] = @data[:security_groups].lazy_find(g.group_id)
      ret << new_result
    end
    perm.ip_ranges.each do |r|
      new_result                   = common.dup
      new_result[:source_ip_range] = r.cidr_ip
      ret << new_result
    end

    ret
  end

  def parse_load_balancer(lb)
    uid = lb.load_balancer_name

    {
      :type    => self.class.load_balancer_type.name,
      :ems_ref => uid,
      :name    => uid,
    }
  end

  def parse_load_balancer_pool(lb)
    uid = lb.load_balancer_name

    {
      :type    => self.class.load_balancer_pool_type.name,
      :ems_ref => uid,
      :name    => uid,
    }
  end

  def parse_load_balancer_pool_member_pools(lb, member)
    {
      :load_balancer_pool        => @data[:load_balancer_pools].lazy_find(lb.load_balancer_name),
      :load_balancer_pool_member => @data[:load_balancer_pool_members].lazy_find(member.instance_id)
    }
  end

  def parse_load_balancer_pool_member(member)
    uid = member.instance_id
    {
      :type    => self.class.load_balancer_pool_member_type.name,
      :ems_ref => uid,
      # TODO(lsmola) AWS always associates to eth0 of the instances, we do not collect that info now, we need to do that
      # :network_port => get eth0 network_port
      :vm      => @data[:vms].lazy_find(uid)
    }
  end

  def parse_load_balancer_listener_pool(listener, lb)
    {
      :load_balancer_listener => @data[:load_balancer_listeners].lazy_find(listener_uid(lb, listener)),
      :load_balancer_pool     => @data[:load_balancer_pools].lazy_find(lb.load_balancer_name)
    }
  end

  def parse_load_balancer_listener(lb, listener)
    {
      :type                     => self.class.load_balancer_listener_type.name,
      :ems_ref                  => listener_uid(lb, listener),
      :load_balancer_protocol   => listener.protocol,
      :load_balancer_port_range => (listener.load_balancer_port.to_i..listener.load_balancer_port.to_i),
      :instance_protocol        => listener.instance_protocol,
      :instance_port_range      => (listener.instance_port.to_i..listener.instance_port.to_i),
      :load_balancer            => @data[:load_balancers].lazy_find(lb.load_balancer_name),
    }
  end

  def parse_load_balancer_health_check(lb)
    uid          = lb.load_balancer_name
    health_check = lb.health_check
    target_match = health_check.target.match(/^(\w+)\:(\d+)\/?(.*?)$/)
    protocol     = target_match[1]
    port         = target_match[2].to_i
    url_path     = target_match[3]

    {
      :type                => self.class.load_balancer_health_check_type.name,
      :ems_ref             => uid,
      :protocol            => protocol,
      :port                => port,
      :url_path            => url_path,
      :interval            => health_check.interval,
      :timeout             => health_check.timeout,
      :unhealthy_threshold => health_check.unhealthy_threshold,
      :healthy_threshold   => health_check.healthy_threshold,
      :load_balancer       => @data[:load_balancers].lazy_find(lb.load_balancer_name),
    }
  end

  def parse_load_balancer_health_check_member(lb, member)
    {
      :load_balancer_health_check => @data[:load_balancer_health_checks].lazy_find(lb.load_balancer_name),
      :load_balancer_pool_member  => @data[:load_balancer_pool_members].lazy_find(member.instance_id),
      :status                     => member.state,
      :status_reason              => member.description
    }
  end

  def parse_floating_ip(ip)
    cloud_network_only = ip.domain["vpc"] ? true : false
    address            = ip.public_ip
    uid                = cloud_network_only ? ip.allocation_id : ip.public_ip

    {
      :type               => self.class.floating_ip_type.name,
      :ems_ref            => uid,
      :address            => address,
      :fixed_ip_address   => ip.private_ip_address,
      :cloud_network_only => cloud_network_only,
      :network_port       => @data[:network_ports].lazy_find(ip.network_interface_id),
      :vm                 => @data[:vms].lazy_find(ip.instance_id)
    }
  end

  def parse_floating_ip_inferred_from_instance(instance)
    address = uid = instance.public_ip_address
    return nil if uid.blank?

    {
      :type               => self.class.floating_ip_type.name,
      :ems_ref            => uid,
      :address            => address,
      :fixed_ip_address   => instance.private_ip_address,
      :cloud_network_only => false,
      :network_port       => @data[:network_ports].lazy_find(instance.id),
      :vm                 => @data[:vms].lazy_find(instance.id)
    }
  end

  def parse_public_ip(public_ip)
    address = uid = public_ip[:public_ip_address]

    {
      :type               => self.class.floating_ip_type.name,
      :ems_ref            => uid,
      :address            => address,
      :fixed_ip_address   => public_ip[:private_ip_address],
      :cloud_network_only => true,
      :network_port       => @data[:network_ports].lazy_find(public_ip[:network_port_id]),
      :vm                 => @data[:network_ports].lazy_find(public_ip[:network_port_id], :key => :device)
    }
  end

  def parse_cloud_subnet_network_port(network_port, address)
    {
      :address      => address.private_ip_address,
      :cloud_subnet => @data[:cloud_subnets].lazy_find(network_port.subnet_id),
      :network_port => @data[:network_ports].lazy_find(network_port.network_interface_id)
    }
  end

  def parse_ec2_cloud_subnet_network_port(instance)
    {
      :address      => instance.private_ip_address,
      :cloud_subnet => nil,
      :network_port => @data[:network_ports].lazy_find(instance.id)
    }
  end

  def parse_network_port(network_port)
    uid             = network_port.network_interface_id
    security_groups = network_port.groups.blank? ? [] : network_port.groups.map do |x|
      @data[:security_groups].lazy_find(x.group_id)
    end

    {
      :type            => self.class.network_port_type.name,
      :name            => uid,
      :ems_ref         => uid,
      :status          => network_port.status,
      :mac_address     => network_port.mac_address,
      :device_owner    => network_port.try(:attachment).try(:instance_owner_id),
      :device_ref      => network_port.try(:attachment).try(:instance_id),
      :device          => @data[:vms].lazy_find(network_port.try(:attachment).try(:instance_id)),
      :security_groups => security_groups,
    }
  end

  def parse_network_port_inferred_from_instance(instance)
    uid  = instance.id
    name = get_from_tags(instance, :name)
    name ||= uid

    {
      :type            => self.class.network_port_type.name,
      :name            => name,
      :ems_ref         => uid,
      :status          => nil,
      :mac_address     => nil,
      :device_owner    => nil,
      :device_ref      => nil,
      :device          => @data[:vms].lazy_find(uid),
      :security_groups => instance.security_groups.to_a.collect do |sg|
        @data[:security_groups].lazy_find(sg.group_id)
      end.compact,
    }
  end

  class << self
    def load_balancer_type
      ManageIQ::Providers::Amazon::NetworkManager::LoadBalancer
    end

    def load_balancer_listener_type
      ManageIQ::Providers::Amazon::NetworkManager::LoadBalancerListener
    end

    def load_balancer_health_check_type
      ManageIQ::Providers::Amazon::NetworkManager::LoadBalancerHealthCheck
    end

    def load_balancer_pool_type
      ManageIQ::Providers::Amazon::NetworkManager::LoadBalancerPool
    end

    def load_balancer_pool_member_type
      ManageIQ::Providers::Amazon::NetworkManager::LoadBalancerPoolMember
    end

    def security_group_type
      ManageIQ::Providers::Amazon::NetworkManager::SecurityGroup
    end

    def network_router_type
      ManageIQ::Providers::Amazon::NetworkManager::NetworkRouter
    end

    def cloud_network_type
      ManageIQ::Providers::Amazon::NetworkManager::CloudNetwork
    end

    def cloud_subnet_type
      ManageIQ::Providers::Amazon::NetworkManager::CloudSubnet
    end

    def floating_ip_type
      ManageIQ::Providers::Amazon::NetworkManager::FloatingIp
    end

    def network_port_type
      ManageIQ::Providers::Amazon::NetworkManager::NetworkPort
    end
  end
end
