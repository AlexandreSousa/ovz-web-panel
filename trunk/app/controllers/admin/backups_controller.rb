class Admin::BackupsController < Admin::Base
  before_filter :is_allowed
  
  def list
    @virtual_server = VirtualServer.find_by_id(params[:virtual_server_id])
    redirect_to :controller => 'dashboard' and return if !@virtual_server or !@current_user.can_control(@virtual_server)
    
    @up_level = '/admin/virtual-servers/show?id=' + @virtual_server.id.to_s
  end
  
  def list_data
    virtual_server = VirtualServer.find_by_id(params[:virtual_server_id])
    redirect_to :controller => 'dashboard' and return if !virtual_server or !@current_user.can_control(virtual_server)
    
    backups = virtual_server.backups
    
    backups.map! { |backup| {
      :id => backup.id,
      :name => backup.name,
      :description => backup.description,
      :size => backup.size,
      :archive_date => backup.date.strftime("%Y.%m.%d %H:%M:%S"),
    }}
    render :json => { :data => backups }  
  end
  
  def delete
    params[:ids].split(',').each { |id|
      backup = Backup.find(id) 
      
      if !backup.delete_physically
        render :json => { :success => false }  
        return
      end
    }
    
    render :json => { :success => true }
  end
  
  def create
    virtual_server = VirtualServer.find_by_id(params[:virtual_server_id])
    redirect_to :controller => 'dashboard' and return if !virtual_server or !@current_user.can_control(virtual_server)
    hardware_server = virtual_server.hardware_server
    
    orig_ve_state = virtual_server.state
    virtual_server.stop if 'running' == orig_ve_state
    
    result = virtual_server.backup
    job_id = result[:job]['job_id']
    backup = result[:backup]
    backup.description = params[:description]
    
    spawn do
      job = BackgroundJob.create('backups.create', { :identity => virtual_server.identity, :host => hardware_server.host })
      
      while true
        job_running = false
        job_running = true if hardware_server.rpc_client.job_status(job_id)['alive']
        break unless job_running
        sleep 10
      end
      
      job.finish
      backup.save
      hardware_server.sync_backups
      virtual_server.start if 'running' == orig_ve_state
    end
    
    render :json => { :success => true }
  end
  
  def restore
    backup = Backup.find_by_id(params[:id])
    virtual_server = backup.virtual_server
    redirect_to :controller => 'dashboard' and return if !virtual_server or !@current_user.can_control(virtual_server)
    
    orig_ve_state = virtual_server.state
    virtual_server.stop if 'running' == orig_ve_state
    
    job_id = backup.restore['job_id']
    
    spawn do
      job = BackgroundJob.create('backups.restore', { :identity => virtual_server.identity, :host => virtual_server.hardware_server.host })
      
      while true
        job_running = false
        job_running = true if virtual_server.hardware_server.rpc_client.job_status(job_id)['alive']
        break unless job_running
        sleep 10
      end
      
      job.finish
      virtual_server.start if 'running' == orig_ve_state
    end
    
    render :json => { :success => true }
  end
  
  private
  
    def is_allowed
      redirect_to :controller => 'admin/dashboard' unless @current_user.superadmin? || AppConfig.backups.allow_for_users
    end
   
end
