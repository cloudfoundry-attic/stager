require "spec_helper"

describe VCAP::Stager::Task do
  describe "#perform" do
    before :each do
      @work_dir = Dir.mktmpdir
      @http_server = start_http_server(@work_dir)
    end

    after :each do
      @http_server.stop
      FileUtils.rm_rf(@work_dir)
    end

    it "should raise an error if the download fails" do
      # Will 404
      request = {
        "download_uri" => DummyHandler.app_download_uri(@http_server, "fake")
      }

      expect_error(request, /Failed downloading/)
    end

    it "should raise an error if unpacking the app fails" do
      app_name = "invalid_app"
      invalid_app_path = File.join(@work_dir, "#{app_name}.zip")
      File.open(invalid_app_path, "w+") { |f| f.write("garbage") }

      request = create_request(app_name)

      expect_error(request, /Failed unpacking/)
    end

    it "should raise an error if staging the application fails" do
      app_name = "sinatra_trivial"
      app_path = zip_app(@work_dir, app_name)

      # Framework/runtime mismatch. Web.xml will not be found
      request = create_request(app_name,
                               "framework_info" => {"name" => "spring", "runtimes" => ["java" => {"default" => true}],
                                               "detection" => [{"*.war" => true}]},
                               "runtime_info"   => {"name" => "java", "version" => "1.6", "executable"=> "java"})

      expect_error(request, /Staging plugin failed/)
    end

    it "should raise an error if uploading the droplet fails" do
      app_name = "sinatra_trivial"
      app_path = zip_app(@work_dir, app_name)

      request = create_request(app_name)
      # Auth will fail
      request["upload_uri"] = "http://127.0.0.1:#{@http_port}"

      expect_error(request, /Failed uploading/)
    end

    it "should return nil on success" do
      app_name = "sinatra_trivial"
      app_path = zip_app(@work_dir, app_name)
      app_tarball_path = File.join(@work_dir, "#{app_name}.tgz")

      request = create_request(app_name)
      task = VCAP::Stager::Task.new(request)

      task.perform.should be_nil

      File.exist?(app_tarball_path).should be_true
      files = `tar -ztvf #{app_tarball_path}`
      files.should match(/app\.rb/)
      files.should match(/hidden_file_in_droplet/)
    end
  end

  def expect_error(request, matcher)
    task = VCAP::Stager::Task.new(request)
    expect do
      task.perform
    end.to raise_error(matcher)
  end

  def create_request(app_name, app_props = {})
    ruby18_version =  ENV["VCAP_RUNTIME_RUBY18_VER"] || "1.8.7"
    ruby18_exec =  ENV["VCAP_RUNTIME_RUBY18"] || "/usr/bin/ruby"
    { "download_uri" => DummyHandler.app_download_uri(@http_server, app_name),
      "upload_uri" => DummyHandler.droplet_upload_uri(@http_server, app_name),
      "properties" => {
        "framework_info" => {"name" => "sinatra", "runtimes" => ["ruby18" => {"default" => true}],
                        "detection" => [{"*.rb" => "require 'sinatra'|require \"sinatra\""}]},
        "runtime_info"   => {"name" => "ruby18", "version" => ruby18_version, "executable"=> ruby18_exec},
        "services"  => [{}],
        "resources" => {
          "memory" => 128,
          "disk"   => 1024,
          "fds"    => 64,
        }
      }.merge(app_props),
    }
  end
end
