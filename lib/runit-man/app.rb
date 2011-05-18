# encoding: utf-8

require 'fileutils'
require 'yajl'
require 'haml'
require 'i18n'
require 'sinatra/base'
require 'file/tail'
require 'runit-man/helpers'
require 'runit-man/version'

if RUBY_VERSION >= '1.9'
  Encoding.default_external = "utf-8"
  Encoding.default_internal = "utf-8"
end

class RunitMan < Sinatra::Base
  VERSION       = RunitManVersion::VERSION
  MIN_TAIL      = 100
  MAX_TAIL      = 10000
  GEM_FOLDER    = File.expand_path(File.join('..', '..'), File.dirname(__FILE__)).freeze
  CONTENT_TYPES = {
    :html => 'text/html',
    :txt  => 'text/plain',
    :css  => 'text/css',
    :js   => 'application/x-javascript',
    :json => 'application/json'
  }.freeze
  DEFAULT_LOGGER = 'svlogd'.freeze

	set :logger_option, DEFAULT_LOGGER
  set :environment,   :production
  set :static,        true
  set :logging,       true
  set :dump_errors,   true
  set :raise_errors,  false
  set :root,          GEM_FOLDER

  helpers do
    include Helpers
  end

  def self.i18n_location
    File.join(GEM_FOLDER, 'i18n') 
  end

  def self.setup_i18n_files
    files = []
    Dir.glob("#{i18n_location}/*.yml") do |full_path|
      next unless File.file?(full_path)
      files << full_path
    end
    I18n.load_path = files
    I18n.reload!
    nil 
  end

  configure do
    Encoding.default_internal = 'utf-8' if defined?(Encoding) && Encoding.respond_to?(:default_internal=)
    RunitMan.setup_i18n_files
    haml_options = { :ugly => true }
    haml_options[:encoding] = 'utf-8' if defined?(Encoding)
    set :haml, haml_options
  end

  before do
    @scripts = []
    base_content_type = CONTENT_TYPES.keys.detect do |t|
      request.env['REQUEST_URI'] =~ /\.#{Regexp.escape(t.to_s)}$/
    end || :html
    content_type CONTENT_TYPES[base_content_type], :charset => 'utf-8'
    headers({
      'X-Powered-By' => 'runit-man',
      'X-Version' => RunitMan::VERSION
    })
    parse_language(request.env['HTTP_ACCEPT_LANGUAGE'])
  end


  def setup_i18n(locales)
    locales.each do |locale|
      if I18n.available_locales.include?(locale)
        I18n.locale = locale
        break
      end
    end
  end

  def parse_language(header)
    weighted_locales = []
    if header
      header.split(',').each do |s|
        if s =~ /^(.+)\;q\=(\d(?:\.\d)?)$/
          weighted_locales << { :locale => $1.to_sym, :weight => $2.to_f }
        else
          weighted_locales << { :locale => s.to_sym, :weight => 1.0 }
        end
      end
    end
    weighted_locales << { :locale => :en, :weight => 0.0 }
    if weighted_locales.length >= 2
      weighted_locales.sort! do |a, b|
        b[:weight] <=> a[:weight]
      end
    end
    locales = weighted_locales.map { |wl| wl[:locale] }
    setup_i18n(locales)
  end

  get '/' do
    @scripts = %w[ jquery-1.6.min runit-man ]
    @title = host_name
    haml :index
  end

  get '/services' do
    partial :services
  end

  get '/services.json' do
    Yajl::Encoder.encode(service_infos)
  end

  def log_of_service(name, count)
    count = count.to_i
    count = MIN_TAIL if count < MIN_TAIL
    count = MAX_TAIL if count > MAX_TAIL
    srv   = ServiceInfo[name]
    return nil if srv.nil? || !srv.logged?
    text = ''
    File::Tail::Logfile.open(srv.log_file_location, :backward => count, :return_if_eof => true) do |log|
      log.tail do |line|
        text += line
      end
    end

    {
      :name         => name,
      :count        => count,
      :log_location => srv.log_file_location,
      :text         => text
    }
  end

  def data_of_file_view(request)
    if !request.GET.has_key?('file')
      return nil
    end
    file_path = request.GET['file']
    return nil unless all_files_to_view.include?(file_path)
    text = IO.read(file_path)
    {
       :name => file_path,
       :text => text
    }
  end

  get %r[^/([^/]+)/log(?:/(\d+))?/?$] do |name, count|
    data = log_of_service(name, count)
    return not_found if data.nil?
    @title = t('runit.services.log.title', :name => h(name), :host => h(host_name), :count => h(count), :log_location => h(data[:log_location]))
    haml :log, :locals => data
  end

  get %r[^/([^/]+)/log\-downloads/?$] do |name|
    srv = ServiceInfo[name]
    return not_found if srv.nil? || !srv.logged?
    haml :log_downloads, :locals => {
      :name  => name,
      :files => srv.log_files
    }
  end

  get %r[^/([^/]+)/log\-download/(.+)$] do |name, file_name|
    srv = ServiceInfo[name]
    return not_found if srv.nil? || !srv.logged?
    f = srv.log_files.detect { |f| f[:name] == file_name }
    return not_found unless f
    send_file(srv.log_file_path(file_name), :type => 'text/plain', :disposition => 'attachment', :filename => f[:label], :last_modified => f[:modified].httpdate)
  end

  get %r[^/([^/]+)/log(?:/(\d+))?\.txt$] do |name, count|
    data = log_of_service(name, count)
    return not_found if data.nil?
    data[:text]
  end

  get '/view' do
    data = data_of_file_view(request)
    if data.nil?
      return not_found
    end
    @title = t('runit.view_file.title', :file => h(data[:name]), :host => h(host_name))
    content_type CONTENT_TYPES[:html], :charset => 'utf-8'
    haml :view_file, :locals => data 
  end

  get '/view.txt' do
    data = data_of_file_view(request)
    if data.nil?
      return not_found
    end
    content_type CONTENT_TYPES[:txt], :charset => 'utf-8'
    data[:text]
  end

  def log_action(name, text)
    env  = request.env
    addr = env.include?('X_REAL_IP') ? env['X_REAL_IP'] : env['REMOTE_ADDR']
    $stdout.puts "#{addr} - - [#{Time.now}] \"Do #{text} on #{name}\""
    $stdout.flush
  end

  post '/:name/signal/:signal' do |name, signal|
    service = ServiceInfo[name]
    return not_found if service.nil?
    service.send_signal(signal)
    log_action(name, "send signal \"#{signal}\"")
    ''
  end

  post '/:name/:action' do |name, action|
    service = ServiceInfo[name]
    action = "#{action}!".to_sym
    return not_found if service.nil? || !service.respond_to?(action)
    service.send(action)
    log_action(name, action)
    ''
  end

  class << self
    def register_as_runit_service
      all_r_dir    = File.join(RunitMan.all_services_directory, 'runit-man')
      active_r_dir = File.join(RunitMan.active_services_directory, 'runit-man')
      my_dir       = File.join(GEM_FOLDER, 'sv')
      log_dir      = File.join(all_r_dir, 'log')
      if File.symlink?(all_r_dir)
        File.unlink(all_r_dir)
      end
      unless File.directory?(all_r_dir)
        FileUtils.mkdir_p(log_dir)
        create_log_run_script(all_r_dir)
      end
      create_run_script(all_r_dir)
      unless File.symlink?(active_r_dir)
        File.symlink(all_r_dir, active_r_dir)
      end
    end

    def enable_view_of(file_location)
      files_to_view << File.expand_path(file_location, '/')
    end

    def add_user(name, password)
      allowed_users[name] = password
    end

    def files_to_view
      @files_to_view ||= []
    end

    def allowed_users
      @allowed_users ||= {}
    end

    def logger
      settings.logger_option || DEFAULT_LOGGER
    end

    def prepare_to_run
      unless allowed_users.empty?
        use Rack::Auth::Basic, 'runit-man' do |username, password|
          allowed_users.include?(username) && allowed_users[username] == password
        end
      end
    end

  private
    def create_run_script(dir)
      require 'erb'
      script_name   = File.join(dir, 'run')
      template_name = File.join(GEM_FOLDER, 'sv', 'run.erb')
      File.open(script_name, 'w') do |script_source|
        script_source.print ERB.new(IO.read(template_name)).result(
          :all_services_directory    => RunitMan.all_services_directory,
          :active_services_directory => RunitMan.active_services_directory,
          :port                      => RunitMan.port,
          :bind                      => RunitMan.respond_to?(:bind) ? RunitMan.bind : nil,
          :server                    => RunitMan.server,
          :files_to_view             => RunitMan.files_to_view,
          :logger                    => RunitMan.logger,
          :auth                      => RunitMan.allowed_users
        )
      end
      File.chmod(0755, script_name)
    end

    def create_log_run_script(dir)
      require 'erb'
      script_name   = File.join(dir, 'log', 'run')
      template_name = File.join(GEM_FOLDER, 'sv', 'log', 'run.erb')
      File.open(script_name, 'w') do |script_source|
        script_source.print ERB.new(IO.read(template_name)).result(
          :logger                    => RunitMan.logger
        )
      end
      File.chmod(0755, script_name)
    end
  end
end

