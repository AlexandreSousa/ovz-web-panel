class HardwareServer < ActiveRecord::Base
  attr_accessible :host, :auth_key, :description, :daemon_port
  validates_uniqueness_of :host
  validates_numericality_of :daemon_port, :only_integer => true, :greater_than => 1023, :less_than => 49152
  has_many :os_templates, :dependent => :destroy
  has_many :server_templates, :dependent => :destroy
  has_many :virtual_servers, :dependent => :destroy
  
  def connect    
    begin
      if !rpc_client.ping
        self.errors.add :auth_key, :bad_auth
        return false
      end
    rescue SocketError => socket_error
      self.errors.add :host, :connection
      return false
    end
    
    result = save    
    sync if result
    EventLog.info("hardware_server.connect", { :host => self.host })
    result
  end
  
  def disconnect
    destroy
    EventLog.info("hardware_server.disconnect", { :host => self.host })
  end
  
  def rpc_client
    HwDaemonClient.new(host, auth_key, daemon_port, AppConfig.hw_daemon.timeout)
  end
      
  def sync_os_templates
    os_templates_on_server = rpc_client.exec('ls', "#{self.templates_dir}/cache")['output'].split
    
    os_templates.each { |template|
      if !os_templates_on_server.include?(template.name + '.tar.gz')
        template.destroy
      end
    }
    
    os_templates_on_server.each { |template_name|
      template_name.sub!(/\.tar.\gz/, '')
      if !OsTemplate.find_by_name_and_hardware_server_id(template_name, self.id)
        os_template = OsTemplate.new(:name => template_name)
        os_template.hardware_server = self
        os_template.save
      end
    }
  end
  
  def sync_server_templates
    path = '/etc/vz/conf';
    server_templates_on_server = rpc_client.exec('ls', "#{path}/ve-*.conf-sample")['output'].split
    
    server_templates.each { |template|
      if !server_templates_on_server.include?("#{path}/ve-" + template.name + '.conf-sample')
        template.destroy
      end
    }
    
    server_templates_on_server.each { |template_name|
      template_name.sub!(/\/etc\/vz\/conf\/ve\-(.*)\.conf\-sample/, '\1')
      if !ServerTemplate.find_by_name_and_hardware_server_id(template_name, self.id)
        server_template = ServerTemplate.new(:name => template_name)
        server_template.hardware_server = self
        server_template.save
      end
    }
  end
  
  def sync_virtual_servers
    ves_on_server = rpc_client.exec('vzlist', '-a -H -o veid,hostname,ip,status')['output'].split("\n")
    # skip error lines
    ves_on_server = ves_on_server.find_all { |item| item =~ /^\s+\d+/ }
    
    ves_ids_on_server = ves_on_server.map { |vzlist_entry|
      vzlist_entry = vzlist_entry.split.first
    }

    virtual_servers.each { |virtual_server|
      if !ves_ids_on_server.include?(virtual_server.identity.to_s)
        virtual_server.destroy
      end
    }
    
    ves_on_server.each { |vzlist_entry|
      ve_id, host_name, ip_address, ve_state = vzlist_entry.split
      
      virtual_server = virtual_servers.find_by_identity(ve_id)
      virtual_server = VirtualServer.new(:identity => ve_id) unless virtual_server
      
      virtual_server.state = ve_state
        
      parser = IniParser.new(rpc_client.exec('cat', "/etc/vz/conf/#{ve_id}.conf")['output'])
      
      virtual_server.orig_os_template = parser.get('OSTEMPLATE')
      virtual_server.orig_server_template = parser.get('ORIGIN_SAMPLE')
      virtual_server.start_on_boot = ('yes' == parser.get('ONBOOT'))
      virtual_server.host_name = parser.get('HOSTNAME')
      virtual_server.ip_address = parser.get('IP_ADDRESS')
      virtual_server.nameserver = parser.get('NAMESERVER')
      virtual_server.search_domain = parser.get('SEARCHDOMAIN')
      virtual_server.diskspace = parser.get('DISKSPACE').split(":").last.to_i / 1024
      virtual_server.memory = parser.get('PRIVVMPAGES').split(":").last.to_i * 4 / 1024
      virtual_server.description = parser.get('DESCRIPTION') if ve_descriptions_supported?
      virtual_server.cpu_units = parser.get('CPUUNITS')
      virtual_server.cpus = parser.get('CPUS')
      virtual_server.cpu_limit = parser.get('CPULIMIT')
      virtual_server.hardware_server = self
      virtual_server.save(false)
    }
  end
  
  def sync_backups
    backups_list = rpc_client.exec('ls', "--block-size=M -s #{backups_dir}")['output']
    backups_list = backups_list.split("\n")
    # remove totals line
    backups_list.shift
    
    backups_list.each { |backup_record|
      size, filename = backup_record.split
      next unless match = filename.match(/^ve-dump\.(\d+)\.\d+.tar$/)
      
      ve_id = match[1]
      virtual_server = VirtualServer.find_by_identity(ve_id.to_i)
      next unless virtual_server
      
      backup = Backup.find_by_name(filename)
      if backup
        backup.size = size.to_i
        backup.save
        next
      end
      
      backup = Backup.new(:name => filename, :size => size.to_i, :virtual_server_id => virtual_server.id)
      backup.save
    }
  end
  
  def sync_config
    parser = IniParser.new(rpc_client.exec('cat', "/etc/vz/vz.conf")['output'])
    self.default_os_template = parser.get('DEF_OSTEMPLATE')
    self.default_server_template = parser.get('CONFIGFILE')
    self.templates_dir = parser.get('TEMPLATE')
    self.backups_dir = parser.get('DUMPDIR')
    self.ve_private = parser.get('VE_PRIVATE')
    save
  end
  
  def sync_server_info
    self.vzctl_version = rpc_client.exec('vzctl --version')['output'].split[2]
    sync_config
    save
  end
  
  def sync
    sync_server_info
    sync_os_templates
    sync_server_templates
    sync_virtual_servers
    sync_backups
    EventLog.info("hardware_server.sync", { :host => self.host })
  end
  
  def ve_descriptions_supported?
    AppConfig.vzctl.save_descriptions and ((vzctl_version.split('.').map(&:to_i) <=> "3.0.23".split('.').map(&:to_i)) >= 0)
  end
  
  def reboot
    EventLog.info("hardware_server.reboot", { :host => self.host })
    rpc_client.exec('reboot &')
  end
  
  def disk_usage
    raw_info = rpc_client.exec('df', '-lP -k')['output']
    raw_info.split("\n").find_all{ |item| item =~ /^\// }.map{ |item|
      item = item.split
      {
        'partition' => item[0],
        'total_bytes' => item[1].to_i * 1024,
        'used_bytes' => item[2].to_i * 1024,
        'free_bytes' => item[3].to_i * 1024,
        'usage_percent' => item[4].to_i,
        'mount_point' => item[5],
      }
    }
  end
  
  def cpu_load_average
    rpc_client.exec('cat', '/proc/loadavg')['output'].split[0..2]
  end
  
  def memory_usage
    raw_info = rpc_client.exec('free', '-bo')['output'].split("\n")[1].split
    info = {}
    info['total_bytes'] = raw_info[1].to_i
    info['used_bytes'] = raw_info[2].to_i
    info['free_bytes'] = raw_info[3].to_i
    info['usage_percent'] = (info['used_bytes'].to_f / info['total_bytes'].to_f * 100).to_i
    info
  end
  
  def os_version
    rpc_client.exec('uname', '-srm')['output']
  end
    
end
