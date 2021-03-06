require 'spec_helper'
require 'bosh/registry/client'

describe Bosh::AwsCloud::InstanceManager do
  subject(:instance_manager) { described_class.new(region, registry, elb, az_selector, logger) }
  let(:region) { mock_ec2 }
  let(:registry) { double('Bosh::Registry::Client', :endpoint => 'http://...', :update_settings => nil) }
  let(:elb) { double('AWS::ELB') }
  let(:az_selector) { instance_double('Bosh::AwsCloud::AvailabilityZoneSelector', common_availability_zone: 'us-east-1a') }
  let(:logger) { Logger.new('/dev/null') }

  describe '#create' do
    before { allow(region).to receive(:subnets).and_return('sub-123456' => fake_aws_subnet) }
    let(:fake_aws_subnet) { instance_double('AWS::EC2::Subnet').as_null_object }

    let(:aws_instance_params) do
      {
        count: 1,
        image_id: 'stemcell-id',
        instance_type: 'm1.small',
        user_data: '{"registry":{"endpoint":"http://..."},"dns":{"nameserver":"foo"}}',
        key_name: 'bar',
        security_groups: ['baz'],
        subnet: fake_aws_subnet,
        private_ip_address: '1.2.3.4',
        availability_zone: 'us-east-1a'
      }
    end

    before { allow(region).to receive(:instances).and_return(aws_instances) }
    let(:aws_instances) { instance_double('AWS::EC2::InstanceCollection') }

    let(:aws_instance) { instance_double('AWS::EC2::Instance', id: 'i-12345678') }
    let(:aws_client) { double(AWS::EC2::Client) }

    it 'should ask AWS to create an instance in the given region, with parameters built up from the given arguments' do
      expect(aws_instances).to receive(:create).with(aws_instance_params).and_return(aws_instance)
      allow(Bosh::AwsCloud::ResourceWait).to receive(:for_instance).with(instance: aws_instance, state: :running)

      agent_id = 'agent-id'
      stemcell_id = 'stemcell-id'
      resource_pool = {'instance_type' => 'm1.small', 'key_name' => 'bar'}
      networks_spec = {
        'default' => {
          'type' => 'dynamic',
          'dns' => 'foo',
          'cloud_properties' => {'security_groups' => 'baz'}
        },
        'other' => {
          'type' => 'manual',
          'cloud_properties' => {'subnet' => 'sub-123456'},
          'ip' => '1.2.3.4'
        }
      }
      disk_locality = nil
      environment = nil
      options = {'aws' => {'region' => 'us-east-1'}}
      instance_manager.create(agent_id, stemcell_id, resource_pool, networks_spec, disk_locality, environment, options)
    end

    it 'should ask AWS to create a SPOT instance in the given region, when resource_pool includes spot_bid_price' do
      allow(region).to receive(:client).and_return(aws_client)
      allow(region).to receive(:subnets).and_return('sub-123456' => fake_aws_subnet)
      allow(region).to receive(:instances).and_return('i-12345678' => aws_instance)

      # need to translate security group names to security group ids
      sg1 = instance_double('AWS::EC2::SecurityGroup', security_group_id:'sg-baz-1234')
      allow(sg1).to receive(:name).and_return('baz')
      allow(region).to receive(:security_groups).and_return([sg1])

      agent_id = 'agent-id'
      stemcell_id = 'stemcell-id'
      networks_spec = {
        'default' => {
          'type' => 'dynamic',
          'dns' => 'foo',
          'cloud_properties' => {'security_groups' => 'baz'}
        },
        'other' => {
          'type' => 'manual',
          'cloud_properties' => {'subnet' => 'sub-123456'},
          'ip' => '1.2.3.4'
        }
      }
      disk_locality = nil
      environment = nil
      options = {'aws' => {'region' => 'us-east-1'}}

      # NB: The spot_bid_price param should trigger spot instance creation
      resource_pool = {'spot_bid_price'=>0.15, 'instance_type' => 'm1.small', 'key_name' => 'bar'}

      # Should not recieve an ondemand instance create call
      expect(aws_instances).to_not receive(:create).with(aws_instance_params)

      #Should rather recieve a spot instance request
      expect(aws_client).to receive(:request_spot_instances) do |spot_request|
        expect(spot_request[:spot_price]).to eq('0.15')
        expect(spot_request[:instance_count]).to eq(1)
        expect(spot_request[:launch_specification]).to eq({
          :image_id=>'stemcell-id',
          :key_name=>'bar',
          :instance_type=>'m1.small',
          :user_data=>Base64.encode64('{"registry":{"endpoint":"http://..."},"dns":{"nameserver":"foo"}}'),
          :placement=> { :availability_zone=>'us-east-1a' },
          :network_interfaces=>[ {
            :subnet_id=>fake_aws_subnet,
            :groups=>['sg-baz-1234'],
            :device_index=>0,
            :private_ip_address=>'1.2.3.4'
          }]
        })

        # return
        {
          :spot_instance_request_set => [ { :spot_instance_request_id=>'sir-12345c', :other_params_here => 'which are not used' }],
          :request_id => 'request-id-12345'
        }
      end

      # Should poll the spot instance request until state is active
      expect(aws_client).to receive(:describe_spot_instance_requests).
        with(:spot_instance_request_ids=>['sir-12345c']).
        and_return(:spot_instance_request_set => [{:state => 'active', :instance_id=>'i-12345678'}])

      # Should then wait for instance to be running, just like in the case of on deman
      expect(Bosh::AwsCloud::ResourceWait).to receive(:for_instance).with(instance: aws_instance, state: :running)

      # Trigger spot instance request
      instance_manager.create(agent_id, stemcell_id, resource_pool, networks_spec, disk_locality, environment, options)
    end

    it 'should retry creating the VM when AWS::EC2::Errors::InvalidIPAddress::InUse raised' do
      allow(region).to receive(:subnets).and_return('sub-123456' => fake_aws_subnet)

      expect(aws_instances).to receive(:create).with(aws_instance_params).and_raise(AWS::EC2::Errors::InvalidIPAddress::InUse)
      expect(aws_instances).to receive(:create).with(aws_instance_params).and_return(aws_instance)
      allow(Bosh::AwsCloud::ResourceWait).to receive(:for_instance).with(instance: aws_instance, state: :running)

      allow(instance_manager).to receive(:instance_create_wait_time).and_return(0)

      agent_id = 'agent-id'
      stemcell_id = 'stemcell-id'
      resource_pool = {'instance_type' => 'm1.small', 'key_name' => 'bar'}
      networks_spec = {
        'default' => {
          'type' => 'dynamic',
          'dns' => 'foo',
          'cloud_properties' => {'security_groups' => 'baz'}
        },
        'other' => {
          'type' => 'manual',
          'cloud_properties' => {'subnet' => 'sub-123456'},
          'ip' => '1.2.3.4'
        }
      }
      disk_locality = nil
      environment = nil
      options = {'aws' => {'region' => 'us-east-1'}}
      instance_manager.create(agent_id, stemcell_id, resource_pool, networks_spec, disk_locality, environment, options)
    end

    context 'when waiting it to become running fails' do
      before { expect(instance).to receive(:wait_for_running).and_raise(create_err) }
      let(:create_err) { StandardError.new('fake-err') }

      before { allow(Bosh::AwsCloud::Instance).to receive(:new).and_return(instance) }
      let(:instance) { instance_double('Bosh::AwsCloud::Instance', id: 'fake-instance-id') }

      before { expect(aws_instances).to receive(:create).and_return(aws_instance) }

      it 'terminates created instance and re-raises the error if ' do
        expect(instance).to receive(:terminate).with(no_args)

        expect {
          instance_manager.create('fake-agent-id', 'fake-stemcell-id', {}, {}, nil, nil, {'aws' => {}})
        }.to raise_error(create_err)
      end

      context 'when termination of created instance fails' do
        before { allow(instance).to receive(:terminate).and_raise(StandardError.new('fake-terminate-err')) }

        it 're-raises creation error' do
          expect {
            instance_manager.create('fake-agent-id', 'fake-stemcell-id', {}, {}, nil, nil, {'aws' => {}})
          }.to raise_error(create_err)
        end
      end
    end

    context 'when attaching instance to load balancers fails' do
      before { expect(instance).to receive(:attach_to_load_balancers).and_raise(lb_err) }
      let(:lb_err) { StandardError.new('fake-err') }

      before { allow(Bosh::AwsCloud::Instance).to receive(:new).and_return(instance) }
      let(:instance) { instance_double('Bosh::AwsCloud::Instance', id: 'fake-instance-id', wait_for_running: nil) }

      before { expect(aws_instances).to receive(:create).and_return(aws_instance) }

      it 'terminates created instance and re-raises the error' do
        expect(instance).to receive(:terminate).with(no_args)

        expect {
          instance_manager.create('fake-agent-id', 'fake-stemcell-id', {}, {}, nil, nil, {'aws' => {}})
        }.to raise_error(lb_err)
      end

      context 'when termination of created instance fails' do
        before { allow(instance).to receive(:terminate).and_raise(StandardError.new('fake-terminate-err')) }

        it 're-raises creation error' do
          expect {
            instance_manager.create('fake-agent-id', 'fake-stemcell-id', {}, {}, nil, nil, {'aws' => {}})
          }.to raise_error(lb_err)
        end
      end
    end
  end

  describe '#find' do
    before { allow(region).to receive(:instances).and_return(instance_id => aws_instance) }
    let(:aws_instance) { instance_double('AWS::EC2::Instance', id: instance_id) }
    let(:instance_id) { 'fake-id' }

    it 'returns found instance (even though it might not exist)' do
      instance = instance_double('Bosh::AwsCloud::Instance')

      allow(Bosh::AwsCloud::Instance).to receive(:new).
        with(aws_instance, registry, elb, logger).
        and_return(instance)

      expect(instance_manager.find(instance_id)).to eq(instance)
    end
  end

  describe 'setting instance parameters' do
    let(:instance_params) { {} }

    describe '#set_key_name_parameter' do
      it 'should set the key name instance parameter to the first non-null argument' do
        instance_manager.set_key_name_parameter(instance_params, 'foo', nil)
        expect(instance_params[:key_name]).to eq('foo')

        instance_manager.set_key_name_parameter(instance_params, nil, 'bar')
        expect(instance_params[:key_name]).to eq('bar')
      end

      it 'should not have a key name instance parameter if it receives only null arguments' do
        instance_manager.set_key_name_parameter(instance_params, nil, nil)
        expect(instance_params.keys).to_not include(:key_name)
      end
    end

    describe '#set_security_groups_parameter' do
      context 'when the networks specs have security groups' do
        it 'returns a unique list of the specified group names' do
          instance_manager.set_security_groups_parameter(
            instance_params,
            {
              'network' => {'cloud_properties' => {'security_groups' => 'yay'}},
              'artwork' => {'cloud_properties' => {'security_groups' => ['yay', 'aya']}}
            },
            ['default_1', 'default_2']
          )

          expect(instance_params[:security_groups].size).to eq(2)
          expect(instance_params[:security_groups]).to include('yay', 'aya')
        end
      end

      context 'when the networks specs have no security groups specified' do
        it 'returns the list of default AWS group names' do
          instance_manager.set_security_groups_parameter(
            instance_params,
            {'network' => {'cloud_properties' => {'foo' => 'bar'}}},
            ['default_1', 'default_2'],
          )

          expect(instance_params[:security_groups].size).to eq(2)
          expect(instance_params[:security_groups]).to include('default_1', 'default_2')
        end
      end
    end

    describe '#set_vpc_parameters' do
      let(:fake_aws_subnet) { instance_double('AWS::EC2::Subnet') }

      before { allow(region).to receive(:subnets).and_return('sub-123456' => fake_aws_subnet) }

      context 'when there is not a manual network in the specs' do
        it 'should not set the private IP address parameters' do
          instance_manager.set_vpc_parameters(
            instance_params,
            'network' => {
              'type' => 'designed by robots',
              'ip' => '1.2.3.4',
            },
          )

          expect(instance_params.keys).to_not include(:private_ip_address)
        end
      end

      context 'when there is a manual network in the specs' do
        it 'should set the private IP address parameters' do
          instance_manager.set_vpc_parameters(
            instance_params,
            'network' => {
              'type' => 'manual',
              'ip' => '1.2.3.4',
            },
          )

          expect(instance_params[:private_ip_address]).to eq('1.2.3.4')
        end
      end

      context 'when there is a network in the specs with unspecified type' do
        it 'should set the private IP address parameters for that network (treat it as manual)' do
          instance_manager.set_vpc_parameters(
            instance_params,
            'network' => {
              'ip' => '1.2.3.4',
              'cloud_properties' => {'subnet' => 'sub-123456'},
            },
          )

          expect(instance_params[:private_ip_address]).to eq('1.2.3.4')
        end
      end

      context 'when there is a subnet in the cloud_properties in the specs' do
        context 'and network type is dynamic' do
          it 'should set the subnet parameter' do
            instance_manager.set_vpc_parameters(
              instance_params,
              'network' => {
                'type' => 'dynamic',
                'cloud_properties' => {'subnet' => 'sub-123456'},
              },
            )

            expect(instance_params.keys).to include(:subnet)
          end
        end

        context 'and network type is manual' do
          it 'should set the subnet parameter' do
            instance_manager.set_vpc_parameters(
              instance_params,
              'network' => {
                'type' => 'manual',
                'cloud_properties' => {'subnet' => 'sub-123456'},
              },
            )

            expect(instance_params.keys).to include(:subnet)
          end
        end

        context 'and network type is not set' do
          it 'should set the subnet parameter' do
            instance_manager.set_vpc_parameters(
              instance_params,
              'network' => {
                'cloud_properties' => {'subnet' => 'sub-123456'},
              },
            )

            expect(instance_params.keys).to include(:subnet)
          end
        end

        context 'and network type is vip' do
          it 'should not set the subnet parameter' do
            instance_manager.set_vpc_parameters(
              instance_params,
              'network' => {
                'type' => 'vip',
                'cloud_properties' => {'subnet' => 'sub-123456'},
              },
            )

            expect(instance_params.keys).to_not include(:subnet)
          end
        end
      end

      context 'when there is no subnet in the cloud_properties in the specs' do
        it 'should not set the subnet parameter' do
          instance_manager.set_vpc_parameters(instance_params, 'network' => { 'type' => 'dynamic' })
          expect(instance_params.keys).to_not include(:subnet)
        end
      end
    end

    describe '#set_availability_zone_parameter' do
      let(:az_selector) { instance_double('Bosh::AwsCloud::AvailabilityZoneSelector') }

      context 'if there is a common availability zone specified' do
        before { allow(az_selector).to receive(:common_availability_zone).and_return('fake-zone') }

        it 'sets the availability zone parameter appropriately' do
          instance_manager.set_availability_zone_parameter(instance_params, ['fake-zone'], nil, 'fake-zone')
          expect(instance_params[:availability_zone]).to eq('fake-zone')
        end
      end

      context 'if there is no common availability zone' do
        before { allow(az_selector).to receive(:common_availability_zone).and_return(nil) }

        it 'does not set the availability zone parameter' do
          instance_manager.set_availability_zone_parameter(instance_params, [], nil, nil)
          expect(instance_params.keys).to_not include(:availability_zone)
        end
      end
    end

    describe '#set_user_data_parameter' do
      context 'when a dns configuration is provided' do
        it 'populates the user data parameter with registry and dns data' do
          instance_manager.set_user_data_parameter(instance_params, 'foo' => {'dns' => 'bar'})
          expect(instance_params[:user_data]).
             to eq('{"registry":{"endpoint":"http://..."},"dns":{"nameserver":"bar"}}')
        end
      end

      context 'when a dns configuration is not provided' do
        it 'populates the user data parameter with only the registry data' do
          instance_manager.set_user_data_parameter(instance_params, 'foo' => {'no_dns' => 'bar'})
          expect(instance_params[:user_data]).
            to eq('{"registry":{"endpoint":"http://..."}}')
        end
      end
    end
  end
end
