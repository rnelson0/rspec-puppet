# frozen_string_literal: true

require 'pathname'

# Load this library before enabling the monkey-patches to avoid HI-581
begin
  require 'hiera/util/win32'
rescue LoadError
  # ignore this on installs without hiera, e.g. puppet 3 gems
end

class RSpec::Puppet::EventListener
  def self.example_started(example)
    if rspec3?
      @rspec_puppet_example = example.example.example_group.ancestors.include?(RSpec::Puppet::Support)
      @current_example = example.example
      if !@current_example.respond_to?(:environment) && @current_example.respond_to?(:example_group_instance)
        @current_example = @current_example.example_group_instance
      end
    else
      @rspec_puppet_example = example.example_group.ancestors.include?(RSpec::Puppet::Support)
      @current_example = example
    end
  end

  def self.example_passed(_example)
    @rspec_puppet_example = false
  end

  def self.example_pending(_example)
    @rspec_puppet_example = false
  end

  def self.example_failed(_example)
    @rspec_puppet_example = false
  end

  def self.rspec_puppet_example?
    @rspec_puppet_example || false
  end

  def self.rspec3?
    @rspec3 = defined?(RSpec::Core::Notifications) if @rspec3.nil?

    @rspec3
  end

  class << self
    attr_reader :current_example
  end
end

RSpec.configuration.reporter.register_listener(RSpec::Puppet::EventListener, :example_started, :example_pending,
                                               :example_passed, :example_failed)

require 'rspec-puppet/monkey_patches/win32/taskscheduler'
require 'rspec-puppet/monkey_patches/win32/registry'
require 'rspec-puppet/monkey_patches/windows/taskschedulerconstants'

module Puppet
  # Allow rspec-puppet to prevent Puppet::Type from automatically picking
  # a provider for a resource. We need to do this because in order to fully
  # resolve the graph edges, we have to convert the Puppet::Resource objects
  # into Puppet::Type objects so that their autorequires are evaluated. We need
  # to prevent provider code from being called during this process as it's very
  # platform specific.
  class Type
    old_set_default = instance_method(:set_default)

    define_method(:set_default) do |attr|
      if RSpec::Puppet.rspec_puppet_example?
        old_posix = nil
        old_microsoft_windows = nil

        if attr == :provider
          old_posix = Puppet.features.posix?
          old_microsoft_windows = Puppet.features.microsoft_windows?

          if Puppet::Util::Platform.pretend_windows?
            Puppet.features.add(:posix) { false }
            Puppet.features.add(:microsoft_windows) { true }
          else
            Puppet.features.add(:posix) { true }
            Puppet.features.add(:microsoft_windows) { false }
          end
        end

        retval = old_set_default.bind_call(self, attr)

        Puppet.features.add(:posix) { old_posix } unless old_posix.nil?
        Puppet.features.add(:microsoft_windows) { old_microsoft_windows } unless old_microsoft_windows.nil?

        retval
      else
        old_set_default.bind_call(self, attr)
      end
    end
  end

  module Parser::Files
    alias old_find_manifests_in_modules find_manifests_in_modules
    module_function :old_find_manifests_in_modules

    def find_manifests_in_modules(pattern, environment)
      if RSpec::Puppet.rspec_puppet_example?
        pretending = Puppet::Util::Platform.pretend_platform

        unless pretending.nil?
          Puppet::Util::Platform.pretend_to_be nil
          RSpec::Puppet::Consts.stub_consts_for(RSpec.configuration.platform)
        end

        if pretending && pretending != Puppet::Util::Platform.actual_platform && environment.respond_to?(:value_cache,
                                                                                                         true)
          environment.send(:value_cache).clear
        end
        output = old_find_manifests_in_modules(pattern, environment)

        unless pretending.nil?
          Puppet::Util::Platform.pretend_to_be pretending
          RSpec::Puppet::Consts.stub_consts_for pretending
        end

        output
      else
        old_find_manifests_in_modules(pattern, environment)
      end
    end
    module_function :find_manifests_in_modules
  end

  module Util
    # Fix for removal of default_env function
    # Bug: https://github.com/rodjek/rspec-puppet/issues/796
    # Upstream: https://github.com/puppetlabs/puppet/commit/94df3c1a3992d89b2d7d5db8a70373c135bdd86b
    unless respond_to?(:default_env)
      def default_env
        DEFAULT_ENV
      end
      module_function :default_env
    end

    if respond_to?(:get_env)
      alias old_get_env get_env
      module_function :old_get_env

      def get_env(name, mode = default_env)
        if RSpec::Puppet.rspec_puppet_example?
          # use the actual platform, not the pretended
          old_get_env(name, Platform.actual_platform)
        else
          old_get_env(name, mode)
        end
      end
      module_function :get_env
    end

    if respond_to?(:path_to_uri)
      alias old_path_to_uri path_to_uri
      module_function :old_path_to_uri

      def path_to_uri(*args)
        if RSpec::Puppet.rspec_puppet_example?
          RSpec::Puppet::Consts.without_stubs do
            old_path_to_uri(*args)
          end
        else
          old_path_to_uri(*args)
        end
      end
      module_function :path_to_uri
    end

    # Allow rspec-puppet to pretend to be different platforms.
    module Platform
      alias old_windows? windows?
      module_function :old_windows?

      def windows?
        if RSpec::Puppet.rspec_puppet_example?
          pretending? ? pretend_windows? : (actual_platform == :windows)
        else
          old_windows?
        end
      end
      module_function :windows?

      def actual_platform
        @actual_platform ||= !!File::ALT_SEPARATOR ? :windows : :posix
      end
      module_function :actual_platform

      def actually_windows?
        actual_platform == :windows
      end
      module_function :actually_windows?

      def pretend_windows?
        pretend_platform == :windows
      end
      module_function :pretend_windows?

      def pretend_to_be(platform)
        # Ensure that we cache the real platform before pretending to be
        # a different one
        actual_platform

        @pretend_platform = platform
      end
      module_function :pretend_to_be

      def pretend_platform
        @pretend_platform ||= nil
      end
      module_function :pretend_platform

      def pretending?
        !pretend_platform.nil?
      end
      module_function :pretending?
    end

    class Autoload
      if respond_to?(:load_file)
        singleton_class.send(:alias_method, :old_load_file, :load_file)

        def self.load_file(*args)
          if RSpec::Puppet.rspec_puppet_example?
            RSpec::Puppet::Consts.without_stubs do
              old_load_file(*args)
            end
          else
            old_load_file(*args)
          end
        end
      end
    end
  end

  begin
    require 'puppet/confine/exists'

    class Confine::Exists < Puppet::Confine
      old_pass = instance_method(:pass?)

      define_method(:pass?) do |value|
        if RSpec::Puppet.rspec_puppet_example?
          true
        else
          old_pass.bind_call(self, value)
        end
      end
    end
  rescue LoadError
    require 'puppet/provider/confine/exists'

    class Provider::Confine::Exists < Puppet::Provider::Confine
      old_pass = instance_method(:pass?)

      define_method(:pass?) do |value|
        if RSpec::Puppet.rspec_puppet_example?
          true
        else
          old_pass.bind_call(self, value)
        end
      end
    end
  end

  if Puppet::Util::Package.versioncmp(Puppet.version, '4.9.0') >= 0
    class Module
      old_hiera_conf_file = instance_method(:hiera_conf_file)
      define_method(:hiera_conf_file) do
        if RSpec::Puppet.rspec_puppet_example?
          if RSpec.configuration.disable_module_hiera
            return nil
          elsif RSpec.configuration.fixture_hiera_configs.key?(name)
            config = RSpec.configuration.fixture_hiera_configs[name]
            config = File.absolute_path(config, path) unless config.nil?
            return config
          elsif RSpec.configuration.use_fixture_spec_hiera
            config = RSpec::Puppet.current_example.fixture_spec_hiera_conf(self)
            return config unless config.nil? && RSpec.configuration.fallback_to_default_hiera
          end
        end
        old_hiera_conf_file.bind_call(self)
      end
    end

    class Pops::Lookup::ModuleDataProvider
      old_configuration_path = instance_method(:configuration_path)
      define_method(:configuration_path) do |lookup_invocation|
        if RSpec::Puppet.rspec_puppet_example?
          env = lookup_invocation.scope.environment
          mod = env.module(module_name)
          unless mod
            raise Puppet::DataBinding::LookupError,
                  format(_("Environment '%<env>s', cannot find module '%<module_name>s'"), env: env.name,
                                                                                           module_name: module_name)
          end

          return Pathname.new(mod.hiera_conf_file)
        end
        old_configuration_path.bind_call(self, lookup_invocation)
      end
    end
  end
end

class Pathname
  def rspec_puppet_basename(path)
    raise ArgumentError, 'pathname stubbing not enabled' unless RSpec.configuration.enable_pathname_stubbing

    path = path[2..-1] if /\A[a-zA-Z]:(#{SEPARATOR_PAT}.*)\z/.match?(path)
    path.split(SEPARATOR_PAT).last || path[/(#{SEPARATOR_PAT})/, 1] || path
  end

  if instance_methods.include?('chop_basename')
    old_chop_basename = instance_method(:chop_basename)

    define_method(:chop_basename) do |path|
      if RSpec::Puppet.rspec_puppet_example?
        if RSpec.configuration.enable_pathname_stubbing
          base = rspec_puppet_basename(path)
          return nil if /\A#{SEPARATOR_PAT}?\z/o.match?(base)

          [path[0, path.rindex(base)], base]

        else
          old_chop_basename.bind_call(self, path)
        end
      else
        old_chop_basename.bind_call(self, path)
      end
    end
  end
end

# Puppet loads init.pp, then foo.pp, to find class "mod::foo".  If
# class "mod" has been mocked using pre_condition when testing
# "mod::foo", this causes duplicate declaration for "mod".
# This monkey patch only loads "init.pp" if "foo.pp" does not exist.
class Puppet::Module
  if [:match_manifests, 'match_manifests'].any? { |r| instance_methods.include?(r) }
    old_match_manifests = instance_method(:match_manifests)

    define_method(:match_manifests) do |rest|
      result = old_match_manifests.bind_call(self, rest)
      result.shift if result.length > 1 && File.basename(result[0]) == 'init.pp'
      result
    end
  end
end

# Prevent the File type from munging paths (which uses File.expand_path to
# normalise paths, which does very bad things to *nix paths on Windows.
file_path_munge = Puppet::Type.type(:file).paramclass(:path).instance_method(:unsafe_munge)
Puppet::Type.type(:file).paramclass(:path).munge do |value|
  if RSpec::Puppet.rspec_puppet_example?
    value
  else
    file_path_munge.bind_call(self, value)
  end
end

# Prevent the Exec type from validating the user. This parameter isn't
# supported under Windows at all and only under *nix when the current user is
# root.
exec_user_validate = Puppet::Type.type(:exec).paramclass(:user).instance_method(:unsafe_validate)
Puppet::Type.type(:exec).paramclass(:user).validate do |value|
  if RSpec::Puppet.rspec_puppet_example?
    true
  else
    exec_user_validate.bind_call(self, value)
  end
end

# Stub out Puppet::Util::Windows::Security.supports_acl? if it has been
# defined. This check only makes sense when applying the catalogue to a host
# and so can be safely stubbed out for unit testing.
Puppet::Type.type(:file).provide(:windows).class_eval do
  old_supports_acl = instance_method(:supports_acl?) if respond_to?(:supports_acl?)

  def supports_acl?(_path)
    if RSpec::Puppet.rspec_puppet_example?
      true
    else
      old_supports_acl.bind_call(self, value)
    end
  end

  old_manages_symlinks = instance_method(:manages_symlinks?) if respond_to?(:manages_symlinks?)

  def manages_symlinks?
    if RSpec::Puppet.rspec_puppet_example?
      true
    else
      old_manages_symlinks.bind_call(self, value)
    end
  end
end

# Prevent Puppet from requiring 'puppet/util/windows' if we're pretending to be
# windows, otherwise it will require other libraries that probably won't be
# available on non-windows hosts.
module Kernel
  alias old_require require
  def require(path)
    return if ['puppet/util/windows',
               'win32/registry'].include?(path) && RSpec::Puppet.rspec_puppet_example? && Puppet::Util::Platform.pretend_windows?

    old_require(path)
  end
end
