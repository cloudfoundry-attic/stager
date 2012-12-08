require 'schemata/staging'
require 'spec_helper'

require 'vcap/spec/forked_component/nats_server'
require 'vcap/stager/client'

describe VCAP::Stager do
  before :all do
    @task_timeout = ENV['VCAP_TEST_TASK_TIMEOUT'] || 10
    # Set this to true if you want to save the output of each component
    @save_logs = ENV['VCAP_TEST_LOG'] == 'true'
    ruby18_version =  ENV['VCAP_RUNTIME_RUBY18_VER'] || '1.8.7'
    ruby18_exec =  ENV['VCAP_RUNTIME_RUBY18'] || '/usr/bin/ruby'
    @mock_object = Schemata::Staging.mock_message
    @app_props = {
      'framework'      => @mock_object.properties['framework'],
      'framework_info' => {'name' => "sinatra", 'runtimes' => ['ruby18' => {'default' => true}],
                        'detection' => [{'*.rb' => "require 'sinatra'|require \"sinatra\""}]},
      'runtime'        => @mock_object.properties['runtime'],
      'runtime_info'   => {'name' => 'ruby18', 'version' => ruby18_version, 'executable'=> ruby18_exec},
      'services'    => [],
      'meta'        => @mock_object.properties['meta'],
      'environment' => @mock_object.properties['environment'],
      'resources'   => {
        'memory'    => 128,
        'disk'      => 1024,
        'fds'       => 64,
      },
    }
  end

  before :each do
    @tmp_dirs     = create_tmp_dirs
    @uploads      = {}
    @http_server  = start_http_server(@tmp_dirs[:http], @tmp_dirs)
    @nats_server  = start_nats(@tmp_dirs[:nats])
    @stager       = start_stager(@nats_server.port,
                                 @tmp_dirs[:stager])
  end

  after :each do
    @stager.stop
    @http_server.stop
    @nats_server.stop
    if @save_logs
      puts "Logs saved under #{@tmp_dirs[:base]}"
    else
      FileUtils.rm_rf(@tmp_dirs[:base])
    end
  end

  describe 'on success' do
    it 'it should post a bundled droplet to the callback uri' do
      app_name = "sinatra_trivial"

      zip_app(@tmp_dirs[:download], app_name)

      request = @mock_object
      request.properties = @app_props
      request.download_uri = DummyHandler.app_download_uri(@http_server, app_name)
      request.upload_uri = DummyHandler.droplet_upload_uri(@http_server, app_name)

      task_result = wait_for_task_result(@nats_server.uri, request.contents)

      task_result["error"].should be_nil
    end
  end

  def create_tmp_dirs
    tmp_dirs = { :base => Dir.mktmpdir("stager_functional_tests") }
    for d in [:upload, :download, :nats, :stager, :http]
      tmp_dirs[d] = File.join(tmp_dirs[:base], d.to_s)
      Dir.mkdir(tmp_dirs[d])
    end
    tmp_dirs
  end

  def start_nats(nats_dir)
    port = VCAP.grab_ephemeral_port
    pid_file = File.join(nats_dir, 'nats.pid')
    nats = VCAP::Spec::ForkedComponent::NatsServer.new(pid_file, port, nats_dir)
    nats.start.wait_ready.should be_true
    nats
  end

  def start_stager(nats_port, stager_dir)
    stager = VCAP::Stager::Spec::ForkedStager.new(nats_port, stager_dir)
    ready = false
    NATS.start(:uri => "nats://127.0.0.1:#{nats_port}") do
      EM.add_timer(30) { EM.stop }
      NATS.subscribe('vcap.component.announce') do
        ready = true
        EM.stop
      end
      NATS.publish('zazzle', "BLAH")
      stager.start
    end
    ready.should be_true
    stager
  end

  def wait_for_task_result(nats_uri, request)
    ret = nil

    NATS.start(:uri => nats_uri) do
      client = VCAP::Stager::Client::EmAware.new(NATS.client, "staging")

      # The client also uses schemata to validate messages
      deferrable = client.stage(request, 30)

      deferrable.callback do |r|
        ret = r
        NATS.stop
      end

      deferrable.errback do |e|
        ret = { "error" => e }
        NATS.stop
      end
    end

    ret
  end
end
