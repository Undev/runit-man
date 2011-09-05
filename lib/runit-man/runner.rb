require 'optparse'
require 'runit-man/app'

RunitMan.set :active_services_directory, RunitMan::DEFAULT_ACTIVE_SERVICES_DIR
RunitMan.set :all_services_directory,    RunitMan::DEFAULT_ALL_SERVICES_DIR
RunitMan.set :runit_logger,              RunitMan::DEFAULT_LOGGER
RunitMan.set :rackup_command_line,       false
RunitMan.set :read_write_mode,           true

OptionParser.new { |op|
  op.banner = 'Usage: runit-man <options>'
  op.separator "Version: #{RunitMan::VERSION}"
  op.separator 'Server options:'
  op.on('-s server') { |val| RunitMan.set :server, val }
  op.on('-p port')   { |val| RunitMan.set :port, val.to_i }
  op.on('-b addr')   { |val| RunitMan.set :bind, val } if RunitMan.respond_to?(:bind)
  op.on('-m mode')   { |val| RunitMan.set :read_write_mode, false if val == 'read-only' } 
  op.separator 'runit options:'
  op.on('-a active_services_directory (/etc/service by default)') { |val| RunitMan.set :active_services_directory, val }
  op.on('-f all_services_directory (/etc/sv by default)')         { |val| RunitMan.set :all_services_directory, val }
  op.separator 'runit logger options (now svlogd and logger supported only):'
  op.on('-l runit logger application[:base folder[:priority]] (svlogd by default)') { |val| RunitMan.set :runit_logger, val }
  op.separator 'View options:'
  op.on('-v file_location', 'Enables view of specified file through runit-man') { |val| RunitMan.enable_view_of(val) }
  op.on('-u user:password', 'Requires user name with given password to auth') { |val| RunitMan.add_user(*(val.split(':', 2))) }
  op.separator 'Configuration options:'
  op.on('--rackup command_line', 'Change directory to config.ru location, set environment by options and execute specified command_line') do |command_line|
    RunitMan.set :rackup_command_line, command_line
  end
  op.on_tail('-r', '--register', 'Register as runit service') do
    RunitMan.register_as_runit_service
    exit
  end
}.parse!(ARGV.dup)

if RunitMan.rackup_command_line
  RunitMan.exec_rackup(RunitMan.rackup_command_line)
end

RunitMan.prepare_to_run

RunitMan.run!

