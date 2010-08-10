require 'digest/sha1'

class User < ActiveRecord::Base
  include Authentication
  include Authentication::ByPassword
  include Authentication::ByCookieToken

  validates_presence_of :login
  validates_length_of :login, :within => 2..40
  validates_uniqueness_of :login
  validates_format_of :login, :with => Authentication.login_regex, :message => Authentication.bad_login_message

  attr_accessible :login, :password, :password_confirmation, :role_type
  
  attr_accessor :password, :password_confirmation
  
  has_many :virtual_servers
  has_many :requests
  has_many :comments

  def self.authenticate(login, password)
    return nil if login.blank? || password.blank?
    u = find_by_login(login.downcase) # need to get the salt
    u && u.authenticated?(password) ? u : nil
  end

  def login=(value)
    write_attribute :login, (value ? value.downcase : nil)
  end
  
  def superadmin?
    role_type == 1
  end
  
  def ve_admin?
    role_type == 2
  end
  
  def self.get_virtual_servers_owners
    User.find(:all, :conditions => { :role_type => 2 })
  end
  
  def can_control(server)    
    superadmin? or (server.user and (server.user.id == self.id))
  end

  protected
  
    def before_destroy
      login != 'admin'
    end
    
end
