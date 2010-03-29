class BackgroundJob < ActiveRecord::Base
  
  FINISHED = 0
  RUNNING = 1
  
  def self.create(description, params = {})
    super(:description => description, :status => RUNNING, :params => Marshal.dump(params))
  end
  
  def finish
    self.status = FINISHED
    save
  end

  def t_description(locale = I18n.locale)
    params = Marshal.load(self.params)
    params[:locale] = locale
    I18n.t("admin.tasks." + self.description, params)
  end

end
