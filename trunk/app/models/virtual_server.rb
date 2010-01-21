class VirtualServer < ActiveRecord::Base
  attr_accessible :identity, :ip_address, :host_name, :hardware_server_id, 
    :os_template_id, :password, :start_on_boot, :start_after_creation, :state,
    :nameserver, :search_domain, :diskspace, :memory, :password_confirmation
  attr_accessor :password, :password_confirmation, :start_after_creation
  belongs_to :hardware_server
  belongs_to :os_template
  
  validates_format_of :ip_address, :with => /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/
  validates_uniqueness_of :ip_address
  validates_uniqueness_of :identity, :scope => :hardware_server_id
  validates_confirmation_of :password
  validates_format_of :nameserver, :with => /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})?$/

  def start
    hardware_server.rpc_client.exec('vzctl', 'start ' + identity.to_s)
    self.state = 'running'
    save
  end
  
  def stop
    hardware_server.rpc_client.exec('vzctl', 'stop ' + identity.to_s)
    self.state = 'stopped'
    save
  end
  
  def restart
    hardware_server.rpc_client.exec('vzctl', 'restart ' + identity.to_s)
    self.state = 'running'
    save
  end
    
  def delete_physically
    stop
    hardware_server.rpc_client.exec('vzctl', 'destroy ' + identity.to_s)
    destroy
    EventLog.info("virtual_server.removed", { :identity => identity })
  end
     
  def save_physically
    return false if !valid?
    
    if new_record?
      hardware_server.rpc_client.exec('vzctl', "create #{identity.to_s} --ostemplate #{os_template.name}")
      self.state = 'stopped'
    end
  
    vzctl_set("--hostname #{host_name} --save") if host_name
    vzctl_set("--ipdel all --ipadd #{ip_address} --save")
    vzctl_set("--userpasswd root:#{password}") if password
    vzctl_set("--onboot " + (start_on_boot ? "yes" : "no") + " --save")
    vzctl_set("--nameserver #{nameserver} --save") if nameserver
    vzctl_set("--searchdomain #{search_domain} --save") if search_domain
    vzctl_set("--diskspace #{diskspace * 1024} --privvmpages #{memory * 1024 / 4} --save")
    start if start_after_creation
  
    result = save
    EventLog.info("virtual_server.created", { :identity => identity })
    result
  end
  
  private

    def vzctl_set(param)
      hardware_server.rpc_client.exec('vzctl', "set #{identity.to_s} #{param}")
    end
  
end
