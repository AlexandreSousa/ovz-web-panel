class Admin::VirtualServersController < AdminController
  
  def list_data
    hardware_server = HardwareServer.find_by_id(params[:hardware_server_id])
    virtual_servers = hardware_server.virtual_servers
    virtual_servers.map! { |item| {
      :id => item.id,
      :identity => item.identity,
      :ip_address => item.ip_address,
      :host_name => item.host_name,
      :state => item.state,
      :os_template_name => item.os_template ? item.os_template.name : '-'
    }}
    render :json => { :data => virtual_servers }  
  end
  
  def change_state    
    params[:ids].split(',').each { |id|
      virtual_server = VirtualServer.find_by_id(id)
      
      case params[:command]  
        when 'start' then virtual_server.start
        when 'stop' then virtual_server.stop
        when 'restart' then virtual_server.restart
      end
    }
    
    render :json => { :success => true }  
  end
  
  def delete
    params[:ids].split(',').each { |id|
      virtual_server = VirtualServer.find(id) 
      
      if !virtual_server.delete_physically
        render :json => { :success => false }  
        return
      end
    }
    
    render :json => { :success => true }
  end
  
  def create
    hardware_server = HardwareServer.find_by_id(params[:hardware_server_id])    
    redirect_to :controller => 'hardware_servers', :action => 'list' if !hardware_server
    
    virtual_server = VirtualServer.new(params)
    
    if virtual_server.create_physically
      render :json => { :success => true }  
    else
      render :json => { :success => false, :form_errors => virtual_server.errors }
    end    
  end
  
end
