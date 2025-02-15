# frozen_string_literal: true

require 'spec_helper'

describe 'server_facts', if: Puppet::Util::Package.versioncmp(Puppet.version, '4.3.0') >= 0 do
  context 'with server_facts' do
    before do
      RSpec.configuration.trusted_server_facts = true
    end

    let(:facts) do
      {
        ipaddress: '192.168.1.10'
      }
    end
    let(:node) { 'test123.test.com' }

    it { is_expected.to contain_class('server_facts') }
    it { is_expected.to compile.with_all_deps }
    it { is_expected.to contain_notify('servername-test123.test.com') }
    it { is_expected.to contain_notify('serverip-192.168.1.10') }
    it { is_expected.to contain_notify("serverversion-#{Puppet.version}") }
    it { is_expected.to contain_notify('environment-rp_env') }
  end
end
